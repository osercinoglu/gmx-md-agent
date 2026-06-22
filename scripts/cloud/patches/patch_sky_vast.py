#!/usr/bin/env python3
"""Patch SkyPilot's Vast provisioner so it NEVER substitutes the requested GPU.

Why: sky/provision/vast/utils.py builds a Vast search query that includes
`georegion=true geolocation="<cc>"`. When those are present, Vast's search
IGNORES the `gpu_name="..."` filter and returns offers of ALL GPU types; the
provisioner then blindly takes `instance_list[0]`, which is often a different
(e.g. Blackwell RTX 5090 / B200) GPU than requested. That breaks GROMACS builds
compiled for older compute capabilities (2024.2 / CUDA 11.8 => <= sm_90).

This patch inserts, right before `instance_touse = instance_list[0]`, a strict
filter that keeps ONLY offers whose gpu_name exactly matches the requested one,
sorts them cheapest-first, and (optionally) drops any above a price ceiling from
the env var VAST_MAX_DPH. Idempotent: re-running is a no-op.
"""
import sys

try:
    import sky.provision.vast.utils as u
    path = u.__file__
except Exception as e:  # pragma: no cover
    print(f"[patch] SkyPilot vast utils not importable: {e}", file=sys.stderr)
    sys.exit(0)  # don't fail the image build if layout changed

MARKER = "# [gmx-md-agent] strict gpu_name + price filter"
src = open(path, "r").read()
if MARKER in src:
    print(f"[patch] already applied: {path}")
    sys.exit(0)

needle = "    instance_touse = instance_list[0]\n"
if needle not in src:
    print(f"[patch] anchor not found in {path}; SkyPilot internals changed — "
          "NOT patching (review manually)", file=sys.stderr)
    sys.exit(1)

block = (
    "    " + MARKER + "\n"
    "    # Vast ignores gpu_name when georegion/geolocation is in the query, so\n"
    "    # search_offers can return other GPU types. Keep only the EXACT requested\n"
    "    # GPU, cheapest first, and honor an optional VAST_MAX_DPH price ceiling.\n"
    "    import os as _os\n"
    "    _want = gpu_name.strip().lower()\n"
    "    _exact = [o for o in instance_list\n"
    "              if str(o.get('gpu_name', '')).strip().lower() == _want]\n"
    "    if _exact:\n"
    "        # Prefer reliability, THEN price: the absolute-cheapest Vast offers are\n"
    "        # often broken hosts (e.g. kaalia/OCI shim failures). Highest reliability\n"
    "        # first, cheapest among equally-reliable.\n"
    "        def _rel(o):\n"
    "            return float(o.get('reliability2', o.get('reliability', 0)) or 0)\n"
    "        instance_list = sorted(\n"
    "            _exact, key=lambda o: (-round(_rel(o), 3), float(o.get('dph_total', 1e9))))\n"
    "    _cap = _os.environ.get('VAST_MAX_DPH')\n"
    "    if _cap:\n"
    "        try:\n"
    "            _capf = float(_cap)\n"
    "            _cheap = [o for o in instance_list\n"
    "                      if float(o.get('dph_total', 1e9)) <= _capf]\n"
    "            if _cheap:\n"
    "                instance_list = _cheap\n"
    "        except ValueError:\n"
    "            pass\n"
    "    if not instance_list:\n"
    "        raise RuntimeError(\n"
    "            f'no Vast offer matches gpu_name=\"{gpu_name}\" within VAST_MAX_DPH')\n"
    + needle
)

src = src.replace(needle, block, 1)
open(path, "w").write(src)
print(f"[patch] applied strict GPU filter to {path}")
