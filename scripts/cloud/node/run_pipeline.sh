#!/usr/bin/env bash
# =============================================================================
# run_pipeline.sh — GROMACS MD compute for one replica (general, system-agnostic).
#
# Runs in the working directory (a rented Vast.ai node's ~/sky_workdir for cloud
# runs, or the mounted folder for local runs). It ONLY computes the dynamics and
# writes tiny status/ markers; analysis is separate (analyze.sh / a preset/hook).
#
# Phases are MDP-DRIVEN and skippable — a phase runs only if its mdp is present:
#   mdp/em.mdp    energy minimization (from START_STRUCT)
#   mdp/nvt.mdp   NVT      (from the previous .gro; velocities per your mdp)
#   mdp/npt.mdp   NPT      (from the previous .gro, continued via -t prev.cpt)
#   mdp/prod.mdp  production (REQUIRED; TOTAL_NS in STAGE_NS chunks)
# Nothing is hardcoded about the molecular system: you bring START_STRUCT, TOP,
# optional INDEX, and your own mdp files.
#
# Resume/recovery (cloud): each phase resumes from its checkpoint; a destroyed
# node is re-provisioned by the orchestrator, which pushes back the latest
# .cpt/.tpr/.gro and we resume with -noappend (cross-node) -> md_*.partNNNN.*.
#
# Env (orchestrator/CLI set these; defaults are sane):
#   REPLICA_TAG TOTAL_NS STAGE_NS CKPT_MIN NT GPU_ID MAXH_PER_STAGE GMX MAXWARN
#   START_STRUCT TOP INDEX        (inputs; auto-detected if unset)
#   EXTEND_BASE EXTEND_TO_PS      (extend mode)
# =============================================================================
set -euo pipefail
export LC_ALL=C LANG=C
[ -f "$HOME/gmx_activate.sh" ] && source "$HOME/gmx_activate.sh"

# Some Vast/base-image environments export OMP_NUM_THREADS=1. GROMACS then FATAL-errors
# whenever our -ntomp differs ("OMP_NUM_THREADS (1) and ... command line (N) have
# different values"), so mdrun never starts. Clear it (and OMP_THREAD_LIMIT) so -ntomp
# alone controls thread count.
unset OMP_NUM_THREADS OMP_THREAD_LIMIT 2>/dev/null || true

# Robust usable-core count: `nproc` honors cgroup quota/affinity and can return 1
# inside a Vast container even on a 32-core host (that is the -ntomp 1 GPU-starvation
# bug). Take the largest plausible signal, then clamp to any cgroup CPU quota.
detect_cores() {
  local cg=0 aff=0 cpuinfo=0 npall=0 n=0 q p
  if [ -r /sys/fs/cgroup/cpu.max ]; then                       # cgroup v2
    read -r q p < /sys/fs/cgroup/cpu.max || true
    [ "${q:-max}" != "max" ] && [ "${p:-0}" -gt 0 ] 2>/dev/null && cg=$(awk -v q="$q" -v p="$p" 'BEGIN{n=int(q/p);if(n<1)n=1;print n}')
  elif [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ] && [ -r /sys/fs/cgroup/cpu/cpu.cfs_period_us ]; then  # cgroup v1
    q=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us); p=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)
    [ "${q:-0}" -gt 0 ] 2>/dev/null && [ "${p:-0}" -gt 0 ] 2>/dev/null && cg=$(awk -v q="$q" -v p="$p" 'BEGIN{n=int(q/p);if(n<1)n=1;print n}')
  fi
  command -v python3 >/dev/null 2>&1 && aff=$(python3 -c 'import os;print(len(os.sched_getaffinity(0)))' 2>/dev/null || echo 0)
  cpuinfo=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 0)
  npall=$(nproc --all 2>/dev/null || echo 0)
  for v in "$cg" "$aff" "$cpuinfo" "$npall"; do [ "${v:-0}" -gt "$n" ] 2>/dev/null && n="$v"; done
  [ "${cg:-0}" -gt 0 ] 2>/dev/null && [ "$n" -gt "$cg" ] && n="$cg"   # cgroup quota is a hard ceiling
  [ "${n:-0}" -lt 1 ] 2>/dev/null && n=1
  printf '%d' "$n"
}

REPLICA_TAG="${REPLICA_TAG:-$(basename "$PWD")}"
TOTAL_NS="${TOTAL_NS:-750}"
STAGE_NS="${STAGE_NS:-50}"
CKPT_MIN="${CKPT_MIN:-15}"
NT="${NT:-$(detect_cores)}"
if [ "${NT:-1}" -lt 2 ] 2>/dev/null; then _re=$(detect_cores); echo "[pipeline] WARNING: NT=$NT degenerate; re-detected NT=$_re" >&2; NT="$_re"; fi
GPU_ID="${GPU_ID:-0}"
MAXH_PER_STAGE="${MAXH_PER_STAGE:-48}"
GMX="${GMX:-gmx}"
MAXWARN="${MAXWARN:-1}"
TOP="${TOP:-topol.top}"
INDEX="${INDEX:-index.ndx}"
START_STRUCT="${START_STRUCT:-}"
EXTEND_BASE="${EXTEND_BASE:-}"
EXTEND_TO_PS="${EXTEND_TO_PS:-}"
KEEPALIVE_MAXH="${KEEPALIVE_MAXH:-6}"    # after outputs are done/failed, hold the
                                         # instance up (non-idle) this many hours
                                         # waiting for the supervisor to confirm a
                                         # verified pull (status/PULLED_OK), so the
                                         # node never idles into -i --down before
                                         # its data is safely local.

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$HERE"
RUN_LOG="$HERE/run_pipeline.log"
exec > >(tee -a "$RUN_LOG") 2>&1

# ns / hours may arrive as floats (e.g. "1.0"); bash integer math dies on the ".0".
# KEEPALIVE_MAXH especially: a float would crash wait_for_pull's $(( )) and silently
# turn the data-safety keepalive into a no-op (node could autostop before the pull).
TOTAL_NS=$(awk -v v="$TOTAL_NS" 'BEGIN{n=int(v+0); if(n<1)n=1; printf "%d", n}')
STAGE_NS=$(awk -v v="$STAGE_NS" 'BEGIN{n=int(v+0); if(n<1)n=1; printf "%d", n}')
KEEPALIVE_MAXH=$(awk -v v="${KEEPALIVE_MAXH:-6}" 'BEGIN{n=int(v+0); if(n<1)n=1; printf "%d", n}')
N_STAGES=$(( (TOTAL_NS + STAGE_NS - 1) / STAGE_NS ))   # ceiling: never undershoot the target
STATUS_DIR="$HERE/status"; mkdir -p "$STATUS_DIR"
# optional index: only use -n if the file actually exists
[ -n "$INDEX" ] && [ -f "$INDEX" ] || INDEX=""

mark()      { printf '%s\n' "$(date '+%F %T')" > "$STATUS_DIR/$1"; }
clear_mark(){ rm -f "$STATUS_DIR/$1" 2>/dev/null || true; }

# Hold the instance UP (process alive => SkyPilot cluster not idle => -i --down
# cannot terminate it) until the local supervisor confirms a verified pull by
# writing status/PULLED_OK back into this workdir, or a billing cap elapses.
# This is the core guarantee that no trajectory dies on the node before it is
# safely on the local store. The supervisor sky-down's the node on success.
wait_for_pull() {
  # LOCAL runs (mda local / mda extend --where local) have NO supervisor to write
  # status/PULLED_OK, so without this guard a finished local run would block here for
  # the full KEEPALIVE_MAXH (hours) before the CLI's analysis step ever runs. The CLI
  # sets WAIT_FOR_PULL=0 for local; cloud leaves it 1 (default) so the keepalive holds.
  if [ "${WAIT_FOR_PULL:-1}" != "1" ]; then
    echo "[node] WAIT_FOR_PULL=0 (local/unsupervised) — not holding for a pull; continuing."
    return 0
  fi
  local maxs=$(( KEEPALIVE_MAXH * 3600 )) t=0
  echo "[node] outputs complete — holding instance up for the supervisor's verified pull"
  echo "[node]   (waiting for status/PULLED_OK, billing cap ${KEEPALIVE_MAXH}h)"
  while [ ! -f "$STATUS_DIR/PULLED_OK" ] && [ "$t" -lt "$maxs" ]; do sleep 30; t=$((t+30)); done
  if [ -f "$STATUS_DIR/PULLED_OK" ]; then
    echo "[node] PULLED_OK received — data confirmed local; exiting cleanly."
  else
    echo "[node] keepalive cap (${KEEPALIVE_MAXH}h) reached without PULLED_OK — exiting (supervisor offline?)."
  fi
}

STAGE_NAME="(init)"
stage_banner() {
  STAGE_NAME="$1"
  echo; echo "============================================================================"
  echo "[$(date '+%F %T')] STAGE: $STAGE_NAME"
  echo "============================================================================"
}
on_failure() {
  trap - ERR
  echo; echo "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
  echo "[$(date '+%F %T')] FAILED at stage: $STAGE_NAME"
  echo "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
  printf '%s\n' "$STAGE_NAME" > "$STATUS_DIR/FAILED"
  # Hold the failed node up so the supervisor can pull the failure-time data
  # (checkpoints/partial trajectory) before anything terminates it.
  wait_for_pull
}
trap 'on_failure' ERR

# ------------------------- GROMACS helpers -----------------------------------
GROMPP() {            # $1 mdp  $2 coord  $3 out.tpr  $4(opt) continuation cpt
  local mdp="$1" coord="$2" tpr="$3" cpt="${4:-}"
  "$GMX" grompp -f "$mdp" -c "$coord" -r "$coord" -p "$TOP" ${INDEX:+-n "$INDEX"} \
                -o "$tpr" ${cpt:+-t "$cpt"} -maxwarn "$MAXWARN"
}
# GPU/CPU auto-detect: GPU node uses offload; CPU-only container falls back.
if nvidia-smi -L >/dev/null 2>&1; then
  MD_OFFLOAD=(-nb gpu -pme gpu -bonded gpu)   # NO -update gpu (all-bonds LINCS)
  EM_OFFLOAD=(-nb gpu)
  GPU_ARGS=(-gpu_id "$GPU_ID")
  echo "[pipeline] GPU detected — GPU offload"
else
  MD_OFFLOAD=(); EM_OFFLOAD=(); GPU_ARGS=()
  echo "[pipeline] no GPU detected — CPU-only run (slow; fine for tests)"
fi

# Production threading + offload are auto-tuned per node (autotune_mdrun, below).
# Until tuned, sane defaults: -ntomp capped to a single-GPU OpenMP sweet spot (8-16;
# scaling flattens past ~16 on many-core/NUMA hosts) + the standard offload. EM/NVT/NPT
# use these defaults (short, not perf-critical); production uses the tuned winner.
default_ntomp() { local c="${NT:-1}"; [ "$c" -gt 16 ] && c=16; [ "$c" -lt 1 ] && c=1; printf '%d' "$c"; }
TUNE_NTOMP="$(default_ntomp)"
TUNE_EXTRA=("${MD_OFFLOAD[@]}")

mdrun_fresh() {           # $1 deffnm ; $2.. offload (EM passes EM_OFFLOAD)
  local d="$1"; shift
  "$GMX" mdrun -deffnm "$d" "$@" -cpo "${d}.cpt" -cpt "$CKPT_MIN" \
               "${GPU_ARGS[@]}" -ntmpi 1 -ntomp "$TUNE_NTOMP" -pin on -maxh "$MAXH_PER_STAGE" -v
}
mdrun_resume_append() {
  local d="$1" cpt="$2"
  "$GMX" mdrun -s "${d}.tpr" -cpi "$cpt" -deffnm "$d" -append "${TUNE_EXTRA[@]}" \
               -cpo "${d}.cpt" -cpt "$CKPT_MIN" \
               "${GPU_ARGS[@]}" -ntmpi 1 -ntomp "$TUNE_NTOMP" -pin on -maxh "$MAXH_PER_STAGE" -v
}
mdrun_resume_noappend() {
  local d="$1" cpt="$2"
  "$GMX" mdrun -s "${d}.tpr" -cpi "$cpt" -deffnm "$d" -noappend "${TUNE_EXTRA[@]}" \
               -cpt "$CKPT_MIN" \
               "${GPU_ARGS[@]}" -ntmpi 1 -ntomp "$TUNE_NTOMP" -pin on -maxh "$MAXH_PER_STAGE" -v
}
mdrun_continue() {        # extend: initial continuation from a PRIOR stage's cpt
  local d="$1" src="$2"
  "$GMX" mdrun -s "${d}.tpr" -cpi "$src" -deffnm "$d" -noappend "${TUNE_EXTRA[@]}" \
               -cpt "$CKPT_MIN" \
               "${GPU_ARGS[@]}" -ntmpi 1 -ntomp "$TUNE_NTOMP" -pin on -maxh "$MAXH_PER_STAGE" -v
}
# ---- per-instance mdrun auto-tuner -----------------------------------------
# Benchmark a few mdrun flag-sets on THIS node+system once (after NPT, before the
# production loop), pick the fastest VALID one, persist it (status/TUNED) so a
# resume/recovery never re-benchmarks. Sets TUNE_NTOMP + TUNE_EXTRA used by every
# production chunk. Falls back to the robust-NT defaults on any failure.
perf_nsday() { awk '/^Performance:/{v=$2} END{print (v==""?0:v)}' "$1" 2>/dev/null; }
load_tuned() {
  [ -f "$STATUS_DIR/TUNED" ] || return 1
  local nt extra
  nt=$(awk -F= '/^NTOMP=/{print $2}' "$STATUS_DIR/TUNED")
  extra=$(awk -F= '/^EXTRA=/{sub(/^EXTRA=/,"");print}' "$STATUS_DIR/TUNED")
  [ -n "$nt" ] && [ "$nt" -ge 1 ] 2>/dev/null || return 1
  TUNE_NTOMP="$nt"; read -r -a TUNE_EXTRA <<< "$extra"
  echo "[autotune] reusing persisted tune: -ntomp $TUNE_NTOMP ${TUNE_EXTRA[*]}"; return 0
}
autotune_mdrun() {
  AUTOTUNE="${AUTOTUNE:-1}"; BENCH_STEPS="${BENCH_STEPS:-4000}"
  BENCH_RESET="${BENCH_RESET:-1500}"; BENCH_BUDGET_S="${BENCH_BUDGET_S:-900}"
  local TUNE_DIR="$HERE/bench"
  load_tuned && return 0
  if [ "$AUTOTUNE" != "1" ] || [ "${#MD_OFFLOAD[@]}" -eq 0 ]; then
    echo "[autotune] disabled or CPU-only — using defaults -ntomp $TUNE_NTOMP"; return 0; fi
  { [ -f mdp/prod.mdp ] && [ -f "$prev_gro" ]; } || { echo "[autotune] no prod.mdp/equilibrated gro — defaults"; return 0; }
  mkdir -p "$TUNE_DIR"
  stage_banner "Autotune mdrun (${BENCH_STEPS} steps/trial, budget ${BENCH_BUDGET_S}s)"
  local btpr="$TUNE_DIR/bench.tpr"
  cp -f mdp/prod.mdp "$TUNE_DIR/bench.mdp"
  if grep -qE '^[[:space:]]*nsteps[[:space:]]*=' "$TUNE_DIR/bench.mdp"; then
    sed -i -E "s|^([[:space:]]*nsteps[[:space:]]*=).*|\1 ${BENCH_STEPS}|" "$TUNE_DIR/bench.mdp"
  else printf 'nsteps = %s\n' "$BENCH_STEPS" >> "$TUNE_DIR/bench.mdp"; fi
  set +e
  "$GMX" grompp -f "$TUNE_DIR/bench.mdp" -c "$prev_gro" -r "$prev_gro" -p "$TOP" \
         ${INDEX:+-n "$INDEX"} ${prev_cpt:+-t "$prev_cpt"} -o "$btpr" -maxwarn "$MAXWARN" >"$TUNE_DIR/grompp.out" 2>&1
  local grc=$?; set -e
  { [ $grc -eq 0 ] && [ -f "$btpr" ]; } || { echo "[autotune] bench grompp failed — defaults"; rm -rf "$TUNE_DIR"; return 0; }
  local ncap="$NT"; [ "$ncap" -gt 16 ] && ncap=16
  local -a CANDS=("$ncap|-nb gpu -pme gpu -bonded gpu")
  [ "$NT" -ge 8 ]  && CANDS+=("8|-nb gpu -pme gpu -bonded gpu")
  [ "$NT" -ge 16 ] && CANDS+=("16|-nb gpu -pme gpu -bonded gpu")
  CANDS+=("$ncap|-nb gpu -pme gpu -bonded cpu")
  CANDS+=("$ncap|-nb gpu -pme gpu -bonded gpu -update gpu")   # may be rejected -> auto-skipped
  # NB: a separate PME rank (-npme) is NOT a single-GPU lever — omitted on purpose.
  local start_ts best_ns="0" best_spec="" spec ntomp offload rc nsday i=0 elapsed d
  start_ts=$(date +%s)
  for spec in "${CANDS[@]}"; do
    i=$((i+1)); elapsed=$(( $(date +%s) - start_ts ))
    [ "$elapsed" -ge "$BENCH_BUDGET_S" ] && { echo "[autotune] budget hit — stopping sweep"; break; }
    ntomp="${spec%%|*}"; offload="${spec#*|}"; d="$TUNE_DIR/t$i"
    echo "[autotune] trial $i: -ntomp $ntomp $offload"
    set +e
    # -resethway discards warmup (PME tune + CUDA JIT) by resetting perf counters at the
    # halfway step — always valid, unlike -resetstep <n> which FATALs if the bench tpr's
    # start step is already past <n>. Do NOT force -nstlist (keep the tpr's Verlet value);
    # overriding both was making every trial exit rc=1 (validated in a live smoke test).
    # -notunepme: PME-on-GPU auto-enables PME load-balancing, which GROMACS refuses to
    # combine with -resethway/-resetstep (fatal). Disable it for the bench — we want
    # steady-state throughput on a fixed grid, comparable across trials, not a tuned
    # grid. (Production keeps PME tuning; the bench only RANKS configs.)
    timeout "$BENCH_BUDGET_S" "$GMX" mdrun -s "$btpr" -deffnm "$d" -ntmpi 1 -ntomp "$ntomp" -pin on "${GPU_ARGS[@]}" $offload \
      -nsteps "$BENCH_STEPS" -resethway -notunepme -noconfout >"$d.out" 2>&1
    rc=$?; set -e
    if [ $rc -ne 0 ]; then
      echo "[autotune]   trial $i INVALID (rc=$rc) — skipped; mdrun output:"
      awk '/Fatal error:/{f=1} f{print} /manual.gromacs.org/{f=0}' "$d.out" 2>/dev/null | head -8 | sed 's/^/[autotune]       | /'
      rm -f "$d".* 2>/dev/null; continue
    fi
    nsday=$(perf_nsday "$d.log"); [ -z "$nsday" ] && nsday=0
    echo "[autotune]   trial $i -> ${nsday} ns/day"
    awk -v a="$nsday" -v b="$best_ns" 'BEGIN{exit !(a>b)}' && { best_ns="$nsday"; best_spec="$spec"; }
    rm -f "$d".* 2>/dev/null || true
  done
  if [ -n "$best_spec" ] && awk -v b="$best_ns" 'BEGIN{exit !(b>0)}'; then
    TUNE_NTOMP="${best_spec%%|*}"; read -r -a TUNE_EXTRA <<< "${best_spec#*|}"
    { echo "NTOMP=$TUNE_NTOMP"; echo "EXTRA=${TUNE_EXTRA[*]}"; echo "NSDAY=$best_ns"; } > "$STATUS_DIR/TUNED"
    mark TUNE_DONE
    echo "[autotune] WINNER: -ntomp $TUNE_NTOMP ${TUNE_EXTRA[*]}  (${best_ns} ns/day)"
  else
    echo "[autotune] no valid trial — keeping defaults (-ntomp $TUNE_NTOMP ${TUNE_EXTRA[*]})"
  fi
  rm -rf "$TUNE_DIR" 2>/dev/null || true
}

tpr_end_ps() {            # end time (ps) baked into a tpr = nsteps*dt
  "$GMX" dump -s "$1" 2>/dev/null | awk '
    /^[[:space:]]*nsteps[[:space:]]*=/{ns=$NF}
    /^[[:space:]]*dt[[:space:]]*=/{dt=$NF}
    END{ if(ns!=""&&dt!="") printf "%.6f", ns*dt }'
}

stage_done() {
  local d="$1"
  # Final structure must exist...
  [ -f "${d}.gro" ] || ls "${d}".part*.gro >/dev/null 2>&1 || return 1
  # ...and for production/extension chunks the TRAJECTORY must exist too. A recovery
  # that restaged a chunk's .gro without its .xtc would otherwise be treated as a
  # finished chunk and skipped, leaving a hole that later passes ALL_DONE verification.
  case "$d" in
    md_part*|md_ext*) [ -f "${d}.xtc" ] || ls "${d}".part*.xtc >/dev/null 2>&1 || return 1 ;;
  esac
  return 0
}
latest_gro() {
  local d="$1"
  if ls "${d}".part*.gro >/dev/null 2>&1; then ls -v "${d}".part*.gro | tail -1; else echo "${d}.gro"; fi
}

resume_stage() {
  local d="$1" rc
  set +e
  # ALWAYS -noappend: each resume writes a fresh ${d}.partNNNN.* so existing .xtc
  # are strictly append-only. That makes the supervisor's rsync --append safe and
  # avoids the GROMACS -append rewind that would corrupt an already-pulled .xtc.
  mdrun_resume_noappend "$d" "${d}.cpt"; rc=$?
  if [ $rc -ne 0 ] && [ -f "${d}_prev.cpt" ]; then
    echo "→ ${d}: retry from ${d}_prev.cpt (-noappend)"; mdrun_resume_noappend "$d" "${d}_prev.cpt"; rc=$?
  fi
  set -e
  return $rc
}

run_md_stage() {          # $1 deffnm  $2 mdp  $3 coord  $4(opt) cpt-for-grompp
  local deffnm="$1" mdp="$2" coord="$3" cpt_in="${4:-}"
  if stage_done "$deffnm"; then echo "→ ${deffnm} complete, skipping"; return 0; fi
  [ -f "${deffnm}.tpr" ] || GROMPP "$mdp" "$coord" "${deffnm}.tpr" "$cpt_in"
  local pass=0
  while ! stage_done "$deffnm"; do
    pass=$((pass+1))
    if [ -f "${deffnm}.cpt" ]; then
      echo "→ ${deffnm}: resume (pass ${pass})"; resume_stage "$deffnm" || { on_failure; exit 1; }
    else
      echo "→ ${deffnm}: fresh (pass ${pass})"; mdrun_fresh "$deffnm" "${TUNE_EXTRA[@]}" || { on_failure; exit 1; }
    fi
  done
}

# ---------- EXTEND mode: continue <base>.tpr/.cpt via convert-tpr + mdrun -cpi
run_extend() {
  local base="$EXTEND_BASE" target_ps="$EXTEND_TO_PS" rc
  [ -f "${base}.tpr" ] || { echo "extend: missing ${base}.tpr"; on_failure; exit 1; }
  [ -f "${base}.cpt" ] || { echo "extend: missing ${base}.cpt"; on_failure; exit 1; }
  [ -n "$target_ps" ]  || { echo "extend: EXTEND_TO_PS not set"; on_failure; exit 1; }
  local stage_ps; stage_ps=$(awk -v s="$STAGE_NS" 'BEGIN{printf "%.6f", s*1000}')
  local prev_tpr="${base}.tpr" prev_cpt="${base}.cpt"
  local cur_ps; cur_ps=$(tpr_end_ps "$prev_tpr")
  [ -n "$cur_ps" ] || { echo "extend: cannot read ${base}.tpr end time"; on_failure; exit 1; }
  echo "extend: base=$base current=${cur_ps}ps target=${target_ps}ps chunk=${stage_ps}ps"
  if awk -v c="$cur_ps" -v t="$target_ps" 'BEGIN{exit !(c >= t-1e-6)}'; then
    echo "extend: already at/beyond target"; mark ALL_DONE; return 0
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
          echo "→ ${deffnm}: resume own cpt (pass ${pass})"
          set +e; mdrun_resume_noappend "$deffnm" "${deffnm}.cpt"; rc=$?
          if [ $rc -ne 0 ] && [ -f "${deffnm}_prev.cpt" ]; then mdrun_resume_noappend "$deffnm" "${deffnm}_prev.cpt"; rc=$?; fi
          set -e; [ $rc -eq 0 ] || { on_failure; exit 1; }
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
  echo "[$(date '+%F %T')] EXTENSION COMPLETE: $base -> ${target_ps} ps"
}

# ============================================================================
echo "============================================================================"
echo "[$(date '+%F %T')] MD REPLICA (compute): $REPLICA_TAG"
echo "  GMX=$($GMX --version 2>/dev/null | head -1 || echo "$GMX")  NT=$NT  GPU_ID=$GPU_ID"
echo "  top=$TOP  index=${INDEX:-<none>}  prod=${TOTAL_NS}ns/${N_STAGES}x${STAGE_NS}ns"
echo "============================================================================"
clear_mark FAILED
mark STARTED

if [ -n "$EXTEND_BASE" ]; then
  echo "MODE: EXTEND base=$EXTEND_BASE target=${EXTEND_TO_PS}ps"; run_extend; wait_for_pull; exit 0
fi

# resolve the starting structure if not given
if [ -z "$START_STRUCT" ]; then
  for c in solvated_ions.pdb conf.gro start.gro start.pdb *.gro *.pdb; do
    [ -f "$c" ] && { START_STRUCT="$c"; break; }
  done
fi
[ -n "$START_STRUCT" ] && [ -f "$START_STRUCT" ] || { echo "no starting structure (set START_STRUCT / --struct)"; on_failure; exit 1; }
[ -f "$TOP" ] || { echo "topology $TOP not found"; on_failure; exit 1; }
[ -f mdp/prod.mdp ] || { echo "production mdp (mdp/prod.mdp) required"; on_failure; exit 1; }
echo "  start structure: $START_STRUCT"

prev_gro="$START_STRUCT"; prev_cpt=""

# ---- EM (optional) ----
if [ -f mdp/em.mdp ]; then
  stage_banner "Energy minimization"
  if ! stage_done em; then GROMPP mdp/em.mdp "$prev_gro" em.tpr; mdrun_fresh em "${EM_OFFLOAD[@]}"; else echo "→ em done"; fi
  mark EM_DONE; prev_gro="$(latest_gro em)"; prev_cpt=""
fi
# ---- NVT (optional; velocities per your mdp) ----
if [ -f mdp/nvt.mdp ]; then
  stage_banner "NVT equilibration"
  run_md_stage nvt mdp/nvt.mdp "$prev_gro"
  mark NVT_DONE; prev_gro="$(latest_gro nvt)"; prev_cpt="nvt.cpt"
fi
# ---- NPT (optional) ----
if [ -f mdp/npt.mdp ]; then
  stage_banner "NPT equilibration"
  run_md_stage npt mdp/npt.mdp "$prev_gro" "$prev_cpt"
  mark NPT_DONE; prev_gro="$(latest_gro npt)"; prev_cpt="npt.cpt"
fi
# ---- Production chunk length is driven by --stage-ns (single source of truth) ----
# Override prod.mdp's nsteps so each chunk is EXACTLY STAGE_NS ns (computed from the
# mdp's own dt). This removes the foot-gun where chunk length silently depended on
# whatever nsteps the prod mdp carried, makes per-chunk progress/notifications exact,
# and matches extend mode (which is already stage-ns-driven via convert-tpr -until).
# Operates on the staged COPY mdp/prod.mdp — never the user's source mdp.
if [ -f mdp/prod.mdp ]; then
  PROD_DT=$(awk -F= '/^[[:space:]]*dt[[:space:]]*=/{gsub(/[^0-9.eE+-]/,"",$2); print $2; exit}' mdp/prod.mdp)
  PROD_DT=${PROD_DT:-0.001}   # GROMACS default dt when the mdp omits it
  PROD_NSTEPS=$(awk -v ns="$STAGE_NS" -v dt="$PROD_DT" 'BEGIN{printf "%.0f", (ns*1000.0)/dt}')
  if grep -qE '^[[:space:]]*nsteps[[:space:]]*=' mdp/prod.mdp; then
    sed -i -E "s|^([[:space:]]*nsteps[[:space:]]*=).*|\1 ${PROD_NSTEPS}   ; set by --stage-ns=${STAGE_NS} ns (dt=${PROD_DT})|" mdp/prod.mdp
  else
    printf 'nsteps = %s   ; set by --stage-ns=%s ns (dt=%s)\n' "$PROD_NSTEPS" "$STAGE_NS" "$PROD_DT" >> mdp/prod.mdp
  fi
  echo "[pipeline] production chunk = ${STAGE_NS} ns -> nsteps=${PROD_NSTEPS} (dt=${PROD_DT} ps)"
fi
# Pick the fastest mdrun flags for THIS node+system (once; persisted) before producing.
autotune_mdrun
# ---- Production (required; chunked) ----
for i in $(seq 1 "$N_STAGES"); do
  deffnm=$(printf "md_part%02d" "$i")
  stage_banner "Production ${i}/${N_STAGES} (${STAGE_NS} ns) — ${deffnm}"
  run_md_stage "$deffnm" mdp/prod.mdp "$prev_gro" "$prev_cpt"
  prev_gro="$(latest_gro "$deffnm")"; prev_cpt="${deffnm}.cpt"
  mark "PROD_$(printf '%02d' "$i")_DONE"
done
mark ALL_DONE
echo "[$(date '+%F %T')] PRODUCTION COMPLETE: $REPLICA_TAG (${N_STAGES}x${STAGE_NS}ns)"
wait_for_pull
