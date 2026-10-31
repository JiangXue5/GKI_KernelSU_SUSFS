#!/usr/bin/env bash
# gki6677 P1 — apply the ordered quilt series (plan §2 series.conf, §10.4).
#
# Applies each patch listed in series.conf to the kernel tree with plain
# `git apply` (no --3way: the shallow Google tree has no blob history for a
# 3-way fallback). A failing patch aborts LOUDLY with its name — the exact
# string bot B3 and runbook §10.4 consume.
#
# A non-empty series is committed into the kernel tree with the §3.4 contract
# identity afterwards, so setlocalversion sees a clean tree (no -dirty suffix)
# and each build's `-g<hash>` in uname -r identifies its exact series state.
# An empty series (this seed) builds the bit-exact pinned Google tip.
#
# usage: apply-series.sh [series.conf]
# env:   KERNEL_DIR  kernel tree to patch (default: ./kernel/common)
set -euo pipefail

SERIES="${1:-gki6677/series.conf}"
KERNEL_DIR="${KERNEL_DIR:-kernel/common}"

log() { echo "[apply-series] $*"; }
[ -f "$SERIES" ] || { echo "ERROR: series file not found: ${SERIES}" >&2; exit 2; }
[ -d "$KERNEL_DIR" ] || { echo "ERROR: kernel tree not found: ${KERNEL_DIR}" >&2; exit 2; }

SERIES_DIR="$(cd "$(dirname "$SERIES")" && pwd)"
PATCH_BASE="${SERIES_DIR}/patches"

mapfile -t ENTRIES < <(grep -vE '^[[:space:]]*(#|$)' "$SERIES" || true)
log "series: ${SERIES} — ${#ENTRIES[@]} patch(es)"

APPLIED=()
i=0
for entry in "${ENTRIES[@]}"; do
  i=$((i+1))
  patch="${PATCH_BASE}/${entry}"
  name="$(basename "$entry")"
  if [ ! -f "$patch" ]; then
    echo "ERROR: series entry ${i}: file not found: ${patch}" >&2
    exit 1
  fi
  log "[${i}/${#ENTRIES[@]}] ${name}"
  if ! git -C "$KERNEL_DIR" apply --check "$patch" 2>/tmp/gki6677-apply.err; then
    {
      echo "==============================================="
      echo "FAILING PATCH: ${name}"
      echo "-----------------------------------------------"
      cat /tmp/gki6677-apply.err
      echo "==============================================="
    } >&2
    exit 1
  fi
  git -C "$KERNEL_DIR" apply "$patch"
  APPLIED+=("$name")
done

if [ "${#APPLIED[@]}" -eq 0 ]; then
  log "empty effective series — building the bit-exact pinned Google tip (pure flavor)"
  exit 0
fi

# Commit the applied series (identity = plan §3.4 contract) so the version
# string stays clean and traceable to the series state.
MSG_FILE="$(mktemp)"
{
  echo "gki6677: apply series (${#APPLIED[@]} patches)"
  echo
  echo "Applied from ${SERIES} in CI:"
  for p in "${APPLIED[@]}"; do
    echo "  ${p}"
  done
} > "$MSG_FILE"

git -C "$KERNEL_DIR" add -A
git -C "$KERNEL_DIR" \
  -c user.name="Irina Shinakawa" \
  -c user.email="25380803+chandr1000@users.noreply.github.com" \
  commit -q -F "$MSG_FILE"
rm -f "$MSG_FILE"

log "committed series into kernel tree: $(git -C "$KERNEL_DIR" rev-parse --short=12 HEAD)"
log "applied ${#APPLIED[@]} patch(es): ${APPLIED[*]}"
