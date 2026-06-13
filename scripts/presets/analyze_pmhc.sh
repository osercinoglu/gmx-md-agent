#!/usr/bin/env bash
# =============================================================================
# analyze_pmhc.sh — pMHC-I post-processing preset (opt-in: --analysis pmhc).
# Reproduces the on-prem run_replica.sh analysis from a concatenated prod.xtc:
#   whole -> nojump -> center(grp 1) -> fit(grp 4) -> dry(grp 1) -> ref/last PDB
#   -> chain-ID stamping (chains A/B/C) via add_chain_ids.py.
# Assumes the default make_ndx groups (1=Protein, 4=Backbone) in index.ndx and
# the 3 chain itps (topol_Protein_chain_{A,B,C}.itp) typical of pMHC systems.
#
# Usage: analyze_pmhc.sh <folder> <last.tpr>   (called by analyze.sh; GMX env set)
# =============================================================================
set -euo pipefail
export LC_ALL=C LANG=C
GMX="${GMX:-gmx}"
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
FOLDER="${1:?folder}"; LAST_TPR="${2:?last.tpr}"
cd "$FOLDER"
[ -f prod.xtc ] || { echo "pmhc preset: prod.xtc not found (analyze.sh builds it first)"; exit 1; }
[ -f index.ndx ] || { echo "pmhc preset: index.ndx required"; exit 1; }
[ -f add_chain_ids.py ] || cp -p "$HERE/../add_chain_ids.py" . 2>/dev/null || true

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
  echo ">> pmhc preset: chain itps absent — skipping chain-ID stamping"
fi
echo ">> pmhc preset complete: prod_dry.xtc / prod_ref.pdb / prod_last.pdb in $FOLDER"
