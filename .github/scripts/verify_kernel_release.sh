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
#     action saved, runs it against the *real* build config (the .config /
#     auto.conf the build resolved, including CONFIG_LOCALVERSION), and that
#     produces the release string the same tree would have produced without any
#     branding;
#   * it runs the in-tree (possibly rewritten) script under exactly the same
#     conditions and compares the two;
#   * it reads the version out of the built Image (and kernel.release) and
#     requires it to equal what the rewritten script emits.
#
# If the artifact's suffix differs from the stock baseline by anything other
# than the KMI/brand tokens this run inserted, the step fails. A green build is
# not accepted as proof on its own.

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

TMPCFG=""
if [ -z "$AUTOCONF" ]; then
  if [ -z "$BUILT_CONFIG" ]; then
    fail "neither auto.conf nor .config found; the stock baseline cannot be computed."
    exit 1
  fi
  TMPCFG="$(mktemp)"
  {
    grep -E '^CONFIG_LOCALVERSION=' "$BUILT_CONFIG" || true
    grep -E '^CONFIG_LOCALVERSION_AUTO=' "$BUILT_CONFIG" || true
  } > "$TMPCFG"
  AUTOCONF="$TMPCFG"
fi

# --------------------------------------------------------------- baselines ---
# The script reads include/config/auto.conf from the working directory and the
# localversion* files plus git metadata from its srctree argument. Two modes are
# possible for the real build:
#   none   - srctree has no .git (Kleaf sandbox: --config=fast does not stamp)
#   source - srctree is the checked out tree with .git (build/build.sh lanes)
# Both are computed; the one that matches the artifact is the build's real
# environment, and the check is then made against that one.
run_rel() {   # $1 = script, $2 = none|source
  local script="$1" mode="$2" d src out=""
  d="$(mktemp -d)"
  mkdir -p "$d/include/config"
  cp "$AUTOCONF" "$d/include/config/auto.conf"
  for f in "$COMMON"/localversion*; do
    [ -e "$f" ] && cp -R "$f" "$d/" 2>/dev/null
  done
  src="$d"
  [ "$mode" = source ] && src="$COMMON"
  if [ "$format" = full ]; then
    out="$( cd "$d" && KERNELVERSION="$kernel_version" LOCALVERSION= LC_ALL=C sh "$script" "$src" 2>/dev/null )"
  elif [ -n "$branch" ] && [ -n "$kmi_generation" ]; then
    out="$( cd "$d" && KERNELVERSION="$kernel_version" LOCALVERSION= LC_ALL=C sh "$script" "$src" "$branch" "$kmi_generation" 2>/dev/null )"
    [ -n "$out" ] && out="$kernel_version$out"
  else
    out="$( cd "$d" && KERNELVERSION="$kernel_version" LOCALVERSION= LC_ALL=C sh "$script" "$src" 2>/dev/null )"
    [ -n "$out" ] && out="$kernel_version$out"
  fi
  rm -rf "$d"
  printf '%s' "$out"
}

BASE_NONE="$(run_rel "$STOCK_SCRIPT" none)"
PRED_NONE="$(run_rel "$INTREE_SCRIPT" none)"
BASE_SRC="$(run_rel "$STOCK_SCRIPT" source)"
PRED_SRC="$(run_rel "$INTREE_SCRIPT" source)"

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

MODE=""
if [ "$PRED_NONE" = "$ACT" ]; then
  MODE=none
elif [ "$PRED_SRC" = "$ACT" ]; then
  MODE=source
fi

if [ -z "$MODE" ]; then
  note "  stock (no git)   : ${BASE_NONE:-<empty>}"
  note "  new   (no git)   : ${PRED_NONE:-<empty>}"
  note "  stock (git)      : ${BASE_SRC:-<empty>}"
  note "  new   (git)      : ${PRED_SRC:-<empty>}"
  fail "the built version '${ACT}' matches neither what the rewritten script emits without git ('${PRED_NONE}') nor with git ('${PRED_SRC}'); a later build stage changed the version string."
  emit "" "" false
  exit 1
fi

if [ "$MODE" = none ]; then BASE="$BASE_NONE"; PRED="$PRED_NONE"; else BASE="$BASE_SRC"; PRED="$PRED_SRC"; fi

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

STRIPPED="$(strip_tokens "$PRED")"
STOCK_SUFFIX="${BASE#"$kernel_version"}"

[ "$STRIPPED" = "$BASE" ] || fail "the rewritten script changes more than the inserted tokens: stock='${BASE}' new-without-tokens='${STRIPPED}'"

if [ "$keep_kmi" = true ] && [ -n "$expected_kmi" ] && [ "$KMI_COUNT" -ne 1 ]; then
  fail "expected exactly one '${expected_kmi}' in '${ACT}', found ${KMI_COUNT}"
fi
case "$ACT" in
  "$kernel_version"*) ;;
  *) fail "the built version '${ACT}' does not start with the kernel version '${kernel_version}'" ;;
esac
if [ -n "$brand_suffix" ]; then
  case "$ACT" in
    *"$brand_suffix") ;;
    *) fail "the built version '${ACT}' does not end with the brand '${brand_suffix}'" ;;
  esac
fi

# The version right after the KMI edit, i.e. before the brand was appended.
AFTER_KMI="$PRED"
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
note "    config used for the baseline   : ${AUTOCONF}"
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
