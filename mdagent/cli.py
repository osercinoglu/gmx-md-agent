#!/usr/bin/env python3
"""
pmhc-md-agent — one CLI to run a GROMACS pMHC MD replica either LOCALLY (on this
machine's/container's GPU) or on a rented Vast.ai GPU via SkyPilot, plus continue
(extend) an existing run. It is a thin argparse front-end over the vendored,
tested bash pipeline in scripts/; flags become environment variables.

Subcommands:
  local    EM->NVT->NPT->production(+analysis) here, in STAGE_NS chunks.
  cloud    same pipeline on a rented Vast.ai GPU (SkyPilot), pulled back here.
  extend   continue an existing run (<base>.tpr/.cpt) to a target ns, local|cloud.
  status / follow / teardown   manage a cloud run.
  poc      cheap end-to-end proof of the cloud path (dryrun|happy|resume|extend|all).

The agent runs on a normal Docker host (your workstation), NOT on a Vast
instance — for cloud runs it only drives the Vast API + SSH/rsync, so there is
no docker-in-docker anywhere.
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
MDP_DIR = SCRIPTS / "mdp"
GMX = os.environ.get("GMX", "gmx")


def sh(cmd, env=None, cwd=None):
    """Run a command, inheriting stdio; raise SystemExit on failure."""
    full = dict(os.environ)
    if env:
        full.update({k: str(v) for k, v in env.items() if v is not None})
    print(f"+ {' '.join(str(c) for c in cmd)}", flush=True)
    rc = subprocess.run([str(c) for c in cmd], env=full, cwd=cwd).returncode
    if rc != 0:
        sys.exit(rc)


def gmx_tpr_end_ps(tpr: Path) -> float:
    """End time (ps) baked into a .tpr = nsteps * dt, via `gmx dump`."""
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


def stage_local_pipeline(folder: Path, prod_mdp: Path):
    """Drop run_pipeline.sh + mdp/ into the working folder (run_pipeline.sh cd's
    into its own dir, so it must live alongside the inputs)."""
    shutil.copy2(NODE_PIPELINE, folder / "run_pipeline.sh")
    mdp = folder / "mdp"
    mdp.mkdir(exist_ok=True)
    for m in ("minim", "nvt", "npt"):
        shutil.copy2(MDP_DIR / f"{m}.mdp", mdp / f"{m}.mdp")
    shutil.copy2(prod_mdp, mdp / "md_prod.mdp")


def common_run_env(a):
    return {
        "TOTAL_NS": getattr(a, "total_ns", None),
        "STAGE_NS": getattr(a, "stage_ns", None),
        "CKPT_MIN": getattr(a, "ckpt_min", None),
        "MAXH_PER_STAGE": getattr(a, "maxh", None),
        "NT": getattr(a, "nt", None),
        "GPU_ID": getattr(a, "gpu_id", None),
        "GMX": "gmx",
    }


# ----------------------------- local --------------------------------------
def cmd_local(a):
    folder = Path(a.folder).resolve()
    if not folder.is_dir():
        sys.exit(f"folder not found: {folder}")
    prod_mdp = Path(a.prod_mdp).resolve() if a.prod_mdp else (MDP_DIR / "md_50ns.mdp")
    print(f">> LOCAL run in {folder}  ({a.total_ns} ns / {a.stage_ns} ns chunks)")
    stage_local_pipeline(folder, prod_mdp)
    sh(["bash", folder / "run_pipeline.sh"], env=common_run_env(a), cwd=folder)
    if not a.skip_analysis:
        sh(["bash", ANALYZE, folder], env={"GMX": "gmx"})
    print(f">> LOCAL run complete — prod*.xtc / prod_*.pdb in {folder}")


# ----------------------------- cloud --------------------------------------
def cloud_env(a):
    return {
        "IMAGE": getattr(a, "image", None),
        "IMAGE_KIND": getattr(a, "image_kind", None),
        "CONDA_SPEC": getattr(a, "conda_spec", None),
        "TOTAL_NS": getattr(a, "total_ns", None),
        "STAGE_NS": getattr(a, "stage_ns", None),
        "CKPT_MIN": getattr(a, "ckpt_min", None),
        "SYNC_MIN": getattr(a, "sync_min", None),
        "MAXH_PER_STAGE": getattr(a, "maxh", None),
        "MAX_RESTARTS": getattr(a, "max_restarts", None),
        "DISK_GB": getattr(a, "disk_gb", None),
        "PROD_MDP": (str(Path(a.prod_mdp).resolve()) if getattr(a, "prod_mdp", None) else None),
        "GPU_NAMES": getattr(a, "gpu_names", None),
        "TYPE": getattr(a, "type", None),
        "PICK": getattr(a, "pick", None),          # non-interactive offer pick
        "PUSHOVER_DEVICE": getattr(a, "pushover_device", None),
        "VAST_API_KEY": os.environ.get("VAST_API_KEY"),
    }


def cloud_launch_then_supervise(subcmd_args, env, folder, supervise):
    """launch/extend WITHOUT spawning the background supervisor, then run the
    supervisor in the FOREGROUND so the container stays alive for the whole run
    (docker run -d to detach). --no-supervise returns right after provisioning."""
    e = dict(env)
    e["LAUNCH_NO_SUPERVISE"] = "1"
    sh(["bash", RUNNER, *subcmd_args, folder], env=e)
    if supervise:
        sh(["bash", RUNNER, "supervise", folder])


def cmd_cloud(a):
    folder = Path(a.folder).resolve()
    cloud_launch_then_supervise(["launch"], cloud_env(a), folder, supervise=not a.no_supervise)


# ----------------------------- extend -------------------------------------
def cmd_extend(a):
    folder = Path(a.folder).resolve()
    base = a.from_base
    for suf in (".tpr", ".cpt", ".xtc"):
        base = base[: -len(suf)] if base.endswith(suf) else base
    btpr, bcpt = folder / f"{base}.tpr", folder / f"{base}.cpt"
    if not btpr.exists() or not bcpt.exists():
        sys.exit(f"extend needs {base}.tpr and {base}.cpt in {folder}")
    if not a.to_ns and not a.by_ns:
        sys.exit("extend: pass --to-ns <absolute> or --by-ns <delta>")

    if a.where == "local":
        cur_ns = gmx_tpr_end_ps(btpr) / 1000.0
        target_ns = float(a.to_ns) if a.to_ns else cur_ns + float(a.by_ns)
        if target_ns <= cur_ns + 1e-9:
            sys.exit(f"target {target_ns} ns is not beyond current {cur_ns} ns")
        print(f">> LOCAL extend {base}: {cur_ns:g} -> {target_ns:g} ns")
        shutil.copy2(NODE_PIPELINE, folder / "run_pipeline.sh")
        env = common_run_env(a)
        env.update({"EXTEND_BASE": base, "EXTEND_TO_PS": f"{target_ns * 1000.0:.6f}"})
        sh(["bash", folder / "run_pipeline.sh"], env=env, cwd=folder)
        if not a.skip_analysis:
            sh(["bash", ANALYZE, folder, base], env={"GMX": "gmx"})
        print(f">> LOCAL extend complete — prod*.xtc / prod_*.pdb in {folder}")
    else:  # cloud
        e = cloud_env(a)
        e["EXTEND_FROM"] = base
        if a.to_ns:
            e["EXTEND_TO_NS"] = a.to_ns
        else:
            e["EXTEND_BY_NS"] = a.by_ns
        cloud_launch_then_supervise(["extend"], e, folder, supervise=not a.no_supervise)


# ------------------------- passthrough cloud verbs ------------------------
def cmd_passthrough(a):
    folder = Path(a.folder).resolve()
    sh(["bash", RUNNER, a._verb, folder])


def cmd_poc(a):
    sh(["bash", POC, a.mode])


# ------------------------------- argparse ---------------------------------
def build_parser():
    p = argparse.ArgumentParser(prog="mdagent", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    def add_sim_flags(sp, cloud=False):
        sp.add_argument("folder", nargs="?", default=".", help="replica folder (default: cwd / mounted /work)")
        sp.add_argument("--total-ns", type=float, default=750, help="total production ns (default 750)")
        sp.add_argument("--stage-ns", type=float, default=50, help="ns per chunk (default 50)")
        sp.add_argument("--ckpt-min", type=int, default=15, help="checkpoint cadence, minutes (default 15)")
        sp.add_argument("--maxh", type=float, default=48, help="mdrun -maxh per chunk (default 48)")
        sp.add_argument("--prod-mdp", default=None, help="production .mdp (default scripts/mdp/md_50ns.mdp)")
        if cloud:
            sp.add_argument("--sync-min", type=int, default=15, help="local pull cadence, minutes")
            sp.add_argument("--max-restarts", type=int, default=10, help="recovery relaunch cap")
            sp.add_argument("--disk-gb", type=int, default=100, help="Vast node disk to reserve, GB")
            sp.add_argument("--image", default=None, help="Vast node docker image (default cuda+conda gmx)")
            sp.add_argument("--image-kind", default=None, choices=["conda", "ngc"])
            sp.add_argument("--conda-spec", default=None, help="gmx conda spec for the node")
            sp.add_argument("--gpu-names", default=None, help="Vast GPU filter, e.g. RTX_4090,RTX_3090")
            sp.add_argument("--type", default=None, choices=["on-demand", "bid"], help="pricing")
            sp.add_argument("--pick", default="1", help="offer row to auto-pick (non-interactive; default 1)")
            sp.add_argument("--pushover-device", default=None)
            sp.add_argument("--no-supervise", action="store_true",
                            help="provision + start only; do not block supervising (advanced)")
        else:
            sp.add_argument("--nt", type=int, default=None, help="OpenMP threads (default: all cores)")
            sp.add_argument("--gpu-id", type=int, default=0, help="GPU id for offload (default 0)")
            sp.add_argument("--skip-analysis", action="store_true", help="stop after production")

    sp = sub.add_parser("local", help="run the replica on this machine/container")
    add_sim_flags(sp, cloud=False); sp.set_defaults(func=cmd_local)

    sp = sub.add_parser("cloud", help="run the replica on a rented Vast.ai GPU")
    add_sim_flags(sp, cloud=True); sp.set_defaults(func=cmd_cloud)

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
    sp.add_argument("--skip-analysis", action="store_true")
    # cloud-only knobs (ignored for --where local)
    sp.add_argument("--sync-min", type=int, default=15)
    sp.add_argument("--max-restarts", type=int, default=10)
    sp.add_argument("--disk-gb", type=int, default=100)
    sp.add_argument("--image", default=None)
    sp.add_argument("--gpu-names", default=None)
    sp.add_argument("--type", default=None, choices=["on-demand", "bid"])
    sp.add_argument("--pick", default="1")
    sp.add_argument("--pushover-device", default=None)
    sp.add_argument("--no-supervise", action="store_true")
    sp.set_defaults(func=cmd_extend)

    for verb, helptext in (("status", "show cloud run status + progress"),
                           ("follow", "tail the cloud supervisor log"),
                           ("teardown", "cancel + tear down a cloud run")):
        sp = sub.add_parser(verb, help=helptext)
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
