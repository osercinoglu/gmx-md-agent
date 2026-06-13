#!/usr/bin/env bash
# =============================================================================
# analyze.sh — concatenate the production chunks into a single prod.xtc, then
# optionally run a post-processing step. System-agnostic.
#
# Usage: analyze.sh <folder> [extend_base]
#   fresh  (no extend_base): concatenates md_part* chunks.
#   extend (extend_base given): concatenates <base>.xtc + md_ext* chunks.
# Env:
#   GMX       (default gmx)
#   ANALYSIS  none (default) | pmhc | <path to a hook script>
#             pmhc  -> presets/analyze_pmhc.sh (trjconv pbc/center/fit/dry + chain IDs)
#             hook  -> runs:  bash <hook> <folder> <prod.xtc> <last.tpr>
# =============================================================================
set -euo pipefail
export LC_ALL=C LANG=C
GMX="${GMX:-gmx}"
ANALYSIS="${ANALYSIS:-none}"
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
FOLDER="${1:?usage: analyze.sh <folder> [extend_base]}"
EXT_BASE="${2:-}"
[ -f "$HOME/gmx_activate.sh" ] && source "$HOME/gmx_activate.sh" || true
cd "$FOLDER"

last_of() { ls -v "$1" 2>/dev/null | tail -1; }
if [ -n "$EXT_BASE" ]; then
  LAST_TPR="$(last_of 'md_ext*.tpr')"
  [ -n "$LAST_TPR" ] && [ -f "$LAST_TPR" ] || { echo "extend: no md_ext*.tpr"; exit 1; }
  [ -f "${EXT_BASE}.xtc" ] || { echo "extend: original ${EXT_BASE}.xtc missing"; exit 1; }
  PROD_XTCS="${EXT_BASE}.xtc $(ls -v md_ext*.xtc 2>/dev/null)"; TRJCAT_FLAGS=""
else
  LAST_TPR="$(last_of 'md_part*.tpr')"
  [ -n "$LAST_TPR" ] && [ -f "$LAST_TPR" ] || { echo "no md_part*.tpr"; exit 1; }
  if ls md_part*.part*.xtc >/dev/null 2>&1; then
    PROD_XTCS=$(ls md_part??.xtc md_part*.part*.xtc 2>/dev/null | sort -uV); TRJCAT_FLAGS=""
  else
    PROD_XTCS=$(ls md_part??.xtc 2>/dev/null | sort -V); TRJCAT_FLAGS="-cat"
  fi
fi
[ -n "$PROD_XTCS" ] || { echo "no trajectory chunks found in $FOLDER"; exit 1; }
echo ">> last tpr : $LAST_TPR"
echo ">> trjcat   : $PROD_XTCS"
[ -f prod.xtc ] || "$GMX" trjcat -f $PROD_XTCS -o prod.xtc $TRJCAT_FLAGS

case "$ANALYSIS" in
  none|"")
    echo ">> analysis=none — raw concatenated prod.xtc (post-process it yourself)";;
  pmhc)
    echo ">> analysis=pmhc preset"
    GMX="$GMX" bash "$HERE/presets/analyze_pmhc.sh" "$FOLDER" "$LAST_TPR";;
  *)
    if [ -f "$ANALYSIS" ]; then
      echo ">> analysis hook: $ANALYSIS"
      GMX="$GMX" bash "$ANALYSIS" "$FOLDER" "prod.xtc" "$LAST_TPR"
    else
      echo ">> WARNING: ANALYSIS='$ANALYSIS' is neither 'none'/'pmhc' nor an existing hook script — skipping"
    fi;;
esac
echo ">> analysis step complete (prod.xtc in $FOLDER)"
