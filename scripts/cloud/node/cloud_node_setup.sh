#!/usr/bin/env bash
# =============================================================================
# cloud_node_setup.sh — SkyPilot `setup:` step. Ensures a working single-
# precision CUDA `gmx` AND `rsync` exist on the rented Vast.ai node, and writes
# ~/gmx_activate.sh (sourced by run_pipeline.sh) to put gmx on PATH.
#
# `rsync` is required because the LOCAL orchestrator pulls this node's outputs
# (checkpoints, trajectories) over rsync-on-ssh. No object store, no aws cli.
#
# gmx, three paths in order:
#   1. gmx already on PATH (e.g. NGC nvcr.io/hpc/gromacs image) -> use it.
#   2. gmx at a known NGC/install location -> add to PATH.
#   3. Install GROMACS via micromamba from conda-forge (CUDA build). Default,
#      no external registry/account needed.
#
# Env:
#   GMX_IMAGE_KIND = conda | ngc   (default conda)
#   GMX_CONDA_SPEC = conda match spec (default "gromacs=2024.2=nompi_cuda_*")
# =============================================================================
set -euo pipefail
export LC_ALL=C LANG=C

GMX_IMAGE_KIND="${GMX_IMAGE_KIND:-conda}"
GMX_CONDA_SPEC="${GMX_CONDA_SPEC:-gromacs=2024.2=nompi_cuda_*}"
ACT="$HOME/gmx_activate.sh"

write_act() { printf '%s\n' "$1" > "$ACT"; echo "[setup] wrote $ACT"; }
gmx_works() {
  command -v gmx >/dev/null 2>&1 || return 1
  gmx --version 2>/dev/null | grep -qiE 'GPU support:[[:space:]]*CUDA|GPU support:[[:space:]]*enabled' || return 1
}
ensure_rsync() {
  # rsync is how the local orchestrator pulls outputs + pushes state on recovery.
  command -v rsync >/dev/null 2>&1 && { echo "[setup] rsync present: $(command -v rsync)"; return 0; }
  echo "[setup] installing rsync"
  if command -v apt-get >/dev/null 2>&1; then
    (apt-get update -y && apt-get install -y --no-install-recommends rsync) >/dev/null 2>&1 || true
  fi
  command -v rsync >/dev/null 2>&1 || { [ -x "$HOME/bin/micromamba" ] && "$HOME/bin/micromamba" install -y -p "$HOME/gmxenv" -c conda-forge rsync >/dev/null 2>&1 || true; }
  command -v rsync >/dev/null 2>&1 && echo "[setup] rsync ready: $(command -v rsync)" \
    || echo "[setup] WARNING: rsync unavailable — local pull/recovery will fail"
}

echo "[setup] GMX_IMAGE_KIND=$GMX_IMAGE_KIND"
nvidia-smi -L 2>/dev/null || echo "[setup] WARNING: nvidia-smi not available yet"
ensure_rsync

# --- Path 1: gmx already present (NGC image / pre-baked) ---
if gmx_works; then
  echo "[setup] gmx already present and CUDA-capable: $(command -v gmx)"
  write_act ': # gmx already on PATH'
  exit 0
fi

# --- Path 2: known NGC locations ---
for cand in /usr/local/gromacs/bin/gmx /usr/local/gromacs/avx2_256/bin/gmx /opt/gromacs/bin/gmx; do
  if [ -x "$cand" ]; then
    base="$(dirname "$cand")"
    if [ -f "$base/GMXRC" ]; then write_act "source '$base/GMXRC'"; else write_act "export PATH='$base':\$PATH"; fi
    source "$ACT"; gmx_works && { echo "[setup] using $cand"; exit 0; }
  fi
done

# --- Path 3: micromamba + conda-forge CUDA build ---
echo "[setup] installing GROMACS via micromamba (conda-forge)"
if command -v apt-get >/dev/null 2>&1; then
  (apt-get update -y && apt-get install -y --no-install-recommends curl bzip2 ca-certificates) >/dev/null 2>&1 || true
fi
MM="$HOME/bin/micromamba"
if [ ! -x "$MM" ]; then
  mkdir -p "$HOME/bin"
  curl -Ls https://micro.mamba.pm/api/micromamba/linux-64/latest -o /tmp/mm.tar.bz2
  tar -xj -f /tmp/mm.tar.bz2 -C "$HOME" --strip-components=1 bin/micromamba 2>/dev/null \
    || tar -xjf /tmp/mm.tar.bz2 -C "$HOME" bin/micromamba
fi
export MAMBA_ROOT_PREFIX="$HOME/micromamba"
ENVDIR="$HOME/gmxenv"
if [ ! -x "$ENVDIR/bin/gmx" ]; then
  "$MM" create -y -p "$ENVDIR" -c conda-forge "$GMX_CONDA_SPEC" python=3.11 \
    || "$MM" create -y -p "$ENVDIR" -c conda-forge "gromacs=*=nompi_cuda_*" python=3.11 \
    || "$MM" create -y -p "$ENVDIR" -c conda-forge gromacs python=3.11
fi
if [ -f "$ENVDIR/bin/GMXRC" ]; then
  write_act "source '$ENVDIR/bin/GMXRC'
export PATH='$ENVDIR/bin':\$PATH"
else
  write_act "export PATH='$ENVDIR/bin':\$PATH
export LD_LIBRARY_PATH='$ENVDIR/lib':\${LD_LIBRARY_PATH:-}"
fi
source "$ACT"
gmx --version 2>/dev/null | head -15 || true
gmx_works || { echo "[setup] ERROR: installed gmx is not CUDA-capable"; exit 1; }
# rsync may live in the same env if apt was unavailable
command -v rsync >/dev/null 2>&1 || "$MM" install -y -p "$ENVDIR" -c conda-forge rsync >/dev/null 2>&1 || true
echo "[setup] GROMACS ready: $(command -v gmx); rsync: $(command -v rsync 2>/dev/null || echo 'MISSING')"
