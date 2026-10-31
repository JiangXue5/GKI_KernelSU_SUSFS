#!/usr/bin/env bash
# gki6677 P1 — ABI gate (plan §7): Module.symvers CRC zero-delta discipline.
#
# Modes:
#   abi-gate.sh capture <current.symvers> <outdir>
#       G1 baseline capture: copy the unpatched build's Module.symvers to
#       <outdir>/Module.symvers.baseline (+ sha256). Used for shot #1.
#   abi-gate.sh check <baseline.symvers> <current.symvers> [report.txt]
#       Gate: every symbol present in the baseline must exist in the current
#       build with an IDENTICAL CRC. Any missing symbol or CRC delta = FAIL
#       (exit 1) with a symbol|old|new|verdict table. New symbols are
#       reported as info only (allowed; unlisted — stock vendor modules
#       cannot bind to symbols they do not know).
#
# Scope note (plan §7): this v1 gate enforces zero delta on ALL baseline
# symbols — stricter than the §7 minimum (KMI-listed symbols only). The
# baseline is captured from the pinned tip whose exports are exactly what
# the device's 268 stock vendor modules bind against, so a strict gate is
# the safest default. Relaxing to the .stg-listed scope is a documented,
# deliberate change if it ever becomes necessary.
#
# Module.symvers format (TAB-separated): crc, symbol, module, export type,
# namespace. Key = symbol|module (symbols are not globally unique).
set -euo pipefail

log() { echo "[abi-gate] $*"; }

usage() {
  echo "usage: $0 capture <current.symvers> <outdir>" >&2
  echo "       $0 check   <baseline.symvers> <current.symvers> [report.txt]" >&2
  exit 2
}

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
    echo "NOTE: this file is G1 evidence — it must be committed to gki6677/abi-baseline/ (via the follow-up mbox) before any patch batch is gated." >&2
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

    # 3) new symbols (info only)
    comm -13 <(cut -f1 "$TMP/base") <(cut -f1 "$TMP/cur") > "$TMP/added"

    NBASE=$(wc -l < "$TMP/base"); NCUR=$(wc -l < "$TMP/cur")
    NDELTA=$(wc -l < "$TMP/delta"); NMISS=$(wc -l < "$TMP/missing"); NADD=$(wc -l < "$TMP/added")

    log "baseline symbols: ${NBASE}   current symbols: ${NCUR}"
    log "CRC deltas: ${NDELTA}   missing: ${NMISS}   new (info): ${NADD}"

    if [ -n "$REPORT" ]; then
      {
        echo "gki6677 ABI gate report"
        echo "baseline: ${BASE} (${NBASE} symbols)"
        echo "current : ${CUR} (${NCUR} symbols)"
        echo "verdict : $([ "$NDELTA" -eq 0 ] && [ "$NMISS" -eq 0 ] && echo PASS || echo FAIL)"
        echo
        if [ "$NDELTA" -gt 0 ] || [ "$NMISS" -gt 0 ]; then
          echo "=== deltas / missing (symbol|module  old-crc  new-crc) ==="
          cat "$TMP/delta"
          sed 's/$/\t<missing>\t<missing>\tMISSING/' "$TMP/missing"
        fi
        if [ "$NADD" -gt 0 ]; then
          echo "=== new symbols (info only, allowed) ==="
          cat "$TMP/added"
        fi
      } > "$REPORT"
      log "report written: ${REPORT}"
    fi

    if [ "$NDELTA" -gt 0 ] || [ "$NMISS" -gt 0 ]; then
      {
        echo "=== ABI GATE FAIL ==="
        cat "$TMP/delta"
        sed 's/$/\t<missing>\t<missing>\tMISSING/' "$TMP/missing"
      } >&2
      exit 1
    fi
    log "ABI GATE PASS — zero delta"
    exit 0
    ;;

  *)
    usage
    ;;
esac
