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
CKPT_MIN="${CKPT_MIN:-15}";  SYNC_MIN="${SYNC_MIN:-15}"   # SYNC_MIN = local pull cadence
MAXH_PER_STAGE="${MAXH_PER_STAGE:-48}"; MAX_RESTARTS="${MAX_RESTARTS:-10}"
DISK_GB="${DISK_GB:-100}"
PROD_MDP="${PROD_MDP:-}"                       # production mdp (required for a fresh run)
EM_MDP="${EM_MDP:-}"; NVT_MDP="${NVT_MDP:-}"; NPT_MDP="${NPT_MDP:-}"   # optional phases
START_STRUCT="${START_STRUCT:-}"              # starting structure (auto-detected on node if unset)
TOP="${TOP:-topol.top}"; INDEX="${INDEX:-index.ndx}"; MAXWARN="${MAXWARN:-1}"
ANALYSIS="${ANALYSIS:-none}"                  # none | pmhc | <hook path>  (local post-process)
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
# SkyPilot cluster names (and thus the ssh alias used for rsync) must be
# lowercase [a-z0-9-]; sanitize the replica tag accordingly.
jobname_of()  { echo "gmx-$(tag_of "$1")" | tr 'A-Z_' 'a-z-' | tr -cd 'a-z0-9-'; }

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
vast_desc() {
  "$VASTAI" show instances --raw 2>/dev/null | python3 -c '
import sys, json
job = sys.argv[1]
try: data = json.load(sys.stdin)
except Exception: data = []
out = "vast#?"
for o in (data or []):
    lab = str(o.get("label") or "")
    if lab.startswith(job + "-") and lab.endswith("-head"):
        gid = o.get("id"); gpu = (o.get("gpu_name") or "").replace(" ", "")
        out = ("vast#%s/%s" % (gid, gpu)) if gpu else ("vast#%s" % gid)
        break
print(out)
' "$1" 2>/dev/null || echo "vast#?"
}
refresh_vast_id() { VAST_ID="$(vast_desc "$1")"; return 0; }

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
  np=$(ls -1 "$STORE"/status/PROD_*_DONE 2>/dev/null | wc -l | tr -d ' ')
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
  log=$(ls -t "$STORE"/md_part*.log 2>/dev/null | head -1)
  [ -n "$log" ] && [ -f "$log" ] || return 0
  nsteps=$(grep -m1 -E 'nsteps[[:space:]]*=' "$log" 2>/dev/null | grep -oE '[0-9]+' | head -1)
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
  if [ -x "$PUSHOVER_SH" ] && [ -n "$PUSHOVER_TOKEN" ] && [ -n "$PUSHOVER_USER" ]; then
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
    --include='md_part*.gro' --include='md_part*.edr' --include='md_part*.log' \
    --include='md_ext*.gro' --include='md_ext*.edr' --include='md_ext*.log' \
    --include='run_pipeline.log' \
    --exclude='*' \
    "$JOB:sky_workdir/" "$STORE/"
  rc=$?
  set -e
  # Pass B: append-only trajectories (large) — best effort, --append.
  if [ "$rc" -eq 0 ]; then
    rsync -az --partial --append --timeout=120 -e "$SSH_OPTS" --prune-empty-dirs \
      --include='md_part*.xtc' --include='md_ext*.xtc' --exclude='*' \
      "$JOB:sky_workdir/" "$STORE/" || true
  fi
  return "$rc"
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
  # analyze.sh concatenates chunks -> prod.xtc, then runs ANALYSIS (none|pmhc|hook).
  ANALYSIS="$ANALYSIS" GMX="$LOCAL_GMX" bash "$ANALYZE_SH" "$STORE" ${A_BASE:+"$A_BASE"} || return 1
  local f
  for f in prod.xtc prod_dry.xtc prod_ref.pdb prod_last.pdb; do
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
    ls "$REPLICA_DIR"/*.gro "$REPLICA_DIR"/*.pdb >/dev/null 2>&1 || die "no .gro/.pdb starting structure in $REPLICA_DIR (set START_STRUCT/--struct)"
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
  rm -rf "$STORE"; mkdir -p "$STORE"   # fresh run: clear stale markers/trajectory from any prior run
  stage_workdir "$REPLICA_DIR"
  render_yaml "$REPLICA_DIR"
  say "Rendered job spec: $STAGE/gromacs_md.sky.yaml"

  if [ "${RENDER_ONLY:-0}" = "1" ]; then
    say "RENDER_ONLY=1 — validating the rendered spec without renting a GPU"
    python3 -c "import sky; sky.Task.from_yaml('$STAGE/gromacs_md.sky.yaml'); print('   Task.from_yaml: OK')" || die "rendered YAML failed to parse"
    ( cd "$STAGE" && "$SKY" launch --dryrun ./gromacs_md.sky.yaml 2>&1 | sed -n '1,40p' ) || true
    return 0
  fi

  say "Provisioning Vast.ai node + installing GROMACS (this can take a few minutes)…"
  # Cluster mode (not managed jobs): recovery is local-driven. -i/--down is a
  # backstop — if this machine ever dies, the node self-terminates after it goes
  # idle (i.e. once the run ends or crashes), so nothing bills indefinitely.
  ( cd "$STAGE" && "$SKY" launch -c "$JOB" ./gromacs_md.sky.yaml -y --detach-run -i 30 --down ) \
    || die "sky launch failed — check the output above."

  local VAST_ID=""; refresh_vast_id "$JOB"
  notify "Run starting on $JOB: ${TOTAL_NS} ns in $(( TOTAL_NS / STAGE_NS )) stages" "$TAG ▶" 0

  if [ "${LAUNCH_NO_SUPERVISE:-0}" = "1" ]; then
    say "LAUNCH_NO_SUPERVISE=1 — node is running; supervisor NOT spawned (caller drives it)."
    return 0
  fi

  local SUPLOG SUPPID; SUPLOG="$(suplog_of "$REPLICA_DIR")"; SUPPID="$(suppid_of "$REPLICA_DIR")"
  say "Spawning background supervisor (pull + recover + analyze + teardown)"
  nohup bash "$0" supervise "$REPLICA_DIR" >"$SUPLOG" 2>&1 &
  echo $! > "$SUPPID"
  echo "============================================================"
  echo " Launched: $JOB   (supervisor PID $(cat "$SUPPID"))"
  echo "   follow   : $0 follow $REPLICA_DIR     (tails $SUPLOG)"
  echo "   node logs: $SKY logs $JOB"
  echo "   status   : $0 status $REPLICA_DIR"
  echo "   teardown : $0 teardown $REPLICA_DIR"
  echo " Outputs are pulled into $(store_dir "$REPLICA_DIR")/ as stages finish;"
  echo " final prod*.xtc / prod_*.pdb are written to $REPLICA_DIR/ at the end."
  echo " This machine should stay online; the supervisor survives terminal close."
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
  [ -f "$bxtc" ] || echo ">> WARNING: $bxtc not found — the final prod.xtc will contain only the NEW segment."

  say "Bootstrap (tools + Vast key + local gmx)"
  ensure_tools; ensure_vast_key
  [ "${RENDER_ONLY:-0}" = "1" ] || ensure_pushover
  ensure_local_gmx     # needed to read the current end time of the .tpr

  local cur_ps cur_ns target_ns added_ns n_ext
  cur_ps="$(local_tpr_end_ps "$btpr")"
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

  rm -rf "$STORE"; mkdir -p "$STORE"   # fresh extension: clear stale markers/chunks from any prior run
  stage_workdir "$REPLICA_DIR" extend
  render_yaml "$REPLICA_DIR"
  { echo "EXTEND_BASE=\"$EXT_BASE\""
    echo "EXTEND_STAGES=$n_ext"
    echo "EXTEND_CURRENT_NS=$cur_ns"
    echo "EXTEND_TO_NS=$target_ns"; } > "$STAGE/.extend.env"
  say "Rendered job spec: $STAGE/gromacs_md.sky.yaml  (EXTEND $EXT_BASE -> ${target_ns} ns)"

  if [ "${RENDER_ONLY:-0}" = "1" ]; then
    say "RENDER_ONLY=1 — validating the rendered spec without renting a GPU"
    python3 -c "import sky; sky.Task.from_yaml('$STAGE/gromacs_md.sky.yaml'); print('   Task.from_yaml: OK')" || die "rendered YAML failed to parse"
    ( cd "$STAGE" && "$SKY" launch --dryrun ./gromacs_md.sky.yaml 2>&1 | sed -n '1,40p' ) || true
    return 0
  fi

  say "Provisioning Vast.ai node + installing GROMACS…"
  ( cd "$STAGE" && "$SKY" launch -c "$JOB" ./gromacs_md.sky.yaml -y --detach-run -i 30 --down ) \
    || die "sky launch failed — check the output above."
  local VAST_ID=""; refresh_vast_id "$JOB"
  notify "Extending $EXT_BASE on $JOB: ${cur_ns} -> ${target_ns} ns (+${added_ns}, $n_ext chunks)" "$TAG ▶" 0

  if [ "${LAUNCH_NO_SUPERVISE:-0}" = "1" ]; then
    say "LAUNCH_NO_SUPERVISE=1 — node is running; supervisor NOT spawned (caller drives it)."
    return 0
  fi
  local SUPLOG SUPPID; SUPLOG="$(suplog_of "$REPLICA_DIR")"; SUPPID="$(suppid_of "$REPLICA_DIR")"
  say "Spawning background supervisor (pull + recover + analyze + teardown)"
  nohup bash "$0" supervise "$REPLICA_DIR" >"$SUPLOG" 2>&1 &
  echo $! > "$SUPPID"
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
  mkdir -p "$STORE"
  echo "[$(date '+%F %T')] supervising $JOB  (pull cadence ${SYNC_MIN}m, max restarts ${MAX_RESTARTS})"

  local N_STAGES=$(( TOTAL_NS / STAGE_NS )) MODE="normal" NS_BASE=0 STAGE_WORD="production"
  if [ -f "$STAGE/.extend.env" ]; then
    # shellcheck disable=SC1090
    source "$STAGE/.extend.env"
    MODE="extend"; N_STAGES="${EXTEND_STAGES:-$N_STAGES}"; NS_BASE="${EXTEND_CURRENT_NS:-0}"; STAGE_WORD="extension"
    echo "[$(date '+%F %T')] mode=EXTEND base=${EXTEND_BASE:-?} from ${NS_BASE} ns in ${N_STAGES} x ${STAGE_NS} ns chunks"
  fi
  local restarts=0 fails=0 last_prod=0 nvt_done=0 npt_done=0 first_pull=1 nprod VAST_ID=""
  while true; do
    # resolve (or re-resolve after a recovery) the Vast instance id for messages
    if [ -z "$VAST_ID" ] || [ "$VAST_ID" = "vast#?" ]; then refresh_vast_id "$JOB"; fi
    if pull_state "$JOB" "$STORE"; then
      fails=0
      nprod=$(ls -1 "$STORE"/status/PROD_*_DONE 2>/dev/null | wc -l | tr -d ' ')
      if [ "$first_pull" = 1 ]; then
        # Baseline: record what is already done WITHOUT notifying, so a (re)attach
        # of the supervisor doesn't replay milestones reached on a previous run.
        last_prod="$nprod"
        [ -f "$STORE/status/NVT_DONE" ] && nvt_done=1
        [ -f "$STORE/status/NPT_DONE" ] && npt_done=1
        first_pull=0
      else
        # equilibration milestones (fresh runs only; extend has no NVT/NPT markers)
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
      say "Production complete on node. Final pull + local analysis."
      pull_state "$JOB" "$STORE" || true
      notify "$TAG: ${STAGE_WORD} done — running local analysis — $(progress_str "$STORE" "$N_STAGES" 0 "$MODE")" "$TAG ▣" 0
      if run_local_analysis "$REPLICA_DIR"; then
        notify "$TAG ✅ DONE — analysis ready in $(basename "$REPLICA_DIR") — $(progress_str "$STORE" "$N_STAGES" 1 "$MODE")" "$TAG ✅" 0
        echo "[$(date '+%F %T')] DONE — prod*.xtc / prod_*.pdb in $REPLICA_DIR"
      else
        notify "$TAG ⚠ production done but local analysis failed — see supervisor log" "$TAG ⚠" 1
        echo "[$(date '+%F %T')] analysis FAILED — node left up for inspection; not tearing down."
        return 1
      fi
      teardown_cluster "$REPLICA_DIR"
      return 0
    fi
    if [ -f "$STORE/status/FAILED" ]; then
      local where; where="$(cat "$STORE/status/FAILED" 2>/dev/null || echo '?')"
      notify "$TAG ❌ node reported FAILURE at: $where (no auto-retry — gmx error)" "$TAG ❌" 1
      echo "[$(date '+%F %T')] node FAILED at: $where — leaving node up for inspection."
      return 1
    fi

    # recover a dead node (only on repeated connection failure, not a gmx error)
    if [ "$fails" -ge 3 ]; then
      if [ "$restarts" -ge "$MAX_RESTARTS" ]; then
        notify "$TAG ❌ node unreachable and max restarts ($MAX_RESTARTS) exhausted" "$TAG ❌" 1
        die "exhausted $MAX_RESTARTS restarts; giving up. Inspect: $SKY status ; vastai show instances"
      fi
      restarts=$((restarts+1))
      notify "$TAG ↻ node unreachable — recovering (restart $restarts/$MAX_RESTARTS)" "$TAG ↻" 1
      echo "[$(date '+%F %T')] recovering: sky down + restage state + relaunch ($restarts/$MAX_RESTARTS)"
      "$SKY" down -y "$JOB" >/dev/null 2>&1 || true
      VAST_ID=""    # new instance after relaunch — force re-resolve next cycle
      restage_state "$STORE" "$STAGE"
      if ( cd "$STAGE" && "$SKY" launch -c "$JOB" ./gromacs_md.sky.yaml -y --detach-run -i 30 --down ); then
        echo "[$(date '+%F %T')] relaunched $JOB; resuming pulls"
        fails=0
      else
        echo "[$(date '+%F %T')] relaunch failed; will retry next cycle"
      fi
    fi

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
  if [ -f "$SUPPID" ] && kill -0 "$(cat "$SUPPID")" 2>/dev/null; then echo "  running (PID $(cat "$SUPPID"))"; else echo "  not running"; fi
  echo "=== progress ==="
  local adone=0; [ -f "$REPLICA_DIR/prod.xtc" ] && adone=1
  echo "  overall: $(progress_str "$STORE" "$N_STAGES" "$adone")"
  local sstr; sstr="$(stage_step_str "$STORE")"; [ -n "$sstr" ] && echo "  current: $sstr"
  echo "  markers: $(ls -1 "$STORE/status" 2>/dev/null | tr '\n' ' ' | sed 's/ $//' || echo '(none yet)')"
  echo "  vast   : $(vast_desc "$JOB")"
  echo "=== sky cluster ==="; "$SKY" status "$JOB" 2>/dev/null || "$SKY" status 2>/dev/null || true
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
  local REPLICA_DIR JOB; REPLICA_DIR="$(resolve_dir "${1:-$PWD}")"; JOB="$(jobname_of "$REPLICA_DIR")"
  echo "[$(date '+%F %T')] sky down $JOB"
  "$SKY" down -y "$JOB" >/dev/null 2>&1 || echo "  WARN: 'sky down $JOB' failed — check '$SKY status'"
}

cmd_teardown() {
  local REPLICA_DIR JOB SUPPID; REPLICA_DIR="$(resolve_dir "${1:-$PWD}")"
  JOB="$(jobname_of "$REPLICA_DIR")"; SUPPID="$(suppid_of "$REPLICA_DIR")"
  if [ -f "$SUPPID" ] && kill -0 "$(cat "$SUPPID")" 2>/dev/null; then
    say "Stopping supervisor (PID $(cat "$SUPPID"))"; kill "$(cat "$SUPPID")" 2>/dev/null || true
  fi
  rm -f "$SUPPID" 2>/dev/null || true
  say "sky down $JOB (terminates the Vast instance)"
  teardown_cluster "$REPLICA_DIR"
  echo ">> Current Vast instances:"; "$VASTAI" show instances 2>/dev/null || true
  if [ "${SWEEP:-0}" = "1" ]; then
    say "SWEEP=1: destroying ALL Vast instances on your account (every instance, not just this job)"
    "$VASTAI" show instances --raw 2>/dev/null | python3 -c 'import sys,json;[print(o["id"]) for o in json.load(sys.stdin)]' \
      | xargs -r -n1 -I{} "$VASTAI" destroy instance {} -y
    echo ">> Remaining:"; "$VASTAI" show instances 2>/dev/null || true
  else
    echo ">> (SWEEP=1 force-destroys ALL Vast instances on your account as a last resort.)"
  fi
}

# ============================ dispatch ========================================
SUB="${1:-launch}"; shift || true
case "$SUB" in
  launch)    cmd_launch    "$@" ;;
  extend)    cmd_extend    "$@" ;;
  supervise) cmd_supervise "$@" ;;
  follow)    cmd_follow    "$@" ;;
  status)    cmd_status    "$@" ;;
  fetch)     cmd_fetch     "$@" ;;
  teardown)  cmd_teardown  "$@" ;;
  *) echo "usage: $0 {launch|extend|supervise|follow|status|fetch|teardown} [REPLICA_DIR]"; echo "  extend: EXTEND_FROM=<base> EXTEND_TO_NS=<ns>|EXTEND_BY_NS=<ns> $0 extend [DIR]"; exit 1 ;;
esac
