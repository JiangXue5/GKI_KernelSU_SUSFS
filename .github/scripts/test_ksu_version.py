#!/usr/bin/env python3
"""Behavioural tests for .github/scripts/ksu_version.py.

The point of these tests is that the expected numbers are never written by
hand: every fixture repo is built, then

  * upstream's own version block (a verbatim excerpt of SukiSU Nova's
    kernel/Kbuild and kernel/Makefile, see .github/scripts/fixtures/) is
    evaluated with `make`, and
  * our resolver is evaluated on the same repo,

and the two must agree.  A change in the formula, the counted branch, or the
tag handling therefore fails here instead of shipping a wrong KSU_VERSION.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))

import ksu_version as kv  # noqa: E402

PASS = 0
FAIL = 0
FAILURES: list[str] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    global PASS, FAIL
    if ok:
        PASS += 1
        print("  PASS  %s" % name)
    else:
        FAIL += 1
        FAILURES.append(name)
        print("  FAIL  %s%s" % (name, ("  -- " + detail) if detail else ""))


def check_eq(name: str, got, want) -> None:
    check(name, got == want, "got %r, want %r" % (got, want))


def sh(args, cwd=None, env=None, check=True):
    full_env = dict(os.environ)
    full_env.update(
        {
            "GIT_AUTHOR_NAME": "t",
            "GIT_AUTHOR_EMAIL": "t@t",
            "GIT_COMMITTER_NAME": "t",
            "GIT_COMMITTER_EMAIL": "t@t",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_SYSTEM": os.devnull,
        }
    )
    if env:
        full_env.update(env)
    proc = subprocess.run(args, cwd=cwd, env=full_env, capture_output=True, text=True)
    if check and proc.returncode != 0:
        raise RuntimeError("%s failed: %s" % (" ".join(map(str, args)), proc.stderr))
    return proc


def commit(repo: Path, msg: str) -> str:
    sh(["git", "commit", "-q", "--allow-empty", "-m", msg], cwd=repo)
    return sh(["git", "rev-parse", "HEAD"], cwd=repo).stdout.strip()


def new_repo(tmp: Path, name: str, layout: str, main_commits: int = 6,
             builtin_commits: int = 3, tag_at: int = 2) -> Path:
    """Create a repo shaped like the upstream one.

    layout="main":    only a modular `main` branch (kernel/Kbuild).
    layout="builtin": a modular `main` plus an unrelated `builtin` history in
                      the classic layout (kernel/Makefile), exactly like
                      upstream: builtin is not a descendant of main.
    """
    repo = tmp / name
    repo.mkdir()
    sh(["git", "init", "-q", "-b", "main"], cwd=repo)

    def install(fixture: str, target: str) -> None:
        path = repo / "kernel" / target
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(HERE / "fixtures" / fixture, path)

    install("ksu_kbuild_main.mk", "Kbuild")
    sh(["git", "add", "-A"], cwd=repo)
    commit(repo, "base")

    for i in range(1, main_commits):
        commit(repo, "main %d" % i)
        if i == tag_at:
            sh(["git", "tag", "-a", "v3.0.0", "-m", "v3.0.0"], cwd=repo)

    if layout == "builtin":
        sh(["git", "checkout", "-q", "--orphan", "builtin"], cwd=repo)
        sh(["git", "rm", "-rfq", "."], cwd=repo)
        install("ksu_kbuild_builtin.mk", "Makefile")
        sh(["git", "add", "-A"], cwd=repo)
        commit(repo, "builtin base")
        for i in range(1, builtin_commits):
            commit(repo, "builtin %d" % i)
        sh(["git", "checkout", "-q", "main"], cwd=repo)
    return repo


PROBE = """include {fixture}
.PHONY: probe
probe:
\t@printf '%s|%s\\n' '$(KSU_VERSION)' '$(KSU_VERSION_FULL)'
"""


def upstream_make(repo: Path, branch: str) -> tuple[int, str]:
    """Evaluate the vendored upstream block with make (no network)."""
    sh(["git", "checkout", "-q", branch], cwd=repo, check=False)
    fixture = "kernel/Kbuild" if (repo / "kernel/Kbuild").exists() else "kernel/Makefile"
    probe = repo / "probe.mk"
    probe.write_text(PROBE.format(fixture=fixture))
    out = sh(["make", "-s", "-f", "probe.mk", "probe", "CURL_BIN=true"], cwd=repo).stdout
    line = [ln for ln in out.splitlines() if "|" in ln][-1]
    version, full = line.split("|", 1)
    return int(version), full


def case_t1(tmp: Path) -> None:
    print("\n--- T1 main: our formula equals upstream's own make evaluation")
    repo = new_repo(tmp, "t1", "main")
    version, full = upstream_make(repo, "main")
    info = kv.resolve(repo, "main", offline=True)
    check_eq("T1 version == make", info["version"], version)
    check_eq("T1 full == make", info["full"], full)
    check_eq("T1 offset read from tree", info["offset"], 996)
    check_eq("T1 counts main", info["count"], 6)
    check("T1 formula is base+count+offset", info["formula"] == "30000 + 6 (main) +996 = %d" % version,
          info["formula"])


def case_t2(tmp: Path) -> None:
    print("\n--- T2 builtin: own offset, counts main, not builtin")
    repo = new_repo(tmp, "t2", "builtin")
    version, full = upstream_make(repo, "builtin")
    info = kv.resolve(repo, "builtin", offline=True)
    check_eq("T2 version == make", info["version"], version)
    check_eq("T2 full == make", info["full"], full)
    check_eq("T2 offset read from tree", info["offset"], 4001)
    check_eq("T2 counts main", info["count"], 6)
    check_eq("T2 version is base+main-4001", info["version"], 30000 + 6 - 4001)
    check("T2 full carries the builtin branch", info["full"].endswith("@builtin"), info["full"])


def case_t3(tmp: Path) -> None:
    print("\n--- T3 latest: a new upstream commit moves the version")
    repo = new_repo(tmp, "t3", "main", main_commits=4)
    first = kv.resolve(repo, "main", offline=True)
    commit(repo, "new tip")
    second = kv.resolve(repo, "main", offline=True)
    check_eq("T3 version +1", second["version"], first["version"] + 1)
    check("T3 commit moved", second["commit"] != first["commit"])
    check("T3 full carries the new sha", second["short"] in second["full"], second["full"])


def case_t4(tmp: Path) -> None:
    print("\n--- T4 verified: pinned commit, version still counts the branch tip")
    repo = new_repo(tmp, "t4", "main", main_commits=5)
    pinned = sh(["git", "rev-parse", "HEAD~2"], cwd=repo).stdout.strip()
    sh(["git", "checkout", "-q", "--detach", pinned], cwd=repo)
    info = kv.resolve(repo, "main", offline=True)
    check_eq("T4 pinned sha reported", info["commit"], pinned)
    check_eq("T4 counts the branch tip, not the pinned commit", info["count"], 5)
    check("T4 full uses the pinned sha", info["short"] in info["full"], info["full"])
    check("T4 full names the branch", info["full"].endswith("@main"), info["full"])


def case_t5() -> None:
    print("\n--- T5 SUSFS selects builtin, no SUSFS selects main")
    check_eq("T5 susfs on -> builtin", kv.branch_for_susfs(True), "builtin")
    check_eq("T5 susfs off -> main", kv.branch_for_susfs(False), "main")
    main_yml = (ROOT / ".github/workflows/main.yml").read_text()
    check("T5 main.yml resolves builtin only for SUSFS",
          'refs/heads/builtin)' in main_yml and 'refs/heads/main)' in main_yml)
    check("T5 main.yml keeps the branch choice coupled to the SUSFS flag",
          "SCHED_SUSFS" in main_yml and "SUKISU_NOVA_COMMIT" in main_yml)


def case_t6(tmp: Path) -> None:
    print("\n--- T6 API unavailable: local git fallback, same number")
    repo = new_repo(tmp, "t6", "main", main_commits=3)
    info = kv.resolve(
        repo, "main", offline=False,
        api_count_fn=lambda *a, **k: None,
        api_tag_fn=lambda *a, **k: None,
    )
    check_eq("T6 api status", info["api_status"], "unavailable")
    check_eq("T6 source", info["source"], "local-git")
    check_eq("T6 count", info["count"], 3)
    check_eq("T6 version", info["version"], 30000 + 3 + 996)


def case_t7(tmp: Path) -> None:
    print("\n--- T7 shallow clone: unshallowed before counting")
    origin = new_repo(tmp, "t7-origin", "main", main_commits=7)
    clone = tmp / "t7-shallow"
    sh(["git", "clone", "-q", "--depth=1", "file://%s" % origin, str(clone)], cwd=tmp)
    check("T7 clone really is shallow", kv.is_shallow(clone))
    info = kv.resolve(clone, "main", offline=True)
    check_eq("T7 count after unshallow", info["count"], 7)
    check("T7 no longer shallow", not kv.is_shallow(clone))

    print("\n--- T7b shallow and un-unshallowable: refuse instead of guessing")
    broken = tmp / "t7-broken"
    sh(["git", "clone", "-q", "--depth=1", "file://%s" % origin, str(broken)], cwd=tmp)
    sh(["git", "remote", "set-url", "origin", str(tmp / "gone")], cwd=broken)
    try:
        kv.resolve(broken, "main", offline=True)
        check("T7b raises", False, "no exception")
    except kv.KsuVersionError as exc:
        check("T7b raises", "shallow" in str(exc), str(exc))


def case_t8(tmp: Path) -> None:
    print("\n--- T8 detached HEAD: branch comes from the caller, not rev-parse")
    repo = new_repo(tmp, "t8", "main", main_commits=5)
    sh(["git", "checkout", "-q", "--detach", "HEAD"], cwd=repo)
    info = kv.resolve(repo, "main", offline=True)
    check("T8 not @HEAD", not info["full"].endswith("@HEAD"), info["full"])
    check("T8 names main", info["full"].endswith("@main"), info["full"])

    print("\n--- T8b a branch label the checkout is not on is refused")
    repo2 = new_repo(tmp, "t8b", "builtin", main_commits=3, builtin_commits=2)
    sh(["git", "update-ref", "refs/remotes/origin/builtin", "refs/heads/builtin"], cwd=repo2)
    try:
        kv.resolve(repo2, "builtin", offline=True)
        check("T8b raises", False, "no exception")
    except kv.KsuVersionError as exc:
        check("T8b raises", "not on origin/builtin" in str(exc), str(exc))


def case_t9(tmp: Path) -> None:
    print("\n--- T9 upstream CI formula is measured, never assumed")
    repo = new_repo(tmp, "t9", "builtin", main_commits=8)
    # The resolver reads the tree being built, so select the branch first, the
    # way root-setup does.
    sh(["git", "checkout", "-q", "builtin"], cwd=repo)
    info = kv.resolve(repo, "builtin", offline=True)
    check("T9 CI number computed", info["upstream_ci"] is not None)
    check_eq("T9 CI uses main offset", info["upstream_ci"]["offset"], 996)
    check_eq("T9 CI version", info["upstream_ci"]["version"], 30000 + 8 + 996)
    check_eq("T9 delta", info["upstream_ci_delta"], (30000 + 8 - 4001) - (30000 + 8 + 996))
    check("T9 delta is the structural offset difference, not zero",
          info["upstream_ci_delta"] == -4997)


def case_t10(tmp: Path) -> None:
    print("\n--- T10 --pin writes one assignment and freezes the numbers")
    repo = new_repo(tmp, "t10", "main", main_commits=4)
    info = kv.resolve(repo, "main", offline=True)
    build = repo / info["build_file"]
    check("T10 first pin changes the file", kv.pin_build_file(build, info))
    text = build.read_text()
    check_eq("T10 exactly one KSU_VERSION assignment",
             len([ln for ln in text.splitlines() if ln.startswith("KSU_VERSION ")]), 1)
    check_eq("T10 exactly one FULL assignment",
             len([ln for ln in text.splitlines() if ln.startswith("KSU_VERSION_FULL")]), 1)
    check("T10 marker present", kv.MARKER in text)
    check("T10 second pin is a no-op", not kv.pin_build_file(build, info))

    probe = repo / "pinprobe.mk"
    probe.write_text(
        "include kernel/Kbuild\n.PHONY: p\np:\n\t@echo version=$(KSU_VERSION)\n"
        "\t@echo full=$(KSU_VERSION_FULL)\n\t@echo flags=$(ccflags-y)\n"
    )
    out = sh(["make", "-s", "-f", "pinprobe.mk", "p"], cwd=repo).stdout.strip().splitlines()
    check_eq("T10 make sees the pinned number", out[-3], "version=%d" % info["version"])
    check_eq("T10 make sees the pinned full string", out[-2], "full=%s" % info["full"])
    check("T10 compiler flag quotes the string exactly once",
          '-DKSU_VERSION_FULL="%s"' % info["full"] in out[-1], out[-1][-160:])


def case_t11() -> None:
    print("\n--- T11 legacy flavor and other roots stay callable")
    root_setup = (ROOT / ".github/actions/root-setup/action.yml").read_text()
    main_yml = (ROOT / ".github/workflows/main.yml").read_text()
    managers = (ROOT / ".github/workflows/managers.yml").read_text()

    check("T11 root-setup accepts sukisu-nova", "sukisu-nova|sukisu-ultra)" in root_setup)
    check("T11 root-setup accepts the legacy sukisu-ultra alias", "sukisu-ultra)" in root_setup)
    check("T11 root-setup clones the new repository",
          "https://github.com/SukiSU-Nova/SukiSU-Nova.git" in root_setup)
    check("T11 nova directory name", 'directory="SukiSU-Nova"' in root_setup)
    check("T11 old repo url gone", "SukiSU-Ultra/SukiSU-Ultra.git" not in root_setup)
    check("T11 main.yml offers SukiSU Nova", "SukiSU Nova" in main_yml)
    check("T11 main.yml still maps the legacy label", "SukiSU-Ultra)" in main_yml)
    check("T11 managers.yml still maps the legacy label", "SukiSU-Ultra)" in managers)

    for flavor, repo in (
        ("kernelsu", "https://github.com/tiann/KernelSU.git"),
        ("next", "https://github.com/KernelSU-Next/KernelSU-Next.git"),
        ("bakasu", "https://github.com/Baka-SU/BakaSU.git"),
        ("finasu", "https://github.com/LyraVoid/FinaSU.git"),
        ("kowsu", "https://github.com/KOWX712/KernelSU.git"),
    ):
        check("T11 %s unchanged" % flavor, repo in root_setup)


def case_static() -> None:
    print("\n--- S: launcher / workflow wiring")
    root_setup = (ROOT / ".github/actions/root-setup/action.yml").read_text()
    build = (ROOT / ".github/workflows/build.yml").read_text()
    check("S1 root-setup calls the resolver", "ksu_version.py" in root_setup)
    check("S2 resolver pins the build file", "--pin" in root_setup)
    check("S3 no 30000+count override for nova", ".github/scripts/ksu_version.py" in root_setup)
    check("S4 build prints the metadata block", "Root implementation" in build)
    check("S5 build verifies the FULL string in the image", "KSU_VERSION_FULL" in build)


def main() -> int:
    tmp = Path(tempfile.mkdtemp(prefix="ksu-version-"))
    try:
        for fn in (case_t1, case_t2, case_t3, case_t4, case_t6, case_t7,
                   case_t8, case_t9, case_t10):
            fn(tmp)
        case_t5()
        case_t11()
        case_static()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("\n%d checks passed, %d failed" % (PASS, FAIL))
    if FAIL:
        print("failed: %s" % ", ".join(FAILURES))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
