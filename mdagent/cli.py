#!/usr/bin/env python3
"""
gmx-md-agent — one CLI to run a GROMACS MD replica either LOCALLY (this
machine's/container's GPU) or on a rented Vast.ai GPU via SkyPilot, and to
continue (extend) an existing run to a target length. System-agnostic: you bring
your own structure, topology, optional index, and mdp files; trajectory analysis
is opt-in (a post-process hook, or the bundled `pmhc` preset).

Subcommands:
  local    EM/NVT/NPT/production (whichever mdps you provide) here, in chunks.
  cloud    same, on a rented Vast.ai GPU (SkyPilot), pulled back here.
  extend   continue an existing run (<base>.tpr/.cpt) to a target ns, local|cloud.
  status / follow / teardown   manage a cloud run.
  poc      cheap end-to-end proof of the cloud path.

Phases are mdp-driven: a phase runs only if you pass its mdp (--prod-mdp is
required for a fresh run; --em-mdp/--nvt-mdp/--npt-mdp are optional).

The agent runs on a normal Docker host (your workstation), NOT on a Vast
instance — cloud runs only drive the Vast API + SSH/rsync (no docker-in-docker).
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
CLOUD = SCRIPTS / "cloud"
RUNNER = CLOUD / "run_cloud_replica.sh"
POC = CLOUD / "poc.sh"
NODE_PIPELINE = CLOUD / "node" / "run_pipeline.sh"
ANALYZE = SCRIPTS / "analyze.sh"
GMX = os.environ.get("GMX", "gmx")


def sh(cmd, env=None, cwd=None):
    full = dict(os.environ)
    if env:
        full.update({k: str(v) for k, v in env.items() if v is not None})
    print(f"+ {' '.join(str(c) for c in cmd)}", flush=True)
    rc = subprocess.run([str(c) for c in cmd], env=full, cwd=cwd).returncode
    if rc != 0:
        sys.exit(rc)


def abspath_or_none(p):
    return str(Path(p).resolve()) if p else None


def gmx_tpr_end_ps(tpr: Path) -> float:
    out = subprocess.run([GMX, "dump", "-s", str(tpr)], capture_output=True, text=True).stdout
    ns = dt = None
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("nsteps") and "=" in s:
            ns = float(s.split("=")[-1].strip())
        elif s.startswith("dt") and "=" in s:
            dt = float(s.split("=")[-1].strip())
    if ns is None or dt is None:
        sys.exit(f"could not read nsteps/dt from {tpr} (gmx dump failed)")
    return ns * dt


def stage_local_pipeline(folder: Path, a):
    """run_pipeline.sh cd's into its own dir, so it must live with the inputs."""
    shutil.copy2(NODE_PIPELINE, folder / "run_pipeline.sh")
    mdp = folder / "mdp"; mdp.mkdir(exist_ok=True)
    if a.em_mdp:  shutil.copy2(a.em_mdp,  mdp / "em.mdp")
    if a.nvt_mdp: shutil.copy2(a.nvt_mdp, mdp / "nvt.mdp")
    if a.npt_mdp: shutil.copy2(a.npt_mdp, mdp / "npt.mdp")
    shutil.copy2(a.prod_mdp, mdp / "prod.mdp")


def input_env(a):
    return {
        "START_STRUCT": getattr(a, "struct", None) or "",
        "TOP": getattr(a, "top", None) or "topol.top",
        "INDEX": getattr(a, "index", None) or "index.ndx",
        "MAXWARN": getattr(a, "maxwarn", None),
    }


def local_run_env(a):
    e = {
        "TOTAL_NS": a.total_ns, "STAGE_NS": a.stage_ns, "CKPT_MIN": a.ckpt_min,
        "MAXH_PER_STAGE": a.maxh, "NT": getattr(a, "nt", None),
        "GPU_ID": getattr(a, "gpu_id", 0), "GMX": "gmx",
    }
    e.update(input_env(a))
    return e


def cloud_env(a):
    e = {
        "IMAGE": getattr(a, "image", None), "IMAGE_KIND": getattr(a, "image_kind", None),
        "CONDA_SPEC": getattr(a, "conda_spec", None),
        "TOTAL_NS": getattr(a, "total_ns", None), "STAGE_NS": a.stage_ns,
        "CKPT_MIN": a.ckpt_min, "SYNC_MIN": getattr(a, "sync_min", None),
        "MAXH_PER_STAGE": a.maxh, "MAX_RESTARTS": getattr(a, "max_restarts", None),
        "DISK_GB": getattr(a, "disk_gb", None),
        "PROD_MDP": abspath_or_none(getattr(a, "prod_mdp", None)),
        "EM_MDP": abspath_or_none(getattr(a, "em_mdp", None)),
        "NVT_MDP": abspath_or_none(getattr(a, "nvt_mdp", None)),
        "NPT_MDP": abspath_or_none(getattr(a, "npt_mdp", None)),
        "ANALYSIS": getattr(a, "analysis", None) or "none",
        "GPU_NAMES": getattr(a, "gpu_names", None), "TYPE": getattr(a, "type", None),
        "PICK": getattr(a, "pick", None), "PUSHOVER_DEVICE": getattr(a, "pushover_device", None),
        "VAST_API_KEY": os.environ.get("VAST_API_KEY"),
    }
    e.update(input_env(a))
    # ANALYSIS may be a relative hook path -> make absolute so the node-side
    # orchestrator (different cwd) still finds it.
    an = e["ANALYSIS"]
    if an not in ("none", "pmhc") and Path(an).exists():
        e["ANALYSIS"] = str(Path(an).resolve())
    return e


def require_prod_mdp(a):
    if not a.prod_mdp:
        sys.exit("a fresh run needs --prod-mdp <production.mdp>")
    if not Path(a.prod_mdp).is_file():
        sys.exit(f"--prod-mdp not found: {a.prod_mdp}")


# ----------------------------- local --------------------------------------
def cmd_local(a):
    folder = Path(a.folder).resolve()
    if not folder.is_dir():
        sys.exit(f"folder not found: {folder}")
    require_prod_mdp(a)
    print(f">> LOCAL run in {folder}  ({a.total_ns} ns / {a.stage_ns} ns chunks)")
    stage_local_pipeline(folder, a)
    sh(["bash", folder / "run_pipeline.sh"], env=local_run_env(a), cwd=folder)
    if not a.skip_analysis:
        sh(["bash", ANALYZE, folder], env={"GMX": "gmx", "ANALYSIS": a.analysis or "none"})
    print(f">> LOCAL run complete in {folder}")


# ----------------------------- cloud --------------------------------------
def cloud_launch_then_supervise(verb_args, env, folder, supervise):
    e = dict(env); e["LAUNCH_NO_SUPERVISE"] = "1"
    sh(["bash", RUNNER, *verb_args, folder], env=e)
    if supervise:
        sh(["bash", RUNNER, "supervise", folder])


def cmd_cloud(a):
    require_prod_mdp(a)
    folder = Path(a.folder).resolve()
    cloud_launch_then_supervise(["launch"], cloud_env(a), folder, supervise=not a.no_supervise)


# ----------------------------- extend -------------------------------------
def cmd_extend(a):
    folder = Path(a.folder).resolve()
    base = a.from_base
    for suf in (".tpr", ".cpt", ".xtc"):
        if base.endswith(suf):
            base = base[: -len(suf)]
    btpr, bcpt = folder / f"{base}.tpr", folder / f"{base}.cpt"
    if not btpr.exists() or not bcpt.exists():
        sys.exit(f"extend needs {base}.tpr and {base}.cpt in {folder}")

    if a.where == "local":
        cur_ns = gmx_tpr_end_ps(btpr) / 1000.0
        target_ns = float(a.to_ns) if a.to_ns else cur_ns + float(a.by_ns)
        if target_ns <= cur_ns + 1e-9:
            sys.exit(f"target {target_ns} ns is not beyond current {cur_ns} ns")
        print(f">> LOCAL extend {base}: {cur_ns:g} -> {target_ns:g} ns")
        shutil.copy2(NODE_PIPELINE, folder / "run_pipeline.sh")
        env = {
            "TOTAL_NS": 0, "STAGE_NS": a.stage_ns, "CKPT_MIN": a.ckpt_min, "MAXH_PER_STAGE": a.maxh,
            "NT": a.nt, "GPU_ID": a.gpu_id, "GMX": "gmx",
            "EXTEND_BASE": base, "EXTEND_TO_PS": f"{target_ns * 1000.0:.6f}",
        }
        sh(["bash", folder / "run_pipeline.sh"], env=env, cwd=folder)
        if not a.skip_analysis:
            sh(["bash", ANALYZE, folder, base], env={"GMX": "gmx", "ANALYSIS": a.analysis or "none"})
        print(f">> LOCAL extend complete in {folder}")
    else:  # cloud
        e = cloud_env(a)
        e["EXTEND_FROM"] = base
        if a.to_ns:
            e["EXTEND_TO_NS"] = a.to_ns
        else:
            e["EXTEND_BY_NS"] = a.by_ns
        cloud_launch_then_supervise(["extend"], e, folder, supervise=not a.no_supervise)


def cmd_passthrough(a):
    sh(["bash", RUNNER, a._verb, str(Path(a.folder).resolve())])


def cmd_poc(a):
    sh(["bash", POC, a.mode])


# ------------------------------- argparse ---------------------------------
def add_inputs(sp):
    sp.add_argument("folder", nargs="?", default=".", help="working folder (default: cwd / mounted /work)")
    sp.add_argument("--struct", default=None, help="starting structure (.gro/.pdb); auto-detected if unset")
    sp.add_argument("--top", default="topol.top", help="topology file (default topol.top)")
    sp.add_argument("--index", default="index.ndx", help="index file (used if present; default index.ndx)")
    sp.add_argument("--total-ns", type=float, default=750, help="total production ns (default 750)")
    sp.add_argument("--stage-ns", type=float, default=50, help="ns per chunk (default 50)")
    sp.add_argument("--ckpt-min", type=int, default=15, help="checkpoint cadence, minutes")
    sp.add_argument("--maxh", type=float, default=48, help="mdrun -maxh per chunk")
    sp.add_argument("--maxwarn", type=int, default=1, help="grompp -maxwarn")
    sp.add_argument("--prod-mdp", default=None, help="production mdp (REQUIRED for a fresh run)")
    sp.add_argument("--em-mdp", default=None, help="energy-minimization mdp (optional phase)")
    sp.add_argument("--nvt-mdp", default=None, help="NVT mdp (optional phase)")
    sp.add_argument("--npt-mdp", default=None, help="NPT mdp (optional phase)")
    sp.add_argument("--analysis", default="none", help="none (default) | pmhc | <hook script path>")


def add_cloud_flags(sp):
    sp.add_argument("--sync-min", type=int, default=15, help="local pull cadence, minutes")
    sp.add_argument("--max-restarts", type=int, default=10, help="recovery relaunch cap")
    sp.add_argument("--disk-gb", type=int, default=100, help="Vast node disk to reserve, GB")
    sp.add_argument("--image", default=None, help="Vast node docker image")
    sp.add_argument("--image-kind", default=None, choices=["conda", "ngc"])
    sp.add_argument("--conda-spec", default=None, help="gmx conda spec for the node")
    sp.add_argument("--gpu-names", default=None, help="Vast GPU filter, e.g. RTX_4090,RTX_3090")
    sp.add_argument("--type", default=None, choices=["on-demand", "bid"])
    sp.add_argument("--pick", default="1", help="offer row to auto-pick (default 1)")
    sp.add_argument("--pushover-device", default=None)
    sp.add_argument("--no-supervise", action="store_true", help="provision + start only (advanced)")


def build_parser():
    p = argparse.ArgumentParser(prog="mdagent", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("local", help="run on this machine/container")
    add_inputs(sp)
    sp.add_argument("--nt", type=int, default=None, help="OpenMP threads (default: all cores)")
    sp.add_argument("--gpu-id", type=int, default=0)
    sp.add_argument("--skip-analysis", action="store_true")
    sp.set_defaults(func=cmd_local)

    sp = sub.add_parser("cloud", help="run on a rented Vast.ai GPU")
    add_inputs(sp); add_cloud_flags(sp)
    sp.set_defaults(func=cmd_cloud)

    sp = sub.add_parser("extend", help="continue an existing run to a target ns")
    sp.add_argument("folder", nargs="?", default=".")
    sp.add_argument("--from", dest="from_base", required=True, help="base name of existing run (<base>.tpr/.cpt)")
    g = sp.add_mutually_exclusive_group(required=True)
    g.add_argument("--to-ns", default=None, help="absolute target end time, ns")
    g.add_argument("--by-ns", default=None, help="additional ns to add")
    sp.add_argument("--where", choices=["local", "cloud"], default="cloud")
    sp.add_argument("--stage-ns", type=float, default=50)
    sp.add_argument("--ckpt-min", type=int, default=15)
    sp.add_argument("--maxh", type=float, default=48)
    sp.add_argument("--nt", type=int, default=None)
    sp.add_argument("--gpu-id", type=int, default=0)
    sp.add_argument("--analysis", default="none", help="none | pmhc | <hook>")
    sp.add_argument("--skip-analysis", action="store_true")
    add_cloud_flags(sp)
    sp.set_defaults(func=cmd_extend)

    for verb, h in (("status", "cloud run status + progress"),
                    ("follow", "tail the cloud supervisor log"),
                    ("teardown", "cancel + tear down a cloud run")):
        sp = sub.add_parser(verb, help=h)
        sp.add_argument("folder", nargs="?", default=".")
        sp.set_defaults(func=cmd_passthrough, _verb=verb)

    sp = sub.add_parser("poc", help="cheap proof of the cloud path")
    sp.add_argument("mode", nargs="?", default="dryrun",
                    choices=["dryrun", "happy", "resume", "extend", "all"])
    sp.set_defaults(func=cmd_poc)
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
