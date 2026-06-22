#!/usr/bin/env bash
# =============================================================================
# list_offers.sh — Browse live Vast.ai offers and estimate $/replica, then let
# you pick one. Writes the choice to cloud_selection.env (consumed by
# run_cloud_replica.sh) as SkyPilot resource constraints.
#
# NOTE on "picking a node": SkyPilot cannot pin one exact physical Vast offer —
# at launch it takes the first live offer matching GPU type + region + price.
# So your pick is translated into (accelerator, country, price-ceiling, on-demand
# /spot); SkyPilot then lands the best live match. The exact offer id you choose
# is recorded for reference but is not guaranteed to be the physical host.
#
# Env knobs (all optional):
#   GPU_NAMES   comma list of Vast gpu_name tokens (default "RTX_4090")
#               e.g. "RTX_4090,RTX_3090"  or  "A100_SXM4,A100_PCIE"
#   TYPE        on-demand | bid           (default on-demand; bid=interruptible)
#   DISK_GB     disk to price & require   (default 120)
#   MIN_RELIAB  minimum reliability        (default 0.95)
#   MIN_INET    minimum inet_down Mb/s     (default 100)
#   MIN_CUDA    minimum cuda_vers          (default 12.0)
#   COUNTRIES   comma list to restrict, e.g. "US,CA,DE" (default: any)
#   TOTAL_NS    ns for the full run        (default 750)
#   STAGE_NS    ns per stage               (default 50)
#   TOPN        rows to show               (default 12)
#   PICK        non-interactive choice: a row number (1..) or an offer id
# =============================================================================
set -euo pipefail
export LC_ALL=C LANG=C

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
VASTAI="${VASTAI:-vastai}"
command -v "$VASTAI" >/dev/null 2>&1 || { echo "ERROR: vastai CLI not found. Run cloud_setup.sh first."; exit 1; }

GPU_NAMES="${GPU_NAMES:-RTX_4090}"
TYPE="${TYPE:-on-demand}"
DISK_GB="${DISK_GB:-120}"
MIN_RELIAB="${MIN_RELIAB:-0.95}"
MIN_INET="${MIN_INET:-100}"
MIN_CUDA="${MIN_CUDA:-12.0}"
COUNTRIES="${COUNTRIES:-}"
TOTAL_NS="${TOTAL_NS:-750}"
STAGE_NS="${STAGE_NS:-50}"
TOPN="${TOPN:-12}"
PICK="${PICK:-}"
SEL_FILE="${SEL_FILE:-$HERE/cloud_selection.env}"

# ---- build the vastai query ----
gpu_list="[$(echo "$GPU_NAMES" | sed 's/ //g')]"
query="num_gpus=1 reliability>${MIN_RELIAB} cuda_vers>=${MIN_CUDA} inet_down>=${MIN_INET} disk_space>=${DISK_GB} rentable=true rented=false verified=true gpu_name in ${gpu_list}"
if [ -n "$COUNTRIES" ]; then
  query="$query geolocation in [$(echo "$COUNTRIES" | sed 's/ //g')]"
fi

case "$TYPE" in
  bid|interruptible|spot) type_flag="--type bid";       USE_SPOT=true ;;
  *)                      type_flag="--type on-demand"; USE_SPOT=false ;;
esac

echo "Querying Vast.ai offers…"
echo "  filter : $query"
echo "  pricing: $TYPE   storage=${DISK_GB}GiB"
RAW="$(mktemp)"; trap 'rm -f "$RAW"' EXIT
if ! "$VASTAI" search offers "$query" $type_flag --storage "$DISK_GB" -o 'dph_total' --raw > "$RAW" 2>/tmp/vastai_err.txt; then
  echo "ERROR: vastai search failed:"; cat /tmp/vastai_err.txt; exit 1
fi

USE_SPOT="$USE_SPOT" GPU_NAMES="$GPU_NAMES" TOTAL_NS="$TOTAL_NS" STAGE_NS="$STAGE_NS" \
TOPN="$TOPN" PICK="$PICK" DISK_GB="$DISK_GB" TYPE="$TYPE" SEL_FILE="$SEL_FILE" \
python3 - "$RAW" <<'PY'
import json, os, re, sys

raw = json.load(open(sys.argv[1]))
if not isinstance(raw, list):
    raw = raw.get("offers", raw) if isinstance(raw, dict) else []
TOTAL_NS = float(os.environ["TOTAL_NS"]); STAGE_NS = float(os.environ["STAGE_NS"])
TOPN = int(os.environ["TOPN"]); USE_SPOT = os.environ["USE_SPOT"] == "true"
PICK = os.environ.get("PICK", "").strip()
SEL_FILE = os.environ["SEL_FILE"]; DISK_GB = os.environ["DISK_GB"]; TYPE = os.environ["TYPE"]

# Per-replica wall-time also includes provisioning + GROMACS install + EM/NVT/NPT;
# add a fixed overhead so the estimate isn't biased low (R2/bandwidth excluded).
SETUP_H = 1.0

# Map a Vast gpu_name to the SkyPilot accelerator token, mirroring SkyPilot's
# Vast catalog fetcher (sky/catalog/data_fetchers/fetch_vast.py): strip spaces,
# Ada->-Ada, drop trailing Ti|PCIE|SXM4|SXM|NVL and the RTXddd0 S/D suffix, and
# map Tesla/Quadro names. Resolution is an anchored fullmatch, so e.g.
# "A100 SXM4"->"A100", "H100 NVL"->"H100", "RTX 3090 Ti"->"RTX3090".
def normalize_accel(name):
    g = re.sub(r"\s", "", name or "")
    g = re.sub("Ada", "-Ada", g)
    g = re.sub(r"(Ti|PCIE|SXM4|SXM|NVL)$", "", g)
    g = re.sub(r"(RTX\d0\d0)(S|D)$", r"\1", g)
    return {"TeslaV100": "V100", "TeslaT4": "T4", "TeslaP100": "P100",
            "QRTX6000": "RTX6000", "QRTX8000": "RTX8000"}.get(g, g)

# Re-baselined throughput for the REAL ~88-93k-atom pMHC box, single precision,
# CPU update + all-bonds LINCS (no -update gpu). With update on the CPU the run
# is CPU/PCIe-bound, so high-end datacenter cards cluster nearer the 4090 than a
# GPU-bound benchmark would suggest. ROUGH — refine with the POC self-benchmark.
# Keyed by NORMALIZED accelerator token. Units: ns/day on one GPU.
NSDAY = {
    "RTX4090": 185, "RTX4080": 150, "RTX3090": 120, "RTX3080": 95,
    "RTXA6000": 150, "A40": 150, "L40S": 200, "L40": 185,
    "A100": 195, "A100-80GB": 200, "H100": 220, "H200": 230, "V100": 90,
}
def nsday_for(name):
    n = normalize_accel(name)
    if n in NSDAY: return NSDAY[n]
    for k, v in NSDAY.items():
        if n.startswith(re.split(r"[-]", k)[0][:4]):  # crude family fallback
            return v
    return 120

def g(o, *keys, default=None):
    for k in keys:
        if k in o and o[k] is not None:
            return o[k]
    return default

rows = []
for o in raw:
    dph = g(o, "dph_total", "dph", default=None)
    if dph is None:
        continue
    name = g(o, "gpu_name", default="?")
    nsday = nsday_for(name)
    wall_h_total = TOTAL_NS / nsday * 24.0 + SETUP_H
    wall_h_stage = STAGE_NS / nsday * 24.0
    rows.append({
        "id": g(o, "id", "ask_contract_id", default="?"),
        "gpu": name,
        "ngpu": g(o, "num_gpus", default=1),
        "dph": float(dph),
        "reliab": float(g(o, "reliability", "reliability2", default=0) or 0),
        "cuda": g(o, "cuda_max_good", "cuda_vers", default="?"),
        "inet": g(o, "inet_down", default=0),
        "dlperf": g(o, "dlperf", default=0),
        "geo": g(o, "geolocation", default="?"),
        "minbid": g(o, "min_bid", default=None),
        "nsday": nsday,
        "est_total": float(dph) * wall_h_total,
        "est_days": wall_h_total / 24.0,
        "est_stage": float(dph) * wall_h_stage,
    })

rows.sort(key=lambda r: r["dph"])
rows = rows[:TOPN]
if not rows:
    print("\nNo offers matched. Loosen filters (GPU_NAMES / MIN_RELIAB / COUNTRIES).")
    sys.exit(2)

hdr = f'{"#":>2}  {"offer_id":>10}  {"gpu":<14}{"$/hr":>7}  {"relia":>5}  {"cuda":>5}  {"inet":>6}  {"~ns/d":>5}  {"~days":>5}  {"~$/stage":>8}  {"~$/replica":>10}  {"geo":>3}'
print("\n" + hdr); print("-" * len(hdr))
for i, r in enumerate(rows, 1):
    print(f'{i:>2}  {str(r["id"]):>10}  {r["gpu"][:14]:<14}{r["dph"]:>7.3f}  {r["reliab"]:>5.2f}  {str(r["cuda"]):>5}  {str(r["inet"]):>6}  {r["nsday"]:>5}  {r["est_days"]:>5.1f}  {r["est_stage"]:>8.2f}  {r["est_total"]:>10.2f}  {str(r["geo"]):>3}')
print(f'\nEstimates assume ~{rows[0]["nsday"]} ns/day-class throughput on a ~90k-atom box '
      f'({"INTERRUPTIBLE/spot" if USE_SPOT else "on-demand"} pricing, {DISK_GB} GiB disk).')
print("Cost = $/hr x wall-hours; wall-hours = ns / (ns/day) x 24. ROUGH — the POC self-benchmark refines ns/day.")

# ---- selection ----
def write_selection(r):
    accel = normalize_accel(r["gpu"])  # Vast gpu_name -> SkyPilot catalog accel token
    # price ceiling = a GENEROUS safety cap, not a selector. SkyPilot provisions
    # from its own (cached) Vast catalog whose prices can sit above the cheapest
    # live offer, so a tight cap (e.g. live x1.2) makes provisioning fail
    # ("no resource satisfying ... max_cost"). Use ~2.5x the picked price (with a
    # floor) so the catalog has headroom while still capping runaway prices.
    # Override with env MAX_HOURLY=<$/hr> (or MAX_HOURLY=0 to remove the cap).
    _mh = os.environ.get("MAX_HOURLY", "").strip()
    if _mh == "0":
        ceiling = ""                                   # no cap
    elif _mh:
        ceiling = round(float(_mh), 3)
    else:
        ceiling = round(max(r["dph"] * 2.5, r["dph"] + 0.40), 3)
    # Do NOT pin region: SkyPilot validates `region` by exact match against the
    # catalog's full Region strings (e.g. "Germany, DE, EU"), not the offer's
    # short geolocation, so any pin tends to fail and over-constrains FAILOVER.
    # Restrict by country via the COUNTRIES filter on the query instead.
    geo = ""
    with open(SEL_FILE, "w") as fh:
        fh.write(f'# Written by list_offers.sh — picked offer {r["id"]} ({r["gpu"]} @ ${r["dph"]}/hr, {r["geo"]})\n')
        fh.write(f'SEL_ACCEL="{accel}:1"\n')
        fh.write(f'SEL_USE_SPOT="{str(USE_SPOT).lower()}"\n')
        fh.write(f'SEL_MAX_HOURLY="{ceiling}"\n')
        fh.write(f'SEL_REGION="{geo}"\n')
        fh.write(f'SEL_DISK_GB="{DISK_GB}"\n')
        fh.write(f'SEL_OFFER_ID="{r["id"]}"\n')
        fh.write(f'SEL_EST_TOTAL="{r["est_total"]:.2f}"\n')
        fh.write(f'SEL_EST_DAYS="{r["est_days"]:.1f}"\n')
    print(f'\n✓ Selection written to {SEL_FILE}:')
    print(f'    GPU={accel}:1   spot={str(USE_SPOT).lower()}   max $/hr={ceiling}   region={geo or "(any)"}')
    print(f'    est ~${r["est_total"]:.0f} over ~{r["est_days"]:.1f} days for {int(TOTAL_NS)} ns')
    print(f'    (reference offer id {r["id"]})')

choice = None
if PICK:
    if PICK.isdigit() and 1 <= int(PICK) <= len(rows):
        choice = rows[int(PICK) - 1]
    else:
        choice = next((r for r in rows if str(r["id"]) == PICK), None)
    if choice is None:
        print(f"\nPICK='{PICK}' did not match a row number or listed offer id."); sys.exit(3)
else:
    try:
        sel = input(f"\nPick a row 1-{len(rows)} (or blank to cancel): ").strip()
    except EOFError:
        sel = ""
    if not sel:
        print("Cancelled — no selection written."); sys.exit(0)
    if not (sel.isdigit() and 1 <= int(sel) <= len(rows)):
        print("Invalid choice."); sys.exit(3)
    choice = rows[int(sel) - 1]

write_selection(choice)
PY
