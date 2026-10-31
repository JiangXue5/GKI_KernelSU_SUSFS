#!/usr/bin/env bash
# gki6677 P1 — fetch the pinned Google kernel source (plan §2, §6).
#
# Mirrors the WildKernels sync pipeline that already builds this device's
# daily kernel on the same runners (repo manifest + shallow sync + stall-
# abort retries), then enforces the project's exact commit pin so every
# build is bit-identical regardless of upstream branch drift.
#
# usage: fetch-googlesource.sh [kernel_branch] [pin_commit]
#   kernel_branch  default: android15-6.6-2025-03
#   pin_commit     default: 8d05d8f2439f6a6659b324db458b27fb2f53bb50
#                  (deprecated/android15-6.6-2025-03 tip, 2026-03-30 = r33+1;
#                   fallback examples: android15-6.6-2025-03_r33, or a raw SHA)
# env:
#   KERNEL_DIR     destination directory (default: ./kernel)
set -euo pipefail

BRANCH="${1:-android15-6.6-2025-03}"
PIN="${2:-8d05d8f2439f6a6659b324db458b27fb2f53bb50}"
KERNEL_DIR="${KERNEL_DIR:-kernel}"
MANIFEST_BRANCH="common-${BRANCH}"
COMMON_URL="https://android.googlesource.com/kernel/common"
MANIFEST_URL="https://android.googlesource.com/kernel/manifest"
REPO_LAUNCHER="https://storage.googleapis.com/git-repo-downloads/repo"

log() { echo "[fetch-googlesource] $*"; }

# ------------------------------------------------------------- repo launcher
BIN_DIR="${HOME}/.gki-bin"
mkdir -p "$BIN_DIR"
if ! command -v repo >/dev/null 2>&1; then
  log "installing repo launcher -> ${BIN_DIR}/repo"
  curl -fsSL --retry 5 --retry-delay 5 "$REPO_LAUNCHER" -o "$BIN_DIR/repo"
  chmod +x "$BIN_DIR/repo"
fi
export PATH="${BIN_DIR}:${PATH}"

# ------------------------------------------------------------- manifest init
mkdir -p "$KERNEL_DIR"
cd "$KERNEL_DIR"

init_manifest() {
  local depth_flag=""
  [ "${1:-1}" != "0" ] && depth_flag="--depth=${1:-1}"
  repo init -u "$MANIFEST_URL" -b "$MANIFEST_BRANCH" $depth_flag
}

# Wild-proven: kernel branches that Google moved under deprecated/ keep the
# original manifest branch, but the manifest's default revision must be
# rewritten to the deprecated/ path or the sync fails.
log "checking whether branch ${BRANCH} lives under deprecated/ ..."
REMOTE_LINE="$(git ls-remote "$COMMON_URL" "$BRANCH")"
if [ -z "$REMOTE_LINE" ]; then
  echo "ERROR: no upstream ref matches '${BRANCH}' (retired refs? use a tag pin)" >&2
  exit 1
fi
log "upstream ref: ${REMOTE_LINE}"
init_manifest 1
if grep -q deprecated <<<"$REMOTE_LINE"; then
  log "branch is deprecated -> rewriting manifest revision to deprecated/${BRANCH}"
  sed -i "s|\"${BRANCH}\"|\"deprecated/${BRANCH}\"|g" .repo/manifests/default.xml
fi

# ---------------------------------------------------------------- shallow sync
# Wild-proven stall handling: googlesource serves cold deprecated branches at
# zero progress; abort below 1 KB/s after 60 s (instead of idling to the 15 m
# wall) and retry — up to 5 rounds with graduated backoff.
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0=http.lowSpeedLimit
export GIT_CONFIG_VALUE_0=1024
export GIT_CONFIG_KEY_1=http.lowSpeedTime
export GIT_CONFIG_VALUE_1=60

MAX_RETRIES=5
SYNC_TIMEOUT="15m"
delays=(15 30 60 120 240)
attempt=1
sync_ok=""
while [ "$attempt" -le "$MAX_RETRIES" ]; do
  log "attempt ${attempt}/${MAX_RETRIES}: repo sync (shallow, timeout ${SYNC_TIMEOUT}, stall-abort <1KB/s for 60s)"
  if timeout "$SYNC_TIMEOUT" repo sync -c --current-branch --no-clone-bundle --no-tags --jobs-checkout=4 -j4; then
    sync_ok=1
    break
  fi
  rc=$?
  if [ "$rc" -eq 124 ]; then
    log "repo sync timed out after ${SYNC_TIMEOUT} (transfer was progressing, just slow)"
  else
    log "repo sync failed (rc=${rc})"
  fi
  if [ "$attempt" -lt "$MAX_RETRIES" ]; then
    log "cleaning workspace, retrying in ${delays[$((attempt-1))]}s"
    # remove repo metadata AND half-checked-out project dirs from the failed
    # attempt (deleting only .repo leaves stale checkouts that break retries)
    find "$PWD" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    sleep "${delays[$((attempt-1))]}"
  fi
  attempt=$((attempt+1))
done
if [ -z "$sync_ok" ]; then
  echo "ERROR: repo sync failed after ${MAX_RETRIES} attempts" >&2
  exit 1
fi

# ------------------------------------------------------------- pin enforcement
cd common
CURRENT="$(git rev-parse HEAD)"
if [ "$CURRENT" != "$PIN" ]; then
  log "synced tip ${CURRENT} != pin ${PIN} -> fetching pinned object"
  REF="$PIN"
  case "$PIN" in
    *_r[0-9]*) REF="refs/tags/${PIN}" ;;   # tag-style pins fetch by full ref
  esac
  git fetch --depth=1 origin "$REF"
  git checkout --detach --force "$PIN"
fi
if [ "$(git rev-parse HEAD)" != "$PIN" ]; then
  echo "ERROR: pin enforcement failed (HEAD=$(git rev-parse HEAD), want ${PIN})" >&2
  exit 1
fi

COMMIT_DATE="$(git log -1 --format=%cI)"
COMMIT_MSG="$(git log -1 --format=%s)"
log "PINNED source: ${PIN}"
log "   date: ${COMMIT_DATE}"
log "   subject: ${COMMIT_MSG}"

# hand the facts to the workflow (release notes, job summary)
if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "KERNEL_SOURCE_COMMIT=${PIN}"
    echo "KERNEL_SOURCE_DATE=${COMMIT_DATE}"
    echo "KERNEL_SOURCE_SUBJECT=${COMMIT_MSG}"
  } >> "$GITHUB_ENV"
fi
log "done"
