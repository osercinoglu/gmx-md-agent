#!/usr/bin/env bash
# =============================================================================
# run_cloud_replica.sh — Run ONE independent MD replica on a rented Vast.ai GPU
# via SkyPilot, fully self-contained. The cloud analogue of
# replica_prep/run_replica.sh.
#
# Self-contained: on first use it installs the SkyPilot + vastai CLIs if missing,
# prompts for (and stores) your Vast.ai API key and your Pushover credentials if
# absent, and installs a small local CPU-only GROMACS for the final analysis.
#
# Durability WITHOUT a cloud bucket: the node only computes. THIS machine is the
# durable store — it rsync-pulls the node's outputs (checkpoints + trajectories)
# as each stage completes, and on a destroyed/preempted node it pushes the saved
# state back and relaunches so GROMACS resumes from the last checkpoint. When the
# production stages finish it runs the trjconv analysis locally and tears the
# node down. NOTE: this machine must stay online during the run to pull files and
# drive recovery (the supervisor is backgrounded with nohup, so closing the
# terminal is fine, but a powered-off machine pulls nothing).
#
# Subcommands:
#   launch [DIR]   bootstrap, pick a node, provision, start the run, and spawn a
#                  background supervisor (pull + recover + analyze + teardown).
#   supervise [DIR]  (re)attach the supervisor loop in the FOREGROUND.
#   follow [DIR]   tail the local supervisor log.
#   status [DIR]   sky cluster + vast instance + local progress summary.
#   fetch  [DIR]   one-shot rsync pull of the node's current outputs.
#   teardown [DIR] stop the supervisor, `sky down`, optional Vast sweep.
#
# DIR defaults to $PWD; it must contain solvated_ions.pdb, topol.top, the 3 chain
# itps, the 3 posre itps and index.ndx.
#
# Config (env or cloud/cloud.env):
#   IMAGE IMAGE_KIND CONDA_SPEC TOTAL_NS STAGE_NS CKPT_MIN SYNC_MIN
#   MAXH_PER_STAGE MAX_RESTARTS DISK_GB PROD_MDP LOCAL_GMX PUSHOVER_DEVICE
# =============================================================================
set -euo pipefail
export LC_ALL=C LANG=C
[ -d "$HOME/anaconda3/bin" ] && export PATH="$HOME/anaconda3/bin:$PATH"

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PREP="$(cd "$HERE/.." && pwd)"           # replica_prep/
[ -f "$HERE/cloud.env" ] && source "$HERE/cloud.env"

SKY="${SKY:-sky}"; VASTAI="${VASTAI:-vastai}"; PY="$(command -v python3 || echo python3)"
IMAGE="${IMAGE:-nvidia/cuda:12.4.1-runtime-ubuntu22.04}"
IMAGE_KIND="${IMAGE_KIND:-conda}"
CONDA_SPEC="${CONDA_SPEC:-gromacs=2024.2=nompi_cuda_*}"
TOTAL_NS="${TOTAL_NS:-750}"; STAGE_NS="${STAGE_NS:-50}"
# The CLI passes ns as floats (e.g. "1.0"); bash `$(( ))` only does integer math
# and dies on the ".0". Normalize to ints (floor, min 1) so all staging arithmetic
# — here AND on the node (it reads these from the rendered YAML) — is safe.
TOTAL_NS=$(awk -v v="$TOTAL_NS" 'BEGIN{n=int(v+0); if(n<1)n=1; printf "%d", n}')
STAGE_NS=$(awk -v v="$STAGE_NS" 'BEGIN{n=int(v+0); if(n<1)n=1; printf "%d", n}')
CKPT_MIN="${CKPT_MIN:-15}";  SYNC_MIN="${SYNC_MIN:-15}"   # SYNC_MIN = local pull cadence
MAXH_PER_STAGE="${MAXH_PER_STAGE:-48}"; MAX_RESTARTS="${MAX_RESTARTS:-10}"
KEEPALIVE_MAXH="${KEEPALIVE_MAXH:-24}"         # node holds itself up this long awaiting a verified pull
                                              # (covers a day-long supervisor outage; pair with `watchdog`,
                                              # and AUTOSTOP_MIN only fires once the job is no longer RUNNING)
# Idle->terminate billing backstop (minutes). A HEALTHY run keeps the MD job RUNNING, so the
# cluster never goes idle and this never fires; it only triggers when the node sits jobless
# (abandoned/failed/finished). 30 min was too aggressive — a between-stage gap, a recovery
# relaunch, or a brief failure window could trip it and kill a recoverable run. Default 90 min:
# long enough not to preempt recovery/keepalive, bounded for cost. Set AUTOSTOP_MIN=0 to disable
# the idle-autostop entirely (then ONLY the node keepalive + `watchdog` bound a forgotten node).
AUTOSTOP_MIN="${AUTOSTOP_MIN:-90}"
if [ "${AUTOSTOP_MIN:-0}" -gt 0 ] 2>/dev/null; then AUTOSTOP_ARGS="-i ${AUTOSTOP_MIN} --down"; else AUTOSTOP_ARGS=""; fi
NT="${NT:-}"                                   # OpenMP thread ceiling on the node (blank => auto-detect)
AUTOTUNE="${AUTOTUNE:-1}"                       # benchmark mdrun flags per node before production
BENCH_STEPS="${BENCH_STEPS:-4000}"
PULL_RETRIES="${PULL_RETRIES:-6}"             # verified-pull attempts before giving up
FORCE="${FORCE:-0}"                           # FORCE=1 bypasses the pull-before-destroy guards
# DISK_GB: floor it to the solvated run size (~0.45 GB/ns for ~90k-atom boxes) so
# the node can't fill mid-run; a larger user override still wins.
if [ -z "${DISK_GB:-}" ]; then
  DISK_GB=$(awk -v t="${TOTAL_NS:-750}" 'BEGIN{d=100+t*0.45; if(d<100)d=100; printf "%d", d}')
fi
PROD_MDP="${PROD_MDP:-}"                       # production mdp (required for a fresh run)
EM_MDP="${EM_MDP:-}"; NVT_MDP="${NVT_MDP:-}"; NPT_MDP="${NPT_MDP:-}"   # optional phases
START_STRUCT="${START_STRUCT:-}"              # starting structure (auto-detected on node if unset)
TOP="${TOP:-topol.top}"; INDEX="${INDEX:-index.ndx}"; MAXWARN="${MAXWARN:-1}"
ANALYSIS="${ANALYSIS:-none}"                  # none | pmhc | <hook path>  (local post-process)
DRY_GROUP="${DRY_GROUP:-Protein}"             # solvent/ions-stripping selection for analysis
DISK_FACTOR="${DISK_FACTOR:-2}"               # abort analysis if free disk < N x est. dry traj
LOCAL_GMX="${LOCAL_GMX:-}"
PUSHOVER_DEVICE="${PUSHOVER_DEVICE:-}"
PUSHOVER_CONFIG="${PUSHOVER_CONFIG:-$HOME/.pushover/pushover-config}"
GMXCLOUD_ENV="${GMXCLOUD_ENV:-gmxcloud}"   # conda env name for local analysis gmx
EXT_BASE="${EXT_BASE:-}"; EXT_TO_PS="${EXT_TO_PS:-}"   # set by `extend`; empty for fresh runs
ANALYZE_SH="$PREP/analyze.sh"

die() { echo "ERROR: $*" >&2; exit 1; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
say() { printf '\n\033[1m>> %s\033[0m\n' "$*"; }
# Input file types uploaded to the node (system-agnostic GROMACS inputs).
INPUT_GLOBS=(*.gro *.pdb *.top *.itp *.ndx *.cpt)

resolve_dir() { local d="${1:-$PWD}"; (cd "$d" && pwd); }
tag_of()      { basename "$1"; }
# SkyPilot cluster names (== the ssh alias used for rsync) must be lowercase
# [a-z0-9-]. Sanitizing the basename alone collides (AII_C_14_02_1 vs
# AII-C-14-02-1, case folds, etc.) and two replicas would share/clobber one
# cluster + cross-contaminate pulls. Append a stable hash of the ABSOLUTE path so
# each distinct folder gets a unique, reproducible cluster name.
jobname_of() {
  local d base h
  d="$(cd "$1" 2>/dev/null && pwd || echo "$1")"
  # 1) reuse the name persisted at first launch so launch/supervise/status/teardown
  #    all agree on ONE cluster even across separate container invocations.
  if [ -s "$d/.cloud_run/JOBNAME" ]; then cat "$d/.cloud_run/JOBNAME"; return 0; fi
  # 2) host-unique run id from the `mda` wrapper. The in-container dir is always
  #    /work, so deriving from $d alone would collide across replicas — MDAGENT_RUN_ID
  #    carries the HOST folder identity.
  if [ -n "${MDAGENT_RUN_ID:-}" ]; then
    echo "gmx-$(printf '%s' "$MDAGENT_RUN_ID" | tr 'A-Z_' 'a-z-' | tr -cd 'a-z0-9-')"; return 0
  fi
  # 3) fallback: basename + hash of the absolute path (correct for non-/work paths,
  #    e.g. `local` runs or direct host use).
  base="$(echo "gmx-$(basename "$d")" | tr 'A-Z_' 'a-z-' | tr -cd 'a-z0-9-')"
  h="$(printf '%s' "$d" | cksum | cut -d' ' -f1)"
  echo "${base}-$(printf '%x' "$h")"
}
# Persist the resolved cluster name so every later subcommand resolves identically.
persist_jobname() {  # $1=REPLICA_DIR  $2=JOB
  mkdir -p "$1/.cloud_run" 2>/dev/null || true
  printf '%s' "$2" > "$1/.cloud_run/JOBNAME" 2>/dev/null || true
}

stage_dir() { echo "$1/.cloud_run"; }
store_dir() { echo "$1/.cloud_state"; }
suplog_of() { echo "$1/.cloud_supervise.log"; }
suppid_of() { echo "$1/.cloud_supervise.pid"; }

# ---- ssh/rsync to the SkyPilot cluster (alias == cluster name) --------------
SSH_OPTS='ssh -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=3'

# ===================== self-contained bootstrap ==============================
ensure_tools() {
  command -v rsync >/dev/null 2>&1 || die "rsync not found locally — install it first (e.g. sudo apt-get install rsync)."
  local miss=0
  command -v "$SKY" >/dev/null 2>&1 || miss=1
  command -v "$VASTAI" >/dev/null 2>&1 || miss=1
  if [ "$miss" = 1 ]; then
    say "Installing SkyPilot + vastai CLI (one-time)…"
    "$PY" -m pip install --upgrade "skypilot[vast]" vastai >/tmp/cloud_tools_pip.log 2>&1 \
      || die "pip install of skypilot[vast]/vastai failed — see /tmp/cloud_tools_pip.log"
  fi
  command -v "$SKY" >/dev/null 2>&1 || die "sky still not found after install"
  command -v "$VASTAI" >/dev/null 2>&1 || die "vastai still not found after install"
  ok "sky + vastai + rsync present"
}

ensure_vast_key() {
  local VKEY="$HOME/.config/vastai/vast_api_key"
  if [ -s "$VKEY" ]; then ok "Vast.ai API key present"; return 0; fi
  if [ -n "${VAST_API_KEY:-}" ]; then
    mkdir -p "$(dirname "$VKEY")"; umask 077; printf '%s' "$VAST_API_KEY" > "$VKEY"
    ok "Vast.ai API key stored from \$VAST_API_KEY"; return 0
  fi
  [ -t 0 ] || die "No Vast.ai API key at $VKEY and no TTY to prompt. Set VAST_API_KEY=… or run: vastai set api-key <KEY>"
  echo "No Vast.ai API key found. Create/copy one at https://cloud.vast.ai/account"
  local k=""; read -rsp "Paste your Vast.ai API key (input hidden): " k; echo
  [ -n "$k" ] || die "empty API key"
  if "$VASTAI" set api-key "$k" >/dev/null 2>&1; then :; else
    mkdir -p "$(dirname "$VKEY")"; umask 077; printf '%s' "$k" > "$VKEY"
  fi
  unset k
  [ -s "$VKEY" ] && ok "Vast.ai API key stored." || die "failed to store Vast.ai API key"
}

# read pushover creds (never printed) -> PUSHOVER_TOKEN / PUSHOVER_USER
read_pushover() {
  PUSHOVER_TOKEN=""; PUSHOVER_USER=""
  local api_token="" api_key="" user_key=""
  if [ -f "$PUSHOVER_CONFIG" ]; then
    # shellcheck disable=SC1090
    source "$PUSHOVER_CONFIG" >/dev/null 2>&1 || true
    PUSHOVER_TOKEN="${api_token:-${api_key:-}}"
    PUSHOVER_USER="${user_key:-}"
  fi
  PUSHOVER_TOKEN="${PUSHOVER_TOKEN_OVERRIDE:-$PUSHOVER_TOKEN}"
  PUSHOVER_USER="${PUSHOVER_USER_OVERRIDE:-$PUSHOVER_USER}"
}

ensure_pushover() {
  read_pushover
  if [ -n "$PUSHOVER_TOKEN" ] && [ -n "$PUSHOVER_USER" ]; then ok "Pushover credentials present"; return 0; fi
  if [ ! -t 0 ]; then echo "  NOTE: no Pushover creds and no TTY — phone notifications disabled."; return 0; fi
  echo "Pushover can text your phone at start / each stage / completion / failure."
  local yn=""; read -rp "Set up Pushover now? [y/N]: " yn
  case "$yn" in [Yy]*) ;; *) echo "  Skipping Pushover (notifications disabled)."; return 0;; esac
  local t="" u=""
  read -rsp "Pushover application API token/key: " t; echo
  read -rsp "Pushover user key: " u; echo
  if [ -z "$t" ] || [ -z "$u" ]; then echo "  Empty — skipping Pushover."; return 0; fi
  mkdir -p "$(dirname "$PUSHOVER_CONFIG")"
  ( umask 077; { printf 'api_token="%s"\n' "$t"; printf 'user_key="%s"\n' "$u"; } > "$PUSHOVER_CONFIG" )
  unset t u
  read_pushover
  [ -n "$PUSHOVER_TOKEN" ] && [ -n "$PUSHOVER_USER" ] && ok "Pushover configured ($PUSHOVER_CONFIG)" \
    || echo "  WARN: could not read back Pushover config."
}

# Install a local CPU GROMACS used ONLY for the trjconv/trjcat analysis (no GPU
# needed). Sets LOCAL_GMX. Reuses any gmx already on PATH or the gmxcloud env.
ensure_local_gmx() {
  if [ -n "$LOCAL_GMX" ] && command -v "$LOCAL_GMX" >/dev/null 2>&1; then ok "local gmx: $LOCAL_GMX"; return 0; fi
  if command -v gmx >/dev/null 2>&1; then LOCAL_GMX="$(command -v gmx)"; ok "local gmx: $LOCAL_GMX"; return 0; fi
  local envgmx="$HOME/anaconda3/envs/$GMXCLOUD_ENV/bin/gmx"
  [ -x "$envgmx" ] && { LOCAL_GMX="$envgmx"; ok "local gmx: $LOCAL_GMX"; return 0; }
  say "Installing a local CPU GROMACS for analysis (conda env '$GMXCLOUD_ENV', one-time)…"
  if command -v conda >/dev/null 2>&1; then
    conda create -y -n "$GMXCLOUD_ENV" -c conda-forge 'gromacs=2024.2=nompi_*' >/tmp/gmxcloud_install.log 2>&1 \
      || conda create -y -n "$GMXCLOUD_ENV" -c conda-forge gromacs >>/tmp/gmxcloud_install.log 2>&1 || true
  fi
  if [ ! -x "$envgmx" ]; then
    local MM="$HOME/bin/micromamba"
    if [ ! -x "$MM" ]; then
      mkdir -p "$HOME/bin"
      curl -Ls https://micro.mamba.pm/api/micromamba/linux-64/latest -o /tmp/mm.tar.bz2 2>/dev/null \
        && { tar -xj -f /tmp/mm.tar.bz2 -C "$HOME" --strip-components=1 bin/micromamba 2>/dev/null \
             || tar -xjf /tmp/mm.tar.bz2 -C "$HOME" bin/micromamba 2>/dev/null; } || true
    fi
    if [ -x "$MM" ]; then
      envgmx="$HOME/micromamba/envs/$GMXCLOUD_ENV/bin/gmx"
      MAMBA_ROOT_PREFIX="$HOME/micromamba" "$MM" create -y -n "$GMXCLOUD_ENV" -c conda-forge 'gromacs=2024.2=nompi_*' >>/tmp/gmxcloud_install.log 2>&1 \
        || MAMBA_ROOT_PREFIX="$HOME/micromamba" "$MM" create -y -n "$GMXCLOUD_ENV" -c conda-forge gromacs >>/tmp/gmxcloud_install.log 2>&1 || true
    fi
  fi
  [ -x "$envgmx" ] || die "could not install a local gmx for analysis (see /tmp/gmxcloud_install.log). Set LOCAL_GMX=/path/to/gmx and retry."
  LOCAL_GMX="$envgmx"; ok "local gmx: $LOCAL_GMX"
}

# ------------------------- Vast instance lookup ------------------------------
# Resolve the Vast instance backing SkyPilot cluster $1. SkyPilot labels the
# instance "<cluster_name_on_cloud>-head", and cluster_name_on_cloud starts with
# our cluster name + '-', so match startswith("<job>-") & endswith("-head") (the
# trailing '-' avoids gmx-x-1 vs gmx-x-11 prefix collisions). Echoes
# "vast#<id>/<gpu>" or "vast#?".
# Echoes "vast#<id>/<gpu>" (present), "vast#?" (CONFIRMED absent — valid empty/no-match
# listing), or "vast#ERR" (API call FAILED — state UNKNOWN, must NOT be read as absent).
vast_desc() {
  local raw rc
  set +e; raw="$("$VASTAI" show instances --raw 2>/dev/null)"; rc=$?; set -e
  if [ "$rc" -ne 0 ] || [ -z "$raw" ]; then echo "vast#ERR"; return 0; fi
  printf '%s' "$raw" | python3 -c '
import sys, json
job = sys.argv[1]
try: data = json.load(sys.stdin)
except Exception:
    print("vast#ERR"); sys.exit(0)
out = "vast#?"
for o in (data or []):
    lab = str(o.get("label") or "")
    if lab.startswith(job + "-") and lab.endswith("-head"):
        gid = o.get("id"); gpu = (o.get("gpu_name") or "").replace(" ", "")
        out = ("vast#%s/%s" % (gid, gpu)) if gpu else ("vast#%s" % gid)
        break
print(out)
' "$1" 2>/dev/null || echo "vast#ERR"
}
refresh_vast_id() { VAST_ID="$(vast_desc "$1")"; return 0; }

# Echo the Vast MACHINE id backing cluster $1 (the physical host, for blocklisting),
# or nothing. Distinct from vast_desc, which returns the per-rental INSTANCE id.
machine_of() {
  local raw rc
  set +e; raw="$("$VASTAI" show instances --raw 2>/dev/null)"; rc=$?; set -e
  [ "$rc" -ne 0 ] || [ -z "$raw" ] && return 0
  printf '%s' "$raw" | python3 -c '
import sys, json
job = sys.argv[1]
try: data = json.load(sys.stdin)
except Exception: sys.exit(0)
for o in (data or []):
    lab = str(o.get("label") or "")
    if lab.startswith(job + "-") and lab.endswith("-head"):
        m = o.get("machine_id")
        if m is not None: print(m)
        break
' "$1" 2>/dev/null || true
}

# ------------------------- progress ------------------------------------------
# Overall progress bar+pct from the pulled stage markers, using the on-prem
# weights (EM 2, NVT 3, NPT 5, production 85 split across stages, analysis 5).
# $1 STORE  $2 N_STAGES  $3=1 -> local analysis finished (forces 100%).
progress_str() {
  local STORE="$1" N="$2" adone="${3:-0}" mode="${4:-normal}" pct filled i b="" equil=0 span=85 np
  if [ "$mode" = "extend" ]; then
    span=95                                  # no EM/NVT/NPT in an extension
  else
    [ -f "$STORE/status/EM_DONE" ]  && equil=$((equil+2))
    [ -f "$STORE/status/NVT_DONE" ] && equil=$((equil+3))
    [ -f "$STORE/status/NPT_DONE" ] && equil=$((equil+5))
  fi
  np=$( { find "$STORE/status" -maxdepth 1 -name 'PROD_*_DONE' 2>/dev/null || true; } | wc -l | tr -d ' ')
  pct=$(awk -v e="$equil" -v sp="$span" -v np="$np" -v N="$N" -v ad="$adone" 'BEGIN{
    p=e+(N>0?sp*np/N:0); if(ad==1)p=100; if(p>100)p=100; printf "%.0f",p }')
  filled=$(( pct/10 ))
  for ((i=0;i<10;i++)); do if [ "$i" -lt "$filled" ]; then b="${b}█"; else b="${b}░"; fi; done
  printf '▕%s▏ %s%%' "$b" "$pct"
}

# Finer within-stage readout (for `status`, on demand): parse nsteps + current
# step from the newest GROMACS .log. Echoes "md_partNN: step X/Y (Z%)" or "".
stage_step_str() {
  local STORE="$1" log nsteps cur
  # find (not ls<glob>) so no-match exits 0 — under `set -o pipefail` a literal-glob
  # `ls` exits 2 and would crash the assignment via set -e.
  log=$( { find "$STORE" -maxdepth 1 -name 'md_part*.log' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-; } || true )
  [ -n "$log" ] && [ -f "$log" ] || return 0
  nsteps=$(grep -m1 -E 'nsteps[[:space:]]*=' "$log" 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)
  cur=$(awk 'tolower($1)=="step" && tolower($2)=="time"{getline; gsub(/^[[:space:]]+/,""); s=$1} END{if(s!="")print s}' "$log" 2>/dev/null)
  [ -n "$nsteps" ] && [ -n "$cur" ] || return 0
  awk -v c="$cur" -v n="$nsteps" -v f="$(basename "$log")" 'BEGIN{
    p=(n>0?100.0*c/n:0); if(p>100)p=100; printf "%s: step %d/%d (%.0f%%)", f, c, n, p }'
}

# ------------------------- Pushover send (local) -----------------------------
# Every message carries the folder title ($TAG) and the Vast instance id/gpu
# ($VAST_ID), set by callers; both are read via bash dynamic scope.
PUSHOVER_SH="$PREP/pushover.sh"
notify() {
  local msg="$1" title="${2:-replica}" priority="${3:-0}"
  local ctx="[${TAG:-replica} · ${VAST_ID:-vast pending}]"
  read_pushover
  # -f not -x: we run it via `bash`, so the exec bit (often dropped by git) is irrelevant
  if [ -f "$PUSHOVER_SH" ] && [ -n "$PUSHOVER_TOKEN" ] && [ -n "$PUSHOVER_USER" ]; then
    bash "$PUSHOVER_SH" -t "$PUSHOVER_TOKEN" -u "$PUSHOVER_USER" \
      -T "$title" -p "$priority" ${PUSHOVER_DEVICE:+-d "$PUSHOVER_DEVICE"} \
      "$msg  $ctx" >/dev/null 2>&1 || true
  fi
  return 0   # never let a missing-creds branch trip `set -e` in callers
}

# ===================== staging + rendering ===================================
stage_workdir() {
  local REPLICA_DIR="$1" mode="${2:-fresh}" STAGE; STAGE="$(stage_dir "$REPLICA_DIR")"
  rm -rf "$STAGE"; mkdir -p "$STAGE/mdp"
  local f
  cp -p "$HERE/node/run_pipeline.sh"     "$STAGE/run_pipeline.sh"
  cp -p "$HERE/node/cloud_node_setup.sh" "$STAGE/cloud_node_setup.sh"
  if [ "$mode" = "extend" ]; then
    # Extension only needs the existing run's .tpr + .cpt (the big .xtc stays
    # LOCAL and is concatenated during analysis). convert-tpr + mdrun -cpi carry
    # the topology/parameters, so no pdb/top/itp/mdp are uploaded.
    cp -p "$REPLICA_DIR/${EXT_BASE}.tpr" "$STAGE/${EXT_BASE}.tpr"
    cp -p "$REPLICA_DIR/${EXT_BASE}.cpt" "$STAGE/${EXT_BASE}.cpt"
    chmod +x "$STAGE/run_pipeline.sh" "$STAGE/cloud_node_setup.sh"
    return 0
  fi
  # General GROMACS inputs: upload the standard input file types + any local
  # force-field dirs (e.g. charmm36.ff). Trajectories (*.xtc/*.trr) are NOT
  # uploaded. Equilibration restart outputs (*.gro/*.cpt) come along via the
  # globs, letting the node skip/resume finished phases.
  ( shopt -s nullglob
    for f in "$REPLICA_DIR"/*.gro "$REPLICA_DIR"/*.pdb "$REPLICA_DIR"/*.top \
             "$REPLICA_DIR"/*.itp "$REPLICA_DIR"/*.ndx "$REPLICA_DIR"/*.cpt; do
      cp -p "$f" "$STAGE/"
    done
    for d in "$REPLICA_DIR"/*.ff; do [ -d "$d" ] && cp -rp "$d" "$STAGE/"; done )
  # Phase mdps from env, staged under canonical names (only those provided).
  [ -n "$EM_MDP" ]  && cp -p "$EM_MDP"  "$STAGE/mdp/em.mdp"
  [ -n "$NVT_MDP" ] && cp -p "$NVT_MDP" "$STAGE/mdp/nvt.mdp"
  [ -n "$NPT_MDP" ] && cp -p "$NPT_MDP" "$STAGE/mdp/npt.mdp"
  cp -p "$PROD_MDP" "$STAGE/mdp/prod.mdp"
  chmod +x "$STAGE/run_pipeline.sh" "$STAGE/cloud_node_setup.sh"
  return 0
}

render_yaml() {
  local REPLICA_DIR="$1" TAG JOB STAGE
  TAG="$(tag_of "$REPLICA_DIR")"; JOB="$(jobname_of "$REPLICA_DIR")"; STAGE="$(stage_dir "$REPLICA_DIR")"
  # shellcheck disable=SC1090
  source "$HERE/cloud_selection.env"
  local spot_line region_line maxcost_line DISK
  [ "$SEL_USE_SPOT" = "true" ] && spot_line="use_spot: true" || spot_line="# on-demand"
  [ -n "${SEL_REGION:-}" ] && region_line="region: $SEL_REGION" || region_line="# region: (any)"
  [ -n "${SEL_MAX_HOURLY:-}" ] && maxcost_line="max_hourly_cost: $SEL_MAX_HOURLY" || maxcost_line="# max_hourly_cost: (none)"
  DISK="${SEL_DISK_GB:-$DISK_GB}"
  sed -e "s|@@JOBNAME@@|$JOB|g" \
      -e "s|@@ACCEL@@|$SEL_ACCEL|g" \
      -e "s|@@DISK@@|$DISK|g" \
      -e "s|@@IMAGE@@|$IMAGE|g" \
      -e "s|@@SPOT_LINE@@|$spot_line|g" \
      -e "s|@@REGION_LINE@@|$region_line|g" \
      -e "s|@@MAXCOST_LINE@@|$maxcost_line|g" \
      -e "s|@@TAG@@|$TAG|g" \
      -e "s|@@TOTAL_NS@@|$TOTAL_NS|g" \
      -e "s|@@STAGE_NS@@|$STAGE_NS|g" \
      -e "s|@@CKPT_MIN@@|$CKPT_MIN|g" \
      -e "s|@@MAXH_PER_STAGE@@|$MAXH_PER_STAGE|g" \
      -e "s|@@KEEPALIVE_MAXH@@|$KEEPALIVE_MAXH|g" \
      -e "s|@@NT@@|${NT:-}|g" \
      -e "s|@@AUTOTUNE@@|${AUTOTUNE:-1}|g" \
      -e "s|@@BENCH_STEPS@@|${BENCH_STEPS:-4000}|g" \
      -e "s|@@IMAGE_KIND@@|$IMAGE_KIND|g" \
      -e "s|@@CONDA_SPEC@@|$CONDA_SPEC|g" \
      -e "s|@@START_STRUCT@@|${START_STRUCT:-}|g" \
      -e "s|@@TOP@@|${TOP}|g" \
      -e "s|@@INDEX@@|${INDEX}|g" \
      -e "s|@@MAXWARN@@|${MAXWARN}|g" \
      -e "s|@@EXTEND_BASE@@|${EXT_BASE:-}|g" \
      -e "s|@@EXTEND_TO_PS@@|${EXT_TO_PS:-}|g" \
      "$HERE/gromacs_md.sky.yaml.tmpl" > "$STAGE/gromacs_md.sky.yaml"
}

# ===================== rsync pull / push =====================================
# Pull the node's working set into the local durable store. Returns the rc of
# the critical pass (metadata/checkpoints); the bulk-trajectory pass is best
# effort. Two passes because GROMACS REWRITES .cpt in place at the same size, so
# `--append` would wrongly skip an updated checkpoint — only the append-only
# .xtc may use --append (avoids re-reading multi-GB files each cycle).
pull_state() {
  local JOB="$1" STORE="$2" rc
  mkdir -p "$STORE"
  # Pass A: small/rewritten files (default size+mtime delta). The .cpt MUST come
  # through here, not via --append, so a fresh checkpoint is always pulled.
  # (guarded so `set -e` doesn't exit before we capture the rc)
  set +e
  rsync -az --partial --timeout=60 -e "$SSH_OPTS" --prune-empty-dirs \
    --include='status/' --include='status/**' \
    --include='*.tpr' --include='*.cpt' \
    --include='em.gro' --include='nvt.gro' --include='nvt.cpt' \
    --include='npt.gro' --include='npt.cpt' \
    --include='md_part*.gro' --include='md_ext*.gro' \
    --include='*.edr' --include='*.log' --include='*.mdp' \
    --include='run_pipeline.log' \
    --exclude='*' \
    "$JOB:sky_workdir/" "$STORE/"
  rc=$?
  set -e
  # Pass B: append-only trajectories (large) — best effort, --append (safe because
  # the node always resumes with -noappend, so .xtc are strictly append-only).
  if [ "$rc" -eq 0 ]; then
    rsync -az --partial --append --timeout=120 -e "$SSH_OPTS" --prune-empty-dirs \
      --include='md_part*.xtc' --include='md_ext*.xtc' --exclude='*' \
      "$JOB:sky_workdir/" "$STORE/" || true
  fi
  return "$rc"
}

# SSH-list the node's trajectory files with sizes; rc!=0 => node UNREACHABLE only.
# Must exit 0 (empty output) when reachable-but-no-chunks-yet (EM/NVT/NPT phase),
# else pull_verified would read "unreachable" during equilibration and the recovery
# path could tear down a healthy node. nullglob drops unmatched globs; ssh transport
# failure on a truly down host still yields rc!=0.
remote_xtc_sizes() {
  $SSH_OPTS "$1" 'cd sky_workdir 2>/dev/null || exit 0; shopt -s nullglob; f=(md_part*.xtc md_ext*.xtc); [ ${#f[@]} -gt 0 ] && stat -c "%s %n" "${f[@]}" 2>/dev/null; exit 0' 2>/dev/null
}
# Tell the node its data is safely local (releases its keepalive hold).
mark_pulled_ok() { $SSH_OPTS "$1" 'mkdir -p sky_workdir/status && touch sky_workdir/status/PULLED_OK' 2>/dev/null || true; }

# Pull, then VERIFY every trajectory chunk on the node is fully present locally
# (local size >= node size). Loops up to PULL_RETRIES; an --append-verify pass
# repairs any short/partial local file. Returns: 0 = verified complete,
# 1 = still incomplete after retries, 2 = node unreachable (cannot verify).
pull_verified() {
  local JOB="$1" STORE="$2" i listing lrc mism name sz lf lsz reachable=0
  for (( i=1; i<=PULL_RETRIES; i++ )); do
    pull_state "$JOB" "$STORE" || true
    rsync -az --partial --append-verify --timeout=300 -e "$SSH_OPTS" --prune-empty-dirs \
      --include='md_part*.xtc' --include='md_ext*.xtc' --exclude='*' \
      "$JOB:sky_workdir/" "$STORE/" 2>/dev/null || true
    set +e; listing="$(remote_xtc_sizes "$JOB")"; lrc=$?; set -e
    if [ "$lrc" -ne 0 ]; then
      # A SINGLE failed probe must NOT declare the node dead — that's how a healthy,
      # busy node gets wrongly torn down. Retry the probe; only return 2 (unreachable)
      # if EVERY attempt fails.
      echo "[pull_verified] probe failed (attempt $i/$PULL_RETRIES) — node busy/unreachable, retrying…"; sleep 10; continue
    fi
    reachable=1
    mism=0
    while read -r sz name; do
      [ -n "${name:-}" ] || continue
      lf="$STORE/$name"; lsz=$(stat -c %s "$lf" 2>/dev/null || echo 0)
      [ "$lsz" -lt "$sz" ] && { mism=1; echo "[pull_verified] $name: local $lsz < node $sz"; }
    done <<< "$listing"
    [ "$mism" -eq 0 ] && { echo "[pull_verified] all trajectory chunks verified complete locally"; return 0; }
    echo "[pull_verified] incomplete (attempt $i/$PULL_RETRIES) — re-pulling…"; sleep 10
  done
  [ "$reachable" -eq 1 ] && return 1 || return 2   # 1=reachable-but-incomplete, 2=never reachable
}

# Is this job's Vast instance present?  0=present, 1=confirmed absent, 2=unknown (API error).
instance_present() {
  case "$(vast_desc "$1")" in
    vast#ERR) return 2 ;;
    vast#\?)  return 1 ;;
    *)        return 0 ;;
  esac
}

# Echo ALL Vast instance ids whose label belongs to cluster $1 (newest/highest id
# first). SkyPilot provision-failover can leave MORE THAN ONE instance under the same
# "<job>-...-head" label, so teardown/reap must handle the whole set, not just one.
vast_ids_for() {
  local raw rc
  set +e; raw="$("$VASTAI" show instances --raw 2>/dev/null)"; rc=$?; set -e
  { [ "$rc" -ne 0 ] || [ -z "$raw" ]; } && return 0
  printf '%s' "$raw" | python3 -c '
import sys, json
job = sys.argv[1]
try: data = json.load(sys.stdin)
except Exception: sys.exit(0)
ids = [int(o["id"]) for o in (data or [])
       if str(o.get("label") or "").startswith(job + "-")
       and str(o.get("label") or "").endswith("-head") and o.get("id") is not None]
for i in sorted(ids, reverse=True): print(i)
' "$1" 2>/dev/null || true
}

# Destroy ALL of this job's Vast instances (scoped to this job's label; never other
# replicas). Destroys every match — not just the first — so a failover-leaked
# duplicate cannot survive a teardown.
destroy_this_job_instance() {
  local ids id n=0
  ids="$(vast_ids_for "$1")"
  if [ -z "$ids" ]; then echo ">> no live Vast instance for $1 (already gone)"; return 0; fi
  while read -r id; do
    [ -n "$id" ] || continue
    echo ">> destroying this job's Vast instance $id"; "$VASTAI" destroy instance "$id" -y || true; n=$((n+1))
  done <<< "$ids"
  echo ">> destroyed $n instance(s) for $1"
}

# Reconcile a provision-failover LEAK: if >1 instance carries this job's label, keep
# the newest (the cluster's current node) and destroy the older leaked duplicate(s).
reap_duplicate_instances() {
  local ids cnt id first=1 n=0
  ids="$(vast_ids_for "$1")"
  [ -z "$ids" ] && return 0
  cnt="$(printf '%s\n' "$ids" | grep -c . || true)"
  [ "${cnt:-0}" -le 1 ] && return 0
  echo "[$(date '+%F %T')] WARN: $cnt instances share label $1 (SkyPilot failover leak) — keeping newest, destroying $((cnt-1)) extra(s)"
  while read -r id; do
    [ -n "$id" ] || continue
    if [ "$first" = 1 ]; then first=0; echo "  keep (newest): $id"; continue; fi
    echo "  destroy leaked duplicate: $id"; "$VASTAI" destroy instance "$id" -y || true; n=$((n+1))
  done <<< "$ids"
  [ "$n" -gt 0 ] && notify "$TAG ⛔ reaped $n leaked duplicate node(s) for $1 (SkyPilot failover)" "$TAG ⛔" 1 || true
}

# Refuse to launch over a cluster of the same name that is already UP (double
# launch / would clobber a running node). FORCE=1 overrides.
assert_cluster_free() {
  local JOB="$1"
  if "$SKY" status "$JOB" 2>/dev/null | grep -qiE '\bUP\b|\bINIT\b'; then
    [ "$FORCE" = "1" ] || die "cluster '$JOB' is already UP — teardown first (or FORCE=1). Refusing to launch over a running node."
  fi
}

# Reset the local store for a fresh run WITHOUT destroying the only copy of
# pulled-but-unanalyzed chunks: if such data exists, move it aside instead of rm.
safe_reset_store() {
  local STORE="$1" f have=0
  for f in "$STORE"/md_part*.xtc "$STORE"/md_ext*.xtc; do [ -f "$f" ] && { have=1; break; }; done
  if [ "$have" = 1 ] && [ ! -f "$STORE/prod_dry.xtc" ] && [ "$FORCE" != "1" ]; then
    local bak="${STORE}.bak-$(date +%Y%m%d-%H%M%S)"
    mv "$STORE" "$bak"
    echo ">> NOTE: prior un-analyzed chunks present — moved $STORE -> $bak (FORCE=1 to delete instead)."
  else
    rm -rf "$STORE"
  fi
  mkdir -p "$STORE"
}

# Drop saved state back into the staged workdir for a recovery launch. We push
# only .tpr/.cpt/.gro (tiny) — NOT .xtc/.edr/.log — so the node resumes the
# interrupted stage with -noappend (cross-node) and the pre-crash partial .xtc
# (kept here) is concatenated by the local analysis.
restage_state() {
  local STORE="$1" STAGE="$2" f
  rm -f "$STAGE"/*.cpt "$STAGE"/*.tpr "$STAGE"/md_part*.gro "$STAGE"/md_ext*.gro \
        "$STAGE"/em.gro "$STAGE"/nvt.gro "$STAGE"/npt.gro 2>/dev/null || true
  for f in "$STORE"/*.tpr "$STORE"/*.cpt "$STORE"/em.gro "$STORE"/nvt.gro "$STORE"/npt.gro \
           "$STORE"/md_part*.gro "$STORE"/md_ext*.gro; do
    [ -e "$f" ] && cp -pf "$f" "$STAGE/"
  done
  return 0   # globs that match nothing must not trip `set -e`
}

# ===================== local analysis (CPU gmx) ==============================
# Builds the analysis-ready trajectory locally. Fresh runs concatenate the
# md_part* stages; EXTEND runs concatenate the ORIGINAL <base>.xtc (kept local)
# with the new md_ext* chunks. trjconv pipeline + chain-ID stamping is identical
# to on-prem run_replica.sh; chain-ID stamping is skipped if the chain itps are
# absent (e.g. an extended run whose folder lacks them).
run_local_analysis() {
  local REPLICA_DIR="$1" STORE STAGE; STORE="$(store_dir "$REPLICA_DIR")"; STAGE="$(stage_dir "$REPLICA_DIR")"
  ensure_local_gmx
  local A_BASE=""
  if [ -f "$STAGE/.extend.env" ]; then
    # shellcheck disable=SC1090
    source "$STAGE/.extend.env"; A_BASE="$EXTEND_BASE"
  fi
  # Bring analysis inputs into the store (best effort): index, any itps,
  # add_chain_ids.py, and the original .xtc for an extend run.
  cp -pf "$REPLICA_DIR/$INDEX" "$STORE/" 2>/dev/null || true
  ( shopt -s nullglob; for f in "$REPLICA_DIR"/*.itp; do cp -pf "$f" "$STORE/"; done )
  cp -pf "$PREP/add_chain_ids.py" "$STORE/" 2>/dev/null || true
  [ -n "$A_BASE" ] && cp -pf "$REPLICA_DIR/${A_BASE}.xtc" "$STORE/" 2>/dev/null || true
  # analyze.sh runs ANALYSIS (none -> nothing; pmhc/hook -> dry-only post-process).
  # No solvated trajectory is ever built; raw chunks stay in $STORE (.cloud_state).
  ANALYSIS="$ANALYSIS" DRY_GROUP="$DRY_GROUP" DISK_FACTOR="$DISK_FACTOR" GMX="$LOCAL_GMX" bash "$ANALYZE_SH" "$STORE" ${A_BASE:+"$A_BASE"} || return 1
  local f
  for f in prod_dry.xtc prod_ref.pdb prod_last.pdb prod_dry.tpr; do
    cp -pf "$STORE/$f" "$REPLICA_DIR/" 2>/dev/null || true
  done
  return 0
}

# ============================ launch ==========================================
cmd_launch() {
  local REPLICA_DIR; REPLICA_DIR="$(resolve_dir "${1:-$PWD}")"
  local TAG JOB STAGE; TAG="$(tag_of "$REPLICA_DIR")"; JOB="$(jobname_of "$REPLICA_DIR")"; STAGE="$(stage_dir "$REPLICA_DIR")"
  echo "Replica folder : $REPLICA_DIR"
  echo "Replica tag    : $TAG     cluster/job: $JOB"

  [ -f "$REPLICA_DIR/$TOP" ] || die "topology '$TOP' not found in $REPLICA_DIR (set TOP/--top)"
  [ -n "$PROD_MDP" ] && [ -f "$PROD_MDP" ] || die "production mdp not set/found (set PROD_MDP/--prod-mdp)"
  if [ -n "$START_STRUCT" ]; then
    [ -f "$REPLICA_DIR/$START_STRUCT" ] || die "starting structure '$START_STRUCT' not found in $REPLICA_DIR"
  else
    # NB: `ls a b` returns nonzero if ANY glob is empty — check existence robustly.
    _hs=0; for _s in "$REPLICA_DIR"/*.gro "$REPLICA_DIR"/*.pdb; do [ -f "$_s" ] && { _hs=1; break; }; done
    [ "$_hs" = 1 ] || die "no .gro/.pdb starting structure in $REPLICA_DIR (set START_STRUCT/--struct)"
  fi

  say "Bootstrap (tools + Vast key)"
  ensure_tools
  ensure_vast_key
  if [ "${RENDER_ONLY:-0}" != "1" ]; then
    ensure_pushover
    ensure_local_gmx   # surface analysis-gmx install failures NOW, not days later
  fi

  # selection (node pick) ----------------------------------------------------
  if [ ! -f "$HERE/cloud_selection.env" ] || [ "${REPICK:-0}" = "1" ]; then
    say "No selection yet — launching the offer browser…"
    DISK_GB="$DISK_GB" TOTAL_NS="$TOTAL_NS" STAGE_NS="$STAGE_NS" bash "$HERE/list_offers.sh"
  fi
  [ -f "$HERE/cloud_selection.env" ] || die "no cloud_selection.env — pick an offer first."
  # shellcheck disable=SC1090
  source "$HERE/cloud_selection.env"
  echo ">> selection: GPU=$SEL_ACCEL spot=$SEL_USE_SPOT max\$/hr=$SEL_MAX_HOURLY region=${SEL_REGION:-any}"
  echo "   estimated ~\$$SEL_EST_TOTAL over ~$SEL_EST_DAYS days for $TOTAL_NS ns"

  local STORE; STORE="$(store_dir "$REPLICA_DIR")"
  safe_reset_store "$STORE"            # fresh run, but never delete un-analyzed chunks
  stage_workdir "$REPLICA_DIR"
  persist_jobname "$REPLICA_DIR" "$JOB"   # lock the cluster name so all subcommands agree
  render_yaml "$REPLICA_DIR"
  say "Rendered job spec: $STAGE/gromacs_md.sky.yaml"

  if [ "${RENDER_ONLY:-0}" = "1" ]; then
    say "RENDER_ONLY=1 — validating the rendered spec without renting a GPU"
    python3 -c "import sky; sky.Task.from_yaml('$STAGE/gromacs_md.sky.yaml'); print('   Task.from_yaml: OK')" || die "rendered YAML failed to parse"
    ( cd "$STAGE" && "$SKY" launch --dryrun --yes ./gromacs_md.sky.yaml 2>&1 | sed -n '1,40p' ) || true
    return 0
  fi

  assert_cluster_free "$JOB"
  say "Provisioning Vast.ai node + installing GROMACS (this can take a few minutes)…"
  # Cluster mode (recovery is local-driven). The idle-autostop ($AUTOSTOP_ARGS,
  # AUTOSTOP_MIN min, default 90) is only a billing backstop for a jobless/abandoned
  # node; data safety does NOT depend on it — the node holds itself up
  # (KEEPALIVE_MAXH) until the supervisor confirms a verified pull, and teardown
  # only happens after that verified pull.
  if ! ( cd "$STAGE" && "$SKY" launch -c "$JOB" ./gromacs_md.sky.yaml -y --detach-run $AUTOSTOP_ARGS ); then
    # A failed launch can still leave a billed Vast instance (e.g. SSH-setup
    # timeout AFTER allocation). Destroy it and clear the cluster record so we
    # never leak a paid node on a failed provision.
    echo ">> sky launch failed — tearing down any partially-provisioned node for $JOB"
    destroy_this_job_instance "$JOB" || true
    "$SKY" down -y "$JOB" >/dev/null 2>&1 || true
    die "sky launch failed — check the output above (leaked instance, if any, destroyed)."
  fi

  # The node is up and the run is DETACHED (--detach-run): it is independently
  # viable and re-attachable by `watchdog`/`supervise`, and held by the node
  # keepalive + the AUTOSTOP backstop. So we deliberately do NOT arm a
  # destroy-on-exit trap — a post-launch bookkeeping hiccup (PID-file write, nohup
  # spawn) must never tear down a healthy, paid, running node. (A FAILED sky launch
  # is already cleaned up above, before the node is viable.)
  local VAST_ID=""; refresh_vast_id "$JOB" || true
  notify "Run starting on $JOB: ${TOTAL_NS} ns in $(( TOTAL_NS / STAGE_NS )) stages" "$TAG ▶" 0

  if [ "${LAUNCH_NO_SUPERVISE:-0}" = "1" ]; then
    say "LAUNCH_NO_SUPERVISE=1 — node is running; supervisor NOT spawned (caller drives it)."
    _LAUNCH_HANDOFF_OK=1; trap - EXIT   # caller (CLI) owns teardown from here
    return 0
  fi

  local SUPLOG SUPPID; SUPLOG="$(suplog_of "$REPLICA_DIR")"; SUPPID="$(suppid_of "$REPLICA_DIR")"
  say "Spawning background supervisor (pull + recover + analyze + teardown)"
  nohup bash "$0" supervise "$REPLICA_DIR" >/dev/null 2>&1 &   # supervise tees to $SUPLOG itself
  echo $! > "$SUPPID"
  _LAUNCH_HANDOFF_OK=1; trap - EXIT   # supervisor now owns the node's lifecycle
  echo "============================================================"
  echo " Launched: $JOB   (supervisor PID $(cat "$SUPPID"))"
  echo "   follow   : $0 follow $REPLICA_DIR     (tails $SUPLOG)"
  echo "   node logs: $SKY logs $JOB"
  echo "   status   : $0 status $REPLICA_DIR"
  echo "   teardown : $0 teardown $REPLICA_DIR"
  echo " Outputs are pulled into $(store_dir "$REPLICA_DIR")/ as stages finish;"
  echo " final prod*.xtc / prod_*.pdb are written to $REPLICA_DIR/ at the end."
  echo " Keep this machine online; supervisor survives terminal close. The node holds"
  echo " itself up (~${KEEPALIVE_MAXH}h) until a verified pull, so a brief outage won't lose data."
  echo " For long runs, auto-restart a dead supervisor via cron:"
  echo "   */10 * * * * bash $0 watchdog $REPLICA_DIR"
  echo "============================================================"
}

# ============================ extend ==========================================
# End time (ps) baked into a .tpr (= nsteps*dt), read locally with the analysis gmx.
local_tpr_end_ps() {
  "$LOCAL_GMX" dump -s "$1" 2>/dev/null | awk '
    /^[[:space:]]*nsteps[[:space:]]*=/{ns=$NF}
    /^[[:space:]]*dt[[:space:]]*=/{dt=$NF}
    END{ if(ns!=""&&dt!="") printf "%.6f", ns*dt }'
}

# Continue an existing GROMACS run (any origin) on a cloud GPU.
#   EXTEND_FROM=<basename|path>   existing run, expects <base>.tpr + <base>.cpt
#   EXTEND_TO_NS=<ns>   absolute target end time, OR
#   EXTEND_BY_NS=<ns>   additional ns to add on top of the current length
cmd_extend() {
  local REPLICA_DIR; REPLICA_DIR="$(resolve_dir "${1:-$PWD}")"
  local TAG JOB STAGE STORE; TAG="$(tag_of "$REPLICA_DIR")"; JOB="$(jobname_of "$REPLICA_DIR")"
  STAGE="$(stage_dir "$REPLICA_DIR")"; STORE="$(store_dir "$REPLICA_DIR")"
  [ -n "${EXTEND_FROM:-}" ] || die "set EXTEND_FROM=<basename> (expects <base>.tpr and <base>.cpt in the folder)"
  EXT_BASE="$(basename "$EXTEND_FROM")"; EXT_BASE="${EXT_BASE%.tpr}"; EXT_BASE="${EXT_BASE%.cpt}"; EXT_BASE="${EXT_BASE%.xtc}"
  local btpr="$REPLICA_DIR/${EXT_BASE}.tpr" bcpt="$REPLICA_DIR/${EXT_BASE}.cpt" bxtc="$REPLICA_DIR/${EXT_BASE}.xtc"
  echo "Replica folder : $REPLICA_DIR"
  echo "Extend base    : $EXT_BASE     cluster/job: $JOB"
  [ -f "$btpr" ] || die "missing $btpr"
  [ -f "$bcpt" ] || die "missing $bcpt"
  # The original segment lives ONLY in $bxtc; without it the final trajectory
  # would silently contain only the extension. Hard-error unless explicitly opted out.
  if [ ! -f "$bxtc" ]; then
    [ "${NEW_SEGMENT_ONLY:-0}" = "1" ] || die "missing $bxtc — the original segment would be dropped. Provide it, or set NEW_SEGMENT_ONLY=1 to intentionally keep only the new segment."
    echo ">> NEW_SEGMENT_ONLY=1 — proceeding; final trajectory will contain only the NEW segment."
  fi

  say "Bootstrap (tools + Vast key + local gmx)"
  ensure_tools; ensure_vast_key
  [ "${RENDER_ONLY:-0}" = "1" ] || ensure_pushover
  ensure_local_gmx     # needed to read the current end time of the .tpr

  local cur_ps cur_ns target_ns added_ns n_ext
  cur_ps="$(local_tpr_end_ps "$btpr" || true)"   # tolerate gmx-dump failure so the -n guard below fires
  [ -n "$cur_ps" ] || die "could not read end time from $btpr (gmx dump failed)"
  cur_ns=$(awk -v p="$cur_ps" 'BEGIN{printf "%g", p/1000}')
  if [ -n "${EXTEND_TO_NS:-}" ]; then
    target_ns="$EXTEND_TO_NS"
  elif [ -n "${EXTEND_BY_NS:-}" ]; then
    target_ns=$(awk -v c="$cur_ns" -v d="$EXTEND_BY_NS" 'BEGIN{printf "%g", c+d}')
  else
    die "set EXTEND_TO_NS=<absolute ns> or EXTEND_BY_NS=<delta ns>"
  fi
  awk -v c="$cur_ns" -v t="$target_ns" 'BEGIN{exit !(t>c+1e-9)}' || die "target ${target_ns} ns is not beyond current ${cur_ns} ns"
  added_ns=$(awk -v c="$cur_ns" -v t="$target_ns" 'BEGIN{printf "%g", t-c}')
  EXT_TO_PS=$(awk -v t="$target_ns" 'BEGIN{printf "%.6f", t*1000}')
  n_ext=$(awk -v d="$added_ns" -v s="$STAGE_NS" 'BEGIN{n=int(d/s); if(n*s < d-1e-9)n++; if(n<1)n=1; print n}')
  echo ">> current ${cur_ns} ns -> target ${target_ns} ns  (+${added_ns} ns) in ${n_ext} x ${STAGE_NS} ns chunks"

  if [ ! -f "$HERE/cloud_selection.env" ] || [ "${REPICK:-0}" = "1" ]; then
    say "No selection yet — launching the offer browser… (cost estimated for the +${added_ns} ns)"
    DISK_GB="$DISK_GB" TOTAL_NS="$(awk -v a="$added_ns" 'BEGIN{printf "%d", (a<1?1:a)}')" STAGE_NS="$STAGE_NS" bash "$HERE/list_offers.sh"
  fi
  [ -f "$HERE/cloud_selection.env" ] || die "no cloud_selection.env — pick an offer first."
  # shellcheck disable=SC1090
  source "$HERE/cloud_selection.env"
  echo ">> selection: GPU=$SEL_ACCEL spot=$SEL_USE_SPOT max\$/hr=$SEL_MAX_HOURLY"

  safe_reset_store "$STORE"            # fresh extension, but never delete un-analyzed chunks
  stage_workdir "$REPLICA_DIR" extend
  persist_jobname "$REPLICA_DIR" "$JOB"
  render_yaml "$REPLICA_DIR"
  { echo "EXTEND_BASE=\"$EXT_BASE\""
    echo "EXTEND_STAGES=$n_ext"
    echo "EXTEND_CURRENT_NS=$cur_ns"
    echo "EXTEND_TO_NS=$target_ns"; } > "$STAGE/.extend.env"
  say "Rendered job spec: $STAGE/gromacs_md.sky.yaml  (EXTEND $EXT_BASE -> ${target_ns} ns)"

  if [ "${RENDER_ONLY:-0}" = "1" ]; then
    say "RENDER_ONLY=1 — validating the rendered spec without renting a GPU"
    python3 -c "import sky; sky.Task.from_yaml('$STAGE/gromacs_md.sky.yaml'); print('   Task.from_yaml: OK')" || die "rendered YAML failed to parse"
    ( cd "$STAGE" && "$SKY" launch --dryrun --yes ./gromacs_md.sky.yaml 2>&1 | sed -n '1,40p' ) || true
    return 0
  fi

  assert_cluster_free "$JOB"
  say "Provisioning Vast.ai node + installing GROMACS…"
  if ! ( cd "$STAGE" && "$SKY" launch -c "$JOB" ./gromacs_md.sky.yaml -y --detach-run $AUTOSTOP_ARGS ); then
    # A failed launch can still leave a billed Vast instance (e.g. SSH-setup
    # timeout AFTER allocation). Destroy it and clear the cluster record so we
    # never leak a paid node on a failed provision.
    echo ">> sky launch failed — tearing down any partially-provisioned node for $JOB"
    destroy_this_job_instance "$JOB" || true
    "$SKY" down -y "$JOB" >/dev/null 2>&1 || true
    die "sky launch failed — check the output above (leaked instance, if any, destroyed)."
  fi
  # Detached run is independently viable (see cmd_launch) — no destroy-on-exit trap.
  local VAST_ID=""; refresh_vast_id "$JOB" || true
  notify "Extending $EXT_BASE on $JOB: ${cur_ns} -> ${target_ns} ns (+${added_ns}, $n_ext chunks)" "$TAG ▶" 0

  if [ "${LAUNCH_NO_SUPERVISE:-0}" = "1" ]; then
    say "LAUNCH_NO_SUPERVISE=1 — node is running; supervisor NOT spawned (caller drives it)."
    _LAUNCH_HANDOFF_OK=1; trap - EXIT   # caller (CLI) owns teardown from here
    return 0
  fi
  local SUPLOG SUPPID; SUPLOG="$(suplog_of "$REPLICA_DIR")"; SUPPID="$(suppid_of "$REPLICA_DIR")"
  say "Spawning background supervisor (pull + recover + analyze + teardown)"
  nohup bash "$0" supervise "$REPLICA_DIR" >/dev/null 2>&1 &   # supervise tees to $SUPLOG itself
  echo $! > "$SUPPID"
  _LAUNCH_HANDOFF_OK=1; trap - EXIT   # supervisor now owns the node's lifecycle
  echo "============================================================"
  echo " Extending: $JOB  (supervisor PID $(cat "$SUPPID"))   ${cur_ns} -> ${target_ns} ns"
  echo "   follow   : $0 follow $REPLICA_DIR"
  echo "   status   : $0 status $REPLICA_DIR"
  echo "   teardown : $0 teardown $REPLICA_DIR"
  echo " Original ${EXT_BASE}.xtc stays here; the full extended prod*.xtc is written to $REPLICA_DIR/ at the end."
  echo "============================================================"
}

# ============================ supervise =======================================
# The durability + recovery loop. Pulls node state every SYNC_MIN, notifies on
# new stages, recovers a dead node by relaunching with restaged state, and on
# completion runs the local analysis and tears the node down.
cmd_supervise() {
  local REPLICA_DIR; REPLICA_DIR="$(resolve_dir "${1:-$PWD}")"
  local TAG JOB STAGE STORE; TAG="$(tag_of "$REPLICA_DIR")"; JOB="$(jobname_of "$REPLICA_DIR")"
  STAGE="$(stage_dir "$REPLICA_DIR")"; STORE="$(store_dir "$REPLICA_DIR")"
  [ -f "$STAGE/gromacs_md.sky.yaml" ] || die "no rendered spec at $STAGE — run 'launch' first."
  mkdir -p "$STORE" "$STORE/status"   # status/ may not be pulled yet; keep find/globs from erroring on a missing dir
  local SUPPID SUPLOG; SUPPID="$(suppid_of "$REPLICA_DIR")"; SUPLOG="$(suplog_of "$REPLICA_DIR")"
  # Single-supervisor lock: if a LIVE supervisor other than us already owns this run,
  # exit — stops the watchdog/CLI from double-spawning racing supervisors that would
  # fight over recovery/teardown.
  if [ -f "$SUPPID" ]; then
    _op="$(cat "$SUPPID" 2>/dev/null || echo)"
    if [ -n "$_op" ] && [ "$_op" != "$$" ] && kill -0 "$_op" 2>/dev/null; then
      echo "[$(date '+%F %T')] another supervisor (PID $_op) already owns $JOB — exiting"; return 0
    fi
  fi
  echo $$ > "$SUPPID"
  # Mirror output to the supervise log so follow/status/watchdog have one source of
  # truth even when the CLI runs this in the container FOREGROUND (LAUNCH_NO_SUPERVISE).
  exec > >(tee -a "$SUPLOG") 2>&1
  echo "[$(date '+%F %T')] supervising $JOB  (pull cadence ${SYNC_MIN}m, max restarts ${MAX_RESTARTS})"

  # Machine blocklist = user-provided VAST_BLOCK_MACHINES + auto-discovered bad hosts
  # (persisted across restarts). Exported so the offer-selection patch excludes them.
  local BLOCKED_MACHINES="${VAST_BLOCK_MACHINES:-}"
  [ -s "$STORE/blocked_machines" ] && BLOCKED_MACHINES="$(cat "$STORE/blocked_machines"),$BLOCKED_MACHINES"
  BLOCKED_MACHINES="$(printf '%s' "$BLOCKED_MACHINES" | tr ', ' '\n\n' | grep -E '^[0-9]+$' | sort -un | paste -sd, -)"
  export VAST_BLOCK_MACHINES="$BLOCKED_MACHINES"
  [ -n "$BLOCKED_MACHINES" ] && echo "[$(date '+%F %T')] machine blocklist: $BLOCKED_MACHINES"

  local N_STAGES=$(( TOTAL_NS / STAGE_NS )) MODE="normal" NS_BASE=0 STAGE_WORD="production"
  if [ -f "$STAGE/.extend.env" ]; then
    # shellcheck disable=SC1090
    source "$STAGE/.extend.env"
    MODE="extend"; N_STAGES="${EXTEND_STAGES:-$N_STAGES}"; NS_BASE="${EXTEND_CURRENT_NS:-0}"; STAGE_WORD="extension"
    echo "[$(date '+%F %T')] mode=EXTEND base=${EXTEND_BASE:-?} from ${NS_BASE} ns in ${N_STAGES} x ${STAGE_NS} ns chunks"
  fi
  local restarts=0 fails=0 last_prod=0 em_done=0 nvt_done=0 npt_done=0 first_pull=1 nprod VAST_ID="" gone_confirm=0 relaunch_grace=0
  while true; do
    # resolve (or re-resolve after a recovery) the Vast instance id for messages
    if [ -z "$VAST_ID" ] || [ "$VAST_ID" = "vast#?" ]; then refresh_vast_id "$JOB"; fi
    reap_duplicate_instances "$JOB"   # clean up any SkyPilot failover-leaked duplicate node
    if pull_state "$JOB" "$STORE"; then
      fails=0
      nprod=$( { find "$STORE/status" -maxdepth 1 -name 'PROD_*_DONE' 2>/dev/null || true; } | wc -l | tr -d ' ')
      if [ "$first_pull" = 1 ]; then
        # Baseline: record what is already done WITHOUT notifying, so a (re)attach
        # of the supervisor doesn't replay milestones reached on a previous run.
        last_prod="$nprod"
        [ -f "$STORE/status/EM_DONE" ]  && em_done=1
        [ -f "$STORE/status/NVT_DONE" ] && nvt_done=1
        [ -f "$STORE/status/NPT_DONE" ] && npt_done=1
        first_pull=0
      else
        # equilibration milestones (fresh runs only; extend has no EM/NVT/NPT markers)
        if [ "$em_done" = 0 ] && [ -f "$STORE/status/EM_DONE" ]; then
          notify "$TAG: energy minimization done — $(progress_str "$STORE" "$N_STAGES" 0 "$MODE")" "$TAG ⚡" 0; em_done=1
        fi
        if [ "$nvt_done" = 0 ] && [ -f "$STORE/status/NVT_DONE" ]; then
          notify "$TAG: NVT equilibration done (1 ns) — $(progress_str "$STORE" "$N_STAGES" 0 "$MODE")" "$TAG 🌡" 0; nvt_done=1
        fi
        if [ "$npt_done" = 0 ] && [ -f "$STORE/status/NPT_DONE" ]; then
          notify "$TAG: NPT equilibration done (1 ns), production starting — $(progress_str "$STORE" "$N_STAGES" 0 "$MODE")" "$TAG 🧪" 0; npt_done=1
        fi
        # new completed production/extension chunk(s)
        if [ "$nprod" -gt "$last_prod" ]; then
          local ns_now; ns_now=$(awk -v b="$NS_BASE" -v k="$nprod" -v s="$STAGE_NS" 'BEGIN{printf "%g", b + k*s}')
          notify "$TAG: ${STAGE_WORD} chunk ${nprod}/${N_STAGES} done (~${ns_now} ns total) — $(progress_str "$STORE" "$N_STAGES" 0 "$MODE")" "$TAG ⏱" 0
        fi
        last_prod="$nprod"
      fi
    else
      fails=$((fails+1))
      echo "[$(date '+%F %T')] pull failed (consecutive=$fails) — node may be provisioning, busy, or gone"
    fi

    # terminal states (read from pulled markers)
    if [ -f "$STORE/status/ALL_DONE" ]; then
      # Guard against a premature/partial ALL_DONE (e.g. a cross-node resume that
      # skipped a chunk): require the expected chunk count before trusting it.
      local _np; _np=$( { find "$STORE/status" -maxdepth 1 -name 'PROD_*_DONE' 2>/dev/null || true; } | wc -l | tr -d ' ')
      if [ "${_np:-0}" -lt "$N_STAGES" ]; then
        notify "$TAG ⚠ ALL_DONE but only ${_np}/${N_STAGES} chunks — NOT tearing down (possible trajectory hole)" "$TAG ⚠" 1
        echo "[$(date '+%F %T')] ALL_DONE with ${_np}/${N_STAGES} PROD markers — refusing teardown; pulling + leaving node up."
        pull_verified "$JOB" "$STORE" >/dev/null 2>&1 || true
        return 1
      fi
      say "Production complete on node. VERIFIED final pull, then local analysis."
      if pull_verified "$JOB" "$STORE"; then
        mark_pulled_ok "$JOB"     # release the node's keepalive — we have everything
      else
        notify "$TAG ⚠ production done but final pull NOT verified complete — node LEFT UP, not torn down" "$TAG ⚠" 1
        echo "[$(date '+%F %T')] verified final pull FAILED — leaving node up (data still on it). Inspect/retry; FORCE=1 teardown to override."
        return 1
      fi
      notify "$TAG: ${STAGE_WORD} done — running local analysis — $(progress_str "$STORE" "$N_STAGES" 0 "$MODE")" "$TAG ▣" 0
      if run_local_analysis "$REPLICA_DIR"; then
        notify "$TAG ✅ DONE — analysis ready in $(basename "$REPLICA_DIR") — $(progress_str "$STORE" "$N_STAGES" 1 "$MODE")" "$TAG ✅" 0
        echo "[$(date '+%F %T')] DONE — prod*.xtc / prod_*.pdb in $REPLICA_DIR"
      else
        notify "$TAG ⚠ data is SAFE locally but local analysis failed — re-run analysis locally on .cloud_state" "$TAG ⚠" 1
        echo "[$(date '+%F %T')] analysis FAILED (raw chunks are verified-local); node released."
        return 1
      fi
      teardown_cluster "$REPLICA_DIR"
      return 0
    fi
    if [ -f "$STORE/status/FAILED" ]; then
      local where; where="$(cat "$STORE/status/FAILED" 2>/dev/null || echo '?')"
      say "Node reported FAILURE at: $where — pulling failure-time data (verified) first."
      pull_verified "$JOB" "$STORE" || echo "[$(date '+%F %T')] WARN: failure-time pull not fully verified"
      notify "$TAG ❌ node FAILED at: $where — data pulled to .cloud_state; node left up (~${KEEPALIVE_MAXH}h) for inspection" "$TAG ❌" 1
      echo "[$(date '+%F %T')] node FAILED at: $where — data pulled; node left up, auto-stops after keepalive."
      return 1
    fi

    # SkyPilot-level failure BEFORE the pipeline ever started (on-node setup failed
    # before run_pipeline could write status/STARTED). Strictly gated to avoid the
    # false-positive cascade that tore down healthy/producing nodes:
    #   - skip entirely if a STARTED marker exists — the node got PAST setup, so any
    #     FAILED row in `sky queue` is a stale/previous attempt, not this node's setup
    #     (a real post-start failure writes status/FAILED, handled above);
    #   - skip during a relaunch's bring-up (relaunch_grace > 0) so the previous
    #     attempt's lingering FAILED row + the not-yet-RUNNING new job don't re-fire;
    #   - only then: no active job AND a real FAILED/FAILED_SETUP (never CANCELLED —
    #     the recovery path's own `sky down` leaves that row).
    local _q=""
    [ ! -f "$STORE/status/STARTED" ] && [ "${relaunch_grace:-0}" -le 0 ] && _q="$("$SKY" queue "$JOB" 2>/dev/null || true)"
    if [ -n "$_q" ] \
       && ! printf '%s' "$_q" | grep -qwE 'RUNNING|PENDING|SETTING_UP|INIT' \
       && printf '%s' "$_q" | grep -qwE 'FAILED|FAILED_SETUP'; then
      pull_verified "$JOB" "$STORE" >/dev/null 2>&1 || true   # grab any logs first
      # Auto-blocklist the failing physical machine (broken TLS/CA, kaalia shim,
      # too-new GPU, …) so the retry below — and future runs (persisted) — never
      # re-land it. Capture the machine id BEFORE any sky down destroys the instance.
      local _mid; _mid="$(machine_of "$JOB")"
      if [ -n "$_mid" ] && ! printf ',%s,' "${BLOCKED_MACHINES:-}" | grep -q ",${_mid},"; then
        BLOCKED_MACHINES="${BLOCKED_MACHINES:+$BLOCKED_MACHINES,}$_mid"
        printf '%s' "$BLOCKED_MACHINES" > "$STORE/blocked_machines" 2>/dev/null || true
        export VAST_BLOCK_MACHINES="$BLOCKED_MACHINES"
        echo "[$(date '+%F %T')] auto-blocklisted machine $_mid after setup failure; blocklist now: $BLOCKED_MACHINES"
        notify "$TAG ⛔ auto-blocklisted bad machine $_mid (setup failed)" "$TAG ⛔" 0
      fi
      if [ "$restarts" -lt "$MAX_RESTARTS" ]; then
        # Setup failures are often TRANSIENT (mirror/download) or node-specific (a
        # broken host / too-new GPU) — relaunch on a fresh node a bounded number of
        # times rather than giving up on the first failure.
        restarts=$((restarts+1))
        notify "$TAG ↻ node setup/job FAILED — relaunching on a fresh node ($restarts/$MAX_RESTARTS)" "$TAG ↻" 1
        echo "[$(date '+%F %T')] SkyPilot FAILED for $JOB — down + restage + relaunch ($restarts/$MAX_RESTARTS)"
        "$SKY" down -y "$JOB" >/dev/null 2>&1 || true
        VAST_ID=""; restage_state "$STORE" "$STAGE"
        ( cd "$STAGE" && "$SKY" launch -c "$JOB" ./gromacs_md.sky.yaml -y --detach-run $AUTOSTOP_ARGS ) \
          && { echo "[$(date '+%F %T')] relaunched after setup failure"; fails=0; relaunch_grace=3; } \
          || echo "[$(date '+%F %T')] relaunch failed; retry next cycle"
      else
        notify "$TAG ❌ setup/job FAILED and max retries ($MAX_RESTARTS) exhausted — tearing down" "$TAG ❌" 1
        echo "[$(date '+%F %T')] SkyPilot FAILED for $JOB — retries exhausted; tearing down."
        teardown_cluster "$REPLICA_DIR"
        return 1
      fi
    fi

    # Suspected dead node. NEVER destroy a node that might still hold unpulled data:
    # only down+relaunch if CONFIRMED gone across TWO consecutive checks — never on a
    # single transient SSH blip (pull_verified retries the probe) or a Vast-API hiccup
    # (treated as UNKNOWN, not absent).
    if [ "$fails" -ge 3 ]; then
      local pvrc iprc
      if pull_verified "$JOB" "$STORE"; then pvrc=0; else pvrc=$?; fi
      if [ "$pvrc" -eq 0 ]; then
        echo "[$(date '+%F %T')] node reachable + data verified after $fails misses — false alarm, continuing"; fails=0; gone_confirm=0
      elif [ "$pvrc" -eq 1 ]; then
        gone_confirm=0
        notify "$TAG ⚠ node reachable but pull not yet complete — retrying, NOT destroying" "$TAG ⚠" 1
        echo "[$(date '+%F %T')] node alive but pull incomplete; keep retrying (no teardown)"
      else
        # pvrc=2: unreachable across all probe retries. Consult the Vast API.
        if instance_present "$JOB"; then iprc=0; else iprc=$?; fi
        if [ "$iprc" -eq 0 ]; then
          gone_confirm=0
          notify "$TAG ⚠ node unreachable but still PRESENT — NOT destroying (unpulled data may be on it)" "$TAG ⚠" 1
          echo "[$(date '+%F %T')] instance present but unreachable; refusing teardown to avoid data loss"
        elif [ "$iprc" -eq 2 ]; then
          gone_confirm=0
          notify "$TAG ⚠ Vast API unreachable — cannot confirm node state; NOT destroying" "$TAG ⚠" 1
          echo "[$(date '+%F %T')] Vast API error — node state UNKNOWN; refusing teardown, retry next cycle"
        else
          # iprc=1: CONFIRMED absent. Require two consecutive confirmations before the
          # destructive down+restage+relaunch (a single API gap must not trigger it).
          gone_confirm=$((gone_confirm+1))
          if [ "$gone_confirm" -lt 2 ]; then
            echo "[$(date '+%F %T')] node appears GONE ($gone_confirm/2) — confirming once more before relaunch"
          else
            gone_confirm=0
            if [ "$restarts" -ge "$MAX_RESTARTS" ]; then
              notify "$TAG ❌ node gone and max restarts ($MAX_RESTARTS) exhausted" "$TAG ❌" 1
              die "exhausted $MAX_RESTARTS restarts; giving up. Inspect: $SKY status ; vastai show instances"
            fi
            restarts=$((restarts+1))
            notify "$TAG ↻ node confirmed gone — recovering (restart $restarts/$MAX_RESTARTS)" "$TAG ↻" 1
            echo "[$(date '+%F %T')] node confirmed gone: sky down + restage + relaunch ($restarts/$MAX_RESTARTS)"
            "$SKY" down -y "$JOB" >/dev/null 2>&1 || true
            VAST_ID=""; restage_state "$STORE" "$STAGE"
            if ( cd "$STAGE" && "$SKY" launch -c "$JOB" ./gromacs_md.sky.yaml -y --detach-run $AUTOSTOP_ARGS ); then
              echo "[$(date '+%F %T')] relaunched $JOB; resuming pulls"; fails=0; relaunch_grace=3
            else
              echo "[$(date '+%F %T')] relaunch failed; will retry next cycle"
            fi
          fi
        fi
      fi
    fi

    [ "${relaunch_grace:-0}" -gt 0 ] && relaunch_grace=$((relaunch_grace-1))   # bring-up grace for a fresh relaunch

    # Heartbeat each cycle so `docker logs`/`follow` shows liveness between the
    # (coarser) milestone/Pushover events — makes it obvious the run is alive.
    local _phase="node setup (installing GROMACS)"
    [ -f "$STORE/status/STARTED" ] && _phase="equilibration (EM)"
    [ "$em_done"  = 1 ] && _phase="NVT"
    [ "$nvt_done" = 1 ] && _phase="NPT"
    [ "$npt_done" = 1 ] && _phase="production"
    [ "${nprod:-0}" -gt 0 ] 2>/dev/null && _phase="production ${nprod}/${N_STAGES} chunks"
    echo "[$(date '+%F %T')] ♥ $JOB | phase: ${_phase} | pull-misses: ${fails} | next pull in ${SYNC_MIN}m"

    sleep $(( SYNC_MIN * 60 ))
  done
}

# ============================ follow / status / fetch =========================
cmd_follow() {
  local REPLICA_DIR SUPLOG; REPLICA_DIR="$(resolve_dir "${1:-$PWD}")"; SUPLOG="$(suplog_of "$REPLICA_DIR")"
  [ -f "$SUPLOG" ] || die "no supervisor log at $SUPLOG — has it been launched?"
  tail -n +1 -f "$SUPLOG"
}

cmd_status() {
  local REPLICA_DIR JOB STORE SUPPID; REPLICA_DIR="$(resolve_dir "${1:-$PWD}")"
  JOB="$(jobname_of "$REPLICA_DIR")"; STORE="$(store_dir "$REPLICA_DIR")"; SUPPID="$(suppid_of "$REPLICA_DIR")"
  local N_STAGES=$(( TOTAL_NS / STAGE_NS ))
  echo "=== supervisor ==="
  if [ -f "$SUPPID" ] && kill -0 "$(cat "$SUPPID")" 2>/dev/null; then echo "  running (PID $(cat "$SUPPID"))"; else echo "  not running (use 'watchdog' to (re)start)"; fi

  # Derived run state — answers 'is it healthy / idle / keepalive-waiting / dead?'
  # and surfaces the AUTOSTOP timer (the thing that silently stops an idle node).
  local skystat autostop vd state
  skystat="$("$SKY" status --refresh "$JOB" 2>/dev/null || "$SKY" status "$JOB" 2>/dev/null || true)"
  autostop="$(printf '%s' "$skystat" | grep -oE '[0-9]+ ?m \((down|stop)\)' | head -1)"
  vd="$(vast_desc "$JOB")"
  if   [ -f "$REPLICA_DIR/prod_dry.xtc" ] || [ -f "$STORE/status/ALL_DONE" ]; then state="DONE (analysis-ready or all chunks present)"
  elif [ -f "$STORE/status/FAILED" ]; then state="FAILED — node reported an error"
  elif printf '%s' "$skystat" | grep -qiw UP; then
    if [ -f "$STORE/status/NPT_DONE" ] || { ls "$STORE"/status/PROD_*_DONE >/dev/null 2>&1; }; then state="COMPUTING (production)"
    elif [ -f "$STORE/status/STARTED" ]; then state="COMPUTING (equilibration)"
    else state="PROVISIONING / on-node GROMACS setup"; fi
  elif [ "$vd" = "vast#ERR" ]; then state="UNKNOWN (Vast API error — retry)"
  elif [ "$vd" != "vast#?" ]; then state="node present but cluster not UP (stopping / recovering?)"
  else state="DEAD / torn down (no node)"; fi
  echo "=== state ==="
  echo "  derived  : $state"
  [ -n "$autostop" ] && echo "  AUTOSTOP : $autostop  ← idle node self-terminates after this (only fires when no MD job runs)"

  echo "=== progress ==="
  local adone=0; { [ -f "$REPLICA_DIR/prod_dry.xtc" ] || [ -f "$STORE/status/ALL_DONE" ]; } && adone=1
  echo "  overall: $(progress_str "$STORE" "$N_STAGES" "$adone")"
  local sstr; sstr="$(stage_step_str "$STORE")"; [ -n "$sstr" ] && echo "  current: $sstr"
  echo "  markers: $(ls -1 "$STORE/status" 2>/dev/null | tr '\n' ' ' | sed 's/ $//' || echo '(none yet)')"
  echo "  vast   : $vd"
  echo "=== sky cluster ==="; printf '%s\n' "$skystat"
  echo "=== vast instances ==="; "$VASTAI" show instances 2>/dev/null || true
}

cmd_fetch() {
  local REPLICA_DIR JOB STORE; REPLICA_DIR="$(resolve_dir "${1:-$PWD}")"
  JOB="$(jobname_of "$REPLICA_DIR")"; STORE="$(store_dir "$REPLICA_DIR")"
  say "One-shot rsync pull $JOB:sky_workdir -> $STORE/"
  pull_state "$JOB" "$STORE" && ok "pulled" || die "pull failed (node down/unreachable?)"
  ls -la "$STORE" | grep -E 'md_part|\.cpt|\.tpr|status' || true
}

# ============================ teardown ========================================
teardown_cluster() {
  local REPLICA_DIR JOB i; REPLICA_DIR="$(resolve_dir "${1:-$PWD}")"; JOB="$(jobname_of "$REPLICA_DIR")"
  echo "[$(date '+%F %T')] sky down $JOB"
  "$SKY" down -y "$JOB" >/dev/null 2>&1 || echo "  WARN: 'sky down $JOB' failed — check '$SKY status'"
  # `sky down` can leave the Vast instance merely STOPPED — which keeps billing for
  # its reserved disk. Explicitly DESTROY this job's instance and verify it is gone.
  destroy_this_job_instance "$JOB"
  for i in 1 2 3; do
    case "$(vast_desc "$JOB")" in
      vast#\?)  echo "[$(date '+%F %T')] confirmed: $JOB Vast instance destroyed"; return 0 ;;
      vast#ERR) sleep 5 ;;                                  # API hiccup — recheck
      *)        echo "[$(date '+%F %T')] instance still present — retrying destroy"; destroy_this_job_instance "$JOB"; sleep 5 ;;
    esac
  done
  echo "  WARN: could not confirm $JOB's Vast instance is destroyed — check 'vastai show instances'"
}

cmd_teardown() {
  local REPLICA_DIR JOB STORE SUPPID; REPLICA_DIR="$(resolve_dir "${1:-$PWD}")"
  JOB="$(jobname_of "$REPLICA_DIR")"; STORE="$(store_dir "$REPLICA_DIR")"; SUPPID="$(suppid_of "$REPLICA_DIR")"
  # SAFETY: verify all trajectory is local BEFORE destroying anything. This is the
  # main guard against a manual teardown stranding unpulled data on the node.
  if [ "$FORCE" != "1" ]; then
    say "Verified pull before teardown (set FORCE=1 to skip)…"
    if pull_verified "$JOB" "$STORE"; then
      ok "all trajectory verified local — safe to tear down"
    else
      die "final pull NOT verified complete — REFUSING to destroy the node (data may still be on it).
  Re-run teardown when the node is reachable, or 'FORCE=1 ... teardown' to destroy anyway."
    fi
  else
    say "FORCE=1 — skipping the pre-teardown verified pull"
  fi
  if [ -f "$SUPPID" ] && kill -0 "$(cat "$SUPPID")" 2>/dev/null; then
    say "Stopping supervisor (PID $(cat "$SUPPID"))"; kill "$(cat "$SUPPID")" 2>/dev/null || true
  fi
  rm -f "$SUPPID" 2>/dev/null || true
  say "sky down $JOB (terminates THIS job's Vast instance)"
  teardown_cluster "$REPLICA_DIR"
  destroy_this_job_instance "$JOB"     # scoped belt-and-suspenders; never other jobs
  echo ">> Current Vast instances:"; "$VASTAI" show instances 2>/dev/null || true
  if [ "${NUKE_ALL:-0}" = "1" ]; then
    say "NUKE_ALL=1: destroying EVERY Vast instance on the account (DANGER — affects other replicas)"
    "$VASTAI" show instances --raw 2>/dev/null | python3 -c 'import sys,json;[print(o["id"]) for o in json.load(sys.stdin)]' \
      | xargs -r -n1 -I{} "$VASTAI" destroy instance {} -y
    echo ">> Remaining:"; "$VASTAI" show instances 2>/dev/null || true
  fi
}

# ============================ watchdog ========================================
# Re-spawn the supervisor if it's not running. Idempotent — safe to run from cron
# so a dead supervisor (laptop sleep/reboot/OOM) is restarted before the node's
# KEEPALIVE_MAXH window elapses. A re-attached supervisor replays no milestones.
#   */10 * * * * bash <runner> watchdog <REPLICA_DIR>   # in your crontab
cmd_watchdog() {
  local REPLICA_DIR JOB SUPPID SUPLOG; REPLICA_DIR="$(resolve_dir "${1:-$PWD}")"
  JOB="$(jobname_of "$REPLICA_DIR")"; SUPPID="$(suppid_of "$REPLICA_DIR")"; SUPLOG="$(suplog_of "$REPLICA_DIR")"
  if [ -f "$SUPPID" ] && kill -0 "$(cat "$SUPPID")" 2>/dev/null; then
    echo "[$(date '+%F %T')] supervisor alive (PID $(cat "$SUPPID"))"; return 0
  fi
  [ -f "$(stage_dir "$REPLICA_DIR")/gromacs_md.sky.yaml" ] || { echo "no launched run here — nothing to watch"; return 0; }
  echo "[$(date '+%F %T')] supervisor DOWN — respawning"
  nohup bash "$0" supervise "$REPLICA_DIR" >/dev/null 2>&1 &   # supervise tees to $SUPLOG itself
  echo $! > "$SUPPID"; echo "respawned supervisor PID $(cat "$SUPPID")"
}

# ============================ dispatch ========================================
SUB="${1:-launch}"; shift || true
case "$SUB" in
  launch)    cmd_launch    "$@" ;;
  extend)    cmd_extend    "$@" ;;
  supervise) cmd_supervise "$@" ;;
  watchdog)  cmd_watchdog  "$@" ;;
  follow)    cmd_follow    "$@" ;;
  status)    cmd_status    "$@" ;;
  fetch)     cmd_fetch     "$@" ;;
  teardown)  cmd_teardown  "$@" ;;
  *) echo "usage: $0 {launch|extend|supervise|watchdog|follow|status|fetch|teardown} [REPLICA_DIR]"; echo "  extend: EXTEND_FROM=<base> EXTEND_TO_NS=<ns>|EXTEND_BY_NS=<ns> $0 extend [DIR]"; exit 1 ;;
esac
