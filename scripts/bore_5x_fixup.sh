#!/usr/bin/env bash
# BORE post-patch fixups for 5.10/5.15/6.1 (5.1.0-generation patches):
# task_of fwd decl + declaration-order hoists + 8-scalar KABI relocation.
# v3 runtime wrapper (plan integration_plan_feature_patches_v3.0.0.md SS3.3/SS4).
# Bodies extracted VERBATIM from .github/actions/bore/action.yml @
# main-chandr1000-bak (1e4570af) - the logic that produced the known-good
# pre-reset builds. Each body runs in its own bash (per-step semantics
# preserved); the wrapper aborts on the first failing body.
# Contract: $1 = TARGET_DIR (kernel tree root).
set -euo pipefail
TARGET_DIR="${1:?usage: bore_5x_fixup.sh <target_dir>}"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
export TARGET_DIR SCRIPT_DIR
cd "$TARGET_DIR"

bash <<'BORE_BODY_1'
set -euo pipefail

# 5.10 DOES define task_of() - twice, in fair.c (CONFIG_FAIR_GROUP_SCHED
# at ~line 267 and the #else at ~454). An earlier diagnosis claimed it
# was missing because it only grepped sched.h, and a backport step
# added a sched.h definition that collided with the stock ones:
#   fair.c:341: error: redefinition of 'task_of'
# The actual problem is ordering: BORE inserts update_burst_score()
# near the top of fair.c, ABOVE both stock definitions, so the call
# has no declaration in scope. A prototype fixes that without any
# risk of collision - and no-ops on 5.15+ where fair.c already has
# task_of in scope before BORE's call site.
#
# Placement matters twice over. A first attempt inserted the
# prototype after the SPDX line, before the #includes; there
# struct sched_entity has no file-scope declaration yet, so the
# tag got PROTOTYPE scope and vanished at the closing paren
# (C11 6.2.1p4) - every later task_of call then failed with
# 'incompatible pointer types' naming two identical types, and the
# stock definition 'conflicted' with the phantom. Insert AFTER the
# includes instead, so the tag resolves to the real struct.
if ! grep -q 'bore: task_of fwd' kernel/sched/fair.c; then
  # only the early include block counts; pelt.h at ~821 is mid-file
  EARLY=$(grep -n '^#include' kernel/sched/fair.c | awk -F: '$1 < 100' | tail -1 | cut -d: -f1)
  sed -i "${EARLY}a\\/* bore: task_of fwd - defined below, in scope too late */\nstatic inline struct task_struct *task_of(struct sched_entity *se);" kernel/sched/fair.c
fi
grep -n 'bore: task_of fwd' kernel/sched/fair.c | head -2

BORE_BODY_1
bash <<'BORE_BODY_2'
set -euo pipefail

# BORE's update_burst_score() declares locals after an early-return
# guard, which trips -Wdeclaration-after-statement - fatal here because
# the kernel builds it with -Werror. Only the 6.1 and older patches
# have this shape; 6.12+ already declare those variables at file scope.
# One substitution over the four-line block, kept on a single line because
# YAML will not accept a bare multi-line s command at this indent. No ^
# anchors inside it - they apply per-line and never match a multi-line
# pattern space, which is what made an earlier attempt silently do
# nothing. After the rewrite the block no longer exists, so a re-run is
# a no-op.
sed -i '/^\tif (!entity_is_task(se)) return;$/{N;N;N;N;s|\tif (!entity_is_task(se)) return;\n\tstruct task_struct \*p = task_of(se);\n\tu8 prio = p->static_prio - MAX_RT_PRIO;\n\tu8 prev_prio = min(39, prio + se->burst_score);|\tstruct task_struct *p;\n\tu8 prio, prev_prio, new_prio;\n\n\tif (!entity_is_task(se)) return;\n\tp = task_of(se);\n\tprio = p->static_prio - MAX_RT_PRIO;\n\tprev_prio = min(39, prio + se->burst_score);|}' kernel/sched/fair.c

# Second site in the same function: BORE declares u8 new_prio after
# the se->burst_score assignment statement. On sublevels where
# -Wdeclaration-after-statement is -Werror this fails the build; on
# the others it warns. Its declaration was hoisted above, so this
# turns the second site into a plain assignment.
sed -i 's|^\tu8 new_prio = min(39, prio + se->burst_score);$|\tnew_prio = min(39, prio + se->burst_score);|' kernel/sched/fair.c

# 5.9.6 (the 6.6 family patch) has the same disease in
# kernel/sched/bore.c with a different body shape: the task_of
# declaration sits AFTER the early-return guard, and burst_score /
# new_prio are declared mid-function. Hoist all three. Idempotent:
# the rewritten function head carries a 'bore: decls hoisted'
# marker that the address regex requires to end with a bare '{',
# so a re-run does not match. No ^/$ inside the multi-line s
# command - they never match mid pattern-space.
# Guard: ONLY the 5.9.6/6.8.0 generations have bore.c; the 5.1.0
# patches (5.10/5.15/6.1) keep all BORE code in fair.c, so on those
# families the file does not exist and sed would exit 2, failing
# this step under pipefail (run 37273722560's 5.15 jobs: 'sed:
# can't read kernel/sched/bore.c').
if [ -f kernel/sched/bore.c ]; then
sed -i '/^void update_burst_score(struct sched_entity \*se) {$/{N;N;N;s|void update_burst_score(struct sched_entity \*se) {\n\tif (!entity_is_task(se)) return;\n\tstruct task_struct \*p = task_of(se);\n\tu8 prev_prio = effective_prio(p);|void update_burst_score(struct sched_entity *se) { /* bore: decls hoisted */\n\tstruct task_struct *p;\n\tu8 prev_prio, burst_score, new_prio;\n\n\tif (!entity_is_task(se)) return;\n\tp = task_of(se);\n\tprev_prio = effective_prio(p);|}' kernel/sched/bore.c
# The two mid-function decls become plain assignments - but ONLY
# inside update_burst_score. A first version ran these unscoped and
# they also rewrote restart_burst_rescale_deadline's ONLY new_prio
# declaration into an assignment, producing (run 37270128980):
#   bore.c:116: error: use of undeclared identifier 'new_prio'
# The 6.6.102 job of run 37255515932 never showed it because fair.o
# failed first and make stopped before scheduling bore.o.
sed -i '/^void update_burst_score/,/^}/ s|^\tu8 burst_score = 0;$|\tburst_score = 0;|' kernel/sched/bore.c
sed -i '/^void update_burst_score/,/^}/ s|^\tu8 new_prio = effective_prio(p);$|\tnew_prio = effective_prio(p);|' kernel/sched/bore.c

# restart_burst_rescale_deadline has its own decl-after-statement
# violation: 'u8 new_prio' after the restart_burst(se) statement.
# Hoist it onto the prev_prio declaration line, then make the
# mid-function decl an assignment. Scoped to the function body;
# idempotent because neither pattern survives the rewrite.
sed -i '/^void restart_burst_rescale_deadline/,/^}/ s|^\tu8 prev_prio = effective_prio(p);$|\tu8 prev_prio = effective_prio(p), new_prio;|' kernel/sched/bore.c
sed -i '/^void restart_burst_rescale_deadline/,/^}/ s|^\tu8 new_prio = effective_prio(p);$|\tnew_prio = effective_prio(p);|' kernel/sched/bore.c
else
  echo "bore.c not present (5.1.0-generation patch); bore.c seds skipped."
fi

sed -n '/static void update_burst_score/,/^}/p' kernel/sched/fair.c | head -8
# if/then, not '[ ] &&': a failing [ -f ] as the last command leaves
# the script's exit status at 1 even under set -e, which fails the
# step on the 5.1.0 families where bore.c does not exist.
if [ -f kernel/sched/bore.c ]; then
  sed -n '/^void update_burst_score/,/^}/p' kernel/sched/bore.c | head -12
fi

BORE_BODY_2
bash <<'BORE_BODY_3'
echo "=== relocate 8-scalar BORE fields into ANDROID_KABI slots ==="
python3 "$SCRIPT_DIR/bore_kabi_612.py" include/linux/sched.h
grep -A9 'bore-kabi: burst_' include/linux/sched.h | head -10 || true

BORE_BODY_3
