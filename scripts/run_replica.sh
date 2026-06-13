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

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$HERE"
REPLICA_TAG="$(basename "$HERE")"
RUN_LOG="$HERE/run_replica.log"
exec > >(tee -a "$RUN_LOG") 2>&1

N_STAGES=$(( TOTAL_NS / STAGE_NS ))     # 15 production parts
PUSHOVER_SH="$HERE/pushover.sh"
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
  GROMPP mdp/minim.mdp solvated_ions.pdb em.tpr
  MDRUN_GPU_EM em
else
  echo "→ em.gro present, skipping"
fi
advance $W_MIN

# ---------- 2. NVT (random gen_seed -> independent replica) ----------
stage_banner "NVT equilibration (1 ns, fresh velocities)"
if [ ! -f nvt.gro ]; then
  GROMPP mdp/nvt.mdp em.gro nvt.tpr
  MDRUN_GPU nvt
else
  echo "→ nvt.gro present, skipping"
fi
advance $W_NVT

# ---------- 3. NPT ----------
stage_banner "NPT equilibration (1 ns)"
if [ ! -f npt.gro ]; then
  GROMPP mdp/npt.mdp nvt.gro npt.tpr nvt.cpt
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
    GROMPP mdp/md_50ns.mdp "$prev_gro" "${deffnm}.tpr" "$prev_cpt"
    MDRUN_GPU "$deffnm"
  else
    echo "→ ${deffnm}.gro present, skipping"
  fi
  prev_gro="${deffnm}.gro"
  prev_cpt="${deffnm}.cpt"
  # spread 85% evenly across N_STAGES
  advance "$(awk "BEGIN{printf \"%.4f\", $W_PROD_TOTAL / $N_STAGES}")"
done

# ---------- 5. Analysis prep ----------
stage_banner "Analysis: trjcat → whole → nojump → center → fit → dry → PDB"

LAST_TPR="$(printf "md_part%02d.tpr" "$N_STAGES")"
PROD_XTCS=$(ls md_part??.xtc 2>/dev/null | sort -V)
if [ -z "$PROD_XTCS" ]; then
  echo "no md_part*.xtc files found — production stage outputs missing"
  exit 1
fi

# Concatenate parts (raw)
if [ ! -f prod.xtc ]; then
  "$GMX" trjcat -f $PROD_XTCS -o prod.xtc -cat
fi

# PBC: whole  (input group: 0 = System)
if [ ! -f prod_whole.xtc ]; then
  echo 0 | "$GMX" trjconv -s "$LAST_TPR" -f prod.xtc -o prod_whole.xtc -pbc whole
fi

# PBC: nojump
if [ ! -f prod_nojump.xtc ]; then
  echo 0 | "$GMX" trjconv -s "$LAST_TPR" -f prod_nojump.xtc -o prod_nojump.xtc -pbc nojump 2>/dev/null \
    || echo 0 | "$GMX" trjconv -s "$LAST_TPR" -f prod_whole.xtc -o prod_nojump.xtc -pbc nojump
fi

# Center on Protein (center group 1=Protein, output 0=System)
if [ ! -f prod_center.xtc ]; then
  printf "1\n0\n" | "$GMX" trjconv -s "$LAST_TPR" -f prod_nojump.xtc -o prod_center.xtc \
                                   -center -pbc mol -ur compact -n index.ndx
fi

# Fit rot+trans on Backbone (group 4), write System (0)
if [ ! -f prod_fit.xtc ]; then
  printf "4\n0\n" | "$GMX" trjconv -s "$LAST_TPR" -f prod_center.xtc -o prod_fit.xtc \
                                   -fit rot+trans -n index.ndx
fi

# Dry: keep only Protein (group 1) -> water/ions stripped
if [ ! -f prod_dry.xtc ]; then
  echo 1 | "$GMX" trjconv -s "$LAST_TPR" -f prod_fit.xtc -o prod_dry.xtc -n index.ndx
fi

# Reference (frame 0) + final (frame -1) PDB, Protein only, then stamp chain IDs
if [ ! -f prod_ref.pdb ]; then
  echo 1 | "$GMX" trjconv -s "$LAST_TPR" -f prod_fit.xtc -o prod_ref.pdb \
                          -dump 0 -conect -n index.ndx
fi
if [ ! -f prod_last.pdb ]; then
  echo 1 | "$GMX" trjconv -s "$LAST_TPR" -f prod_fit.xtc -o prod_last.pdb \
                          -dump 999999999 -conect -n index.ndx
fi

python3 add_chain_ids.py prod_ref.pdb  topol_Protein_chain_A.itp topol_Protein_chain_B.itp topol_Protein_chain_C.itp
python3 add_chain_ids.py prod_last.pdb topol_Protein_chain_A.itp topol_Protein_chain_B.itp topol_Protein_chain_C.itp

advance $W_ANALYSIS

echo
echo "============================================================================"
echo "[$(date '+%F %T')] REPLICA COMPLETE: $REPLICA_TAG"
echo "  Concatenated trajectory : prod.xtc"
echo "  Analysis-ready (dry/fit): prod_dry.xtc  (water/ions removed)"
echo "  Reference PDB           : prod_ref.pdb  (chain IDs A/B/C)"
echo "  Final-frame PDB         : prod_last.pdb (chain IDs A/B/C)"
echo "============================================================================"
notify "DONE — 750 ns + analysis ready" "$REPLICA_TAG ✅" 0
