# cloud/ — run pMHC MD replicas on Vast.ai via SkyPilot

The cloud counterpart of `replica_prep/run_replica.sh`. It runs one *independent*
replica (EM → NVT[random seed] → NPT → production → analysis) on a rented
**Vast.ai** GPU, orchestrated by **SkyPilot**.

**Self-contained.** The launcher installs the `sky`/`vastai` CLIs if missing,
prompts for (and stores) your Vast.ai API key and Pushover credentials when
they're absent, and installs a small local CPU-only GROMACS for the final
analysis. You only need a Vast.ai account.

**No cloud bucket — your machine is the durable store.** The rented node *only
computes*. The local supervisor `rsync`-pulls the node's outputs (checkpoints +
trajectories) as each stage completes. If the node is destroyed/preempted, the
supervisor re-provisions and pushes the saved state back so GROMACS resumes from
the last checkpoint (you lose minutes, not the stage). When production finishes
it runs the trjconv analysis **locally** and tears the node down. Pushover pings
you at start, on each completed stage, on recovery, and on completion/failure.

> Because there is no cloud bucket, **this machine must stay online during the
> run** to pull files and drive recovery. The supervisor is backgrounded with
> `nohup` (closing the terminal is fine), but a powered-off machine pulls
> nothing. Vast nodes also get a 30-min idle `--down` backstop, so a node never
> bills indefinitely even if your machine disappears.

## How "pick a node" works

SkyPilot **cannot pin one exact physical Vast offer** — at launch it takes the
first live offer matching your constraints. `list_offers.sh` shows live offers
(price, reliability, CUDA, est. $/replica); your pick becomes *(GPU type,
price-ceiling, on-demand/spot)* and SkyPilot lands the best live match.

## One-time setup — optional

The launcher bootstraps itself, so you can skip straight to the POC. If you want
to check everything up front and record defaults:

```bash
cd /opt/experiments/pep_hla_dynamics/md_sims/replica_prep/cloud
bash cloud_setup.sh          # checks tools/key/pushover/gmx, writes cloud.env
```

## Prove it works first (do this before any real run)

```bash
bash poc.sh dryrun     # $0  — bootstrap + offer listing + render + sky launch --dryrun
bash poc.sh happy      # ~$1 — full chain on a ~0.6 ns job, smallest real system
bash poc.sh resume     # ~$1 — destroys the instance mid-run, proves checkpoint resume
# or: bash poc.sh all
```

The **resume** test is the one that matters: it destroys the Vast instance after
a checkpoint has been pulled locally and verifies the supervisor re-provisions
and GROMACS continues from the checkpoint (a `md_partNN.partNNNN.xtc`
continuation appears) instead of restarting the stage.

## Launch a real replica

```bash
cd /opt/experiments/pep_hla_dynamics/md_sims/AII_C_14_02_4
RUNNER=/opt/experiments/pep_hla_dynamics/md_sims/replica_prep/cloud/run_cloud_replica.sh
bash "$RUNNER" launch .       # bootstrap, pick offer, provision, spawn supervisor
bash "$RUNNER" follow .       # tail the local supervisor log
bash "$RUNNER" status .       # supervisor + local progress + cluster + vast instance
bash "$RUNNER" fetch .        # one-shot manual pull of current node outputs
bash "$RUNNER" teardown .     # stop supervisor + sky down (+ SWEEP=1 vast sweep)
```

Stage outputs are pulled into `<REPLICA_DIR>/.cloud_state/` as they finish; the
final `prod*.xtc` / `prod_*.pdb` are written into `<REPLICA_DIR>/` at the end.

## Continue / extend an existing run

Point it at any existing GROMACS run (`<base>.tpr` + `<base>.cpt`, e.g. an on-prem
`md_0_250ns_nohmr`) and continue it on a cloud GPU with proper velocity
continuity (`gmx convert-tpr -extend` + `mdrun -cpi`). The original `<base>.xtc`
stays on your machine; new frames are computed in `STAGE_NS` chunks and
concatenated locally into the full `prod*.xtc`.

```bash
cd <REPLICA_DIR>
RUNNER=.../cloud/run_cloud_replica.sh
# absolute target:
EXTEND_FROM=md_0_250ns_nohmr EXTEND_TO_NS=750 bash "$RUNNER" extend .
# or add a delta:
EXTEND_FROM=md_0_250ns_nohmr EXTEND_BY_NS=500 bash "$RUNNER" extend .
```

The launcher reads the current length from the `.tpr`, computes the chunk count,
and the supervisor/recovery/progress/Pushover all work exactly as for a fresh
run (progress is weighted 0–95 % across the extension, 100 % after analysis).
Only `<base>.tpr` + `<base>.cpt` are uploaded — never the big `.xtc`. Prove it
cheaply first with `bash poc.sh extend`.

## Files

| File | Role |
|---|---|
| `run_cloud_replica.sh` | self-contained launcher + `extend` + supervisor (pull/recover/analyze/teardown) |
| `list_offers.sh` | live Vast offer browser + cost estimate → `cloud_selection.env` |
| `gromacs_md.sky.yaml.tmpl` | SkyPilot **cluster** spec (rendered per run; no secrets) |
| `node/run_pipeline.sh` | on-node compute only (EM/NVT/NPT/production + status markers) |
| `node/cloud_node_setup.sh` | installs CUDA `gmx` + `rsync` on the node |
| `mdp/md_poc.mdp` | 0.6 ns POC production mdp (identical physics) |
| `poc.sh` | end-to-end proof harness (dryrun/happy/resume) |
| `cloud_setup.sh` | optional preflight check, writes `cloud.env` |

## Knobs (env, or edit `cloud.env`)

```
IMAGE      (default nvidia/cuda:12.4.1-runtime-ubuntu22.04)
IMAGE_KIND (conda|ngc, default conda)   CONDA_SPEC (default gromacs=2024.2=nompi_cuda_*)
TOTAL_NS STAGE_NS                  # 750 / 50  (15 stages)
CKPT_MIN                           # node checkpoint cadence (min, default 15)
SYNC_MIN                           # local pull cadence (min, default 15)
MAXH_PER_STAGE MAX_RESTARTS        # mdrun walltime cap / recovery relaunch cap
DISK_GB                            # node disk to reserve for the whole run (default 100)
PROD_MDP                           # production mdp (default ../mdp/md_50ns.mdp)
LOCAL_GMX                          # path to a local gmx for analysis (else auto-install)
GPU_NAMES TYPE COUNTRIES           # offer filters (see list_offers.sh)
PUSHOVER_DEVICE                    # optional
```

## Differences from on-prem `run_replica.sh`

- **Real intra-stage resume.** Each stage resumes from its `.cpt` (no
  `-update gpu` — same all-bonds/LINCS constraint). On a *cross-node* recovery
  the node has only the pushed-back `.cpt`/`.tpr`, so it resumes with
  `-noappend` (writes `md_partNN.partNNNN.*`); the local analysis trjcat-concats
  the pre-crash partial with the continuation. On-prem restarts the whole stage.
- **Local durability + analysis.** Outputs are pulled to this machine over
  rsync every `SYNC_MIN`; the trjconv pipeline runs locally with an
  auto-installed CPU GROMACS. Fixes the on-prem `pbc nojump` self-referential
  input bug (reads `prod_whole.xtc`).
- **GROMACS from the node image** for compute (`gmx`), grompp'd on the node to
  avoid `.tpr` version drift.

## What is NOT changed

Topology, ion layout, mdp parameters, the random-seed NVT (independence),
analysis group indices (center grp 1, fit grp 4) and chain-ID stamping are
identical to on-prem, so atom numbering stays consistent for cross-replica
comparison.
