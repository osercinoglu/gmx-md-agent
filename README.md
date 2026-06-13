# gmx-md-agent

A containerized **agent** that runs a GROMACS MD replica — either **locally**
(on this machine's GPU) or on a rented **Vast.ai** GPU via **SkyPilot** — and can
**continue/extend** an existing run to a target length. You run it from a folder
containing your inputs; it does the work and writes results back into that folder.

It is **system-agnostic**: you bring your own structure, topology, optional
index, and mdp files. The MD workflow is mdp-driven (EM → NVT → NPT → production,
each phase optional), with checkpoint resume, cloud preemption recovery, and
Pushover notifications. Trajectory analysis is **opt-in** (a post-process hook,
or a bundled `pmhc` preset).

## Architecture — no docker-in-docker

The agent runs on a **normal Docker host (your workstation)**, never on a Vast
instance. For cloud runs it only drives the **Vast API + SSH/rsync** (SkyPilot);
Vast launches the GROMACS container **natively** and SkyPilot runs the pipeline
*directly inside it*. No nested Docker, no docker socket, no `--privileged`.

```
your workstation                          Vast.ai
┌ AGENT container ─────────────┐          ┌ one Vast instance (a container) ┐
│ python CLI · sky · vastai ───┼─ API ───▶│ run_pipeline.sh runs directly   │
│ rsync · GROMACS (local+anal) │◀─rsync──▶│ (GROMACS, no nested docker)     │
└──────────────────────────────┘          └─────────────────────────────────┘
```

## Build

Base image = NGC GROMACS 2024.2, so log in to NGC first (username `$oauthtoken`,
password = your NGC API key):

```bash
docker login nvcr.io
cd ~/repos/gmx-md-agent
docker build -t gmx-md-agent .
```

## Credentials (mounted if present, else env)

| Purpose | Mount (preferred) | Env fallback |
|---|---|---|
| Vast API key | `~/.config/vastai` | `VAST_API_KEY` |
| Pushover | `~/.pushover` | `PUSHOVER_TOKEN`, `PUSHOVER_USER` |
| SkyPilot state / SSH | `~/.sky`, `~/.ssh` | — |

```bash
alias mdagent='docker run --rm -it -v "$PWD":/work \
  -v ~/.config/vastai:/root/.config/vastai -v ~/.pushover:/root/.pushover \
  -v ~/.sky:/root/.sky -v ~/.ssh:/root/.ssh gmx-md-agent'
mdagent_gpu() { docker run --rm -it --gpus all -v "$PWD":/work gmx-md-agent "$@"; }
```

## Inputs

Put your run inputs in the folder you mount at `/work`:
- a starting structure (`.gro`/`.pdb`; auto-detected, or `--struct NAME`),
- a topology (`--top`, default `topol.top`) and any `*.itp` / `*.ff` it `#include`s,
- an optional index (`--index`, default `index.ndx`, used only if present),
- the mdp files you want to run (see below).

Phases are **mdp-driven** — a phase runs only if you pass its mdp:
`--prod-mdp` (required), `--em-mdp`, `--nvt-mdp`, `--npt-mdp` (optional). To run
production from an already-equilibrated structure, pass only `--prod-mdp`.

## Run

```bash
# local (this machine's GPU; needs nvidia-container-toolkit on the host)
mdagent_gpu local --struct conf.gro --top topol.top \
  --em-mdp min.mdp --nvt-mdp nvt.mdp --npt-mdp npt.mdp --prod-mdp prod.mdp \
  --total-ns 500 --stage-ns 50

# cloud (Vast.ai)
mdagent cloud --prod-mdp prod.mdp --total-ns 500 --gpu-names RTX_4090,RTX_3090

# continue an existing run (.tpr + .cpt) to a target ns
mdagent extend --from md_0_250ns --to-ns 750 --where cloud      # absolute
mdagent_gpu extend --from md_0_250ns --by-ns 500 --where local  # delta

# manage / prove
mdagent status        # progress bar + vast#<id>
mdagent follow        # tail supervisor log
mdagent teardown
mdagent poc dryrun    # cheap cloud-path proof (uses the bundled pMHC test system)
```

Local GPU passthrough needs the NVIDIA Container Toolkit on the host (one-time):
```bash
sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker
```
Without it (or without `--gpus all`), local runs auto-fall back to **CPU**
(slow; fine for tests).

Cloud runs supervise for the whole job, so the agent container stays alive —
add `-d` to `docker run` to detach; results are pulled into the folder as chunks
finish.

## Analysis (`--analysis`)

- `none` (default) — just the concatenated `prod.xtc`; post-process it yourself.
- `pmhc` — the bundled preset: `trjconv` whole → nojump → center(grp 1) →
  fit(grp 4) → dry → ref/last PDB → chain-ID stamping (chains A/B/C). Expects the
  default `make_ndx` groups and `topol_Protein_chain_{A,B,C}.itp`.
- a path to your own **hook script** — run after production as
  `bash <hook> <folder> prod.xtc <last.tpr>`.

## Layout

```
mdagent/cli.py            argparse front-end (flags -> env -> bash)
scripts/cloud/            run_cloud_replica.sh (+supervisor/recovery/extend),
                          node/run_pipeline.sh (mdp-driven phases, GPU/CPU auto),
                          list_offers.sh, poc.sh, SkyPilot template
scripts/analyze.sh        concat chunks -> prod.xtc, then ANALYSIS dispatch
scripts/presets/analyze_pmhc.sh   the opt-in pMHC trjconv + chain-ID preset
scripts/mdp/              example mdp files (the bundled pMHC test system)
Dockerfile, entrypoint.sh
```

The cloud durability/recovery model (local rsync store, `-noappend` cross-node
resume, checkpoint-`-cpi`, `convert-tpr -extend`, idle-autostop backstop) is
documented in `scripts/cloud/README_cloud.md`.
