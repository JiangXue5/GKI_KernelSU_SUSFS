#!/usr/bin/env python3
"""Strip the two branding hunks out of the vendored 6.6 BORE patch.

The author's 6.6-bore branch carries `localversion` (containing "-bore") and a
setlocalversion edit that comments out `echo "+"`. Both exist purely to make
the author's own kernel announce itself as "-bore"; they are not part of the
scheduler. Applied here they would rewrite UTS_RELEASE, which this repository
pins and verifies (Apply Kernel Branding / Verify Kernel Release String), so
they are removed at vendoring time rather than disabled at build time.

Kept as a script (not a one-off edit) so re-vendoring a newer upstream patch
is reproducible: strip_bore_patch.py <in> <out>.
"""
import sys


def strip(text: str) -> tuple[str, list[str]]:
    out, removed = [], []
    sections = text.split("diff --git ")
    out.append(sections[0])
    for sec in sections[1:]:
        head = sec.split("\n", 1)[0]
        if " b/localversion" in head or " b/scripts/setlocalversion" in head:
            removed.append(head.strip())
            continue
        out.append("diff --git " + sec)
    return "".join(out), removed


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    with open(sys.argv[1], encoding="utf-8", errors="surrogateescape") as fh:
        src = fh.read()
    if "diff --git a/localversion" not in src:
        print("strip-bore-patch: no localversion hunk - already stripped?",
              file=sys.stderr)
        return 1
    dst, removed = strip(src)
    for r in removed:
        print(f"strip-bore-patch: dropped {r}")
    with open(sys.argv[2], "w", encoding="utf-8", errors="surrogateescape") as fh:
        fh.write(dst)
    return 0


if __name__ == "__main__":
    sys.exit(main())
