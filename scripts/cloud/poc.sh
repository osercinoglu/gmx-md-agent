#!/usr/bin/env bash
# =============================================================================
# poc.sh — End-to-end PROOF for the Vast.ai/SkyPilot GROMACS pipeline.
# Run this (cheaply, ~$1-3) BEFORE launching any real 750 ns replica.
#
# Modes:
#   dryrun   $0 cost. tools+key bootstrap + offer listing + render + parse-check
#            + `sky launch --dryrun` (validates config/resources, no GPU rented).
#   happy    Rent the cheapest matching GPU, run a 0.6 ns production on the
#            smallest real system (ILQ_A_02_01), let the supervisor pull stages,
#            run the LOCAL analysis, fetch results, verify chain IDs, tear down.
#   resume   The critical test: launch, wait for a mid-run checkpoint to be
#            PULLED locally, DESTROY the Vast instance to simulate preemption,
#            and verify the supervisor re-provisions and GROMACS RESUMES from the
#            checkpoint (a md_partNN.partNNNN.xtc continuation appears / node log
#            says "continuing from step"), NOT from step 0. Then tear down.
#   all      happy then resume (default).
#
# Env: GPU_NAMES (default "RTX_4090,RTX_3090"), TYPE (default on-demand),
#      POC_SYS (default ILQ_A_02_01_1), POC_TIMEOUT (default 3600 s).
# =============================================================================
set -uo pipefail
export LC_ALL=C LANG=C
[ -d "$HOME/anaconda3/bin" ] && export PATH="$HOME/anaconda3/bin:$PATH"

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PREP="$(cd "$HERE/.." && pwd)"
MDSIMS="$(cd "$PREP/.." && pwd)"
[ -f "$HERE/cloud.env" ] && source "$HERE/cloud.env"

SKY="${SKY:-sky}"; VASTAI="${VASTAI:-vastai}"
RUNNER="$HERE/run_cloud_replica.sh"
MODE="${1:-all}"
GPU_NAMES="${GPU_NAMES:-RTX_4090,RTX_3090}"
TYPE="${TYPE:-on-demand}"
POC_SYS="${POC_SYS:-ILQ_A_02_01_1}"
POC_DIR="$MDSIMS/ILQ_A_02_01_POC"
TAG="ILQ_A_02_01_POC"
JOB="$(echo "gmx-$TAG" | tr 'A-Z_' 'a-z-' | tr -cd 'a-z0-9-')"
STORE="$POC_DIR/.cloud_state"
POC_TIMEOUT="${POC_TIMEOUT:-3600}"
PASS=1
say(){ printf '\n\033[1m## %s\033[0m\n' "$*"; }
ok(){  printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad(){ printf '  \033[31mFAIL\033[0m %s\n' "$*"; PASS=0; }

# POC overrides: 1 ns total in a single 1 ns stage, frequent checkpoints/pulls.
# Uses the bundled pMHC test system (full phase mdps + pmhc analysis preset);
# seeded equilibration outputs make those phases skip so production starts from
# the equilibrated state.
poc_env() {
  PROD_MDP="$HERE/mdp/md_poc.mdp" \
  EM_MDP="$PREP/mdp/minim.mdp" NVT_MDP="$PREP/mdp/nvt.mdp" NPT_MDP="$PREP/mdp/npt.mdp" \
  ANALYSIS=pmhc TOTAL_NS=1 STAGE_NS=1 CKPT_MIN=1 SYNC_MIN=1 MAXH_PER_STAGE=2 MAX_RESTARTS=5 "$@"
}

prepare_poc_dir() {
  say "Preparing throwaway POC folder: $POC_DIR (from $POC_SYS)"
  [ -d "$MDSIMS/$POC_SYS" ] || { bad "source system $POC_SYS not found under $MDSIMS"; exit 1; }
  rm -rf "$POC_DIR"; mkdir -p "$POC_DIR"
  local req=(solvated_ions.pdb topol.top
    topol_Protein_chain_A.itp topol_Protein_chain_B.itp topol_Protein_chain_C.itp
    posre_Protein_chain_A.itp posre_Protein_chain_B.itp posre_Protein_chain_C.itp index.ndx)
  local f
  for f in "${req[@]}"; do
    cp -p "$MDSIMS/$POC_SYS/$f" "$POC_DIR/$f" 2>/dev/null || { bad "missing input $f in $POC_SYS"; exit 1; }
  done
  local seeded=0
  for f in em.gro nvt.gro nvt.cpt npt.gro npt.cpt; do
    [ -f "$MDSIMS/$POC_SYS/$f" ] && { cp -p "$MDSIMS/$POC_SYS/$f" "$POC_DIR/$f"; seeded=1; }
  done
  [ "$seeded" = 1 ] && echo "  seeded equilibration -> production starts immediately" \
                    || echo "  no equilibration outputs found -> POC will run EM/NVT/NPT too (slower)"
  ok "POC folder ready"
}

pick_offer() { GPU_NAMES="$GPU_NAMES" TYPE="$TYPE" TOTAL_NS=1 STAGE_NS=1 PICK=1 bash "$HERE/list_offers.sh"; }

# wait until a glob matches inside a dir, or timeout. $1 dir $2 glob $3 secs
wait_for() {
  local d="$1" pat="$2" lim="$3" t=0
  while [ "$t" -lt "$lim" ]; do
    # shellcheck disable=SC2086
    ls $d/$pat >/dev/null 2>&1 && return 0
    sleep 15; t=$((t+15)); printf '.'
  done
  return 1
}

destroy_all_vast() {
  local ids; ids="$($VASTAI show instances --raw 2>/dev/null | python3 -c 'import sys,json;print(" ".join(str(o["id"]) for o in json.load(sys.stdin)))' 2>/dev/null)"
  [ -n "$ids" ] || return 1
  local id; for id in $ids; do echo "  destroying instance $id"; $VASTAI destroy instance "$id" -y || true; done
  return 0
}

verify_results() {
  say "Verifying results in $POC_DIR"
  [ -s "$POC_DIR/prod_dry.xtc" ]     && ok "prod_dry.xtc present"     || bad "prod_dry.xtc missing"
  [ -s "$POC_DIR/prod_ref.pdb" ] && ok "prod_ref.pdb present" || bad "prod_ref.pdb missing"
  if [ -s "$POC_DIR/prod_ref.pdb" ]; then
    if awk 'substr($0,1,4)=="ATOM"{print substr($0,22,1)}' "$POC_DIR/prod_ref.pdb" | sort -u | tr -d '\n' | grep -q 'ABC'; then
      ok "chain IDs A/B/C stamped on prod_ref.pdb"
    else
      bad "chain IDs A/B/C not found on prod_ref.pdb"
    fi
  fi
}

teardown() {
  say "Teardown (scoped to this POC job; FORCE skips the verified-pull guard — it's a throwaway)"
  FORCE=1 bash "$RUNNER" teardown "$POC_DIR" || true
  local left; left="$($VASTAI show instances --raw 2>/dev/null | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))' 2>/dev/null || echo '?')"
  [ "$left" = 0 ] && ok "no Vast instances remain (nothing billable)" || bad "Vast instances still present: $left — check: vastai show instances"
}

# ---------------- dryrun ----------------
poc_dryrun() {
  say "sky check"
  $SKY check vast 2>&1 | sed -n '1,30p'
  say "Offer listing (cheapest matching, auto-pick #1)"
  pick_offer && ok "offer listing + selection works" || bad "offer listing failed"
  say "Render the EXACT job spec + parse-check + sky launch --dryrun (no GPU rented)"
  prepare_poc_dir
  if poc_env RENDER_ONLY=1 bash "$RUNNER" launch "$POC_DIR"; then
    ok "rendered YAML parses + dryrun feasibility check passed"
  else
    bad "render / parse / dryrun failed — fix before happy/resume"
  fi
  echo; echo ">> dryrun complete — \$0 spent. If clean, run: $0 happy"
}

# ---------------- happy path ----------------
poc_happy() {
  prepare_poc_dir
  pick_offer
  say "Launching POC (auto-supervised): provision + run + pull + local analysis + teardown"
  poc_env bash "$RUNNER" launch "$POC_DIR"
  say "Waiting (≤${POC_TIMEOUT}s) for the supervisor to finish (prod_dry.xtc in $POC_DIR)…"
  if wait_for "$POC_DIR" "prod_dry.xtc" "$POC_TIMEOUT"; then echo; ok "supervisor produced prod_dry.xtc"; else echo; bad "no prod_dry.xtc within timeout — see $(basename "$POC_DIR")/.cloud_supervise.log"; fi
  verify_results
  teardown
}

# ---------------- resume (kill) test ----------------
poc_resume() {
  prepare_poc_dir
  pick_offer
  say "Launching POC (auto-supervised) for the kill/resume test"
  poc_env bash "$RUNNER" launch "$POC_DIR"

  say "Waiting (≤${POC_TIMEOUT}s) for a mid-run checkpoint to be PULLED locally ($STORE/md_part01.cpt)…"
  if wait_for "$STORE" "md_part01.cpt" "$POC_TIMEOUT"; then echo; ok "checkpoint md_part01.cpt pulled locally"; else echo; bad "no checkpoint pulled in time"; teardown; return; fi

  say "Simulating preemption: destroying the live Vast instance"
  destroy_all_vast && ok "instance destroyed (hard preemption simulated)" || bad "could not find a live Vast instance to destroy"

  say "Verifying the supervisor recovers and GROMACS RESUMES from the checkpoint"
  echo "  (the supervisor needs a few failed pulls + a re-provision + gmx reinstall; be patient)"
  # Proof of resume (not restart): a -noappend continuation file appears OR the
  # node log records a checkpoint continuation. Wait for the run to finish too.
  local resumed=0
  if wait_for "$STORE" "md_part01.part*.xtc" "$POC_TIMEOUT"; then resumed=1; fi
  if [ "$resumed" != 1 ] && grep -qiE 'continuing from step|Reading checkpoint|appending to' "$STORE/run_pipeline.log" 2>/dev/null; then resumed=1; fi
  [ "$resumed" = 1 ] && ok "GROMACS resumed from checkpoint after preemption (continuation produced)" \
                      || bad "could not confirm checkpoint resume — inspect $(basename "$POC_DIR")/.cloud_supervise.log + $STORE/run_pipeline.log"

  say "Waiting for the recovered run to finish + analyze (prod_dry.xtc)…"
  if wait_for "$POC_DIR" "prod_dry.xtc" "$POC_TIMEOUT"; then echo; ok "recovered run completed + analyzed"; else echo; bad "recovered run did not complete in time"; fi
  verify_results
  teardown
}

# ---------------- extend (continue an existing run) ----------------
poc_extend() {
  local base="md_part01"
  if [ ! -f "$STORE/${base}.tpr" ] || [ ! -f "$STORE/${base}.cpt" ] || [ ! -f "$STORE/${base}.xtc" ]; then
    say "No prior POC production base in $STORE — running happy first to create one…"
    poc_happy
  fi
  [ -f "$STORE/${base}.tpr" ] && [ -f "$STORE/${base}.cpt" ] && [ -f "$STORE/${base}.xtc" ] \
    || { bad "no $base.{tpr,cpt,xtc} in $STORE to extend"; return; }
  say "Seeding extend base ($base) into $POC_DIR; extending by +0.2 ns on a cloud GPU"
  cp -pf "$STORE/${base}.tpr" "$STORE/${base}.cpt" "$STORE/${base}.xtc" "$POC_DIR/"
  rm -f "$POC_DIR/prod_dry.xtc"        # so the wait below detects the NEW (extended) analysis
  EXTEND_FROM="$base" EXTEND_BY_NS=0.2 poc_env bash "$RUNNER" extend "$POC_DIR"
  say "Waiting (≤${POC_TIMEOUT}s) for the extension to finish (prod_dry.xtc) …"
  if wait_for "$POC_DIR" "prod_dry.xtc" "$POC_TIMEOUT"; then echo; ok "extension produced prod_dry.xtc"; else echo; bad "extension did not finish in time"; fi
  ls "$STORE"/md_ext*.xtc >/dev/null 2>&1 \
    && ok "md_ext* continuation produced (convert-tpr -extend + mdrun -cpi worked)" \
    || bad "no md_ext* chunk produced — inspect $(basename "$POC_DIR")/.cloud_supervise.log"
  verify_results
  teardown
}

case "$MODE" in
  dryrun) poc_dryrun ;;
  happy)  poc_happy ;;
  resume) poc_resume ;;
  extend) poc_extend ;;
  all)    poc_happy; poc_resume ;;
  *) echo "usage: $0 {dryrun|happy|resume|extend|all}"; exit 1 ;;
esac

say "POC SUMMARY"
[ "$PASS" = 1 ] && { echo "  🎉 ALL CHECKS PASSED — safe to launch real replicas."; exit 0; } \
               || { echo "  ⚠️  SOME CHECKS FAILED — review above before any real run."; exit 1; }
