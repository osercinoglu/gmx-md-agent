#!/usr/bin/env bash
# =============================================================================
# cloud_setup.sh — OPTIONAL one-time preflight for the Vast.ai/SkyPilot cloud
# replica runner. The runner (run_cloud_replica.sh) is self-contained and will
# install tools + prompt for your Vast key / Pushover creds on first use, so you
# do NOT have to run this. It exists only to check everything up front and to
# record non-default knobs in cloud/cloud.env. Idempotent; safe to re-run.
#
# There is NO object store anymore: durability is local (the runner rsync-pulls
# the node's outputs to THIS machine and runs the analysis here with a small
# local CPU GROMACS it installs into conda env 'gmxcloud').
# =============================================================================
set -uo pipefail
export LC_ALL=C LANG=C
[ -d "$HOME/anaconda3/bin" ] && export PATH="$HOME/anaconda3/bin:$PATH"
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

ok(){ printf '  \033[32m✓\033[0m %s\n' "$*"; }
no(){ printf '  \033[31m✗\033[0m %s\n' "$*"; }
hd(){ printf '\n=== %s ===\n' "$*"; }
PY="$(command -v python3)"

hd "1. Tooling"
need_install=0
for c in sky vastai rsync; do command -v $c >/dev/null 2>&1 && ok "$c present" || { no "$c missing"; need_install=1; }; done
if [ "$need_install" = 1 ]; then
  echo "  Installing missing tools…"
  "$PY" -m pip install --upgrade "skypilot[vast]" vastai >/tmp/cloud_setup_pip.log 2>&1 \
    && ok "installed sky+vastai (rsync, if missing, needs your OS package manager)" \
    || no "pip install failed — see /tmp/cloud_setup_pip.log"
fi

hd "2. Vast.ai API key"
VKEY="$HOME/.config/vastai/vast_api_key"
if [ -s "$VKEY" ]; then ok "key file present: $VKEY"
else
  no "no Vast key at $VKEY"
  echo "    Get your key at https://cloud.vast.ai/account then run (in YOUR shell):"
  echo "       ! vastai set api-key <YOUR_VAST_KEY>"
  echo "    (or just run the launcher — it will prompt you.)"
fi

hd "3. Pushover (optional)"
PCFG="${PUSHOVER_CONFIG:-$HOME/.pushover/pushover-config}"
if [ -f "$PCFG" ]; then ok "pushover config present: $PCFG"
else no "no pushover config at $PCFG — the launcher will offer to set it up (or skip)."; fi

hd "4. Local analysis GROMACS"
if command -v gmx >/dev/null 2>&1; then ok "gmx on PATH: $(command -v gmx)"
elif [ -x "$HOME/anaconda3/envs/gmxcloud/bin/gmx" ]; then ok "gmxcloud env present"
else no "no local gmx yet — the launcher installs a CPU build into conda env 'gmxcloud' on first launch."; fi

hd "5. sky check"
sky check vast 2>&1 | sed -n '1,30p' || true

hd "6. Writing cloud/cloud.env"
cat > "$HERE/cloud.env" <<EOF
# Written by cloud_setup.sh — defaults sourced by run_cloud_replica.sh
IMAGE="${IMAGE:-nvidia/cuda:12.4.1-runtime-ubuntu22.04}"
IMAGE_KIND="${IMAGE_KIND:-conda}"
CONDA_SPEC="${CONDA_SPEC:-gromacs=2024.2=nompi_cuda_*}"
TOTAL_NS="${TOTAL_NS:-750}"
STAGE_NS="${STAGE_NS:-50}"
CKPT_MIN="${CKPT_MIN:-15}"
SYNC_MIN="${SYNC_MIN:-15}"
MAXH_PER_STAGE="${MAXH_PER_STAGE:-48}"
MAX_RESTARTS="${MAX_RESTARTS:-10}"
DISK_GB="${DISK_GB:-100}"
EOF
ok "wrote $HERE/cloud.env"
echo
echo "Next:  bash cloud/poc.sh dryrun     # \$0 validation"
echo "Then:  bash cloud/poc.sh all        # ~\$1-3 end-to-end proof (incl. kill/resume)"
echo "Real:  cd <REPLICA_DIR> && bash .../cloud/run_cloud_replica.sh launch"
