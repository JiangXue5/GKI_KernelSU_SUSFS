#!/usr/bin/env python3
"""Resolve SukiSU Nova's KSU_VERSION the way the kernel build itself does.

Upstream computes the numbers inside kernel/Kbuild (or kernel/Makefile on the
classic "builtin" layout):

    KSU_VERSION      = VERSION_BASE + count(REPO_BRANCH) + VERSION_OFFSET
    KSU_VERSION_FULL = v<VERSION_TAG>-<short8>@<branch>

`count(REPO_BRANCH)` is the number of commits on the repository branch the
tree declares (main for both main and builtin), obtained from the release API
with a plain `git rev-list --count` fallback.  The Kleaf build sandbox has no
.git and no network, so the same expressions evaluate to their fallback
constants there (30000 / 13000) and every build would report a bogus number.

This script evaluates the *same* formula at checkout time, against the full
clone that is actually compiled, and (with --pin) writes the result into the
build file as a plain assignment.  Nothing is hardcoded: base, offset, the
counted branch and the repository name are read out of the tree, so a future
upstream change (a different offset, a renamed branch) is followed instead of
silently ignored.

Resolution order, mirroring upstream:
  * count: full clone first (authoritative for the tree being built), API
    second.  The API answer is recorded so a divergence is visible.
  * tag:   GitHub release first, `git describe` second, "3.0.0" last.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

MARKER = "# CI: deterministic KSU_VERSION"
UPSTREAM = "SukiSU-Nova/SukiSU-Nova"


class KsuVersionError(RuntimeError):
    pass


def branch_for_susfs(susfs_enabled: bool) -> str:
    """Which upstream branch a build may use.

    main carries the modular tree and no CONFIG_KSU_SUSFS: it is the tree for
    SUSFS-off builds.  builtin is the classic single-object GKI tree whose hooks
    are compiled under CONFIG_KSU_SUSFS, which is what this repository's SUSFS
    integration patches around.  Switching a SUSFS build to main would drop the
    inline hooks, so the mapping is fixed and tested.
    """
    return "builtin" if susfs_enabled else "main"


def _git(repo: Path, *args: str, check: bool = True) -> str:
    proc = subprocess.run(
        ["git", "-C", str(repo), *args],
        capture_output=True,
        text=True,
    )
    if check and proc.returncode != 0:
        raise KsuVersionError(
            "git %s failed in %s: %s" % (" ".join(args), repo, proc.stderr.strip())
        )
    return proc.stdout.strip()


def _try_git(repo: Path, *args: str) -> str:
    try:
        return _git(repo, *args, check=False)
    except OSError:
        return ""


def find_build_file(repo: Path) -> Path:
    """kernel/Kbuild on the modular layout, kernel/Makefile on builtin."""
    for name in ("Kbuild", "Makefile"):
        candidate = repo / "kernel" / name
        if candidate.is_file():
            return candidate
    raise KsuVersionError("no kernel/Kbuild or kernel/Makefile under %s" % repo)


_ASSIGN_RE = re.compile(r"^\s*([A-Z_][A-Z0-9_]*)\s*:?=\s*(.*?)\s*$")


def parse_params(text: str) -> dict:
    """Read the version block out of an upstream build file.

    Only the first assignment of each name is used, which is how make resolves
    these (the files assign them exactly once, before the KSU_VERSION lines).
    """
    wanted = {
        "VERSION_BASE",
        "VERSION_OFFSET",
        "REPO_BRANCH",
        "REPO_NAME",
        "REPO_OWNER",
        "KSU_VERSION",
    }
    found: dict[str, str] = {}
    for line in text.splitlines():
        m = _ASSIGN_RE.match(line)
        if not m:
            continue
        key, value = m.group(1), m.group(2)
        if key in wanted and key not in found:
            found[key] = value.split("#", 1)[0].strip().strip("'\"")
    missing = {"VERSION_BASE", "VERSION_OFFSET", "REPO_BRANCH"} - found.keys()
    if missing:
        raise KsuVersionError(
            "the build file no longer declares %s; refusing to guess a version"
            % ", ".join(sorted(missing))
        )
    # main adds the offset, builtin subtracts it. The sign lives in the
    # expression, not in the value, so read it from the expression instead of
    # assuming one direction.
    expr = found.get("KSU_VERSION", "")
    sign = -1 if re.search(r"-\s*\$\(VERSION_OFFSET\)", expr) else 1
    pinned_sign = re.search(r"# CI formula-sign: ([+-]1)", text)
    if pinned_sign:
        sign = int(pinned_sign.group(1))
    return {
        "base": int(found["VERSION_BASE"]),
        "offset": int(found["VERSION_OFFSET"]),
        "offset_sign": sign,
        "repo_branch": found["REPO_BRANCH"],
        "repo_name": found.get("REPO_NAME", "SukiSU"),
        "repo_owner": found.get("REPO_OWNER", ""),
    }


def is_shallow(repo: Path) -> bool:
    return _try_git(repo, "rev-parse", "--is-shallow-repository") == "true"


def ensure_full_history(repo: Path) -> None:
    if not is_shallow(repo):
        return
    _try_git(repo, "fetch", "--unshallow", "--tags", "origin")
    if is_shallow(repo):
        raise KsuVersionError(
            "shallow clone: commit counts would be truncated, so KSU_VERSION "
            "cannot be derived"
        )


def count_commits(repo: Path, branch: str) -> int | None:
    for ref in (f"refs/remotes/origin/{branch}", branch):
        if not _try_git(repo, "rev-parse", "--verify", "--quiet", ref):
            continue
        out = _try_git(repo, "rev-list", "--count", ref)
        if out.isdigit():
            return int(out)
    return None


def _http_headers(url: str, timeout: float) -> dict:
    req = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "sukisu-nova-version-resolver",
        },
    )
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        req.add_header("Authorization", "Bearer %s" % token)
    with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310
        return {k.lower(): v for k, v in resp.headers.items()}


def api_commit_count(owner: str, name: str, branch: str, timeout: float = 6.0) -> int | None:
    """Same signal upstream uses: Link rel=last, or X-Total-Count for Forgejo."""
    url = "https://api.github.com/repos/%s/%s/commits?sha=%s&per_page=1" % (
        owner,
        name,
        branch,
    )
    try:
        headers = _http_headers(url, timeout)
    except (urllib.error.URLError, OSError, ValueError):
        return None
    total = headers.get("x-total-count", "")
    if total.isdigit():
        return int(total)
    link = headers.get("link", "")
    m = re.search(r'[?&]page=(\d+)>;\s*rel="last"', link)
    return int(m.group(1)) if m else None


def api_release_tag(owner: str, name: str, timeout: float = 6.0) -> str | None:
    url = "https://api.github.com/repos/%s/%s/releases/latest" % (owner, name)
    try:
        req = urllib.request.Request(
            url,
            headers={
                "Accept": "application/vnd.github+json",
                "User-Agent": "sukisu-nova-version-resolver",
            },
        )
        token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
        if token:
            req.add_header("Authorization", "Bearer %s" % token)
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310
            data = json.load(resp)
        tag = (data or {}).get("tag_name") or ""
        return tag.lstrip("v") or None
    except (urllib.error.URLError, OSError, ValueError, json.JSONDecodeError):
        return None


def git_tag(repo: Path, commit: str, pattern: bool = True) -> str | None:
    args = ["describe", "--tags", "--abbrev=0"]
    if pattern:
        args += ["--match", "v[0-9]*"]
    args.append(commit)
    tag = _try_git(repo, *args)
    return tag.lstrip("v") if tag else None


def resolve(
    repo: Path,
    branch: str,
    offline: bool = False,
    api_count_fn=api_commit_count,
    api_tag_fn=api_release_tag,
) -> dict:
    repo = Path(repo)
    ensure_full_history(repo)

    origin_ref = "refs/remotes/origin/%s" % branch
    if _try_git(repo, "rev-parse", "--verify", "--quiet", origin_ref):
        proc = subprocess.run(
            ["git", "-C", str(repo), "merge-base", "--is-ancestor", "HEAD", origin_ref],
            capture_output=True,
            text=True,
        )
        if proc.returncode != 0:
            raise KsuVersionError(
                "HEAD is not on origin/%s: the checkout and the branch label "
                "disagree, so KSU_VERSION_FULL would name the wrong branch" % branch
            )

    build_file = find_build_file(repo)
    params = parse_params(build_file.read_text(encoding="utf-8", errors="replace"))

    commit = _git(repo, "rev-parse", "HEAD")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise KsuVersionError("HEAD is not a full commit id: %r" % commit)
    short = _git(repo, "rev-parse", "--short=8", "HEAD")

    local_count = count_commits(repo, params["repo_branch"])
    api_count = None
    api_status = "skipped"
    if not offline:
        api_count = api_count_fn(params["repo_owner"], params["repo_name"], params["repo_branch"])
        if api_count is None:
            api_status = "unavailable"
        elif local_count is None:
            api_status = "used"
        elif api_count == local_count:
            api_status = "ok"
        else:
            api_status = "mismatch(api=%d,local=%d)" % (api_count, local_count)

    if local_count is not None:
        count = local_count
        source = "local-git"
    elif api_count is not None:
        count = api_count
        source = "upstream-api"
    else:
        raise KsuVersionError(
            "'%s' has no commit count: neither the local clone nor the API "
            "could provide it, so KSU_VERSION would be a guess" % params["repo_branch"]
        )

    version = params["base"] + count + params["offset_sign"] * params["offset"]

    tag = None
    tag_source = "default"
    if not offline:
        tag = api_tag_fn(params["repo_owner"], params["repo_name"])
        if tag:
            tag_source = "upstream-api"
    if not tag:
        tag = git_tag(repo, commit)
        if tag:
            tag_source = "local-git"
    if not tag:
        tag = "3.0.0"

    full = "v%s-%s@%s" % (tag, short, branch)

    # Upstream CI (ci.yml / release.yml) always reports the *main* formula,
    # even when the kernel tree being built is builtin.  Compute it from main's
    # own build file so the difference is a measured number, not a guess.
    ci = None
    for name in ("Kbuild", "Makefile"):
        text = ""
        for ref in ("refs/remotes/origin/main", "main"):
            text = _try_git(repo, "show", "%s:kernel/%s" % (ref, name))
            if text:
                break
        if text:
            try:
                main_params = parse_params(text)
            except KsuVersionError:
                break
            main_count = count_commits(repo, main_params["repo_branch"])
            if main_count is not None:
                ci = {
                    "version": main_params["base"]
                    + main_count
                    + main_params["offset_sign"] * main_params["offset"],
                    "base": main_params["base"],
                    "offset": main_params["offset"],
                    "count": main_count,
                }
            break

    return {
        "repository": "%s/%s" % (params["repo_owner"], params["repo_name"]),
        "branch": branch,
        "commit": commit,
        "short": short,
        "build_file": str(build_file.relative_to(repo)),
        "base": params["base"],
        "offset": params["offset"],
        "offset_sign": params["offset_sign"],
        "count_ref": params["repo_branch"],
        "count": count,
        "version": version,
        "tag": tag,
        "tag_source": tag_source,
        "full": full,
        "source": source,
        "api_status": api_status,
        "formula": "%d + %d (%s) %+d = %d"
        % (
            params["base"],
            count,
            params["repo_branch"],
            params["offset_sign"] * params["offset"],
            version,
        ),
        "upstream_ci": ci,
        "upstream_ci_delta": (version - ci["version"]) if ci else None,
    }


def _pin_line(name: str, value: str) -> str:
    return "%-16s := %s" % (name, value)


def pin_build_file(path: Path, info: dict) -> bool:
    """Rewrite the two assignments so the sandboxed build cannot re-derive them.

    Returns True when the file changed.  Idempotent: re-running with the same
    values leaves the file untouched, and the marker block is added once.
    """
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    out: list[str] = []
    seen_version = seen_full = False
    marker_present = any(line.startswith(MARKER) for line in lines)
    inserted_marker = False

    comment = [
        MARKER + "/KSU_VERSION_FULL (resolved by .github/scripts/ksu_version.py).",
        "# Upstream derives these from git plus the release API inside the kernel",
        "# build. The Kleaf sandbox has no .git and no network, so the same formula",
        "# (VERSION_BASE +- VERSION_OFFSET, sign taken from the tree, over",
        "# count(REPO_BRANCH)) is evaluated against",
        "# the full clone at checkout time and pinned here.",
        "# CI formula-sign: %+d" % info["offset_sign"],
    ]

    for line in lines:
        if re.match(r"^KSU_VERSION\s*:?=", line):
            if not marker_present and not inserted_marker:
                out.extend(comment)
                inserted_marker = True
            out.append(_pin_line("KSU_VERSION", str(info["version"])))
            seen_version = True
            continue
        if re.match(r"^KSU_VERSION_FULL\s*:?=", line):
            out.append(_pin_line("KSU_VERSION_FULL", info["full"]))
            seen_full = True
            continue
        out.append(line)

    if not seen_version or not seen_full:
        if not marker_present:
            out.extend(comment)
        if not seen_version:
            out.append(_pin_line("KSU_VERSION", str(info["version"])))
        if not seen_full:
            out.append(_pin_line("KSU_VERSION_FULL", info["full"]))

    new_text = "\n".join(out) + "\n"
    if new_text == text:
        return False
    path.write_text(new_text, encoding="utf-8")
    return True


ENV_KEYS = (
    "KSU_VERSION",
    "KSU_VERSION_FULL",
    "KSU_VERSION_TAG",
    "KSU_VERSION_BASE",
    "KSU_VERSION_OFFSET",
    "KSU_VERSION_COUNT",
    "KSU_VERSION_COUNT_REF",
    "KSU_VERSION_SOURCE",
    "KSU_KERNEL_BRANCH",
    "KSU_REPOSITORY",
    "KSU_UPSTREAM_CI_VERSION",
    "KSU_UPSTREAM_CI_DELTA",
    "KSU_API_STATUS",
)


def env_values(info: dict) -> dict:
    ci = info.get("upstream_ci") or {}
    return {
        "KSU_VERSION": str(info["version"]),
        "KSU_VERSION_FULL": info["full"],
        "KSU_VERSION_TAG": info["tag"],
        "KSU_VERSION_BASE": str(info["base"]),
        "KSU_VERSION_OFFSET": str(info["offset"]),
        "KSU_VERSION_COUNT": str(info["count"]),
        "KSU_VERSION_COUNT_REF": info["count_ref"],
        "KSU_VERSION_SOURCE": info["source"],
        "KSU_KERNEL_BRANCH": info["branch"],
        "KSU_REPOSITORY": info["repository"],
        "KSU_UPSTREAM_CI_VERSION": str(ci.get("version", "")),
        "KSU_UPSTREAM_CI_DELTA": (
            "" if info["upstream_ci_delta"] is None else str(info["upstream_ci_delta"])
        ),
        "KSU_API_STATUS": info["api_status"],
    }


def report(info: dict) -> str:
    ci = info.get("upstream_ci")
    lines = [
        "-- SukiSU Nova version resolution --",
        "  repository      : %s" % info["repository"],
        "  branch          : %s" % info["branch"],
        "  commit          : %s" % info["commit"],
        "  build file      : %s" % info["build_file"],
        "  formula         : %s" % info["formula"],
        "  KSU_VERSION     : %d" % info["version"],
        "  KSU_VERSION_FULL: %s" % info["full"],
        "  VERSION_TAG     : %s (%s)" % (info["tag"], info["tag_source"]),
        "  version source  : %s (api: %s)" % (info["source"], info["api_status"]),
    ]
    if ci:
        lines.append(
            "  upstream CI     : %d (main formula %d + %d %+d)"
            % (ci["version"], ci["base"], ci["count"], ci["offset"])
        )
        lines.append(
            "  delta vs CI     : %+d (branch-local formula, not forced equal)"
            % info["upstream_ci_delta"]
        )
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, help="checkout of SukiSU-Nova")
    parser.add_argument("--branch", default="", help="selected upstream branch")
    parser.add_argument("--offline", action="store_true", help="never call the API")
    parser.add_argument("--pin", action="store_true", help="write the values into the build file")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--github-env", metavar="FILE", help="append KEY=VALUE lines")
    parser.add_argument("--summary", metavar="FILE", help="append a markdown block")
    args = parser.parse_args(argv)

    repo = Path(args.repo).resolve()
    branch = args.branch
    if not branch:
        branch = _try_git(repo, "rev-parse", "--abbrev-ref", "HEAD")
        if branch in ("", "HEAD"):
            remote = _try_git(repo, "branch", "-r", "--contains", "HEAD")
            guesses = [
                line.strip().split("/", 1)[-1]
                for line in remote.splitlines()
                if "->" not in line
            ]
            if "main" in guesses:
                branch = "main"
            elif guesses:
                branch = guesses[0]
            else:
                raise KsuVersionError(
                    "detached HEAD and no remote branch contains it; pass --branch"
                )

    try:
        info = resolve(repo, branch, offline=args.offline)
    except KsuVersionError as exc:
        print("ERROR: %s" % exc, file=sys.stderr)
        return 2

    if args.pin:
        path = repo / info["build_file"]
        changed = pin_build_file(path, info)
        print(
            "%s %s"
            % ("pinned" if changed else "already pinned", path),
            file=sys.stderr,
        )

    if args.github_env:
        with open(args.github_env, "a", encoding="utf-8") as fh:
            for key, value in env_values(info).items():
                fh.write("%s=%s\n" % (key, value))

    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as fh:
            fh.write(
                "| KSU_VERSION | `%d` |\n| KSU_VERSION_FULL | `%s` |\n"
                "| version source | `%s` |\n"
                % (info["version"], info["full"], info["source"])
            )

    if args.json:
        print(json.dumps(info, indent=2))
    else:
        print(report(info))
    return 0


if __name__ == "__main__":
    sys.exit(main())
