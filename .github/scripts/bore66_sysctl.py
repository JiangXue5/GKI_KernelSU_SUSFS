#!/usr/bin/env python3
"""Repair the one 6.6 sysctl hunk the GKI tree rejects (5.9.6 generation).

The vendored 6.6 patch was cut against linux-6.6.67. Its second fair.c hunk
rewrites the tunable-scaling / base-slice declaration block, and GKI differs
there in two ways: the base slice defaults to 700000ULL (not 750000ULL), and
Android inserts an EXPORT_SYMBOL_GPL between the two declarations that upstream
does not have. The hunk therefore rejects, and every BORE hunk that later
references nsecs_per_tick / sysctl_sched_min_base_slice fails to compile
("use of undeclared identifier 'nsecs_per_tick'").

This rewrites the WHOLE region between two exact anchors into one canonical
#ifdef block, instead of line-splicing a few insertions:

  BORE arm  : tunable_scaling = NONE, nsecs_per_tick, min_base_slice from
              CONFIG_MIN_BASE_SLICE_NS, base_slice = one tick
  #else arm : the tree's own stock literals, untouched
  outside   : EXPORT_SYMBOL_GPL(sysctl_sched_base_slice) - defined either way
  after     : normalized_... with __maybe_unused (nothing compiled under
              CONFIG_SCHED_BORE reads it on 6.6, and -Werror=unused-variable
              would otherwise kill the build)

Deterministic and anchor-checked: any drift aborts without writing, and the
rewrite is verified for comment balance before it lands. Idempotent: keyed on
nsecs_per_tick already being declared.

Usage: bore66_sysctl.py kernel/sched/fair.c
"""
import re
import sys

START_DECL = "unsigned int sysctl_sched_tunable_scaling = SCHED_TUNABLESCALING_LOG;"
END_PREFIX = "static unsigned int normalized_sysctl_sched_base_slice"
MARK = "/* bore: sysctl block (GKI variant of the rejected 6.6 hunk) */"


def comment_balance_bad(text: str) -> int:
    """C comments do not nest: depth must be 0 at EOF."""
    depth, i, n, state = 0, 0, len(text), "code"
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if state == "code":
            if c == "/" and nxt == "/":
                state = "line"; i += 2; continue
            if c == "/" and nxt == "*":
                depth += 1; state = "block"; i += 2; continue
            if c == '"':
                state = "str"; i += 1; continue
            if c == "'":
                state = "chr"; i += 1; continue
        elif state == "line":
            if c == "\n":
                state = "code"
        elif state == "block":
            if c == "*" and nxt == "/":
                depth -= 1; state = "code"; i += 2; continue
        elif state == "str":
            if c == "\\":
                i += 2; continue
            if c == '"':
                state = "code"
        elif state == "chr":
            if c == "\\":
                i += 2; continue
            if c == "'":
                state = "code"
        i += 1
    return depth


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    path = sys.argv[1]

    with open(path, encoding="utf-8", errors="surrogateescape") as fh:
        src = fh.read()

    if "static const unsigned int nsecs_per_tick" in src:
        print("bore66-sysctl: already repaired")
        return 0
    if MARK in src:
        print("bore66-sysctl: FATAL marker present but nsecs_per_tick missing - "
              "half-repaired tree", file=sys.stderr)
        return 1

    decl = src.find(START_DECL)
    if decl < 0:
        print(f"bore66-sysctl: FATAL anchor not found: {START_DECL!r}",
              file=sys.stderr)
        return 1

    # Walk back to the opener of the comment that documents the setting.
    region_start = src.rfind("\n", 0, decl) + 1
    prev_open = src.rfind("/*", 0, decl)
    if prev_open >= 0 and "*/" not in src[prev_open:decl]:
        line_start = src.rfind("\n", 0, prev_open) + 1
        if src[line_start:prev_open].strip() == "":
            region_start = line_start

    end = src.find(END_PREFIX, decl)
    if end < 0:
        print(f"bore66-sysctl: FATAL anchor not found: {END_PREFIX!r}",
              file=sys.stderr)
        return 1
    region_end = src.find("\n", end)
    if region_end < 0:
        print("bore66-sysctl: FATAL unterminated normalized_ line",
              file=sys.stderr)
        return 1
    region_end += 1

    region = src[region_start:region_end]
    if "CONFIG_SCHED_BORE" in region:
        print("bore66-sysctl: FATAL region already carries CONFIG_SCHED_BORE "
              "but nsecs_per_tick is absent - unexpected state", file=sys.stderr)
        return 1

    # Keep the tree's own stock literal (700000 on GKI, 750000 upstream).
    m = re.search(r"sysctl_sched_base_slice\s*=\s*(\d+ULL);", region)
    stock = m.group(1) if m else "700000ULL"

    block = f"""{MARK}
/*
 * The initial- and re-scaling of tunables is configurable
 *
 *   SCHED_TUNABLESCALING_NONE - unscaled, always *1
 *   SCHED_TUNABLESCALING_LOG - scaled logarithmical, *1+ilog(ncpus)
 *   SCHED_TUNABLESCALING_LINEAR - scaled linear, *ncpus
 *
 * BORE : default SCHED_TUNABLESCALING_NONE = *1 constant
 * EEVDF: default SCHED_TUNABLESCALING_LOG  = *(1+ilog(ncpus))
 */
#ifdef CONFIG_SCHED_BORE
unsigned int sysctl_sched_tunable_scaling = SCHED_TUNABLESCALING_NONE;
#else // !CONFIG_SCHED_BORE
unsigned int sysctl_sched_tunable_scaling = SCHED_TUNABLESCALING_LOG;
#endif // CONFIG_SCHED_BORE

/*
 * Minimal preemption granularity for CPU-bound tasks:
 *
 * BORE : base_slice = minimum multiple of nsecs_per_tick >= min_base_slice
 * (default min_base_slice = 2000000 constant, units: nanoseconds)
 * EEVDF: default (1 + ilog(ncpus)) times the stock slice, units: nanoseconds
 */
#ifdef CONFIG_SCHED_BORE
static const unsigned int nsecs_per_tick   = 1000000000ULL / HZ;
unsigned int sysctl_sched_min_base_slice   = CONFIG_MIN_BASE_SLICE_NS;
__read_mostly uint sysctl_sched_base_slice = nsecs_per_tick;
#else // !CONFIG_SCHED_BORE
unsigned int sysctl_sched_base_slice = {stock};
#endif // CONFIG_SCHED_BORE
EXPORT_SYMBOL_GPL(sysctl_sched_base_slice);
static unsigned int normalized_sysctl_sched_base_slice = {stock} __maybe_unused;
"""

    out = src[:region_start] + block + src[region_end:]

    if comment_balance_bad(out) != 0:
        print("bore66-sysctl: FATAL comment balance broken after rewrite - "
              "region boundaries are wrong, not writing", file=sys.stderr)
        return 1
    if out.count("EXPORT_SYMBOL_GPL(sysctl_sched_base_slice);") != \
            src.count("EXPORT_SYMBOL_GPL(sysctl_sched_base_slice);"):
        print("bore66-sysctl: FATAL export count changed", file=sys.stderr)
        return 1

    with open(path, "w", encoding="utf-8", errors="surrogateescape") as fh:
        fh.write(out)
    print(f"bore66-sysctl: rebuilt sysctl region ({len(region)} -> "
          f"{len(block)} bytes, stock literal {stock})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
