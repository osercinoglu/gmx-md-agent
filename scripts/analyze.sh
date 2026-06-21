#!/usr/bin/env bash
# =============================================================================
# analyze.sh — post-processing dispatcher. System-agnostic.
#
# The solvated trajectory must exist ONLY as the raw md_part*/md_ext*/<base>.xtc
# chunks, so this script NEVER builds a solvated concatenated trajectory.
#
# Usage: analyze.sh <folder> [extend_base]
# Env:
#   GMX       (default gmx)
#   DRY_GROUP (default Protein)  -- solvent/ions-stripping selection for presets
#   ANALYSIS  none (default) | pmhc | <path to a hook script>
#     none -> do nothing (leave the raw chunks; no concat)
#     pmhc -> presets/analyze_pmhc.sh (dry-only whole/nojump/center/fit + chain IDs)
#     hook -> runs:  bash <hook> <folder> <last.tpr> [extend_base]
#             (the hook gets the raw chunks + last tpr; it decides what to write)
# =============================================================================
set -euo pipefail
export LC_ALL=C LANG=C
GMX="${GMX:-gmx}"
DRY_GROUP="${DRY_GROUP:-Protein}"
DISK_FACTOR="${DISK_FACTOR:-2}"
ANALYSIS="${ANALYSIS:-none}"
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
FOLDER="${1:?usage: analyze.sh <folder> [extend_base]}"
EXT_BASE="${2:-}"
[ -f "$HOME/gmx_activate.sh" ] && source "$HOME/gmx_activate.sh" || true
cd "$FOLDER"

if [ "$ANALYSIS" = "none" ] || [ -z "$ANALYSIS" ]; then
  echo ">> analysis=none — leaving raw chunks as-is (no concatenation; solvated stays only in chunks)"
  exit 0
fi

# last production tpr (full, solvated reference for the dry selection).
# NB: $1 is a glob and must stay UNQUOTED so the shell expands it.
last_of() { ls -v $1 2>/dev/null | tail -1; }
if [ -n "$EXT_BASE" ]; then
  LAST_TPR="$(last_of 'md_ext*.tpr')"
else
  LAST_TPR="$(last_of 'md_part*.tpr')"
fi
[ -n "$LAST_TPR" ] && [ -f "$LAST_TPR" ] || { echo "analyze: no production .tpr found in $FOLDER"; exit 1; }

case "$ANALYSIS" in
  pmhc)
    echo ">> analysis=pmhc preset (dry-only)"
    GMX="$GMX" DRY_GROUP="$DRY_GROUP" DISK_FACTOR="$DISK_FACTOR" bash "$HERE/presets/analyze_pmhc.sh" "$FOLDER" "$LAST_TPR" "$EXT_BASE" ;;
  *)
    if [ -f "$ANALYSIS" ]; then
      echo ">> analysis hook: $ANALYSIS"
      GMX="$GMX" DRY_GROUP="$DRY_GROUP" DISK_FACTOR="$DISK_FACTOR" bash "$ANALYSIS" "$FOLDER" "$LAST_TPR" "$EXT_BASE"
    else
      echo ">> WARNING: ANALYSIS='$ANALYSIS' is neither none/pmhc nor an existing hook — skipping"
    fi ;;
esac
echo ">> analysis step complete in $FOLDER"
