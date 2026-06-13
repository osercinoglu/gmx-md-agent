#!/usr/bin/env python3
"""Restore chain IDs A/B/C on the protein atoms of a GROMACS-written PDB.

GROMACS writes molecule-aware PDBs but chain IDs (column 22) are sometimes
blanked when the trajectory was produced from a .tpr/.gro that lost chain
metadata. This script reads the per-chain atom counts from the standard
topol_Protein_chain_{A,B,C}.itp files and stamps chain IDs onto the first
N_A + N_B + N_C protein atoms of the PDB.

Idempotent: if chain IDs are already present and correct, the file is left
unchanged (other than newline normalization).

Usage:
    add_chain_ids.py PDB_FILE TOPOL_A.itp TOPOL_B.itp TOPOL_C.itp
"""
from __future__ import annotations

import sys
from pathlib import Path


def count_atoms(itp_path: Path) -> int:
    """Count rows under the [ atoms ] directive of a GROMACS .itp file."""
    n = 0
    in_atoms = False
    with itp_path.open() as fh:
        for raw in fh:
            line = raw.split(";", 1)[0].rstrip()
            stripped = line.strip()
            if not stripped:
                continue
            if stripped.startswith("[") and stripped.endswith("]"):
                in_atoms = stripped.strip("[] ").lower() == "atoms"
                continue
            if in_atoms:
                tok = stripped.split()
                if len(tok) >= 2 and tok[0].lstrip("-").isdigit():
                    n += 1
    return n


def stamp_chains(pdb_path: Path, chain_runs: list[tuple[str, int]]) -> None:
    """Set column 22 (chain ID) on consecutive ATOM/HETATM records.

    chain_runs is a list of (chain_id, atom_count) tuples applied in order
    to the first sum(atom_counts) ATOM/HETATM records.
    """
    flat: list[str] = []
    for cid, n in chain_runs:
        flat.extend([cid] * n)
    n_target = len(flat)

    out_lines: list[str] = []
    atom_idx = 0
    changed = 0
    with pdb_path.open() as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if line.startswith(("ATOM  ", "HETATM")) and atom_idx < n_target:
                desired = flat[atom_idx]
                # PDB chain ID is column 22 (1-indexed) = index 21
                if len(line) < 22:
                    line = line.ljust(22)
                if line[21] != desired:
                    line = line[:21] + desired + line[22:]
                    changed += 1
                atom_idx += 1
            out_lines.append(line)

    pdb_path.write_text("\n".join(out_lines) + "\n")
    print(
        f"[add_chain_ids] {pdb_path.name}: stamped {atom_idx} protein atoms "
        f"({changed} chain-ID cells changed) "
        f"[A={chain_runs[0][1]}, B={chain_runs[1][1]}, C={chain_runs[2][1]}]"
    )


def main(argv: list[str]) -> int:
    if len(argv) != 5:
        print(__doc__, file=sys.stderr)
        return 2
    pdb = Path(argv[1])
    itp_a, itp_b, itp_c = (Path(p) for p in argv[2:5])
    for p in (pdb, itp_a, itp_b, itp_c):
        if not p.is_file():
            print(f"missing: {p}", file=sys.stderr)
            return 1

    n_a = count_atoms(itp_a)
    n_b = count_atoms(itp_b)
    n_c = count_atoms(itp_c)
    if min(n_a, n_b, n_c) <= 0:
        print(
            f"failed to parse atom counts: A={n_a} B={n_b} C={n_c}",
            file=sys.stderr,
        )
        return 1

    stamp_chains(pdb, [("A", n_a), ("B", n_b), ("C", n_c)])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
