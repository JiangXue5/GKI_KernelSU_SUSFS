#!/usr/bin/env bash
# ABI gate — Module.symvers CRC zero-delta discipline.
#
# Ported verbatim from this repo's own gki6677 branch
# (gki6677/scripts/abi-gate.sh; gate design + script originate from the
# gki6677 work, G1 closed 2026-11-01, frozen baseline v0.77-baseline).
# Adaptations for the main-chandr1000 two-tier design (plan v2.2.0 §12):
#   1. optional --fail-on-new flag (D9): on pure/stock builds a NEW symbol
#      means a patch leaked in — fail instead of reporting info.
#   2. Tier 1 (rolling runner): `capture` runs every gated build on the
#      pristine pre-feature tree; `check` compares the feature build
#      against it — every delta is patch-induced by construction.
#   3. Tier 2 (pinned gki<digits> branches): `capture` stays the manual
#      rebump path against a pinned source, as on gki6677.
#
# Modes:
#   abi-gate.sh capture <current.symvers> <outdir>
#       Baseline capture: copy the pristine build's Module.symvers to
#       <outdir>/Module.symvers.baseline (+ sha256).
#   abi-gate.sh [--fail-on-new] check <baseline.symvers> <current.symvers> [report.txt]
#       Gate: every symbol present in the baseline must exist in the current
#       build with an IDENTICAL CRC. Any missing symbol or CRC delta = FAIL
#       (exit 1) with a symbol|old|new|verdict table. New symbols are
#       reported as info only (allowed; unlisted — stock vendor modules
#       cannot bind to symbols they do not know), unless --fail-on-new is
#       given, which turns additions into failures (pure-build leak canary).
#
# Scope note (inherited from gki6677 plan §7): this v1 gate enforces zero
# delta on ALL baseline symbols — stricter than the KMI-symbol-list minimum.
# The baseline tree is exactly what stock vendor modules bind against, so a
# strict gate is the safest default. Relaxing to the .stg-listed scope is a
# documented, deliberate change if it ever becomes necessary.
#
# Module.symvers format (TAB-separated): crc, symbol, module, export type,
# namespace. Key = symbol|module (symbols are not globally unique).
set -euo pipefail

log() { echo "[abi-gate] $*"; }

usage() {
  echo "usage: $0 capture <current.symvers> <outdir>" >&2
  echo "       $0 [--fail-on-new] check <baseline.symvers> <current.symvers> [report.txt]" >&2
  exit 2
}

FAIL_ON_NEW=0
if [ "${1:-}" = "--fail-on-new" ]; then
  FAIL_ON_NEW=1
  shift
fi
[ $# -ge 1 ] || usage
MODE="$1"; shift

norm() {  # file -> sorted "key<TAB>crc" on stdout
  awk -F'\t' 'NF >= 3 && $1 ~ /^0x/ && $2 != "" { print $2 "|" $3 "\t" $1 }' "$1" | LC_ALL=C sort
}

case "$MODE" in
  capture)
    [ $# -eq 2 ] || usage
    CURRENT="$1"; OUTDIR="$2"
    [ -s "$CURRENT" ] || { echo "ERROR: current symvers missing/empty: ${CURRENT}" >&2; exit 2; }
    mkdir -p "$OUTDIR"
    cp "$CURRENT" "${OUTDIR}/Module.symvers.baseline"
    N="$(norm "$CURRENT" | wc -l)"
    log "BASELINE CAPTURED: ${OUTDIR}/Module.symvers.baseline (${N} symbols, $(stat -c%s "${OUTDIR}/Module.symvers.baseline") bytes)"
    sha256sum "${OUTDIR}/Module.symvers.baseline"
    echo "NOTE: Tier 1 (rolling runner) captures per run from the pristine pre-feature tree. On Tier 2 (pinned gki<digits> branches) capture is the MANUAL rebump path only — commit this file to <branch>/abi-baseline/ together with its provenance manifest (plan v2.2.0 §12.4.1)." >&2
    exit 0
    ;;

  check)
    [ $# -ge 2 ] || usage
    BASE="$1"; CUR="$2"; REPORT="${3:-}"
    [ -s "$BASE" ] || { echo "ERROR: baseline missing/empty: ${BASE}" >&2; exit 2; }
    [ -s "$CUR" ]  || { echo "ERROR: current symvers missing/empty: ${CUR}" >&2; exit 2; }

    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    norm "$BASE" > "$TMP/base"
    norm "$CUR"  > "$TMP/cur"

    # 1) CRC deltas on symbols present in both
    join -t "$(printf '\t')" "$TMP/base" "$TMP/cur" \
      | awk -F'\t' '$2 != $3 { print $1 "\t" $2 "\t" $3 "\tCRC-DELTA" }' > "$TMP/delta" || true

    # 2) symbols in baseline but gone from the build (vendor module would
    #    die with "Unknown symbol" — hard fail)
    comm -23 <(cut -f1 "$TMP/base") <(cut -f1 "$TMP/cur") > "$TMP/missing"

    # 3) new symbols (info only — unless --fail-on-new)
    comm -13 <(cut -f1 "$TMP/base") <(cut -f1 "$TMP/cur") > "$TMP/added"

    NBASE=$(wc -l < "$TMP/base"); NCUR=$(wc -l < "$TMP/cur")
    NDELTA=$(wc -l < "$TMP/delta"); NMISS=$(wc -l < "$TMP/missing"); NADD=$(wc -l < "$TMP/added")

    log "baseline symbols: ${NBASE}   current symbols: ${NCUR}"
    log "CRC deltas: ${NDELTA}   missing: ${NMISS}   new: ${NADD}$([ "$FAIL_ON_NEW" -eq 1 ] && echo ' (--fail-on-new: new = FAIL)' || echo ' (new = info)')"

    NADD_FAIL=0
    [ "$FAIL_ON_NEW" -eq 1 ] && NADD_FAIL="$NADD"

    if [ -n "$REPORT" ]; then
      {
        echo "ABI gate report"
        echo "baseline: ${BASE} (${NBASE} symbols)"
        echo "current : ${CUR} (${NCUR} symbols)"
        echo "policy  : existing symbols zero-delta; new symbols $([ "$FAIL_ON_NEW" -eq 1 ] && echo FAIL --fail-on-new || echo 'info only (allowed)')"
        echo "verdict : $([ "$NDELTA" -eq 0 ] && [ "$NMISS" -eq 0 ] && [ "$NADD_FAIL" -eq 0 ] && echo PASS || echo FAIL)"
        echo
        if [ "$NDELTA" -gt 0 ] || [ "$NMISS" -gt 0 ]; then
          echo "=== deltas / missing (symbol|module  old-crc  new-crc) ==="
          cat "$TMP/delta"
          sed 's/$/\t<missing>\t<missing>\tMISSING/' "$TMP/missing"
        fi
        if [ "$NADD" -gt 0 ]; then
          if [ "$NADD_FAIL" -gt 0 ]; then
            echo "=== new symbols (FAIL: --fail-on-new) ==="
          else
            echo "=== new symbols (info only, allowed) ==="
          fi
          cat "$TMP/added"
        fi
      } > "$REPORT"
      log "report written: ${REPORT}"
    fi

    if [ "$NDELTA" -gt 0 ] || [ "$NMISS" -gt 0 ] || [ "$NADD_FAIL" -gt 0 ]; then
      {
        echo "=== ABI GATE FAIL ==="
        cat "$TMP/delta"
        sed 's/$/\t<missing>\t<missing>\tMISSING/' "$TMP/missing"
        [ "$NADD_FAIL" -gt 0 ] && { echo "=== new symbols (--fail-on-new) ==="; cat "$TMP/added"; }
        exit 1
      } >&2
    fi
    log "ABI GATE PASS — zero delta"
    exit 0
    ;;

  *)
    usage
    ;;
esac
