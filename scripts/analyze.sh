#!/usr/bin/env bash
# =============================================================================
# analyze.sh — local trjconv post-processing for a finished (or extended) run.
# Identical pipeline + group indices to the on-prem run_replica.sh:
#   trjcat -> whole -> nojump -> center(1) -> fit(4) -> dry(1) -> ref/last PDB
#   -> chain-ID stamping (skipped if chain itps are absent).
#
# Usage: analyze.sh <folder> [extend_base]
#   fresh  (no extend_base): concatenates md_part* chunks.
#   extend (extend_base given): concatenates <base>.xtc + md_ext* chunks.
# Env: GMX (default gmx).
# =============================================================================
set -euo pipefail
export LC_ALL=C LANG=C
GMX="${GMX:-gmx}"
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
FOLDER="${1:?usage: analyze.sh <folder> [extend_base]}"
EXT_BASE="${2:-}"
[ -f "$HOME/gmx_activate.sh" ] && source "$HOME/gmx_activate.sh" || true
cd "$FOLDER"
[ -f add_chain_ids.py ] || cp -p "$HERE/add_chain_ids.py" . 2>/dev/null || true
[ -f index.ndx ] || { echo "analyze: index.ndx required in $FOLDER"; exit 1; }

local_last_tpr() { ls -v "$1" 2>/dev/null | tail -1; }

if [ -n "$EXT_BASE" ]; then
  LAST_TPR="$(local_last_tpr 'md_ext*.tpr')"
  [ -n "$LAST_TPR" ] && [ -f "$LAST_TPR" ] || { echo "extend: no md_ext*.tpr in $FOLDER"; exit 1; }
  [ -f "${EXT_BASE}.xtc" ] || { echo "extend: original ${EXT_BASE}.xtc missing in $FOLDER"; exit 1; }
  PROD_XTCS="${EXT_BASE}.xtc $(ls -v md_ext*.xtc 2>/dev/null)"; TRJCAT_FLAGS=""
else
  LAST_TPR="$(local_last_tpr 'md_part*.tpr')"
  [ -n "$LAST_TPR" ] && [ -f "$LAST_TPR" ] || { echo "no md_part*.tpr in $FOLDER"; exit 1; }
  if ls md_part*.part*.xtc >/dev/null 2>&1; then
    PROD_XTCS=$(ls md_part??.xtc md_part*.part*.xtc 2>/dev/null | sort -uV); TRJCAT_FLAGS=""
  else
    PROD_XTCS=$(ls md_part??.xtc 2>/dev/null | sort -V); TRJCAT_FLAGS="-cat"
  fi
fi
[ -n "$PROD_XTCS" ] || { echo "no trajectory chunks found in $FOLDER"; exit 1; }
echo ">> last tpr : $LAST_TPR"
echo ">> trjcat of: $PROD_XTCS"

[ -f prod.xtc ]        || "$GMX" trjcat -f $PROD_XTCS -o prod.xtc $TRJCAT_FLAGS
[ -f prod_whole.xtc ]  || echo 0 | "$GMX" trjconv -s "$LAST_TPR" -f prod.xtc        -o prod_whole.xtc  -pbc whole
[ -f prod_nojump.xtc ] || echo 0 | "$GMX" trjconv -s "$LAST_TPR" -f prod_whole.xtc  -o prod_nojump.xtc -pbc nojump
[ -f prod_center.xtc ] || printf "1\n0\n" | "$GMX" trjconv -s "$LAST_TPR" -f prod_nojump.xtc -o prod_center.xtc -center -pbc mol -ur compact -n index.ndx
[ -f prod_fit.xtc ]    || printf "4\n0\n" | "$GMX" trjconv -s "$LAST_TPR" -f prod_center.xtc -o prod_fit.xtc    -fit rot+trans -n index.ndx
[ -f prod_dry.xtc ]    || echo 1 | "$GMX" trjconv -s "$LAST_TPR" -f prod_fit.xtc -o prod_dry.xtc -n index.ndx
[ -f prod_ref.pdb ]    || echo 1 | "$GMX" trjconv -s "$LAST_TPR" -f prod_fit.xtc -o prod_ref.pdb  -dump 0          -conect -n index.ndx
[ -f prod_last.pdb ]   || echo 1 | "$GMX" trjconv -s "$LAST_TPR" -f prod_fit.xtc -o prod_last.pdb -dump 999999999  -conect -n index.ndx
if [ -f topol_Protein_chain_A.itp ] && [ -f topol_Protein_chain_B.itp ] && [ -f topol_Protein_chain_C.itp ]; then
  python3 add_chain_ids.py prod_ref.pdb  topol_Protein_chain_A.itp topol_Protein_chain_B.itp topol_Protein_chain_C.itp
  python3 add_chain_ids.py prod_last.pdb topol_Protein_chain_A.itp topol_Protein_chain_B.itp topol_Protein_chain_C.itp
else
  echo ">> chain itps absent — skipping chain-ID stamping"
fi
echo ">> analysis complete: prod.xtc prod_dry.xtc prod_ref.pdb prod_last.pdb in $FOLDER"
