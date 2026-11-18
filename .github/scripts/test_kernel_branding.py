#!/usr/bin/env python3
"""Behavioural tests for .github/actions/apply-kernel-branding.

The tests never touch a real kernel tree. Each case builds a throw-away
fixture that mirrors one of the two shapes AOSP actually uses:

  kleaf   - 6.6 / 6.12 / 6.18: the script echoes the whole release string
            `${KERNELVERSION}${file_localversion}${config_localversion}${LOCALVERSION}${scm_version}`
            and refuses to run without include/config/auto.conf.
  legacy  - 5.10 / 6.1: the script echoes a suffix; the Makefile prefixes
            $(KERNELVERSION). The `-android14-11` block is printed inside
            scm_version(), i.e. only when the tree is a git repo and
            CONFIG_LOCALVERSION_AUTO=y.

Assertions are made on the version string the script actually emits after the
action ran - not on the action's exit code and not on `bash -n`.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("PyYAML is required: pip install pyyaml")

REPO = Path(__file__).resolve().parents[2]
ACTION_PATH = REPO / ".github/actions/apply-kernel-branding/action.yml"

# --------------------------------------------------------------------------
# Fixtures: faithful to the last lines of the real AOSP scripts.
# --------------------------------------------------------------------------
KLEAF_SCRIPT = r"""#!/bin/sh
# Shape of kernel/common/scripts/setlocalversion on android15-6.6
usage() {
	echo "Usage: $0 [--no-local] [srctree]" >&2
	exit 1
}

no_local=false
if test "$1" = "--no-local"; then
	no_local=true
	shift
fi

srctree=.
if test $# -gt 0; then
	srctree=$1
	shift
fi
if test $# -gt 0 -o ! -d "$srctree"; then
	usage
fi

if ! test -e include/config/auto.conf; then
	echo "Error: kernelrelease not valid - run 'make prepare' to update it" >&2
	exit 1
fi

file_localversion=
for f in "$srctree"/localversion*; do
	if test -e "$f"; then
		file_localversion="$file_localversion$(cat "$f")"
	fi
done
config_localversion=$(sed -n 's/^CONFIG_LOCALVERSION=\(.*\)$/\1/p' include/config/auto.conf)

scm_version=
if grep -q "^CONFIG_LOCALVERSION_AUTO=y$" include/config/auto.conf; then
	if head=$(cd "$srctree" && git rev-parse --verify HEAD 2>/dev/null); then
		scm_version="-g$(echo $head | cut -c1-12)"
	fi
fi

echo "${KERNELVERSION}${file_localversion}${config_localversion}${LOCALVERSION}${scm_version}"
"""

LEGACY_SCRIPT = r"""#!/bin/sh
# Shape of kernel/common/scripts/setlocalversion on android12-5.10 / android14-6.1
usage() {
	echo "Usage: $0 [--save-scmversion] [srctree] [branch] [kmi-generation]" >&2
	exit 1
}

srctree=.
android_release=
kmi_generation=
if test $# -gt 0; then
	srctree=$1
	shift
fi
if test $# -gt 0; then
	android_release=`echo "$1" | sed -e '/android[0-9]\{2,\}/!{q255}; s/^\(android[0-9]\{2,\}\)-.*/\1/'`
	if test $? -ne 0; then
		android_release=
	fi
	shift
	if test $# -gt 0; then
		kmi_generation=$1
		[ $(expr $kmi_generation : '^[0-9]\+$') -eq 0 ] && usage
		shift
	fi
fi
if test $# -gt 0 -o ! -d "$srctree"; then
	usage
fi

scm_version()
{
	if head=$(cd "$srctree" && git rev-parse --verify HEAD 2>/dev/null); then
		if [ -n "$android_release" ] && [ -n "$kmi_generation" ]; then
			printf '%s' "-$android_release-$kmi_generation"
		elif [ -n "$android_release" ]; then
			printf '%s' "-$android_release"
		fi
		printf '%s%s' -g "$(echo $head | cut -c1-12)"
	fi
}

if ! test -e include/config/auto.conf; then
	echo "Error: kernelrelease not valid - run 'make prepare' to update it" >&2
	exit 1
fi

res=""
config_localversion=$(sed -n 's/^CONFIG_LOCALVERSION=\(.*\)$/\1/p' include/config/auto.conf)
res="${res}${config_localversion}${LOCALVERSION}"

if grep -q "^CONFIG_LOCALVERSION_AUTO=y$" include/config/auto.conf; then
	res="$res$(scm_version)"
fi

echo "$res"
"""

FAILURES: list[str] = []
CHECKS = 0


def check(name: str, ok: bool, detail: str = "") -> None:
    global CHECKS
    CHECKS += 1
    if ok:
        print(f"  PASS  {name}" + (f" :: {detail}" if detail else ""))
    else:
        print(f"  FAIL  {name}" + (f" :: {detail}" if detail else ""))
        FAILURES.append(name)


def check_eq(name: str, got: str, want: str) -> None:
    check(name, got == want, f"got={got!r} want={want!r}")


def check_re(name: str, got: str, pattern: str) -> None:
    check(name, re.search(pattern, got) is not None, f"got={got!r} /{pattern}/")


def check_not_re(name: str, got: str, pattern: str) -> None:
    check(name, re.search(pattern, got) is None, f"got={got!r} !~ /{pattern}/")


def sh(cmd: list[str], cwd: Path, env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
    full_env = {**os.environ, "GIT_AUTHOR_DATE": "2024-01-01T00:00:00Z",
                "GIT_COMMITTER_DATE": "2024-01-01T00:00:00Z"}
    if env:
        full_env.update(env)
    return subprocess.run(cmd, cwd=str(cwd), env=full_env, text=True,
                          capture_output=True, check=False)


def extract_action() -> tuple[str, dict]:
    data = yaml.safe_load(ACTION_PATH.read_text())
    steps = data["runs"]["steps"]
    assert len(steps) == 1, "the action is expected to have exactly one step"
    return steps[0]["run"], data


class Tree:
    """A disposable kernel/common tree."""

    def __init__(self, root: Path, kind: str, android: str = "android15",
                 kver: str = "6.6", sublevel: str = "162", kmi: str = "8",
                 branch: str | None = None, cfg_localversion: str | None = None,
                 auto_conf: bool = False, git: bool = True):
        self.kind = kind
        self.kver = kver
        self.android = android
        self.sublevel = sublevel
        self.kmi = kmi
        self.branch = branch if branch is not None else f"{android}-{kver}"
        self.dir = root / "kernel" / "common"
        (self.dir / "scripts").mkdir(parents=True)
        (self.dir / "include" / "config").mkdir(parents=True)
        script = KLEAF_SCRIPT if kind == "kleaf" else LEGACY_SCRIPT
        (self.dir / "scripts" / "setlocalversion").write_text(script)
        (self.dir / "scripts" / "setlocalversion").chmod(0o755)

        common = []
        common.append('. ${ROOT_DIR}/${KERNEL_DIR}/build.config.constants')
        if kmi is not None:
            common.append(f"KMI_GENERATION={kmi}")
        common.append(f"BRANCH={self.branch}")
        (self.dir / "build.config.common").write_text("\n".join(common) + "\n")
        (self.dir / "build.config.constants").write_text("CLANG_VERSION=r510928\n")

        # real branding runs before `make defconfig`, so auto.conf is normally
        # absent; the action's own probe must cope with that.
        if auto_conf:
            (self.dir / "include" / "config" / "auto.conf").write_text(
                "CONFIG_LOCALVERSION_AUTO=y\n"
                + (f"CONFIG_LOCALVERSION={cfg_localversion}\n" if cfg_localversion else ""))
        if git:
            sh(["git", "init", "-q", "."], cwd=self.dir)
            sh(["git", "-c", "user.email=t@t", "-c", "user.name=t", "add", "-A"], cwd=self.dir)
            sh(["git", "-c", "user.email=t@t", "-c", "user.name=t",
                "-c", "commit.gpgsign=false", "commit", "-qm", "init"], cwd=self.dir)

    @property
    def script(self) -> Path:
        return self.dir / "scripts" / "setlocalversion"

    @property
    def kernel_version(self) -> str:
        return f"{self.kver}.{self.sublevel}"


def run_action(tree: Tree, brand: str, keep_kmi: bool) -> tuple[dict, str, str]:
    run, _ = extract_action()
    out_file = tree.dir / ".github_output"
    summ_file = tree.dir / ".github_summary"
    out_file.write_text("")
    summ_file.write_text("")
    env = {
        "INPUT_VERSION": f"{tree.android}-{tree.kver}",
        "INPUT_SUBLEVEL": tree.sublevel,
        "INPUT_BRAND": brand,
        "INPUT_KEEP_KMI": "true" if keep_kmi else "false",
        "GITHUB_OUTPUT": str(out_file),
        "GITHUB_STEP_SUMMARY": str(summ_file),
    }
    proc = sh(["bash", "-c", run], cwd=tree.dir, env=env)
    outputs: dict[str, str] = {}
    for line in out_file.read_text().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            outputs[k] = v
    return outputs, proc.stdout, proc.stderr


def probe_release(tree: Tree, script: Path | None = None) -> str:
    """Run a setlocalversion the way the build does, in an isolated copy."""
    script = script or tree.script
    tmp = Path(tempfile.mkdtemp(prefix="probe-"))
    try:
        (tmp / "include" / "config").mkdir(parents=True)
        shutil.copy2(script, tmp / "setlocalversion")
        (tmp / "setlocalversion").chmod(0o755)
        cfg = "CONFIG_LOCALVERSION_AUTO=y\n"
        if (tree.dir / "include/config/auto.conf").exists():
            cfg = (tree.dir / "include/config/auto.conf").read_text()
        (tmp / "include" / "config" / "auto.conf").write_text(cfg)
        sh(["git", "init", "-q", "."], cwd=tmp)
        sh(["git", "-c", "user.email=t@t", "-c", "user.name=t",
            "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", "p"], cwd=tmp)

        args = [".", tree.branch]
        if tree.kind == "legacy":
            if tree.kmi:
                args.append(tree.kmi)
        else:
            args = ["."]
        res = sh(["sh", "./setlocalversion", *args], cwd=tmp,
                 env={"KERNELVERSION": tree.kernel_version, "LOCALVERSION": ""})
        body = res.stdout.strip()
        if not body:
            return ""
        return body if tree.kind == "kleaf" else f"{tree.kernel_version}{body}"
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def new_tree(tmp: Path, name: str, **kw) -> Tree:
    root = tmp / name
    root.mkdir(parents=True)
    return Tree(root, **kw)


# --------------------------------------------------------------------------
# Cases
# --------------------------------------------------------------------------
def case_t1(tmp: Path) -> None:
    print("\n--- T1  brand=''  keep_kmi=false   (Android 15 / 6.6)")
    tree = new_tree(tmp, "t1", kind="kleaf")
    before = tree.script.read_bytes()
    out, _, err = run_action(tree, "", False)
    check_eq("T1 setlocalversion byte-identical", tree.script.read_bytes().hex(), before.hex())
    check_eq("T1 modified", out.get("modified", ""), "false")
    check_eq("T1 kmi_preserved", out.get("kmi_preserved", ""), "false")
    check_eq("T1 kmi_status", out.get("kmi_status", ""), "not-requested")
    check_eq("T1 release string == stock", probe_release(tree),
             f"6.6.162-g" + probe_release(tree).split("-g", 1)[-1])
    check("T1 no brand token", "Wild" not in probe_release(tree))


def case_t2(tmp: Path) -> None:
    print("\n--- T2  brand=''  keep_kmi=true    (Android 15 / 6.6)")
    tree = new_tree(tmp, "t2", kind="kleaf")
    out, stdout, _ = run_action(tree, "", True)
    rel = probe_release(tree)
    check_eq("T2 kmi_preserved", out.get("kmi_preserved", ""), "true")
    check_eq("T2 kmi_status", out.get("kmi_status", ""), "injected")
    check_re("T2 KMI directly after KERNELVERSION", rel, r"^6\.6\.162-android15-8-g[0-9a-f]{6,}$")
    check_eq("T2 KMI occurs once", str(rel.count("-android15-8")), "1")
    check("T2 no brand added", not re.search(r"Wild|Google|Custom", rel))


def case_t2b(tmp: Path) -> None:
    print("\n--- T2b brand=''  keep_kmi=true, tree carries page size (-4k) in auto.conf")
    tree = new_tree(tmp, "t2b", kind="kleaf", auto_conf=True, cfg_localversion="-4k")
    out, _, _ = run_action(tree, "", True)
    rel = probe_release(tree)
    check_eq("T2b kmi_preserved", out.get("kmi_preserved", ""), "true")
    check_re("T2b page size kept, KMI before it", rel,
             r"^6\.6\.162-android15-8-4k-g[0-9a-f]{6,}$")
    check_eq("T2b KMI once", str(rel.count("-android15-8")), "1")
    check_eq("T2b page size once", str(rel.count("-4k")), "1")


def case_t3(tmp: Path) -> None:
    print("\n--- T3  brand=Wild  keep_kmi=false  (Android 15 / 6.6)")
    tree = new_tree(tmp, "t3", kind="kleaf")
    out, _, _ = run_action(tree, "Wild", False)
    rel = probe_release(tree)
    check_re("T3 ends with -Wild", rel, r"-Wild$")
    check_re("T3 keeps sublevel + git description", rel,
             r"^6\.6\.162-android15-g[0-9a-f]{6,}-Wild$")
    check_eq("T3 android token only once", str(rel.count("-android15")), "1")
    check_eq("T3 no KMI number added", "0", str(rel.count("-android15-8")))
    check_eq("T3 kmi_preserved", out.get("kmi_preserved", ""), "false")
    check_eq("T3 kmi_status", out.get("kmi_status", ""), "not-requested")


def case_t4(tmp: Path) -> None:
    print("\n--- T4  brand=Wild  keep_kmi=true   (Android 15 / 6.6)")
    tree = new_tree(tmp, "t4", kind="kleaf")
    out, _, _ = run_action(tree, "Wild", True)
    rel = probe_release(tree)
    check_eq("T4 kmi_preserved", out.get("kmi_preserved", ""), "true")
    check_re("T4 KMI then brand", rel, r"^6\.6\.162-android15-8-g[0-9a-f]{6,}-Wild$")
    check_eq("T4 KMI once", str(rel.count("-android15-8")), "1")
    check_not_re("T4 no -Wild-Wild", rel, r"Wild-Wild")


def case_t5(tmp: Path) -> None:
    print("\n--- T5  brand=Custom  keep_kmi=true (Android 15 / 6.6)")
    tree = new_tree(tmp, "t5", kind="kleaf")
    out, _, _ = run_action(tree, "Custom", True)
    rel = probe_release(tree)
    check_eq("T5 kmi_preserved", out.get("kmi_preserved", ""), "true")
    check_re("T5 KMI then custom brand", rel, r"^6\.6\.162-android15-8-g[0-9a-f]{6,}-Custom$")
    check_not_re("T5 no Wild", rel, r"Wild")

    print("\n--- T5b brand=Custom  keep_kmi=false (Android 15 / 6.6)")
    tree = new_tree(tmp, "t5b", kind="kleaf")
    run_action(tree, "Custom", False)
    rel = probe_release(tree)
    check_re("T5b android token + brand", rel, r"^6\.6\.162-android15-g[0-9a-f]{6,}-Custom$")
    check_eq("T5b android token once", str(rel.count("-android15")), "1")


def case_t6(tmp: Path) -> None:
    print("\n--- T6  KMI_GENERATION missing, keep_kmi=true")
    tree = new_tree(tmp, "t6", kind="kleaf", kmi=None)
    out, stdout, stderr = run_action(tree, "", True)
    combined = stdout + stderr
    check_re("T6 loud warning", combined, r"::warning title=KMI not preserved::")
    check_eq("T6 kmi_preserved", out.get("kmi_preserved", ""), "false")
    check_eq("T6 kmi_status", out.get("kmi_status", ""), "missing-config")
    rel = probe_release(tree)
    check_not_re("T6 does not fabricate a KMI number", rel, r"android15-[0-9]+")
    check_eq("T6 script untouched", out.get("modified", ""), "false")


def case_t7(tmp: Path) -> None:
    print("\n--- T7  setlocalversion already emits KMI (1) legacy 6.1, empty brand")
    tree = new_tree(tmp, "t7", kind="legacy", android="android14", kver="6.1",
                    sublevel="118", kmi="11")
    before = tree.script.read_bytes()
    out, _, _ = run_action(tree, "", True)
    check_eq("T7 kmi_preserved", out.get("kmi_preserved", ""), "true")
    check_eq("T7 kmi_status", out.get("kmi_status", ""), "already-present")
    check_eq("T7 file untouched", tree.script.read_bytes().hex(), before.hex())
    rel = probe_release(tree)
    check_re("T7 stock release keeps KMI", rel, r"^6\.1\.118-android14-11-g[0-9a-f]{6,}$")
    check_eq("T7 KMI once", str(rel.count("-android14-11")), "1")

    print("\n--- T7b setlocalversion already emits KMI (2) kleaf with CONFIG_LOCALVERSION")
    tree = new_tree(tmp, "t7b", kind="kleaf", auto_conf=True,
                    cfg_localversion="-android15-8")
    out, _, _ = run_action(tree, "Wild", True)
    rel = probe_release(tree)
    check_eq("T7b kmi_status", out.get("kmi_status", ""), "already-present")
    check_eq("T7b kmi_preserved", out.get("kmi_preserved", ""), "true")
    check_re("T7b brand appended after stock KMI", rel,
             r"^6\.6\.162-android15-8-g[0-9a-f]{6,}-Wild$")
    check_eq("T7b KMI once", str(rel.count("-android15-8")), "1")


def case_t7c(tmp: Path) -> None:
    print("\n--- T7c tree already carries -android15, keep_kmi=false + brand")
    tree = new_tree(tmp, "t7c", kind="kleaf", auto_conf=True,
                    cfg_localversion="-android15-8-4k")
    run_action(tree, "Wild", False)
    rel = probe_release(tree)
    check_re("T7c brand only, stock tokens untouched", rel,
             r"^6\.6\.162-android15-8-4k-g[0-9a-f]{6,}-Wild$")
    check_eq("T7c android token count", str(rel.count("-android15")), "1")
    check_eq("T7c page size count", str(rel.count("-4k")), "1")


def case_t8(tmp: Path) -> None:
    print("\n--- T8  same action twice (idempotency)")
    tree = new_tree(tmp, "t8", kind="kleaf")
    run_action(tree, "Wild", True)
    first = probe_release(tree)
    run_action(tree, "Wild", True)
    second = probe_release(tree)
    check_eq("T8 release identical after re-run", second, first)
    check_eq("T8 one Wild", str(second.count("Wild")), "1")
    check_eq("T8 one KMI", str(second.count("-android15-8")), "1")
    check_eq("T8 one android token", str(second.count("-android15")), "1")
    check_eq("T8 sublevel kept", str(second.startswith("6.6.162")), "True")

    print("\n--- T8b legacy twice (5.10)")
    tree = new_tree(tmp, "t8b", kind="legacy", android="android12", kver="5.10",
                    sublevel="101", kmi="9")
    run_action(tree, "Wild", True)
    first = probe_release(tree)
    run_action(tree, "Wild", True)
    second = probe_release(tree)
    check_eq("T8b release identical after re-run", second, first)
    check_eq("T8b one Wild", str(second.count("Wild")), "1")
    check_eq("T8b one KMI", str(second.count("-android12-9")), "1")


def case_t8c(tmp: Path) -> None:
    print("\n--- T8c keep_kmi toggled on after a keep_kmi=false run")
    tree = new_tree(tmp, "t8c", kind="kleaf")
    run_action(tree, "Wild", False)
    mid = probe_release(tree)
    out, _, _ = run_action(tree, "Wild", True)
    rel = probe_release(tree)
    check_re("T8c android token completed, not duplicated", rel,
             r"^6\.6\.162-android15-8-g[0-9a-f]{6,}-Wild$")
    check_eq("T8c android token count", str(rel.count("-android15")), "1")
    check_eq("T8c kmi_status", out.get("kmi_status", ""), "extended")
    check_eq("T8c kmi_preserved", out.get("kmi_preserved", ""), "true")
    check("T8c changed the string", mid != rel)


def case_t9(tmp: Path) -> None:
    print("\n--- T9  different Android/kernel shapes")
    cases = [
        ("legacy", "android12", "5.10", "101", "9", r"^5\.10\.101-android12-9-g[0-9a-f]{6,}-Wild$"),
        ("legacy", "android14", "6.1", "118", "11", r"^6\.1\.118-android14-11-g[0-9a-f]{6,}-Wild$"),
        ("kleaf", "android15", "6.6", "162", "8", r"^6\.6\.162-android15-8-g[0-9a-f]{6,}-Wild$"),
        ("kleaf", "android16", "6.12", "30", "12", r"^6\.12\.30-android16-12-g[0-9a-f]{6,}-Wild$"),
    ]
    for i, (kind, android, kver, sublevel, kmi, pattern) in enumerate(cases):
        tree = new_tree(tmp, f"t9-{i}", kind=kind, android=android, kver=kver,
                        sublevel=sublevel, kmi=kmi)
        out, _, _ = run_action(tree, "Wild", True)
        rel = probe_release(tree)
        check_re(f"T9 {android}-{kver} layout", rel, pattern)
        check_eq(f"T9 {android}-{kver} kmi_preserved", out.get("kmi_preserved", ""), "true")


def case_t10(tmp: Path) -> None:
    print("\n--- T10 brand sanitisation / injection")
    tree = new_tree(tmp, "t10a", kind="kleaf")
    out, stdout, stderr = run_action(tree, "My Kernel", False)
    rel = probe_release(tree)
    check_re("T10a spaces become -", rel, r"-My-Kernel$")
    check("T10a single token", "My-Kernel" in rel and "My Kernel" not in rel)

    marker = tmp / "pwned"
    tree = new_tree(tmp, "t10b", kind="kleaf")
    payload = f'x"; touch {marker}; echo "'
    run_action(tree, payload, False)
    check("T10b payload not executed", not marker.exists())
    rel = probe_release(tree)
    check_re("T10b survives as a legal version string", rel,
             r"^6\.6\.162-android15-g[0-9a-f]{6,}-[A-Za-z0-9._+-]*$")
    check_not_re("T10b no shell metacharacters", rel, r'[^A-Za-z0-9._+-]')

    tree = new_tree(tmp, "t10c", kind="kleaf")
    payload = "$(id)`id`;rm -rf /tmp/nope"
    run_action(tree, payload, False)
    rel = probe_release(tree)
    check_not_re("T10c no metacharacters in release", rel, r'[^A-Za-z0-9._+-]')

    tree = new_tree(tmp, "t10d", kind="kleaf")
    before = tree.script.read_bytes()
    out, stdout, stderr = run_action(tree, '"""', False)
    check_re("T10d unusable brand reported", stdout + stderr,
             r"::warning title=brand_name ignored::")
    check_eq("T10d file untouched", tree.script.read_bytes().hex(), before.hex())
    check_eq("T10d modified", out.get("modified", ""), "false")


def case_static() -> None:
    print("\n--- Static contract of the action")
    run, data = extract_action()
    check("S1 action parses as YAML", isinstance(data, dict))
    proc = subprocess.run(["bash", "-n"], input=run, text=True, capture_output=True)
    check("S2 run block parses", proc.returncode == 0, proc.stderr.strip())
    check("S3 brand not interpolated into shell", "inputs.brand_name" not in run)
    check("S4 no -r flag leftovers", "--jq -r" not in run)
    check("S5 early exit keeps stock string",
          "leaving scripts/setlocalversion untouched" in run)
    check("S6 no grep-only KMI verdict",
          'grep -q \'kmi_generation\' "$SCRIPT"' in run and "TREE_ADDS_KMI=false" in run)
    check("S7 kmi_preserved derived from probe",
          'occurrences "$AFTER_REL" "$EXPECTED_KMI"' in run)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    print("=" * 72)
    print("apply-kernel-branding behavioural tests")
    print(f"action: {ACTION_PATH.relative_to(REPO)}")
    print("=" * 72)

    case_static()
    with tempfile.TemporaryDirectory(prefix="branding-tests-") as td:
        tmp = Path(td)
        for fn in (case_t1, case_t2, case_t2b, case_t3, case_t4, case_t5,
                   case_t6, case_t7, case_t7c, case_t8, case_t8c, case_t9,
                   case_t10):
            fn(tmp)

    print()
    print("=" * 72)
    print(f"{CHECKS - len(FAILURES)}/{CHECKS} checks passed, {len(FAILURES)} failed")
    if FAILURES:
        for name in FAILURES:
            print(f"  failed: {name}")
        return 1
    print("ALL BRANDING BEHAVIOUR TESTS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
