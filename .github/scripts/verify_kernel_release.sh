#!/usr/bin/env bash
# End-to-end check of the release string that was actually built.
#
# Why this exists
# ---------------
# apply-kernel-branding runs before `make defconfig`, so all it can do is run
# scripts/setlocalversion in a scratch copy and compare "stock" against
# "rewritten". That comparison is shape-only: it has no kernel config yet, and
# on the Kleaf lanes the real build never sees .git (Kleaf only embeds the SCM
# version with --config=stamp; this workflow uses --config=fast). A probe is
# therefore not evidence about the artifact.
#
# This script closes that gap after the build:
#   * it takes the untouched copy of scripts/setlocalversion that the branding
#     action saved and runs it against the real build config, which yields the
#     suffix the same tree would have produced without any branding;
#   * it runs the in-tree (possibly rewritten) script under the same conditions
#     and requires the version extracted from the built Image to equal the
#     version prefix plus that suffix;
#   * it removes the tokens this run inserted from the new suffix and requires
#     the result to equal the stock suffix byte for byte. That comparison does
#     not depend on what the version prefix was, so a lost, reordered or
#     truncated suffix cannot hide behind a mismatch elsewhere.
#
# When Kleaf's make environment is available, the exact version prefix is known
# too, and the whole stock release string is reported and compared.

set -uo pipefail

WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"
COMMON="$WORKSPACE/kernel/common"
STATE_FILE="$WORKSPACE/.kernel-branding/state.env"
STOCK_SCRIPT="$WORKSPACE/.kernel-branding/setlocalversion.stock"
INTREE_SCRIPT="$COMMON/scripts/setlocalversion"

FAILURES=0
fail() { echo "::error title=kernel release verification::$*" >&2; FAILURES=$((FAILURES + 1)); }
note() { echo "$*"; }

if [ ! -f "$STATE_FILE" ]; then
  echo "::warning title=release verification skipped::no branding state at $STATE_FILE; the branding action did not run in this job."
  exit 0
fi

format=""; kernel_version=""; branch=""; kmi_generation=""
kmi_suffix=""; extra_suffix=""; expected_kmi=""; brand_suffix=""
kmi_mode=""; kmi_from=""; kmi_to=""; kmi_status=""; keep_kmi=""; modified=""
while IFS='=' read -r k v; do
  case "$k" in
    format) format="$v" ;;
    kernel_version) kernel_version="$v" ;;
    branch) branch="$v" ;;
    kmi_generation) kmi_generation="$v" ;;
    kmi_suffix) kmi_suffix="$v" ;;
    extra_suffix) extra_suffix="$v" ;;
    expected_kmi) expected_kmi="$v" ;;
    brand_suffix) brand_suffix="$v" ;;
    kmi_mode) kmi_mode="$v" ;;
    kmi_from) kmi_from="$v" ;;
    kmi_to) kmi_to="$v" ;;
    kmi_status) kmi_status="$v" ;;
    keep_kmi) keep_kmi="$v" ;;
    modified) modified="$v" ;;
  esac
done < "$STATE_FILE"

[ -n "$format" ] || format="full"
if [ ! -f "$STOCK_SCRIPT" ]; then
  echo "::warning title=release verification skipped::no pristine scripts/setlocalversion at $STOCK_SCRIPT."
  exit 0
fi
if [ ! -f "$INTREE_SCRIPT" ]; then
  fail "$INTREE_SCRIPT is missing; cannot tell what the build ran."
  exit 1
fi

# ---------------------------------------------------------------- artifact ---
IMG=""
for c in \
  "$WORKSPACE/kernel/bazel-bin/common/kernel_aarch64/Image" \
  "/home/runner/out/dist/Image" \
  "$WORKSPACE/AnyKernel3/Image"; do
  if [ -f "$c" ]; then IMG="$c"; break; fi
done

KREL=""
for c in \
  "$WORKSPACE/kernel/bazel-bin/common/kernel_aarch64/out_dir/include/config/kernel.release" \
  "/home/runner/out/include/config/kernel.release"; do
  if [ -f "$c" ]; then KREL="$c"; break; fi
done
if [ -z "$KREL" ] && [ -d "$WORKSPACE/kernel/bazel-bin" ]; then
  KREL="$(find "$WORKSPACE/kernel/bazel-bin" -maxdepth 6 -name kernel.release -type f 2>/dev/null | head -n 1)"
fi

ACT=""
if [ -n "$IMG" ]; then
  ACT="$(LC_ALL=C grep -a -o -m1 'Linux version [^ ]*' "$IMG" 2>/dev/null | awk '{print $3}')"
fi
if [ -z "$ACT" ] && [ -n "$KREL" ]; then
  ACT="$(tr -d '\r\n' < "$KREL")"
fi

if [ -z "$ACT" ]; then
  echo "::warning title=release verification skipped::no Image or kernel.release found (IMAGE='${IMG}', KERNEL.RELEASE='${KREL}')."
  exit 0
fi

# ------------------------------------------------------------------- config ---
AUTOCONF=""
for c in \
  "$WORKSPACE/kernel/bazel-bin/common/kernel_aarch64_config/out_dir/include/config/auto.conf" \
  "/home/runner/out/include/config/auto.conf"; do
  if [ -f "$c" ]; then AUTOCONF="$c"; break; fi
done
BUILT_CONFIG=""
for c in \
  "$WORKSPACE/kernel/bazel-bin/common/kernel_aarch64_config/out_dir/.config" \
  "/home/runner/out/.config" \
  "$WORKSPACE/built.config"; do
  if [ -f "$c" ]; then BUILT_CONFIG="$c"; break; fi
done

# The script only reads these two keys out of include/config/auto.conf. They
# are copied from whatever the build produced, with the quoting of a .config
# string value removed: a release string never carries the quotes, so the
# effective value the build saw was the unquoted one, whether auto.conf stored
# it quoted and the script stripped it, or not.
make_autoconf() {   # $1 = file with the keys
  local src="$1" out
  out="$(mktemp)"
  {
    grep -E '^CONFIG_LOCALVERSION=' "$src" | sed -E 's/^(CONFIG_LOCALVERSION)="(.*)"$/\1=\2/' || true
    grep -E '^CONFIG_LOCALVERSION_AUTO=' "$src" || true
  } > "$out"
  printf '%s' "$out"
}

CFG_SOURCE="$AUTOCONF"
if [ -z "$CFG_SOURCE" ]; then CFG_SOURCE="$BUILT_CONFIG"; fi
if [ -z "$CFG_SOURCE" ]; then
  fail "neither auto.conf nor .config found; the stock baseline cannot be computed."
  exit 1
fi
AUTOCONF="$(make_autoconf "$CFG_SOURCE")"
CONFIG_SOURCE="$CFG_SOURCE"

# -------------------------------------------------------- version prefix -----
# The version prefix handed to setlocalversion is not necessarily the plain
# kernel version: GKI defines the kernel release as
# w.x.y-androidZZ-k-suffix, so the build supplies "6.6.143-android15-8" and
# scripts/setlocalversion only appends what follows it. 5.10/6.1 instead let
# the script produce the KMI itself. Both shapes are tried, most faithful
# first, and the one that reproduces the artifact wins.
KV_ENV=""
KV_ENV_SOURCE=""
read_env_kv() {
  local f="$1" v
  [ -f "$f" ] || return 1
  v="$(sed -n 's/^KERNELVERSION=//p' "$f" 2>/dev/null | head -n 1 | tr -d "\"'")"
  [ -n "$v" ] || return 1
  KV_ENV="$v"
  KV_ENV_SOURCE="$f"
  return 0
}
for f in \
  "$WORKSPACE/kernel/bazel-bin/common/kernel_aarch64_env/kernel_env" \
  "$WORKSPACE/kernel/bazel-bin/common/kernel_aarch64/out_dir/.kernel_env" \
  "/home/runner/out/.kernel_env"; do
  read_env_kv "$f" && break
done
if [ -z "$KV_ENV" ] && [ -d "$WORKSPACE/kernel/bazel-bin/common" ]; then
  for f in $(find "$WORKSPACE/kernel/bazel-bin/common" -maxdepth 3 -type f \
      \( -name 'kernel_env' -o -name '.kernel_env' \) 2>/dev/null | head -n 5); do
    read_env_kv "$f" && break
  done
fi

ANDROID_TOKEN=""
case "$branch" in
  android[0-9]*) ANDROID_TOKEN="${branch%%-*}" ;;
esac
KV_KMI=""
if [ "$format" = full ] && [ -n "$ANDROID_TOKEN" ] && [ -n "$kmi_generation" ]; then
  KV_KMI="${kernel_version}-${ANDROID_TOKEN}-${kmi_generation}"
fi

# --------------------------------------------------------------- baselines ---
# The script reads include/config/auto.conf from the working directory and the
# localversion* files plus git metadata from its srctree argument. Two modes are
# possible for the real build:
#   none   - srctree has no .git (Kleaf sandbox: --config=fast does not stamp)
#   source - srctree is the checked out tree with .git (build/build.sh lanes)
# Both are computed; the one that reproduces the artifact is the build's real
# environment.
run_rel() {   # $1 = script, $2 = none|source, $3 = version prefix
  local script="$1" mode="$2" kv="$3" d src out=""
  d="$(mktemp -d)"
  mkdir -p "$d/include/config"
  cp "$AUTOCONF" "$d/include/config/auto.conf"
  for f in "$COMMON"/localversion*; do
    [ -e "$f" ] && cp -R "$f" "$d/" 2>/dev/null
  done
  src="$d"
  [ "$mode" = source ] && src="$COMMON"
  if [ "$format" = full ]; then
    out="$( cd "$d" && KERNELVERSION="$kv" LOCALVERSION= LC_ALL=C sh "$script" "$src" 2>/dev/null )"
  elif [ -n "$branch" ] && [ -n "$kmi_generation" ]; then
    out="$( cd "$d" && KERNELVERSION="$kv" LOCALVERSION= LC_ALL=C sh "$script" "$src" "$branch" "$kmi_generation" 2>/dev/null )"
    [ -n "$out" ] && out="$kv$out"
  else
    out="$( cd "$d" && KERNELVERSION="$kv" LOCALVERSION= LC_ALL=C sh "$script" "$src" 2>/dev/null )"
    [ -n "$out" ] && out="$kv$out"
  fi
  rm -rf "$d"
  # .github/actions/clean-kernel-flags removes the "-dirty" branch from the
  # script before the build (and commits the result), so the build cannot emit
  # it. The pristine copy still can, because it was saved before that step.
  printf '%s' "${out%-dirty}"
}

split_rel() {   # $1 = full release, $2 = version prefix -> suffix
  local rel="$1" kv="$2"
  case "$rel" in
    "$kv"*) printf '%s' "${rel#"$kv"}" ;;
    *) printf '%s' "$rel" ;;
  esac
}

CANDIDATES=""
[ -n "$KV_ENV" ] && CANDIDATES="$KV_ENV"
[ -n "$KV_KMI" ] && CANDIDATES="$CANDIDATES $KV_KMI"
CANDIDATES="$CANDIDATES $kernel_version"
[ -n "$expected_kmi" ] && CANDIDATES="$CANDIDATES ${kernel_version}${expected_kmi}"

KV=""
KV_SOURCE=""
MODE=""
TRIED=""
for cand in $CANDIDATES; do
  BASE_NONE="$(run_rel "$STOCK_SCRIPT" none "$cand")"
  PRED_NONE="$(run_rel "$INTREE_SCRIPT" none "$cand")"
  BASE_SRC="$(run_rel "$STOCK_SCRIPT" source "$cand")"
  PRED_SRC="$(run_rel "$INTREE_SCRIPT" source "$cand")"
  TRIED="$TRIED $cand"
  if [ "$PRED_NONE" = "$ACT" ]; then MODE=none; KV="$cand"; break; fi
  if [ "$PRED_SRC" = "$ACT" ]; then MODE=source; KV="$cand"; break; fi
done

if [ -n "$KV" ]; then
  if [ -n "$KV_ENV" ] && [ "$KV" = "$KV_ENV" ]; then
    KV_SOURCE="$KV_ENV_SOURCE"
  elif [ "$KV" = "$kernel_version" ]; then
    KV_SOURCE="kernel version (setlocalversion adds the KMI)"
  elif [ -n "$KV_KMI" ] && [ "$KV" = "$KV_KMI" ]; then
    KV_SOURCE="GKI release layout: kernel version + KMI generation"
  else
    KV_SOURCE="kernel version + KMI generation"
  fi
else
  KV="$kernel_version"
  KV_SOURCE="none matched (tried:${TRIED})"
fi

KMI_COUNT=0
if [ -n "$expected_kmi" ]; then
  s="$ACT"
  while [ -n "$s" ] && [ "${s#*"$expected_kmi"}" != "$s" ]; do
    KMI_COUNT=$((KMI_COUNT + 1)); s="${s#*"$expected_kmi"}"
  done
fi

emit() {   # $1 = stock version, $2 = stock suffix, $3 = verified
  [ -n "${GITHUB_OUTPUT:-}" ] || return 0
  {
    echo "built_version=${ACT}"
    echo "stock_version=$1"
    echo "stock_suffix=$2"
    echo "kmi_count=${KMI_COUNT}"
    echo "verified=$3"
  } >> "$GITHUB_OUTPUT"
}

if [ -z "$MODE" ]; then
  note "  prefix tried      : ${KV}  (${KV_SOURCE})"
  note "  stock (no git)    : ${BASE_NONE:-<empty>}"
  note "  new   (no git)    : ${PRED_NONE:-<empty>}"
  note "  stock (git)       : ${BASE_SRC:-<empty>}"
  note "  new   (git)       : ${PRED_SRC:-<empty>}"
  # The suffix is prefix-free, so a dropped or rewritten suffix is still
  # detectable even when the prefix cannot be reproduced.
  STOCK_SUFFIX_RAW="$(split_rel "$BASE_NONE" "$KV")"
  case "$ACT" in
    *"$STOCK_SUFFIX_RAW") ;;
    *) fail "the built version '${ACT}' does not end with the stock suffix '${STOCK_SUFFIX_RAW}'" ;;
  esac
  fail "the built version '${ACT}' matches neither what the rewritten script emits without git ('${PRED_NONE}') nor with git ('${PRED_SRC}'); a later build stage changed the version string."
  emit "" "${STOCK_SUFFIX_RAW}" false
  exit 1
fi

if [ "$MODE" = none ]; then BASE="$BASE_NONE"; PRED="$PRED_NONE"; else BASE="$BASE_SRC"; PRED="$PRED_SRC"; fi
STOCK_SUFFIX="$(split_rel "$BASE" "$KV")"
NEW_SUFFIX="$(split_rel "$PRED" "$KV")"

# Strip exactly what this run inserted, nothing else. merge rewrote
# -android15 into -android15-8 in place; the value tokens are recorded.
strip_tokens() {
  local s="$1"
  if [ -n "$brand_suffix" ]; then
    s="${s%"$brand_suffix"}"
  fi
  if [ "$kmi_mode" = merge ] && [ -n "$kmi_to" ] && [ -n "$kmi_from" ]; then
    s="${s//"$kmi_to"/"$kmi_from"}"
  elif [ -n "$extra_suffix" ]; then
    s="${s//"$extra_suffix"/}"
  fi
  printf '%s' "$s"
}

STRIPPED="$(strip_tokens "$NEW_SUFFIX")"

[ "$STRIPPED" = "$STOCK_SUFFIX" ] || fail "the rewritten script changes the suffix beyond the inserted tokens: stock='${STOCK_SUFFIX}' new-without-tokens='${STRIPPED}'"
case "$ACT" in
  *"$STOCK_SUFFIX") ;;
  *) fail "the built version '${ACT}' does not end with the stock suffix '${STOCK_SUFFIX}'" ;;
esac
case "$ACT" in
  "$kernel_version"*) ;;
  *) fail "the built version '${ACT}' does not start with the kernel version '${kernel_version}'" ;;
esac
if [ "$keep_kmi" = true ] && [ -n "$expected_kmi" ] && [ "$KMI_COUNT" -ne 1 ]; then
  fail "expected exactly one '${expected_kmi}' in '${ACT}', found ${KMI_COUNT}"
fi
if [ -n "$brand_suffix" ]; then
  case "$ACT" in
    *"$brand_suffix") ;;
    *) fail "the built version '${ACT}' does not end with the brand '${brand_suffix}'" ;;
  esac
fi

# The version right after the KMI edit, i.e. before the brand was appended.
AFTER_KMI="${PRED}"
if [ -n "$brand_suffix" ]; then AFTER_KMI="${PRED%"$brand_suffix"}"; fi

KMI_VERDICT="not-requested"
if [ "$keep_kmi" = true ]; then
  if [ "$KMI_COUNT" -eq 1 ] && [ "$ACT" = "$PRED" ]; then KMI_VERDICT="preserved (exactly once)"; else KMI_VERDICT="FAILED"; fi
fi

note ""
note "================= kernel release verification ================="
note "[1] stock version (before branding) : ${BASE}"
note "[2] version after the KMI insertion: ${AFTER_KMI}"
note "[3] version in the built Image     : ${ACT}"
note "[4] original long suffix           : ${STOCK_SUFFIX:-<none>}"
note "[5] KMI verification               : ${KMI_VERDICT}  (status=${kmi_status}, count=${KMI_COUNT})"
note "    image                          : ${IMG:-<none>}"
note "    kernel.release                 : ${KREL:-<none>}"
note "    config used for the baseline   : ${CONFIG_SOURCE}"
note "    version prefix                 : ${KV}  (from: ${KV_SOURCE})"
note "    git visibility that matched    : ${MODE}"
note "    script modified                : ${modified}"
note "==============================================================="

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Kernel release verification"
    echo
    echo "| Item | Value |"
    echo "| --- | --- |"
    echo "| [1] stock version (before branding) | \`${BASE}\` |"
    echo "| [2] version after the KMI insertion | \`${AFTER_KMI}\` |"
    echo "| [3] version in the built Image | \`${ACT}\` |"
    echo "| [4] original long suffix | \`${STOCK_SUFFIX:-<none>}\` |"
    echo "| [5] KMI verification | \`${KMI_VERDICT}\` |"
    echo "| version prefix | \`${KV}\` (\`${KV_SOURCE}\`) |"
    echo "| git visibility | \`${MODE}\` |"
    echo "| branding modified the script | \`${modified}\` |"
    echo
    if [ "$FAILURES" -ne 0 ]; then
      echo "**FAILED**: ${FAILURES} check(s) did not hold."
    else
      echo "**PASSED**: the built version is the stock version with the KMI/brand tokens inserted, and the original suffix is intact."
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

emit "$BASE" "$STOCK_SUFFIX" "$([ "$FAILURES" -eq 0 ] && echo true || echo false)"

if [ "$FAILURES" -ne 0 ]; then
  exit 1
fi
exit 0
