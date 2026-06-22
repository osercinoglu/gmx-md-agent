#!/usr/bin/env bash
# =============================================================================
# run_replica.sh - One-shot independent MD replica runner for pMHC systems.
#
# Pipeline (all stages, in order; no intermediate checks required):
#   1. Energy minimization (steepest descent)
#   2. NVT  equilibration (1 ns, gen_seed=-1  -> random initial velocities)
#   3. NPT  equilibration (1 ns, C-rescale barostat)
#   4. Production (15 x 50 ns = 750 ns, dt=2 fs, no HMR, continuation via -cpi)
#   5. Analysis prep:  trjcat -> whole -> nojump -> center -> fit -> dry,
#                      reference + final PDB with chain IDs A/B/C restored.
#
# Required files in this folder (placed by prep_replicas.sh):
#   solvated_ions.pdb, topol.top, topol_Protein_chain_{A,B,C}.itp,
#   posre_Protein_chain_{A,B,C}.itp, index.ndx,
#   mdp/{minim,nvt,npt,md_50ns}.mdp,
#   pushover.sh, add_chain_ids.py
#
# Notifications: every 10% of total progress via Pushover.
#   Credentials read from $HOME/.pushover/pushover-config (akusei format),
#   or override via env: PUSHOVER_TOKEN, PUSHOVER_USER, PUSHOVER_DEVICE.
# =============================================================================

set -euo pipefail
# Force C locale so awk/printf use '.' (not ',') as the decimal separator —
# needed for the progress arithmetic below.
export LC_ALL=C LANG=C

# ====================== USER CONFIG (edit if needed) =========================
GMX="${GMX:-/home/tugba/gromacs-2024.2-gpu/bin/gmx}"   # GROMACS executable
NT="${NT:-12}"                                          # OpenMP threads
GPU_ID="${GPU_ID:-0}"                                   # CUDA device id
MAXH_PER_STAGE="${MAXH_PER_STAGE:-48}"                  # wall-clock cap per stage (h)
TOTAL_NS=750
STAGE_NS=50
# pushover: leave defaults to read ~/.pushover/pushover-config
PUSHOVER_TOKEN="${PUSHOVER_TOKEN:-}"
PUSHOVER_USER="${PUSHOVER_USER:-}"
PUSHOVER_DEVICE="${PUSHOVER_DEVICE:-}"
# =============================================================================

# Operate on the REPLICA directory (1st arg, else the current dir) — NOT where
# this script file happens to live. This lets you run a central copy against a
# folder (bash /path/run_replica.sh <replica_dir>) or from inside it (cd dir;
# bash .../run_replica.sh). NOTHING is copied into the replica dir: helper files
# (mdp/, pushover.sh, add_chain_ids.py) are read from the SCRIPT's own dir, so
# the script lives in ONE place and runs against any folder of sim inputs.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
HERE="$(cd "${1:-$PWD}" 2>/dev/null && pwd)" || { echo "ERROR: replica dir '${1:-$PWD}' not found"; exit 1; }
cd "$HERE"
REPLICA_TAG="$(basename "$HERE")"

# Guard: refuse to run (and silently "start over") in a non-replica dir.
_have_struct=0
for _s in solvated_ions.pdb *.gro *.pdb; do [ -f "$_s" ] && { _have_struct=1; break; }; done
if [ ! -f topol.top ] || [ "$_have_struct" = 0 ]; then
  echo "ERROR: '$HERE' is not a replica dir (need topol.top + a structure .pdb/.gro)."
  echo "  Run from INSIDE a replica dir, or: bash <path>/run_replica.sh <replica_dir>"
  exit 1
fi
# Central helpers (never copied into the replica dir). mdp: prefer a folder-local
# mdp/ if one exists (per-replica overrides), else the script's shared mdp/.
MDP_DIR="$( [ -d "$HERE/mdp" ] && echo "$HERE/mdp" || echo "$SCRIPT_DIR/mdp" )"
ADD_CHAIN="$SCRIPT_DIR/add_chain_ids.py"
PUSHOVER_SH="$SCRIPT_DIR/pushover.sh"

RUN_LOG="$HERE/run_replica.log"
exec > >(tee -a "$RUN_LOG") 2>&1

N_STAGES=$(( TOTAL_NS / STAGE_NS ))     # 15 production parts
PUSHOVER_CONFIG="${PUSHOVER_CONFIG:-$HOME/.pushover/pushover-config}"

# Source pushover config (akusei format defines api_token / user_key)
if [ -f "$PUSHOVER_CONFIG" ]; then
  # shellcheck disable=SC1090
  source "$PUSHOVER_CONFIG"
fi
PUSHOVER_TOKEN="${PUSHOVER_TOKEN:-${api_token:-${api_key:-}}}"
PUSHOVER_USER="${PUSHOVER_USER:-${user_key:-}}"

# ------------------------- Pushover -------------------------
notify() {
  local msg="$1" title="${2:-$REPLICA_TAG}" priority="${3:-0}"
  if [ -x "$PUSHOVER_SH" ] && [ -n "$PUSHOVER_TOKEN" ] && [ -n "$PUSHOVER_USER" ]; then
    bash "$PUSHOVER_SH" \
      -t "$PUSHOVER_TOKEN" -u "$PUSHOVER_USER" \
      -T "$title" -p "$priority" \
      ${PUSHOVER_DEVICE:+-d "$PUSHOVER_DEVICE"} \
      "$msg" >/dev/null 2>&1 || true
  fi
}

# ------------------------- Progress -------------------------
# Weights sum to 100. Equilibration = 10%, production = 85%, analysis = 5%.
W_MIN=2
W_NVT=3
W_NPT=5
W_ANALYSIS=5
W_PROD_TOTAL=$((100 - W_MIN - W_NVT - W_NPT - W_ANALYSIS))     # = 85

PROGRESS=0
LAST_NOTIFIED=0
STAGE_NAME="(init)"

bar() {
  local pct=$1
  local width=40
  local fill empty
  fill=$(awk "BEGIN{printf \"%d\", $width * $pct / 100}")
  empty=$(( width - fill ))
  local f="" e=""
  for ((i=0;i<fill;i++));  do f="${f}#"; done
  for ((i=0;i<empty;i++)); do e="${e}-"; done
  printf "[%s%s] %5.1f%% — %s\n" "$f" "$e" "$pct" "$STAGE_NAME"
}

advance() {
  local delta=$1
  PROGRESS=$(awk "BEGIN{printf \"%.2f\", $PROGRESS + $delta}")
  bar "$PROGRESS"
  local pct_int=${PROGRESS%.*}
  local milestone=$(( (pct_int / 10) * 10 ))
  if [ "$milestone" -gt "$LAST_NOTIFIED" ] && [ "$milestone" -ge 10 ]; then
    notify "$REPLICA_TAG: ${milestone}% — last completed: ${STAGE_NAME}" \
           "$REPLICA_TAG ${milestone}%" 0
    LAST_NOTIFIED=$milestone
  fi
}

stage_banner() {
  STAGE_NAME="$1"
  echo
  echo "============================================================================"
  echo "[$(date '+%F %T')] STAGE: $STAGE_NAME"
  echo "============================================================================"
}

on_failure() {
  echo
  echo "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
  echo "[$(date '+%F %T')] FAILED at stage: $STAGE_NAME"
  echo "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
  notify "FAILED at: $STAGE_NAME (see $RUN_LOG)" "$REPLICA_TAG ❌" 1
}
trap on_failure ERR

# ------------------------- GROMACS helpers -------------------------
GROMPP() {
  # $1: mdp  $2: -c coord  $3: output tpr (deffnm.tpr)  $4 (optional): -t cpt
  local mdp="$1" coord="$2" tpr="$3" cpt="${4:-}"
  "$GMX" grompp -f "$mdp" -c "$coord" -r "$coord" -p topol.top -o "$tpr" \
                ${cpt:+-t "$cpt"} -maxwarn 1
}

MDRUN_GPU() {
  # $1: deffnm  (dynamical integrator: nb+pme+bonded on GPU; update stays on
  # CPU because all-bonds constraints with chains > 2 long are unsupported by
  # the GPU LINCS implementation — matches what the original 250 ns runs did)
  local deffnm="$1"
  "$GMX" mdrun -deffnm "$deffnm" \
               -nb gpu -pme gpu -bonded gpu \
               -gpu_id "$GPU_ID" \
               -ntmpi 1 -ntomp "$NT" -pin on \
               -maxh "$MAXH_PER_STAGE" -v
}

MDRUN_GPU_EM() {
  # $1: deffnm  (steepest descent — only -nb gpu is valid; pme/bonded/update
  # on GPU require a dynamical integrator and will fail with steep)
  local deffnm="$1"
  "$GMX" mdrun -deffnm "$deffnm" \
               -nb gpu \
               -gpu_id "$GPU_ID" \
               -ntmpi 1 -ntomp "$NT" -pin on \
               -maxh "$MAXH_PER_STAGE" -v
}

MDRUN_GPU_RESUME() {
  # $1: deffnm  (resume from .cpt; mostly used if a run is restarted manually)
  local deffnm="$1"
  "$GMX" mdrun -s "${deffnm}.tpr" -cpi "${deffnm}.cpt" -deffnm "$deffnm" \
               -noappend \
               -nb gpu -pme gpu -bonded gpu -update gpu \
               -gpu_id "$GPU_ID" \
               -ntmpi 1 -ntomp "$NT" -pin on \
               -maxh "$MAXH_PER_STAGE" -v
}

# ============================================================================
# Start
# ============================================================================
echo "============================================================================"
echo "[$(date '+%F %T')] REPLICA: $REPLICA_TAG"
echo "  GMX        = $GMX"
echo "  NT         = $NT   GPU_ID = $GPU_ID"
echo "  total prod = ${TOTAL_NS} ns in ${N_STAGES} x ${STAGE_NS} ns stages, dt=2 fs"
echo "============================================================================"
notify "Run starting: ${TOTAL_NS} ns in ${N_STAGES} stages" "$REPLICA_TAG ▶" 0

# ---------- 1. Energy minimization ----------
stage_banner "Energy minimization"
if [ ! -f em.gro ]; then
  GROMPP "$MDP_DIR/minim.mdp" solvated_ions.pdb em.tpr
  MDRUN_GPU_EM em
else
  echo "→ em.gro present, skipping"
fi
advance $W_MIN

# ---------- 2. NVT (random gen_seed -> independent replica) ----------
stage_banner "NVT equilibration (1 ns, fresh velocities)"
if [ ! -f nvt.gro ]; then
  GROMPP "$MDP_DIR/nvt.mdp" em.gro nvt.tpr
  MDRUN_GPU nvt
else
  echo "→ nvt.gro present, skipping"
fi
advance $W_NVT

# ---------- 3. NPT ----------
stage_banner "NPT equilibration (1 ns)"
if [ ! -f npt.gro ]; then
  GROMPP "$MDP_DIR/npt.mdp" nvt.gro npt.tpr nvt.cpt
  MDRUN_GPU npt
else
  echo "→ npt.gro present, skipping"
fi
advance $W_NPT

# ---------- 4. Production (15 × 50 ns) ----------
prev_gro="npt.gro"
prev_cpt="npt.cpt"
for i in $(seq 1 "$N_STAGES"); do
  deffnm=$(printf "md_part%02d" "$i")
  stage_banner "Production ${i}/${N_STAGES} (50 ns) — ${deffnm}"
  if [ ! -f "${deffnm}.gro" ]; then
    GROMPP "$MDP_DIR/md_50ns.mdp" "$prev_gro" "${deffnm}.tpr" "$prev_cpt"
    MDRUN_GPU "$deffnm"
  else
    echo "→ ${deffnm}.gro present, skipping"
  fi
  prev_gro="${deffnm}.gro"
  prev_cpt="${deffnm}.cpt"
  # spread 85% evenly across N_STAGES
  advance "$(awk "BEGIN{printf \"%.4f\", $W_PROD_TOTAL / $N_STAGES}")"
done

# ---------- 5. Analysis prep (DRY-ONLY: solvent+ions stripped FIRST) ----------
# Disk-safety + correctness: the solvated trajectory must exist ONLY as the raw
# md_part*.xtc chunks. We NEVER write a solvated concatenated/whole/fit copy
# (building those was ~6x the trajectory on disk and filled the drive). Instead
# we strip to the Protein group up front, make a matching dry reference tpr with
# convert-tpr, and run whole -> nojump -> center -> fit on DRY data only. These
# are per-molecule/protein operations, so the protein coordinates are identical
# to the old pipeline. Also fixes the old prod_nojump self-referential -f bug.
stage_banner "Analysis (dry-only): per-chunk dry+whole → trjcat → nojump → center → fit → PDB"
DRY_GROUP="${DRY_GROUP:-Protein}"
LAST_TPR="$(printf "md_part%02d.tpr" "$N_STAGES")"
[ -f "$LAST_TPR" ] || LAST_TPR="$(ls -v md_part*.tpr 2>/dev/null | tail -1)"
PROD_XTCS=$(ls md_part??.xtc 2>/dev/null | sort -V)
[ -n "$PROD_XTCS" ] || { echo "no md_part*.xtc files found — production outputs missing"; exit 1; }
if ls md_part*.part*.xtc >/dev/null 2>&1; then
  PROD_XTCS=$(ls md_part??.xtc md_part*.part*.xtc 2>/dev/null | sort -uV); TRJCAT_FLAGS=""
else
  TRJCAT_FLAGS="-cat"
fi

# Dry reference topology (atoms = DRY_GROUP) so downstream -s matches the dry xtc.
[ -f prod_dry.tpr ] || echo "$DRY_GROUP" | "$GMX" convert-tpr -s "$LAST_TPR" -n index.ndx -o prod_dry.tpr

# Pre-flight disk guard: abort early if free disk < DISK_FACTOR x estimated dry
# trajectory (default 2x). Estimate dry bytes ~= raw_bytes * dry_atoms/full_atoms.
DISK_FACTOR="${DISK_FACTOR:-2}"
_natoms() { "$GMX" dump -s "$1" 2>/dev/null | awk '/^[[:space:]]*natoms/{print $NF; exit}'; }
_human()  { awk -v b="$1" 'BEGIN{printf "%.1f GiB", b/1073741824}'; }
FA=$(_natoms "$LAST_TPR") || true
DA=$(_natoms prod_dry.tpr) || true
RAW_BYTES=$(du -cb -- $PROD_XTCS 2>/dev/null | tail -1 | awk '{print $1}')
if [ -n "${FA:-}" ] && [ -n "${DA:-}" ] && [ "${FA:-0}" -gt 0 ] 2>/dev/null && [ -n "${RAW_BYTES:-}" ]; then
  DRYEST=$(awk -v r="$RAW_BYTES" -v d="$DA" -v f="$FA" 'BEGIN{printf "%.0f", r*d/f}')
  NEED=$(awk -v t="$DRYEST" -v k="$DISK_FACTOR" 'BEGIN{printf "%.0f", t*k}')
  AVAIL=$(df -PB1 . | awk 'NR==2{print $4}')
  if awk -v a="$AVAIL" -v n="$NEED" 'BEGIN{exit !(a < n)}'; then
    echo "ERROR: not enough free disk for analysis on $(df -P . | awk 'NR==2{print $6}')."
    echo "  estimated dry trajectory ~$(_human "$DRYEST"); need ~$(_human "$NEED") (${DISK_FACTOR}x); free $(_human "$AVAIL")."
    echo "  Free up space (e.g. delete old solvated prod_*.xtc) and re-run, or lower DISK_FACTOR."
    exit 1
  fi
  echo "[disk_guard] ok: dry est ~$(_human "$DRYEST"), free $(_human "$AVAIL") (need ${DISK_FACTOR}x ~$(_human "$NEED"))"
else
  echo "[disk_guard] could not estimate sizes — skipping disk check"
fi

# Strip solvent+ions and make whole PER CHUNK into a temp dir (small files).
rm -rf .dryan; mkdir -p .dryan
di=0; DRYLIST=""
for c in $PROD_XTCS; do
  o=$(printf ".dryan/d%04d.xtc" "$di"); di=$((di+1))
  echo "$DRY_GROUP" | "$GMX" trjconv -s "$LAST_TPR" -f "$c" -n index.ndx -pbc whole -o "$o"
  DRYLIST="$DRYLIST $o"
done

# Concatenate the dry chunks, then nojump/center/fit on the DRY reference,
# deleting each intermediate as soon as the next exists (peak ~2x dry traj).
# Default groups of a protein-only tpr: 0=System, 1=Protein, 4=Backbone.
"$GMX" trjcat -f $DRYLIST -o .dryan/whole.xtc $TRJCAT_FLAGS && rm -f .dryan/d*.xtc
echo 0          | "$GMX" trjconv -s prod_dry.tpr -f .dryan/whole.xtc  -o .dryan/nojump.xtc -pbc nojump && rm -f .dryan/whole.xtc
printf "1\n0\n" | "$GMX" trjconv -s prod_dry.tpr -f .dryan/nojump.xtc -o .dryan/center.xtc -center -pbc mol -ur compact && rm -f .dryan/nojump.xtc
printf "4\n0\n" | "$GMX" trjconv -s prod_dry.tpr -f .dryan/center.xtc -o prod_dry.xtc      -fit rot+trans && rm -f .dryan/center.xtc

# Reference (frame 0) + final-frame PDB from the dry trajectory, stamp chain IDs.
echo 0 | "$GMX" trjconv -s prod_dry.tpr -f prod_dry.xtc -o prod_ref.pdb  -dump 0          -conect
echo 0 | "$GMX" trjconv -s prod_dry.tpr -f prod_dry.xtc -o prod_last.pdb -dump 999999999  -conect
python3 "$ADD_CHAIN" prod_ref.pdb  topol_Protein_chain_A.itp topol_Protein_chain_B.itp topol_Protein_chain_C.itp
python3 "$ADD_CHAIN" prod_last.pdb topol_Protein_chain_A.itp topol_Protein_chain_B.itp topol_Protein_chain_C.itp

# Drop all intermediates; keep only the dry deliverables. Raw chunks untouched.
rm -rf .dryan
advance $W_ANALYSIS

echo
echo "============================================================================"
echo "[$(date '+%F %T')] REPLICA COMPLETE: $REPLICA_TAG"
echo "  Analysis-ready (dry/fit): prod_dry.xtc   (water+ions removed)"
echo "  Reference / final PDB   : prod_ref.pdb / prod_last.pdb (chain IDs A/B/C)"
echo "  Dry reference topology  : prod_dry.tpr"
echo "  Solvated data remains ONLY in the raw md_part*.xtc chunks (no prod.xtc)."
echo "============================================================================"
notify "DONE — production + dry analysis ready (no solvated prod.xtc)" "$REPLICA_TAG ✅" 0
