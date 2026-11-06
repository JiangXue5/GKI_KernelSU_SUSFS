#!/usr/bin/env bash
# BORE for 6.12/6.18: dynamic patch resolution (upstream patches/stable
# listing with API->git fallback), provenance verification, fuzzy apply,
# 7.x bore_ctx out-of-line relocation, decl-order + fuzz-splice repairs.
# Extracted verbatim from the old action's select/download/verify/apply
# steps (retry + git fallback logic preserved per plan SS3.2).
# v3 runtime wrapper (plan integration_plan_feature_patches_v3.0.0.md SS3.3/SS4).
# Bodies extracted VERBATIM from .github/actions/bore/action.yml @
# main-chandr1000-bak (1e4570af) - the logic that produced the known-good
# pre-reset builds. Each body runs in its own bash (per-step semantics
# preserved); the wrapper aborts on the first failing body.
# Contract: $1 = TARGET_DIR (kernel tree root).
set -euo pipefail
TARGET_DIR="${1:?usage: bore_612_apply.sh <target_dir>}"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
export TARGET_DIR SCRIPT_DIR
cd "$TARGET_DIR"

# Resolve the kernel version from the tree itself (D18 principle: gate on
# the tree being built, not on metadata about it).
KVER="$(sed -n 's/^VERSION *= *//p' Makefile).$(sed -n 's/^PATCHLEVEL *= *//p' Makefile)"
WORK_DIR="$(mktemp -d /tmp/bore612-work.XXXXXX)"
BORE_SEL_OUT="$(mktemp /tmp/bore612-select.XXXXXX)"
BORE_URL=""
PATCH_PATH="/tmp/bore612.patch"
export WORK_DIR
echo "bore_612: kernel ${KVER}"

# --- select (dynamic resolution) ---
bash <<'BORE_BODY_1'
set -euo pipefail
VER=""$KVER""

# Latest from the author's main branch, like the other external
# dependencies (BBG, Baseband Guard) which also track a branch tip.
BORE_BASE="https://raw.githubusercontent.com/firelzrd/bore-scheduler/main/patches"

# Patch selection, from dry-runs against each local GKI tree rather
# than assumed:
#   5.10 / 5.15  -> 5.15 patch   14-15/14 hunks, clean
#   6.1          -> 6.1  patch   14/14 hunks, clean
#   6.6          -> 6.6  patch    17/18 hunks (from the author's
#                    6.6-bore branch tip, linux-6.6.67 + BORE 5.9.6;
#                    there is no 6.6 entry in patches/ on main, and
#                    the 6.12 patch rejects 9/24 here because its
#                    hooks target sched-ext code 6.6 does not have)
#   6.12 / 6.18  -> resolved DYNAMICALLY from patches/stable/
#                    (see below - the author promotes versions and
#                    deletes the old files, which 404'd us in run
#                    37814552622: 6.8.0 was replaced by 7.0.0)
# There is no 5.10-specific patch upstream, but the 5.15 one applies
# cleanly to 5.10.269.
case "$VER" in
  5.4|5.10|5.15)
    # The legacy series is frozen upstream - these files do not
    # move, so a pinned URL is fine here (and faster).
    URL="${BORE_BASE}/legacy/linux-5.15-bore/0001-linux5.15.y-bore5.1.0.patch" ;;
  6.1)
    URL="${BORE_BASE}/legacy/linux-6.1-bore/0001-linux6.1.y-bore5.1.0.patch" ;;
  6.6)
    # Not published under patches/ on main; vendored from the
    # author's 6.6-bore branch tip (git diff linux-6.6.67..HEAD).
    # NOTE: lives in the action dir, NOT kernel_patches/ - the
    # setup step wipes kernel_patches/ and re-clones the separate
    # WildKernels/kernel_patches repo before this action runs.
    # Two vendored generations:
    #   5.9.6 (default) - inline 24-byte sched_burst_cache members;
    #     needs the out-of-line bore_state design below to keep the
    #     KMI stock.
    #   5.1.0 - 5.1.0-generation scalars (burst_time + four u8s +
    #     child_burst_cnt/last_cached), exactly the shape the
    #     6.1-family kABI relocation script handles; selected with
    #     the bore_variant=5.1.0 dispatch input for A/B boot tests.
    if [ ""5.9.6"" = "5.1.0" ]; then
      URL=".github/actions/bore/patches/0001-linux6.6.67-bore5.1.0.patch"
    else
      URL=".github/actions/bore/patches/0001-linux6.6.67-bore-5.9.6.patch"
    fi
    URL_IS_LOCAL="true" ;;
  6.12|6.18)
    # The author promotes new BORE versions into patches/stable/
    # and DELETES the old files - a pinned name 404'd all 27 6.12
    # jobs of run 37814552622 when 6.8.0 became 7.0.0. Resolve the
    # newest matching file at build time instead. BORE is always
    # wanted, so a resolution failure fails the job - but the
    # listing itself must survive the matrix: with ~54 6.12 jobs
    # firing simultaneously, GitHub's API returns 403 (secondary
    # rate limit) on some of the concurrent listings (run
    # 37910384802, 6.12.23 job: curl 403 -> empty NAMES ->
    # "no patch found"). So: retry the listing with backoff, and
    # only treat it as "no patch exists" when a 200 listing with
    # zero matches is actually seen.
    LATEST=""
    for attempt in 1 2 3 4 5; do
      HTTP=$(curl -sSL -o /tmp/bore_listing.json -w '%{http_code}' \
        "https://api.github.com/repos/firelzrd/bore-scheduler/contents/patches/stable") || HTTP=""
      if [ "$HTTP" = "200" ]; then
        NAMES=$(grep -o '"name": *"0001-linux'"${VER}"'[^"]*\.patch"' /tmp/bore_listing.json \
          | sed 's/"name": *"//;s/"$//' | sort -V)
        LATEST=$(printf '%s\n' "$NAMES" | tail -1)
        break
      fi
      echo "patches/stable listing attempt $attempt/5 got HTTP ${HTTP:-none}; backing off..." >&2
      sleep $((attempt * 15))
    done
    # API dead after all retries (run 37910384802: secondary 403
    # under matrix concurrency; run 38623058057: five 403s while
    # GitHub's API was degraded) -> fall back to the GIT protocol:
    # blobless clone + ls-tree. Never touches api.github.com, no
    # rate limit, ~1.2s. Live tree, so the resolved name is
    # guaranteed to exist on raw.githubusercontent.
    if [ "$HTTP" != "200" ]; then
      echo "API listing failed (HTTP ${HTTP:-none}); falling back to git ls-tree..." >&2
      rm -rf /tmp/bore-src
      if git clone -q --depth 1 --filter=blob:none \
           https://github.com/firelzrd/bore-scheduler /tmp/bore-src 2>/dev/null; then
        NAMES=$(git -C /tmp/bore-src ls-tree -r --name-only HEAD patches/stable/ \
          | xargs -n1 basename 2>/dev/null \
          | grep "^0001-linux${VER}.*\.patch$" | sort -V || true)
        LATEST=$(printf '%s\n' "$NAMES" | tail -1)
        HTTP=200
        rm -rf /tmp/bore-src
      else
        rm -rf /tmp/bore-src
      fi
    fi
    if [ "$HTTP" != "200" ]; then
      echo "ERROR: could not list firelzrd/bore-scheduler patches/stable/ (HTTP $HTTP after 5 attempts + git fallback)" >&2
      exit 1
    fi
    if [ -z "$LATEST" ]; then
      # A 200 listing with zero matches = the author really has
      # no patch for this version. Real problem, not a skip case:
      # BORE is always wanted. Fail the job loudly.
      echo "ERROR: no BORE patch found for ${VER} in firelzrd/bore-scheduler patches/stable/" >&2
      echo "Check: https://github.com/firelzrd/bore-scheduler/tree/main/patches" >&2
      exit 1
    fi
    echo "Resolved ${VER} BORE patch: ${LATEST}"
    URL="${BORE_BASE}/stable/${LATEST}" ;;
  *)
    echo "No BORE patch mapped for kernel ${VER}; skipping."
    echo "url=" >> "$BORE_SEL_OUT"
    exit 0
    ;;
esac

echo "BORE patch for kernel ${VER}: ${URL##*/}"
echo "url=${URL}" >> "$BORE_SEL_OUT"
echo "local=${URL_IS_LOCAL:-}" >> "$BORE_SEL_OUT"

BORE_BODY_1

BORE_URL="$(sed -n 's/^url=//p' "$BORE_SEL_OUT")"
LOCAL_FLAG="$(sed -n 's/^local=//p' "$BORE_SEL_OUT")"
export BORE_URL LOCAL_FLAG
echo "bore_612: selected ${BORE_URL}"

# --- download ---
bash <<'BORE_BODY_2'
set -euo pipefail
mkdir -p "$WORK_DIR/kernel_patches/bore"
if [ ""${LOCAL_FLAG:-}"" = "true" ]; then
  # local URL is relative to the REPO root (where this action's
  # dir lives), while workdir is github.workspace - hence the
  # extra workspace prefix on cp source.
  cp "$WORK_DIR/"$BORE_URL"" \
     "$WORK_DIR/kernel_patches/bore/0001-bore.patch"
else
  # curl's own retries handle transient network flake. A step-level
  # attempts:5 wrapper was here before (the retry action); on a
  # genuinely dead URL it just hammered the 404 five times. With
  # dynamic resolution the URL should always exist; if the download
  # STILL fails, fail the job - BORE is always wanted, never build
  # a family silently without it.
  curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors --connect-timeout 30 \
    ""$BORE_URL"" \
    -o "$WORK_DIR/kernel_patches/bore/0001-bore.patch"
fi
echo "downloaded=true" >> "$BORE_SEL_OUT"

BORE_BODY_2

# --- verify provenance ---
bash <<'BORE_BODY_3'
set -euo pipefail
PATCH="$WORK_DIR/kernel_patches/bore/0001-bore.patch"

[ -s "$PATCH" ] || { echo "ERROR: downloaded BORE patch is empty" >&2; exit 1; }

# The upstream patches are git-format-patch output authored by
# firelzrd. Confirm that before applying anything to the tree.
# The vendored 6.6 patch is a git diff export from the author's
# 6.6-bore branch and carries no mail headers, so check it by
# content instead.
if head -1 "$PATCH" | grep -q '^From [0-9a-f]\{40\} Mon Sep 17 00:00:00 2001$'; then
  AUTHOR=$(head -20 "$PATCH" | sed -n 's/^From: //p' | head -1)
  echo "BORE patch author: ${AUTHOR}"
elif head -1 "$PATCH" | grep -q '^diff --git a/include/linux/sched.h'; then
  echo "BORE patch: vendored diff (no mail headers)"
else
  echo "ERROR: unrecognized patch format" >&2
  exit 1
fi

echo "patch_path=${PATCH}" >> "$BORE_SEL_OUT"

BORE_BODY_3

PATCH_PATH="$(sed -n 's/^patch_path=//p' "$BORE_SEL_OUT")"
[ -n "$PATCH_PATH" ] || PATCH_PATH="/tmp/bore612.patch"

# --- apply (fuzzy, rejects repaired downstream) ---
bash <<'BORE_BODY_4'
set -euo pipefail

if [ -z "$PATCH" ]; then
  echo "ERROR: PATCH path is empty; the verify step did not run." >&2
  exit 1
fi
if [ ! -s "$PATCH" ]; then
  echo "ERROR: BORE patch not found at $PATCH" >&2
  exit 1
fi

# --forward so a re-run over an already-patched tree is a no-op rather
# than a reverse-apply. -F3 absorbs the sublevel drift between the
# version the patch was cut against and the one actually building.
if ! patch -p1 -F3 --forward --no-backup-if-mismatch < "$PATCH"; then
  echo "WARNING: BORE patch did not apply cleanly." >&2
  echo "Rejects (expected on 6.6/6.12/6.18 pending Android-specific resolution):" >&2
  find . -name '*.rej' -newer "$PATCH" 2>/dev/null | while read -r r; do
    echo "  ${r#./}" >&2
  done
  exit 1
  exit 0
fi

echo "BORE patch applied cleanly."
:

BORE_BODY_4

# --- declaration-order hoists (no-op on 7.x shapes, harmless) ---
bash <<'BORE_BODY_5'
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

BORE_BODY_5

# --- 7.x bore_ctx out-of-line relocation ---
bash <<'BORE_BODY_6'
set -euo pipefail

if ! grep -q 'struct bore_ctx' include/linux/sched.h 2>/dev/null; then
  echo "No bore_ctx in task_struct (5.x/6.6 generations); nothing to do."
  exit 0
fi

python3 "$SCRIPT_DIR/bore12_state.py" \
  include/linux/sched.h

# fork.c is passed explicitly: it has no ->bore. accessor (only the
# task_fork_bore call) so the discovery grep would miss it, but it
# needs the dup-NULL/alloc/cleanup/free hooks. All scripts are
# idempotent, so files discovered twice are harmless.
FILES=$(grep -rl -- '->bore\.\|struct bore_ctx \*ctx' \
  include kernel 2>/dev/null || true)
python3 "$SCRIPT_DIR/bore12_flat.py" \
  include/linux/sched/bore.h kernel/sched/bore.c \
  kernel/sched/fair.c kernel/futex/waitwake.c kernel/fork.c \
  $FILES

echo "=== task_struct slot-8 pointer after relocation ==="
grep -A2 'bore-kabi: bore_ctx lives' include/linux/sched.h | head -3
echo "=== bore.c guard census ==="
grep -c 'if (unlikely(!p->bore' kernel/sched/bore.c || true

BORE_BODY_6

# --- fuzz-splice repair (7.0.0) ---
bash <<'BORE_BODY_7'
set -euo pipefail

if ! grep -q 'update_curr_bore' kernel/sched/fair.c 2>/dev/null; then
  echo "No update_curr_bore call site (6.6/5.x generation or patch absent); nothing to do."
  exit 0
fi

# Find the update_curr_bore call and check what sits directly above
# the #ifdef that should guard it.
CALL_LINE=$(grep -n 'update_curr_bore(p, delta_exec);' kernel/sched/fair.c | head -1 | cut -d: -f1)
IFDEF_LINE=$(grep -n '^#ifdef CONFIG_SCHED_BORE' kernel/sched/fair.c \
             | awk -F: -v c="$CALL_LINE" '$1 < c && c - $1 <= 2 {print $1}' | tail -1)

# Inspect the line immediately above the #ifdef: it must be either
# blank or a code line (task_of/update_curr_task region). If it is
# a comment-continuation line (' * ...') the hunk fuzz-spliced into
# the middle of the fair_server comment.
ABOVE=$((IFDEF_LINE - 1))
ABOVE_TXT=$(sed -n "${ABOVE}p" kernel/sched/fair.c)
if printf '%s' "$ABOVE_TXT" | grep -qE '^\s*(\*|/\*)'; then
  echo "Detected fuzz-spliced BORE block inside a comment (line $IFDEF_LINE, above: $ABOVE_TXT)."
  echo "Relocating the block to the correct anchor..."
else
  echo "update_curr_bore block looks correctly anchored (above: $ABOVE_TXT); nothing to do."
  exit 0
fi

# Remove the spliced 3-line block...
sed -i "${IFDEF_LINE},$((CALL_LINE + 1))d" kernel/sched/fair.c

# ...and reinsert it at the true anchor: right after
# 'if (entity_is_task(curr)) {' inside update_curr(), before the
# fair_server comment. Abort loudly if that anchor is missing - a
# silent anchor miss is exactly the failure class we are fixing.
# NOTE on the call argument: the author's 6.12.37 base declares
# 'struct task_struct *p = task_of(curr);' inside update_curr(); GKI
# 6.12.92 inlined that away (no 'p' in scope - run 38015274643:
# fair.c:1378 'use of undeclared identifier p'). Call it with
# task_of(curr) directly, the same pattern the 6.8.0-era patches
# used at their call sites.
ANCHOR=$(grep -n $'\tif (entity_is_task(curr)) {' kernel/sched/fair.c \
         | awk -F: -v c="$CALL_LINE" '$1 < c' | tail -1 | cut -d: -f1)
if [ -z "$ANCHOR" ]; then
  echo "ERROR: 'if (entity_is_task(curr)) {' anchor not found in update_curr(); refusing to guess." >&2
  exit 1
fi
CALLER_ARG="p, delta_exec"
if ! grep -q 'struct task_struct \*p = task_of(curr);' kernel/sched/fair.c; then
  CALLER_ARG="task_of(curr), delta_exec"
fi
sed -i "${ANCHOR}a\\
#ifdef CONFIG_SCHED_BORE\\
\t\tupdate_curr_bore(${CALLER_ARG});\\
#endif /* CONFIG_SCHED_BORE */" kernel/sched/fair.c

echo "=== update_curr() after repair ==="
sed -n "${ANCHOR},$((ANCHOR + 14))p" kernel/sched/fair.c

BORE_BODY_7

rm -f "$BORE_SEL_OUT"
rm -rf "$WORK_DIR"
echo "bore_612: BORE applied"
