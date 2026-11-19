#!/usr/bin/env python3
"""Fold the two BORE declarations that the GKI .stg legitimately rejects.

BORE's scheduler state is fully KABI-neutral, but two declarations in the
5.9.6 patch sit ON exported GKI symbols, so their modversions CRC moves with
them. genksyms drops initialisers ("We never care about the contents of an
initializer", scripts/genksyms/parse.y) but keeps the declaration and its
attributes - so:

  * kernel/sched/features.h grows sched_feat_names[] and sched_feat_keys[] by
    one entry. Both are exported data symbols and their type IS the array
    length, so their CRC follows the size. PLACE_REL_DEADLINE defaults to
    true, which means folding it to a compile-time constant keeps the
    behaviour identical while leaving the two arrays the size stock has.
  * sysctl_sched_base_slice is re-declared `__read_mostly uint`. The
    attribute is part of the declaration text, so it alone moves the CRC of
    an exported symbol whose type never changed.

Observed in run 44633908342: after the SYSVIPC fix the only drift left was
exactly these three symbols (sched_feat_keys, sched_feat_names,
sysctl_sched_base_slice).

The script is anchored and idempotent: running it twice changes nothing, and
it exits non-zero if a rewrite did not land - a silent miss here is an ABI
gate failure 20 minutes later.
"""

import os
import re
import sys

FEATURE_BLOCK = re.compile(
    r"[ \t]*/\*\n"
    r"[ \t]*\* Preserve relative virtual deadline on 'migration'\.\n"
    r"[ \t]*\*/\n"
    r"[ \t]*SCHED_FEAT\(PLACE_REL_DEADLINE, true\)\n"
)
FEATURE_NOTE = """/*
 * PLACE_REL_DEADLINE is unconditional in this port. A SCHED_FEAT entry would
 * grow the exported sched_feat_keys[]/sched_feat_names[] (their type is the
 * array length, so their CRC follows it) and the GKI ABI gate rejects that.
 */
"""
FEATURE_LINE = re.compile(r"[ \t]*SCHED_FEAT\(PLACE_REL_DEADLINE, true\)\n")
# A live use, as opposed to this script's own note about the removal.
LIVE = re.compile(r"\bsched_feat\(\s*PLACE_REL_DEADLINE\s*\)"
                  r"|\bSCHED_FEAT\(\s*PLACE_REL_DEADLINE")

FAIR_REWRITES = (
    # (pattern, replacement, label)
    (re.compile(r"sched_feat\(PLACE_REL_DEADLINE\) && se->rel_deadline"),
     "se->rel_deadline", "fair.c: rel_deadline placement"),
    (re.compile(r"sched_feat\(PLACE_REL_DEADLINE\) && !sleep"),
     "!sleep", "fair.c: rel_deadline wakeup"),
    (re.compile(r"__read_mostly[ \t]+uint[ \t]+sysctl_sched_base_slice"),
     "unsigned int sysctl_sched_base_slice", "fair.c: base_slice declaration"),
)
SCHED_H_REWRITES = (
    (re.compile(r"extern[ \t]+__read_mostly[ \t]+uint[ \t]+sysctl_sched_base_slice"),
     "extern unsigned int sysctl_sched_base_slice", "sched.h: base_slice extern"),
)


def rewrite(path, rules, label):
    if not os.path.exists(path):
        print(f"bore-abi: {label}: {path} missing", file=sys.stderr)
        return False
    src = open(path, encoding="utf-8", errors="surrogateescape").read()
    out = src
    hits = 0
    for pat, rep, what in rules:
        out, n = pat.subn(rep, out)
        if n:
            hits += n
            print(f"bore-abi: {path}: {what} ({n}x)")
    if out == src:
        print(f"bore-abi: {path}: already neutral")
        return True
    open(path, "w", encoding="utf-8", errors="surrogateescape").write(out)
    return hits > 0


def features(path):
    if not os.path.exists(path):
        print(f"bore-abi: {path} missing", file=sys.stderr)
        return False
    src = open(path, encoding="utf-8", errors="surrogateescape").read()
    if not LIVE.search(src):
        print(f"bore-abi: {path}: already neutral")
        return True
    out, n = FEATURE_BLOCK.subn(FEATURE_NOTE, src)
    if n == 0:
        # Comment drifted: still drop the entry, keep whatever comment is there.
        out, n = FEATURE_LINE.subn(FEATURE_NOTE, src)
    if n != 1:
        print(f"bore-abi: {path}: could not neutralise PLACE_REL_DEADLINE "
              f"({n} matches)", file=sys.stderr)
        return False
    open(path, "w", encoding="utf-8", errors="surrogateescape").write(out)
    print(f"bore-abi: {path}: SCHED_FEAT(PLACE_REL_DEADLINE) folded to a constant")
    return True


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    fair = os.path.join(root, "kernel/sched/fair.c")
    sched_h = os.path.join(root, "kernel/sched/sched.h")
    feats = os.path.join(root, "kernel/sched/features.h")

    ok = features(feats)
    ok = rewrite(fair, FAIR_REWRITES, "fair") and ok
    ok = rewrite(sched_h, SCHED_H_REWRITES, "sched.h") and ok

    # Post-condition: the ABI surface is gone, everywhere.
    problems = []
    for path in (fair, feats):
        if os.path.exists(path):
            body = open(path, encoding="utf-8", errors="surrogateescape").read()
            if LIVE.search(body):
                problems.append(f"{path}: PLACE_REL_DEADLINE still live")
    for path in (fair, sched_h):
        if os.path.exists(path):
            body = open(path, encoding="utf-8", errors="surrogateescape").read()
            if re.search(r"__read_mostly[ \t]+uint[ \t]+sysctl_sched_base_slice",
                         body):
                problems.append(f"{path}: __read_mostly uint base_slice survives")
    if problems:
        for p in problems:
            print(f"bore-abi: ERROR {p}", file=sys.stderr)
        return 1
    print("bore-abi: exported-symbol surface is stock again")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
