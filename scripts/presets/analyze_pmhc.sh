#!/usr/bin/env bash
# =============================================================================
# analyze_pmhc.sh — pMHC-I post-processing preset (opt-in: --analysis pmhc).
#
# DRY-ONLY by design: the solvated trajectory must exist ONLY as the raw
# md_part*/md_ext*/<base>.xtc chunks. We strip solvent+ions (the DRY_GROUP,
# default "Protein") up front, build a matching dry reference tpr with
# convert-tpr, and run whole -> nojump -> center -> fit on DRY data only — never
# materializing a solvated concatenated/whole/fit copy (that 6x-on-disk blowup is
# what fills drives). These are per-molecule/protein ops, so the protein
# coordinates are identical to processing the full system then stripping.
#
# Usage: analyze_pmhc.sh <folder> <last.tpr> [extend_base]   (GMX, DRY_GROUP env)
# Outputs: prod_dry.xtc, prod_ref.pdb, prod_last.pdb, prod_dry.tpr.
# =============================================================================
set -euo pipefail
export LC_ALL=C LANG=C
GMX="${GMX:-gmx}"
DRY_GROUP="${DRY_GROUP:-Protein}"
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
FOLDER="${1:?folder}"; LAST_TPR="${2:?last.tpr}"; EXT_BASE="${3:-}"
cd "$FOLDER"
[ -f index.ndx ] || { echo "pmhc preset: index.ndx required"; exit 1; }
[ -f add_chain_ids.py ] || cp -p "$HERE/../add_chain_ids.py" . 2>/dev/null || true

# chunk list (raw, solvated) — never concatenated solvated
if [ -n "$EXT_BASE" ]; then
  [ -f "${EXT_BASE}.xtc" ] || { echo "pmhc preset: ${EXT_BASE}.xtc missing"; exit 1; }
  CHUNKS="${EXT_BASE}.xtc $(ls -v md_ext*.xtc 2>/dev/null)"; TRJCAT_FLAGS=""
elif ls md_part*.part*.xtc >/dev/null 2>&1; then
  CHUNKS=$(ls md_part??.xtc md_part*.part*.xtc 2>/dev/null | sort -uV); TRJCAT_FLAGS=""
else
  CHUNKS=$(ls md_part??.xtc 2>/dev/null | sort -V); TRJCAT_FLAGS="-cat"
fi
[ -n "$CHUNKS" ] || { echo "pmhc preset: no trajectory chunks found"; exit 1; }

# dry reference topology (atoms = DRY_GROUP), matches the dry xtc atom count
[ -f prod_dry.tpr ] || echo "$DRY_GROUP" | "$GMX" convert-tpr -s "$LAST_TPR" -n index.ndx -o prod_dry.tpr

# strip solvent+ions and make whole PER CHUNK (small temp files)
rm -rf .dryan; mkdir -p .dryan
di=0; DRYLIST=""
for c in $CHUNKS; do
  o=$(printf ".dryan/d%04d.xtc" "$di"); di=$((di+1))
  echo "$DRY_GROUP" | "$GMX" trjconv -s "$LAST_TPR" -f "$c" -n index.ndx -pbc whole -o "$o"
  DRYLIST="$DRYLIST $o"
done

# concat dry chunks, then nojump/center/fit on the DRY reference
# (protein-only default groups: 0=System, 1=Protein, 4=Backbone)
"$GMX" trjcat -f $DRYLIST -o .dryan/whole.xtc $TRJCAT_FLAGS
echo 0          | "$GMX" trjconv -s prod_dry.tpr -f .dryan/whole.xtc  -o .dryan/nojump.xtc -pbc nojump
printf "1\n0\n" | "$GMX" trjconv -s prod_dry.tpr -f .dryan/nojump.xtc -o .dryan/center.xtc -center -pbc mol -ur compact
printf "4\n0\n" | "$GMX" trjconv -s prod_dry.tpr -f .dryan/center.xtc -o prod_dry.xtc      -fit rot+trans

echo 0 | "$GMX" trjconv -s prod_dry.tpr -f prod_dry.xtc -o prod_ref.pdb  -dump 0          -conect
echo 0 | "$GMX" trjconv -s prod_dry.tpr -f prod_dry.xtc -o prod_last.pdb -dump 999999999  -conect
if [ -f topol_Protein_chain_A.itp ] && [ -f topol_Protein_chain_B.itp ] && [ -f topol_Protein_chain_C.itp ]; then
  python3 add_chain_ids.py prod_ref.pdb  topol_Protein_chain_A.itp topol_Protein_chain_B.itp topol_Protein_chain_C.itp
  python3 add_chain_ids.py prod_last.pdb topol_Protein_chain_A.itp topol_Protein_chain_B.itp topol_Protein_chain_C.itp
else
  echo ">> pmhc preset: chain itps absent — skipping chain-ID stamping"
fi

rm -rf .dryan   # keep only dry deliverables; raw chunks untouched
echo ">> pmhc preset complete (dry-only): prod_dry.xtc / prod_ref.pdb / prod_last.pdb / prod_dry.tpr in $FOLDER"
