#!/usr/bin/env bash
# BORE post-patch fixups for 6.6 (5.1.0 ALTERNATIVE variant):
# task_of fwd decl + sched_entity 4-slot relocation + decl-order hoists +
# GKI sysctl repairs (generic block rebuild, then the 5.1.0 region script).
# v3 runtime wrapper (plan integration_plan_feature_patches_v3.0.0.md SS3.3/SS4).
# Bodies extracted VERBATIM from .github/actions/bore/action.yml @
# main-chandr1000-bak (1e4570af) - the logic that produced the known-good
# pre-reset builds. Each body runs in its own bash (per-step semantics
# preserved); the wrapper aborts on the first failing body.
# Contract: $1 = TARGET_DIR (kernel tree root).
set -euo pipefail
TARGET_DIR="${1:?usage: bore_66_510_apply.sh <target_dir>}"
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
echo "=== relocate 5.1.0-generation 8-scalar fields into sched_entity slots ==="
python3 "$SCRIPT_DIR/bore66_510.py" include/linux/sched.h
grep -A9 'bore-kabi: burst_' include/linux/sched.h | head -10 || true

BORE_BODY_2
bash <<'BORE_BODY_3'
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

BORE_BODY_3
bash <<'BORE_BODY_4'
set -euo pipefail

if grep -q 'bore: base_slice block' kernel/sched/fair.c; then
  echo "6.6 sysctl block already repaired; skipping."
  exit 0
fi

# Repair is needed exactly when the APPLIED hunks use nsecs_per_tick
# but the REJECTED hunk's declaration is missing. If the declaration
# is present the hunk applied cleanly (nothing to do); if there are
# no uses at all the BORE patch did not apply (nothing to do).
if grep -q 'nsecs_per_tick' kernel/sched/fair.c && \
   ! grep -q 'static const unsigned int nsecs_per_tick' kernel/sched/fair.c; then
  echo "nsecs_per_tick used but undeclared - repairing sysctl block."
else
  echo "NOTE: no missing BORE sysctl declarations; nothing to do."
  exit 0
fi

# Part 1: tunable_scaling default. BORE sets NONE; stock is LOG.
# Nothing compiled under CONFIG_SCHED_BORE reads the value (BORE's
# update_sysctl ignores the factor machinery), but the sysctl stays
# visible in /proc/sys, so report the BORE default for parity with
# the author's patch.
TUNE_LINE=$(grep -n '^unsigned int sysctl_sched_tunable_scaling' kernel/sched/fair.c | cut -d: -f1)
if [ -n "$TUNE_LINE" ]; then
  sed -i "${TUNE_LINE}i\\
/* bore: tunable_scaling default */\\
#ifdef CONFIG_SCHED_BORE\\
unsigned int sysctl_sched_tunable_scaling = SCHED_TUNABLESCALING_NONE;\\
#else // !CONFIG_SCHED_BORE" kernel/sched/fair.c
  TUNE_LINE=$(grep -n '^unsigned int sysctl_sched_tunable_scaling = SCHED_TUNABLESCALING_LOG' kernel/sched/fair.c | cut -d: -f1)
  sed -i "${TUNE_LINE}a\\
#endif // CONFIG_SCHED_BORE" kernel/sched/fair.c
else
  echo "NOTE: tunable_scaling declaration not found; skipping its wrap."
fi

# Locate the stock base_slice declaration; the BORE block goes in
# front of it, and the #else closes after the stock EXPORT line.
# normalized_sysctl_sched_base_slice stays OUTSIDE the conditional:
# newer sublevels (6.12.17+ set_protect_slice, kept in GKI 6.12.92
# and 6.18) read it under CONFIG_SCHED_BORE too, and the author's
# patch never had to handle that because his 6.12.37 base predates
# set_protect_slice. Leaving it unwrapped preserves stock behavior
# exactly; on 6.6 it is simply unused under BORE (benign).
SLICE_LINE=$(grep -n '^unsigned int sysctl_sched_base_slice' kernel/sched/fair.c | head -1 | cut -d: -f1)
if [ -z "$SLICE_LINE" ]; then
  echo "ERROR: stock sysctl block not found; aborting so we do not mangle fair.c" >&2
  exit 1
fi
echo "stock base_slice at line $SLICE_LINE"

# Insert the BORE block BEFORE the stock base_slice declaration,
# wrapping it with #ifdef CONFIG_SCHED_BORE ... #else.
sed -i "${SLICE_LINE}i\\
/* bore: base_slice block - GKI variant of the rejected hunk */\\
#ifdef CONFIG_SCHED_BORE\\
static const unsigned int nsecs_per_tick       = 1000000000ULL / HZ;\\
unsigned int sysctl_sched_min_base_slice       = CONFIG_MIN_BASE_SLICE_NS;\\
__read_mostly uint sysctl_sched_base_slice     = nsecs_per_tick;\\
EXPORT_SYMBOL_GPL(sysctl_sched_base_slice);\\
#else // !CONFIG_SCHED_BORE" kernel/sched/fair.c

# Close the #else right after the STOCK export line - the second
# EXPORT_SYMBOL_GPL(sysctl_sched_base_slice) in the file (the first
# is the one just inserted in the BORE branch).
EXPORT_LINE=$(grep -n '^EXPORT_SYMBOL_GPL(sysctl_sched_base_slice)' kernel/sched/fair.c | sed -n '2p' | cut -d: -f1)
if [ -z "$EXPORT_LINE" ]; then
  echo "ERROR: stock EXPORT_SYMBOL_GPL(sysctl_sched_base_slice) not found" >&2
  exit 1
fi
sed -i "${EXPORT_LINE}a\\
#endif // CONFIG_SCHED_BORE" kernel/sched/fair.c

# normalized_sysctl_sched_base_slice is static, and on 6.6 nothing
# under CONFIG_SCHED_BORE reads it (its only stock reader, the
# SET_SYSCTL expansion inside the #else update_sysctl, is compiled
# out), so -Werror=unused-variable kills the build there (run
# 37255515932). The author's own hunk wraps it inside #else - which
# instead strands 6.12/6.18, whose set_protect_slice (6.12.17+,
# present in GKI 6.12.92 and 6.18) reads it under BORE too. Keep it
# unconditional and mark it __maybe_unused: silences the warning
# where it is unused, is the kernel's standard marker, and changes
# nothing at runtime where it is used.
sed -i 's|^static unsigned int normalized_sysctl_sched_base_slice|static unsigned int normalized_sysctl_sched_base_slice __maybe_unused|' kernel/sched/fair.c

echo "=== repaired block ==="
sed -n "$((SLICE_LINE-2)),$((EXPORT_LINE+3))p" kernel/sched/fair.c

BORE_BODY_4
bash <<'BORE_BODY_5'
echo "=== 5.1.0 sysctl region rebuild ==="
python3 "$SCRIPT_DIR/bore66_510_sysctl.py" kernel/sched/fair.c

BORE_BODY_5
