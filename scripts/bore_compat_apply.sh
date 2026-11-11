#!/usr/bin/env bash
# bore_compat_apply.sh -- era-probing applier for the BORE 6.6 sysctl +
# setlocalversion micro-patches (wide-compat plan, 2026-11-11).
#
# Invoked by the feature-patches applier as:   bash <script> <TARGET_DIR>
# MUST run after the bore-scheduler core patch (depends_on) and before
# anything that consumes the post-BORE fair.c shape (fair-gaming-bias).
#
# Why a script: two regions of the BORE surface have era-divergent STOCK
# text across the 6.6 family, which no single strict git-apply hunk can
# serve:
#   kernel/sched/fair.c      base_slice 750000ULL (<=6.6.89 stock)
#                            vs 700000ULL (>=6.6.92 stock, 0.70 ms backport)
#   scripts/setlocalversion  pre-rewrite 4-tab shape (<=6.6.58)
#                            vs post-rewrite 2-tab shape (>=6.6.66)
# The tree is probed for the actual stock text and the matching
# micro-patch from patches/bore/compat/ is applied with the same strict
# git apply --check + git apply discipline as every patch entry.
#
# Failure policy: HARD FAIL (never warn+skip). A silent skip would leave
# bore.o referencing sysctl_sched_min_base_slice with the fair.c block
# absent -> a confusing link error downstream instead of a clear apply
# verdict, and would ship a "BORE-on" kernel without its sysctl block.
set -euo pipefail

TARGET="${1:?usage: bore_compat_apply.sh <kernel-tree-dir>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPAT="$SCRIPT_DIR/../patches/bore/compat"
cd "$TARGET"

apply_first_match() {
    # $2..@: candidate patch paths (order = preference); first whose
    # strict preflight passes is applied. None passes => hard fail.
    local desc="$1"; shift
    local p
    for p in "$@"; do
        if [ ! -f "$p" ]; then
            echo "ERROR [bore-compat] candidate missing: $p" >&2
            continue
        fi
        if git apply --check "$p" 2>/dev/null; then
            git apply "$p"
            echo "OK [bore-compat] $desc <- $(basename "$p")"
            return 0
        fi
    done
    echo "ERROR [bore-compat] $desc: no candidate applied. The tree's stock" >&2
    echo "ERROR [bore-compat] text matches none of the known 6.6 era shapes." >&2
    echo "ERROR [bore-compat] A new Google backport likely drifted these files;" >&2
    echo "ERROR [bore-compat] re-run scripts/verify/bore_compat_matrix.py and add" >&2
    echo "ERROR [bore-compat] the new era variant to patches/bore/compat/." >&2
    return 1
}

echo "=== [bore-compat] probing tree shapes at $(pwd) ==="

# --- 1. fair.c sysctl era ---------------------------------------------------
FAIR_VAR=none
if grep -q 'sysctl_sched_base_slice[[:space:]]*= 750000ULL' kernel/sched/fair.c; then
    FAIR_VAR=750
elif grep -q 'sysctl_sched_base_slice[[:space:]]*= 700000ULL' kernel/sched/fair.c; then
    FAIR_VAR=700
fi
case "$FAIR_VAR" in
    750) apply_first_match "fair.c base_slice block (750000ULL era)" \
            "$COMPAT/0002-bore-66-fair-sysctl-750.patch" ;;
    700) apply_first_match "fair.c base_slice block (700000ULL era)" \
            "$COMPAT/0003-bore-66-fair-sysctl-700.patch" ;;
    *)   # unknown stock value: let git apply arbitrate before failing
         apply_first_match "fair.c base_slice block (unrecognized value, preflight ladder)" \
            "$COMPAT/0002-bore-66-fair-sysctl-750.patch" \
            "$COMPAT/0003-bore-66-fair-sysctl-700.patch" ;;
esac

# --- 2. setlocalversion shape -----------------------------------------------
SLV_VAR=none
if grep -q 'If none of the attempted tags exist' scripts/setlocalversion; then
    SLV_VAR=v2
elif grep -q 'if \[ "${tag}" != "${desc}" \]' scripts/setlocalversion; then
    SLV_VAR=v1
fi
case "$SLV_VAR" in
    v2) apply_first_match "setlocalversion short-version suppress (v2 shape)" \
            "$COMPAT/0004-bore-66-setlocalversion-short-v2.patch" ;;
    v1) apply_first_match "setlocalversion short-version suppress (v1 shape)" \
            "$COMPAT/0005-bore-66-setlocalversion-short-v1.patch" ;;
    *)  apply_first_match "setlocalversion short-version suppress (unrecognized shape, preflight ladder)" \
            "$COMPAT/0004-bore-66-setlocalversion-short-v2.patch" \
            "$COMPAT/0005-bore-66-setlocalversion-short-v1.patch" ;;
esac

# --- 3. post-conditions (loud, cheap, catches silent half-apply) ------------
grep -q 'sysctl_sched_min_base_slice' kernel/sched/fair.c \
    || { echo "ERROR [bore-compat] post-check failed: sysctl_sched_min_base_slice missing from fair.c" >&2; exit 1; }
grep -q 'sysctl_sched_tunable_scaling = SCHED_TUNABLESCALING_NONE' kernel/sched/fair.c \
    || { echo "ERROR [bore-compat] post-check failed: BORE tunable_scaling override missing" >&2; exit 1; }
grep -q '#echo' scripts/setlocalversion \
    || { echo "ERROR [bore-compat] post-check failed: setlocalversion short-marker not suppressed" >&2; exit 1; }

echo "=== [bore-compat] all compat hunks applied and post-checks passed ==="
