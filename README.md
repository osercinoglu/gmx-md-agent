# pmhc-md-agent

A containerized **agent** that runs one GROMACS peptide–HLA (pMHC-I) MD replica —
either **locally** (on this machine's GPU) or on a rented **Vast.ai** GPU via
**SkyPilot** — and can **continue/extend** an existing run to a target length.
You run it from a replica folder; it does the work and writes the analysis-ready
trajectory back into that folder.

It's a Python `argparse` CLI over a vendored, tested bash pipeline (EM → NVT →
NPT → production in `STAGE_NS` chunks → trjconv analysis), with checkpoint
resume, cloud preemption recovery, and Pushover notifications (folder title +
`vast#<id>` + a progress bar).

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

The base image is NVIDIA NGC GROMACS 2024.2, so log in to NGC first (username is
literally `$oauthtoken`, password is your NGC API key from ngc.nvidia.com):

```bash
docker login nvcr.io
cd ~/repos/pmhc-md-agent
docker build -t pmhc-md-agent .
```

## Credentials (mount or env — whichever is present)

The agent prefers bind-mounted host configs and falls back to env vars:

| Purpose | Mount (preferred) | Env fallback |
|---|---|---|
| Vast API key | `~/.config/vastai` | `VAST_API_KEY` |
| Pushover | `~/.pushover` | `PUSHOVER_TOKEN`, `PUSHOVER_USER` |
| SkyPilot state / SSH (cloud, multi-command) | `~/.sky`, `~/.ssh` | — |

## Run

Bind-mount the replica folder at `/work`. A convenience alias:

```bash
alias mdagent='docker run --rm -it \
  -v "$PWD":/work \
  -v ~/.config/vastai:/root/.config/vastai \
  -v ~/.pushover:/root/.pushover \
  -v ~/.sky:/root/.sky -v ~/.ssh:/root/.ssh \
  pmhc-md-agent'
```

### Local run (this machine's GPU)

GPU passthrough needs the NVIDIA Container Toolkit (one-time, on the host):

```bash
sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker
```

Then, from a replica folder (must contain `solvated_ions.pdb`, `topol.top`, the
3 chain itps, the 3 posre itps, `index.ndx`):

```bash
cd /path/to/AII_C_14_02_4
mdagent_gpu() { docker run --rm -it --gpus all -v "$PWD":/work pmhc-md-agent "$@"; }

mdagent_gpu local --total-ns 750 --stage-ns 50
```

No GPU / no toolkit yet? It auto-detects and runs **CPU-only** (slow; fine for a
quick test): drop `--gpus all`.

### Cloud run (Vast.ai)

```bash
mdagent cloud --total-ns 750 --stage-ns 50 --gpu-names RTX_4090,RTX_3090 --type on-demand
```

This provisions a Vast GPU, runs the pipeline, pulls each chunk back into the
folder, runs analysis locally, and tears the node down. The container stays alive
supervising for the whole run — add `-d` to `docker run` to detach. `--pick N`
chooses the offer row non-interactively (default 1).

### Continue / extend an existing run

Point at any existing run's `<base>.tpr` + `<base>.cpt` (e.g. an on-prem
`md_0_250ns_nohmr`). The original `<base>.xtc` is concatenated with the new
chunks into the full `prod*.xtc`.

```bash
# absolute target, on the cloud:
mdagent extend --from md_0_250ns_nohmr --to-ns 750 --where cloud
# add a delta, locally:
mdagent_gpu extend --from md_0_250ns_nohmr --by-ns 500 --where local
```

### Manage / prove

```bash
mdagent status        # cloud run status + progress bar + vast#<id>
mdagent follow        # tail the supervisor log
mdagent teardown      # cancel + sky down (+ SWEEP)
mdagent poc dryrun    # $0 validation of the cloud path; then: poc all / poc extend
```

## Flags (argparse)

`mdagent <local|cloud|extend|status|follow|teardown|poc> --help` for the full
list. Common: `--total-ns`, `--stage-ns`, `--ckpt-min`, `--maxh`, `--prod-mdp`;
local adds `--nt`, `--gpu-id`, `--skip-analysis`; cloud adds `--sync-min`,
`--max-restarts`, `--disk-gb`, `--image`, `--gpu-names`, `--type`, `--pick`,
`--no-supervise`; extend adds `--from`, `--to-ns | --by-ns`, `--where`.

## Layout

```
mdagent/cli.py            argparse front-end (flags -> env -> bash)
scripts/cloud/            run_cloud_replica.sh, list_offers.sh, poc.sh, the SkyPilot
                          template, and node/run_pipeline.sh (compute, GPU/CPU auto)
scripts/analyze.sh        local trjconv post-processing (fresh + extend)
scripts/mdp/, pushover.sh, add_chain_ids.py
Dockerfile, entrypoint.sh
```

Science (topology, ion layout, mdp parameters, random-seed NVT, analysis group
indices, chain-ID stamping) is identical to the on-prem `run_replica.sh`, so atom
numbering stays consistent for cross-replica comparison.
