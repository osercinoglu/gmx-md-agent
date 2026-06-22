#!/usr/bin/env bash
# Container entrypoint: make `gmx` available, materialize credentials from env
# when host config dirs are not mounted, then hand off to the Python CLI.
set -euo pipefail
export LC_ALL=C LANG=C
: "${HOME:=/root}"

# --- GROMACS on PATH ---
# This image installs gmx into the conda env /opt/gmx; source its GMXRC (sets
# GMXDATA etc.). Fall back to common system locations for other base images.
for rc in /opt/gmx/bin/GMXRC /usr/local/gromacs/bin/GMXRC /opt/gromacs/bin/GMXRC; do
  [ -f "$rc" ] && { source "$rc"; break; }
done
export PATH="/opt/gmx/bin:$PATH"

# --- credentials: env/flags fallback when host configs are NOT mounted ---
# Vast API key (mounted at ~/.config/vastai/vast_api_key, else from $VAST_API_KEY)
if [ -n "${VAST_API_KEY:-}" ] && [ ! -s "$HOME/.config/vastai/vast_api_key" ]; then
  mkdir -p "$HOME/.config/vastai"; umask 077
  printf '%s' "$VAST_API_KEY" > "$HOME/.config/vastai/vast_api_key"
fi
# Pushover (mounted at ~/.pushover/pushover-config, else from env)
if [ -n "${PUSHOVER_TOKEN:-}" ] && [ -n "${PUSHOVER_USER:-}" ] && [ ! -f "$HOME/.pushover/pushover-config" ]; then
  mkdir -p "$HOME/.pushover"
  ( umask 077; { printf 'api_token="%s"\n' "$PUSHOVER_TOKEN"; printf 'user_key="%s"\n' "$PUSHOVER_USER"; } > "$HOME/.pushover/pushover-config" )
fi

# --- SSH dir for SkyPilot ---
# SkyPilot writes /root/.ssh/{config,sky-key} and reaches the Vast node with its
# OWN generated key — your personal keys are not needed. The ssh client rejects a
# config/dir it does not own ("Bad owner or permissions on /root/.ssh/config"),
# which happens if a host ~/.ssh (uid 1000) is bind-mounted here. Normalize it for
# the container user so SkyPilot can manage SSH cleanly.
mkdir -p "$HOME/.ssh"
chown -R "$(id -u)":"$(id -g)" "$HOME/.ssh" 2>/dev/null || true
chmod 700 "$HOME/.ssh" 2>/dev/null || true
find "$HOME/.ssh" -type f -exec chmod 600 {} + 2>/dev/null || true

exec python3 -m mdagent.cli "$@"
