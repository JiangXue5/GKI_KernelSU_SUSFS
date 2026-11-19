#!/usr/bin/env python3
"""Verify that the BORE port actually landed in the tree.

`patch` returning 0 (or 1 with a repaired reject) only says the text matched.
This script reads the RESULT and asserts the invariants the port depends on, so
a fuzz-spliced hunk or a silently skipped fix step fails the job instead of
producing a kernel that boots without BORE - or does not boot at all.

Checks are per generation; every failure prints what was expected, where, and
which fix step should have produced it.

Usage:
  bore_check.py --family 6.6 [--variant 5.9.6] --sched-h <sched.h> --fair <fair.c>
  bore_check.py --family 6.12 --sched-h ... --fair ...
Exit: 0 = all invariants hold, 1 = at least one failed, 2 = usage.
"""
import argparse
import os
import re
import sys

FAILS = []


def fail(msg):
    FAILS.append(msg)
    print(f"  [FAIL] {msg}")


def ok(msg):
    print(f"  [ok]   {msg}")


def read(path):
    with open(path, encoding="utf-8", errors="surrogateescape") as fh:
        return fh.read()


def need(text, needle, what):
    if needle in text:
        ok(what)
        return True
    fail(f"{what}: expected {needle!r}")
    return False


def splice_probe(text, path):
    """A BORE block that landed inside a comment.

    The #ifdef must not be preceded by a comment-continuation line (' * ...'),
    which is how -F3 fuzz splices a hunk into an unrelated comment and turns
    the rest of it into code (-Wcomment, then parse errors).
    """
    lines = text.splitlines()
    bad = 0
    for i, line in enumerate(lines):
        if line.strip() != "#ifdef CONFIG_SCHED_BORE":
            continue
        j = i - 1
        while j >= 0 and not lines[j].strip():
            j -= 1
        if j < 0:
            continue
        prev = lines[j]
        # Only a comment CONTINUATION line (" * ...") or an unclosed opener
        # means the block landed inside a comment. A closed "*/" or a "/* */"
        # one-liner above the #ifdef is normal: the patch documents the option
        # in a comment and then guards the code.
        inside_comment = (
            re.match(r"^\s*\*(?!/)", prev) is not None
            or ("/*" in prev and "*/" not in prev.split("/*", 1)[1])
        )
        if inside_comment:
            bad += 1
            fail(f"{path}:{i+1}: #ifdef CONFIG_SCHED_BORE spliced after a "
                 f"comment line: {prev.strip()[:60]!r}")
    if not bad:
        ok(f"{path}: no BORE block spliced into a comment")


def check_rej(root):
    rej = []
    for dirpath, _dirs, files in os.walk(root):
        for f in files:
            if f.endswith(".rej"):
                rej.append(os.path.relpath(os.path.join(dirpath, f), root))
    if rej:
        fail(f"unresolved reject files: {', '.join(sorted(rej))}")
    else:
        ok("no .rej left in the tree")


def family_66(sched_h, fair, variant):
    sh = read(sched_h)
    fc = read(fair)

    if variant == "5.1.0":
        # 5.1.0 keeps its state in sched_entity scalars (no cache type, no
        # nsecs_per_tick): bore66_510.py flattens the scalars into slots 1-4.
        need(sh, "bore-kabi: burst_", "5.1.0 KABI relocation marker")
        need(fc, "configured_sched_base_slice", "configured base slice declared")
        if "struct bore_ctx" in sh:
            fail("unexpected bore_ctx in the 5.1.0 generation")
    else:
        need(sh, "struct sched_burst_cache {", "burst cache type present")
        # The upstream patch adds ONE inline `child_burst` member to
        # sched_entity. The relocation removes it and re-adds a same-named
        # payload inside a KABI replace, under the marker. So the marker plus
        # a single occurrence is the expected end state; no marker means the
        # inline layout (and its KMI shift) is still in the tree.
        if "bore-kabi: 6.6 burst state" not in sh:
            fail("inline BORE state remains in sched_entity: bore66_state.py "
                 "did not run (sched_entity layout is shifted)")
        else:
            ok("6.6 out-of-line KABI marker")
            n = sh.count("struct sched_burst_cache child_burst;")
            if n == 1:
                ok("exactly one child_burst member (inside the KABI slots)")
            else:
                fail(f"child_burst member appears {n} times (want 1: the "
                     f"inline copy should have been removed)")
            # KMI: the ONLY member BORE retypes is on_rq, which every sched
            # user hashes - genksyms reads the declaration text, so a narrow
            # on_rq moves 6000+ exported CRCs (run 44555422806). The port
            # must keep the stock declaration and hide rel_deadline in the
            # slots, which genksyms never sees (_ANDROID_KABI_REPLACE is
            # compiled away under __GENKSYMS__).
            if "\tunsigned int\t\t\ton_rq;\n" in sh:
                ok("on_rq keeps its stock declaration (genksyms-neutral)")
            else:
                fail("on_rq is not the stock 'unsigned int on_rq;' - the "
                     "BORE on_rq narrowing survived, which moves the CRC of "
                     "every symbol that mentions sched_entity")
            if re.search(r"^\tunsigned char\s+on_rq;", sh, re.M):
                fail("a narrow on_rq declaration is still in sched_entity")
            marker = sh.find("bore-kabi: 6.6 burst state")
            if marker != -1 and re.search(r"\bu8\s+rel_deadline;",
                                          sh[marker:]):
                ok("rel_deadline carried in the sched_entity KABI payload")
            else:
                fail("rel_deadline is not in the KABI payload (it was "
                     "dropped, or the splice did not run)")
        need(fc, "static const unsigned int nsecs_per_tick",
             "nsecs_per_tick declared")

    need(fc, "sysctl_sched_min_base_slice", "min_base_slice declared")
    need(fc, "curr->burst_time += delta_exec;", "update_curr accounts burst time")
    need(fc, "#ifdef CONFIG_SCHED_BORE", "BORE arms present in fair.c")

    exports = len(re.findall(r"^EXPORT_SYMBOL_GPL\(sysctl_sched_base_slice\);",
                             fc, re.M))
    if exports == 1:
        ok("sysctl_sched_base_slice exported exactly once")
    else:
        fail(f"sysctl_sched_base_slice exported {exports} times (want 1)")


def family_612(sched_h, fair):
    sh = read(sched_h)
    fc = read(fair)
    if "struct bore_ctx *bore" not in sh:
        fail("task_struct has no 'struct bore_ctx *bore' slot-8 pointer")
    else:
        ok("bore_ctx moved out-of-line into a KABI slot")
    need(fc, "update_curr_bore", "update_curr_bore call site")


def family_legacy(sched_h):
    sh = read(sched_h)
    need(sh, "bore-kabi: burst_", "5.15/6.1 KABI relocation marker")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--family", required=True)
    ap.add_argument("--variant", default="5.9.6")
    ap.add_argument("--sched-h", required=True)
    ap.add_argument("--fair", default="")
    ap.add_argument("--root", default=".")
    args = ap.parse_args()

    if not os.path.exists(args.sched_h):
        print(f"bore-check: FATAL {args.sched_h} missing", file=sys.stderr)
        return 2

    print(f"bore-check: family {args.family}, variant {args.variant}")
    if args.family == "6.6":
        if not args.fair or not os.path.exists(args.fair):
            print("bore-check: FATAL --fair required for 6.6", file=sys.stderr)
            return 2
        family_66(args.sched_h, args.fair, args.variant)
    elif args.family in ("6.12", "6.18"):
        if not args.fair or not os.path.exists(args.fair):
            print("bore-check: FATAL --fair required for 6.12", file=sys.stderr)
            return 2
        family_612(args.sched_h, args.fair)
    else:
        family_legacy(args.sched_h)

    if args.fair and os.path.exists(args.fair):
        splice_probe(read(args.fair), os.path.basename(args.fair))
    splice_probe(read(args.sched_h), os.path.basename(args.sched_h))
    check_rej(args.root)

    if FAILS:
        print(f"\nbore-check: {len(FAILS)} invariant(s) failed", file=sys.stderr)
        return 1
    print("\nbore-check: all invariants hold")
    return 0


if __name__ == "__main__":
    sys.exit(main())
