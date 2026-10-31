#!/usr/bin/env bash
# gki6677 P1 — package the built kernel into an AnyKernel3 flashable zip.
#
# Uses the same AnyKernel3 branch the device's daily Wild builds use
# (WildKernels/AnyKernel3 @ gki-2.0), pinned by commit for reproducibility,
# and mirrors Wild's proven zip layout: the raw uncompressed Image staged as
# AnyKernel3/Image, then `zip -r -9` of the directory contents.
#
# usage: build-ak3.sh <flavor> <image_path> <zip_basename>
#   flavor        pure | ksu-susfs (label only in v1)
#   image_path    path to the built kernel Image (uncompressed)
#   zip_basename  output file name without .zip
# env:
#   AK3_REPO / AK3_BRANCH / AK3_PIN   AnyKernel3 source + pinned commit
#   AK3_DIR                           work dir (default: ./AnyKernel3)
set -euo pipefail

FLAVOR="${1:?usage: build-ak3.sh <flavor> <image_path> <zip_basename>}"
IMAGE="${2:?usage: build-ak3.sh <flavor> <image_path> <zip_basename>}"
ZIP_BASE="${3:?usage: build-ak3.sh <flavor> <image_path> <zip_basename>}"

AK3_REPO="${AK3_REPO:-https://github.com/WildKernels/AnyKernel3.git}"
AK3_BRANCH="${AK3_BRANCH:-gki-2.0}"
AK3_PIN="${AK3_PIN:-e1e9dce98430c5c6f231f7094a8c7f4ecaf50948}"   # gki-2.0 tip, 2026-10-31
AK3_DIR="${AK3_DIR:-AnyKernel3}"

log() { echo "[build-ak3] $*"; }

[ -f "$IMAGE" ] || { echo "ERROR: kernel Image not found: ${IMAGE}" >&2; exit 2; }
IMG_SIZE=$(stat -c%s "$IMAGE")
# GKI arm64 Image is ~30-70 MB; anything smaller means we staged the wrong file.
[ "$IMG_SIZE" -ge $((10 * 1024 * 1024)) ] || {
  echo "ERROR: staged Image is only ${IMG_SIZE} bytes — wrong file?" >&2
  exit 1
}

case "$FLAVOR" in
  pure|ksu-susfs) ;;
  *) echo "ERROR: flavor must be 'pure' or 'ksu-susfs' (got '${FLAVOR}')" >&2; exit 2 ;;
esac

rm -rf "$AK3_DIR"
git clone --depth 1 -b "$AK3_BRANCH" "$AK3_REPO" "$AK3_DIR"
git -C "$AK3_DIR" fetch --depth=1 origin "$AK3_PIN" >/dev/null 2>&1 || true
git -C "$AK3_DIR" checkout --detach --force "$AK3_PIN" >/dev/null 2>&1
if [ "$(git -C "$AK3_DIR" rev-parse HEAD)" != "$AK3_PIN" ]; then
  echo "ERROR: AnyKernel3 pin mismatch (HEAD=$(git -C "$AK3_DIR" rev-parse HEAD), want ${AK3_PIN})" >&2
  exit 1
fi

log "staging Image (${IMG_SIZE} bytes) -> ${AK3_DIR}/Image"
cp "$IMAGE" "$AK3_DIR/Image"

# Detach the zip from the clone's history — the zip must contain only AK3 payload.
rm -rf "${AK3_DIR}/.git"

ZIP_OUT="${ZIP_BASE}.zip"
rm -f "$ZIP_OUT"
( cd "$AK3_DIR" && zip -r -q -9 "../${ZIP_OUT}" . )

[ -s "$ZIP_OUT" ] || { echo "ERROR: zip produced no output: ${ZIP_OUT}" >&2; exit 1; }
# Integrity: AK3 zips need every entry readable at flash time.
unzip -tq "$ZIP_OUT" >/dev/null

ZIP_SIZE=$(stat -c%s "$ZIP_OUT")
log "packaged: ${ZIP_OUT} (${ZIP_SIZE} bytes, flavor=${FLAVOR})"
log "sha256: $(sha256sum "$ZIP_OUT" | cut -d' ' -f1)"

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "AK3_ZIP=${ZIP_OUT}" >> "$GITHUB_ENV"
fi
