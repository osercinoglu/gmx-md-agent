#!/usr/bin/env bash
# =============================================================================
# run_pipeline.sh — On-NODE MD compute for a cloud (Vast.ai) replica.
#
# Cloud port of replica_prep/run_replica.sh. Runs INSIDE the rented Vast.ai
# instance (launched by SkyPilot) from the synced workdir (~/sky_workdir).
#
# This node script ONLY computes the dynamics:
#   1. EM (steep, -nb gpu only)   2. NVT (1 ns, gen_seed=-1 -> independent)
#   3. NPT (1 ns, C-rescale)      4. Production (TOTAL_NS in STAGE_NS chunks)
# It writes tiny marker files under ./status/ after each stage. It does NOT do
# analysis and does NOT push anything anywhere — the LOCAL orchestrator
# (run_cloud_replica.sh) pulls outputs over rsync as stages complete, drives
# recovery, and runs the trjconv analysis locally. There are NO secrets on the
# node (no R2, no Pushover token).
#
# DURABILITY MODEL (no object store):
#   * The local orchestrator rsync-pulls *.cpt / *.gro / *.tpr / md_part*.xtc
#     every SYNC_MIN. The node's local disk holds the working set; `disk_size`
#     is provisioned large enough for the whole run.
#   * On a destroyed/preempted node the orchestrator re-provisions, pushes the
#     saved state back into the workdir (latest .cpt + .tpr + completed .gro),
#     and this script RESUMES the interrupted stage from its checkpoint.
#   * CROSS-NODE resume: a recovery node has the .cpt/.tpr but NOT the partial
#     .xtc/.edr/.log (those stay local), so `-append` has nothing to append to.
#     We detect that (no .log/.edr present) and resume with `-noappend`, which
#     writes md_partNN.partNNNN.* continuation files. The local analysis
#     trjcat-concatenates the pre-crash partial with the continuation.
#   * -maxh truncation: a stage that hits the wall-clock cap writes a checkpoint
#     but no .gro; the stage loops and resumes until its .gro appears.
#
# Env (set by the SkyPilot YAML / launcher; defaults are sane):
#   REPLICA_TAG TOTAL_NS STAGE_NS CKPT_MIN NT GPU_ID MAXH_PER_STAGE GMX
# =============================================================================

set -euo pipefail
export LC_ALL=C LANG=C
[ -f "$HOME/gmx_activate.sh" ] && source "$HOME/gmx_activate.sh"

# ====================== CONFIG (env overrides) ===============================
REPLICA_TAG="${REPLICA_TAG:-$(basename "$PWD")}"
TOTAL_NS="${TOTAL_NS:-750}"
STAGE_NS="${STAGE_NS:-50}"
CKPT_MIN="${CKPT_MIN:-15}"               # gmx mdrun -cpt (checkpoint every N min)
NT="${NT:-$(nproc)}"
GPU_ID="${GPU_ID:-0}"
MAXH_PER_STAGE="${MAXH_PER_STAGE:-48}"
GMX="${GMX:-gmx}"
EXTEND_BASE="${EXTEND_BASE:-}"           # extend mode: base name of an existing run (expects <base>.tpr + <base>.cpt)
EXTEND_TO_PS="${EXTEND_TO_PS:-}"         # extend mode: absolute target end time, picoseconds
# =============================================================================

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$HERE"
RUN_LOG="$HERE/run_pipeline.log"
exec > >(tee -a "$RUN_LOG") 2>&1

N_STAGES=$(( TOTAL_NS / STAGE_NS ))
STATUS_DIR="$HERE/status"
mkdir -p "$STATUS_DIR"

# ------------------------- status markers (pulled by local) ------------------
# The local orchestrator watches these to drive notifications + completion.
mark()    { printf '%s\n' "$(date '+%F %T')" > "$STATUS_DIR/$1"; }
clear_mark(){ rm -f "$STATUS_DIR/$1" 2>/dev/null || true; }

# ------------------------- progress banner -----------------------------------
STAGE_NAME="(init)"
stage_banner() {
  STAGE_NAME="$1"
  echo; echo "============================================================================"
  echo "[$(date '+%F %T')] STAGE: $STAGE_NAME"
  echo "============================================================================"
}
on_failure() {
  trap - ERR    # disarm so explicit calls can't recurse
  echo; echo "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
  echo "[$(date '+%F %T')] FAILED at stage: $STAGE_NAME"
  echo "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
  printf '%s\n' "$STAGE_NAME" > "$STATUS_DIR/FAILED"
}
trap 'on_failure' ERR

# ------------------------- GROMACS helpers -----------------------------------
GROMPP() {
  local mdp="$1" coord="$2" tpr="$3" cpt="${4:-}"
  "$GMX" grompp -f "$mdp" -c "$coord" -r "$coord" -p topol.top -n index.ndx \
                -o "$tpr" ${cpt:+-t "$cpt"} -maxwarn 1
}
# GPU/CPU auto-detect: a GPU node uses the standard offload; a CPU-only
# container (run without --gpus) falls back to CPU so local test runs still work.
if nvidia-smi -L >/dev/null 2>&1; then
  MD_OFFLOAD=(-nb gpu -pme gpu -bonded gpu)   # NO -update gpu (all-bonds LINCS)
  EM_OFFLOAD=(-nb gpu)
  GPU_ARGS=(-gpu_id "$GPU_ID")
  echo "[pipeline] GPU detected — GPU offload (-nb/-pme/-bonded gpu)"
else
  MD_OFFLOAD=(); EM_OFFLOAD=(); GPU_ARGS=()
  echo "[pipeline] no GPU detected — CPU-only run (slow; fine for tests)"
fi

mdrun_fresh() {           # $1 deffnm ; $2.. offload
  local d="$1"; shift
  "$GMX" mdrun -deffnm "$d" "$@" -cpo "${d}.cpt" -cpt "$CKPT_MIN" \
               "${GPU_ARGS[@]}" -ntmpi 1 -ntomp "$NT" -pin on -maxh "$MAXH_PER_STAGE" -v
}
mdrun_resume_append() {   # $1 deffnm ; $2 cpt
  local d="$1" cpt="$2"
  "$GMX" mdrun -s "${d}.tpr" -cpi "$cpt" -deffnm "$d" -append "${MD_OFFLOAD[@]}" \
               -cpo "${d}.cpt" -cpt "$CKPT_MIN" \
               "${GPU_ARGS[@]}" -ntmpi 1 -ntomp "$NT" -pin on -maxh "$MAXH_PER_STAGE" -v
}
mdrun_resume_noappend() { # $1 deffnm ; $2 cpt  (writes md_partNN.partNNNN.* — analysis dedups)
  local d="$1" cpt="$2"
  "$GMX" mdrun -s "${d}.tpr" -cpi "$cpt" -deffnm "$d" -noappend "${MD_OFFLOAD[@]}" \
               -cpt "$CKPT_MIN" \
               "${GPU_ARGS[@]}" -ntmpi 1 -ntomp "$NT" -pin on -maxh "$MAXH_PER_STAGE" -v
}
mdrun_continue() {        # extend mode: initial continuation from a PRIOR stage's cpt
  local d="$1" src="$2"   # -s d.tpr (extended), state from src cpt, fresh d.partNNNN.* outputs
  "$GMX" mdrun -s "${d}.tpr" -cpi "$src" -deffnm "$d" -noappend "${MD_OFFLOAD[@]}" \
               -cpt "$CKPT_MIN" \
               "${GPU_ARGS[@]}" -ntmpi 1 -ntomp "$NT" -pin on -maxh "$MAXH_PER_STAGE" -v
}
# End time (ps) baked into a .tpr = nsteps * dt (read via gmx dump).
tpr_end_ps() {
  "$GMX" dump -s "$1" 2>/dev/null | awk '
    /^[[:space:]]*nsteps[[:space:]]*=/{ns=$NF}
    /^[[:space:]]*dt[[:space:]]*=/{dt=$NF}
    END{ if(ns!=""&&dt!="") printf "%.6f", ns*dt }'
}

stage_done() { local d="$1"; [ -f "${d}.gro" ] || ls "${d}".part*.gro >/dev/null 2>&1; }
latest_gro() {
  local d="$1"
  if ls "${d}".part*.gro >/dev/null 2>&1; then ls -v "${d}".part*.gro | tail -1; else echo "${d}.gro"; fi
}

resume_stage() {          # try the right resume mode for this node
  local d="$1" rc
  set +e
  if [ ! -f "${d}.log" ] && [ ! -f "${d}.edr" ]; then
    # Cross-node restage: only .cpt/.tpr were pushed back, no append targets
    # exist here, so -append would fail. Continue with -noappend directly.
    echo "→ ${d}: cross-node resume (no local append targets) — using -noappend"
    mdrun_resume_noappend "$d" "${d}.cpt"; rc=$?
    if [ $rc -ne 0 ] && [ -f "${d}_prev.cpt" ]; then
      echo "→ retrying from ${d}_prev.cpt (-noappend)"
      mdrun_resume_noappend "$d" "${d}_prev.cpt"; rc=$?
    fi
  else
    # Same-node resume (e.g. after -maxh): append onto the existing files.
    mdrun_resume_append "$d" "${d}.cpt"; rc=$?
    if [ $rc -ne 0 ]; then
      echo "→ -append resume failed (rc=$rc); retrying with -noappend"
      mdrun_resume_noappend "$d" "${d}.cpt"; rc=$?
    fi
    if [ $rc -ne 0 ] && [ -f "${d}_prev.cpt" ]; then
      echo "→ retrying from previous checkpoint ${d}_prev.cpt (-noappend)"
      mdrun_resume_noappend "$d" "${d}_prev.cpt"; rc=$?
    fi
  fi
  set -e
  return $rc
}

run_md_stage() {          # $1 deffnm  $2 mdp  $3 coord  $4(opt) cpt-for-grompp
  local deffnm="$1" mdp="$2" coord="$3" cpt_in="${4:-}"
  if stage_done "$deffnm"; then echo "→ ${deffnm} complete, skipping"; return 0; fi
  [ -f "${deffnm}.tpr" ] || GROMPP "$mdp" "$coord" "${deffnm}.tpr" "$cpt_in"
  # Loop until the stage actually produces its .gro. mdrun returns 0 on a clean
  # -maxh cutoff WITHOUT writing .gro, so .gro (not exit status) is the only
  # completion signal; each pass advances the checkpoint, so this terminates.
  local pass=0
  while ! stage_done "$deffnm"; do
    pass=$((pass+1))
    # bash suppresses the ERR trap for a command that fails inside a loop body
    # nested in a function, so call on_failure ourselves before exiting.
    if [ -f "${deffnm}.cpt" ]; then
      echo "→ ${deffnm}: resuming from checkpoint (pass ${pass})"
      resume_stage "$deffnm" || { on_failure; exit 1; }
    else
      echo "→ ${deffnm}: fresh start (pass ${pass})"
      mdrun_fresh "$deffnm" "${MD_OFFLOAD[@]}" || { on_failure; exit 1; }
    fi
  done
}

# ---------- EXTEND mode: continue an existing run via convert-tpr + mdrun -cpi -
# Chains STAGE_NS chunks from <base>.tpr/<base>.cpt up to EXTEND_TO_PS, preserving
# the ORIGINAL run parameters (convert-tpr keeps them; no re-grompp). Each chunk
# k: convert-tpr -until <abs_ps> from the previous tpr, then mdrun -cpi the
# previous cpt (-noappend -> md_extKK.partNNNN.*). Reuses PROD_kk_DONE markers so
# the supervisor progress/recovery is unchanged. The original <base>.xtc stays on
# the LOCAL machine and is concatenated with the md_ext* parts during analysis.
run_extend() {
  local base="$EXTEND_BASE" target_ps="$EXTEND_TO_PS" rc
  [ -f "${base}.tpr" ] || { echo "extend: missing ${base}.tpr on node"; on_failure; exit 1; }
  [ -f "${base}.cpt" ] || { echo "extend: missing ${base}.cpt on node"; on_failure; exit 1; }
  [ -n "$target_ps" ]  || { echo "extend: EXTEND_TO_PS not set"; on_failure; exit 1; }
  local stage_ps; stage_ps=$(awk -v s="$STAGE_NS" 'BEGIN{printf "%.6f", s*1000}')
  local prev_tpr="${base}.tpr" prev_cpt="${base}.cpt"
  local cur_ps; cur_ps=$(tpr_end_ps "$prev_tpr")
  [ -n "$cur_ps" ] || { echo "extend: could not read end time from ${base}.tpr"; on_failure; exit 1; }
  echo "extend: base=$base  current_end=${cur_ps} ps  target=${target_ps} ps  chunk=${stage_ps} ps"
  if awk -v c="$cur_ps" -v t="$target_ps" 'BEGIN{exit !(c >= t-1e-6)}'; then
    echo "extend: base already at/beyond target — nothing to do"; mark ALL_DONE; return 0
  fi
  local i=0 deffnm end_ps pass
  while awk -v c="$cur_ps" -v t="$target_ps" 'BEGIN{exit !(c < t-1e-6)}'; do
    i=$((i+1)); deffnm=$(printf "md_ext%02d" "$i")
    end_ps=$(awk -v c="$cur_ps" -v s="$stage_ps" -v t="$target_ps" 'BEGIN{e=c+s; if(e>t)e=t; printf "%.6f", e}')
    stage_banner "Extend ${deffnm}: ${cur_ps} -> ${end_ps} ps"
    if ! stage_done "$deffnm"; then
      [ -f "${deffnm}.tpr" ] || "$GMX" convert-tpr -s "$prev_tpr" -until "$end_ps" -o "${deffnm}.tpr" || { on_failure; exit 1; }
      pass=0
      while ! stage_done "$deffnm"; do
        pass=$((pass+1))
        if [ -f "${deffnm}.cpt" ]; then
          echo "→ ${deffnm}: resume own checkpoint (pass ${pass})"
          set +e
          mdrun_resume_noappend "$deffnm" "${deffnm}.cpt"; rc=$?
          if [ $rc -ne 0 ] && [ -f "${deffnm}_prev.cpt" ]; then mdrun_resume_noappend "$deffnm" "${deffnm}_prev.cpt"; rc=$?; fi
          set -e
          [ $rc -eq 0 ] || { on_failure; exit 1; }
        else
          echo "→ ${deffnm}: continue from ${prev_cpt} (pass ${pass})"
          mdrun_continue "$deffnm" "$prev_cpt" || { on_failure; exit 1; }
        fi
      done
    fi
    mark "PROD_$(printf '%02d' "$i")_DONE"
    prev_tpr="${deffnm}.tpr"; prev_cpt="${deffnm}.cpt"; cur_ps="$end_ps"
  done
  mark ALL_DONE
  echo; echo "[$(date '+%F %T')] EXTENSION COMPLETE on node: $base -> ${target_ps} ps"
}

# ============================================================================
echo "============================================================================"
echo "[$(date '+%F %T')] CLOUD REPLICA (compute node): $REPLICA_TAG"
echo "  GMX=$($GMX --version 2>/dev/null | head -1 || echo "$GMX")"
echo "  NT=$NT  GPU_ID=$GPU_ID"
echo "  production: ${TOTAL_NS} ns in ${N_STAGES} x ${STAGE_NS} ns stages, dt=2 fs"
echo "  (local orchestrator pulls outputs over rsync; no R2, no on-node analysis)"
echo "============================================================================"

clear_mark FAILED
mark STARTED

# EXTEND mode short-circuits the fresh EM/NVT/NPT/production pipeline.
if [ -n "$EXTEND_BASE" ]; then
  echo "MODE: EXTEND  base=$EXTEND_BASE  target=${EXTEND_TO_PS} ps  chunk=${STAGE_NS} ns"
  run_extend
  exit 0
fi

# ---------- 1. Energy minimization (steep; fast, rerun if incomplete) ----------
stage_banner "Energy minimization"
if ! stage_done em; then
  GROMPP mdp/minim.mdp solvated_ions.pdb em.tpr
  mdrun_fresh em "${EM_OFFLOAD[@]}"
else
  echo "→ em complete, skipping"
fi
mark EM_DONE
EM_GRO="$(latest_gro em)"

# ---------- 2. NVT (random gen_seed -> independent replica) ----------
stage_banner "NVT equilibration (1 ns, fresh velocities)"
run_md_stage nvt mdp/nvt.mdp "$EM_GRO"
mark NVT_DONE
NVT_GRO="$(latest_gro nvt)"

# ---------- 3. NPT ----------
stage_banner "NPT equilibration (1 ns)"
run_md_stage npt mdp/npt.mdp "$NVT_GRO" nvt.cpt
mark NPT_DONE
NPT_GRO="$(latest_gro npt)"

# ---------- 4. Production (N_STAGES × STAGE_NS) ----------
prev_gro="$NPT_GRO"; prev_cpt="npt.cpt"
for i in $(seq 1 "$N_STAGES"); do
  deffnm=$(printf "md_part%02d" "$i")
  stage_banner "Production ${i}/${N_STAGES} (${STAGE_NS} ns) — ${deffnm}"
  run_md_stage "$deffnm" mdp/md_prod.mdp "$prev_gro" "$prev_cpt"
  prev_gro="$(latest_gro "$deffnm")"; prev_cpt="${deffnm}.cpt"
  mark "PROD_$(printf '%02d' "$i")_DONE"
done

mark ALL_DONE
echo; echo "============================================================================"
echo "[$(date '+%F %T')] PRODUCTION COMPLETE on node: $REPLICA_TAG"
echo "  ${N_STAGES} x ${STAGE_NS} ns done. Local orchestrator will pull the final"
echo "  md_part*.xtc, run trjconv analysis locally, and tear this node down."
echo "============================================================================"
