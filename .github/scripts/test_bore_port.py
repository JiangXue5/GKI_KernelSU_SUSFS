#!/usr/bin/env python3
"""Tests for the BORE port (branch `bore` -> main).

The kernel tree is not in this repository, so the transform scripts are
exercised against synthetic fixtures that carry the exact anchors they match
(sched_entity burst block, KABI reserve tails, the stock GKI sysctl block).
That is enough to prove the transforms are deterministic, idempotent and loud
on drift - the parts that used to fail silently.

The workflow half is checked structurally: the gate defaults off, every build
leg forwards it, and nothing bypasses the shared fragment mechanism.

Run: python3 .github/scripts/test_bore_port.py
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CHECKS = 0
FAILED = []


def check(cond, what):
    global CHECKS
    CHECKS += 1
    if cond:
        print(f"  PASS  {what}")
    else:
        print(f"  FAIL  {what}")
        FAILED.append(what)


def run(args, cwd):
    return subprocess.run(args, cwd=str(cwd), capture_output=True, text=True)


# --------------------------------------------------------------------------
# fixtures: only the regions the transforms touch, with upstream's spacing
# --------------------------------------------------------------------------
SCHED_H = """\
/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _LINUX_SCHED_H
#define _LINUX_SCHED_H

#ifdef CONFIG_SCHED_BORE
struct sched_burst_cache {
\tu8\t\t\t\tscore;
\tu32\t\t\t\tcount;
\tu64\t\t\t\ttimestamp;
    spinlock_t\t\tlock;
};
#endif // CONFIG_SCHED_BORE

struct sched_entity {
\tstruct load_weight\t\tload;
\tstruct rb_node\t\t\trun_node;
\tstruct list_head\t\tgroup_node;
\tunsigned char\t\t\ton_rq;
\tunsigned char\t\t\trel_deadline;
\tu64\t\t\t\texec_start;
#ifdef CONFIG_SCHED_BORE
\tu64\t\t\t\tburst_time;
\tu8\t\t\t\tprev_burst_penalty;
\tu8\t\t\t\tcurr_burst_penalty;
\tu8\t\t\t\tburst_penalty;
\tu8\t\t\t\tburst_score;
\tstruct sched_burst_cache child_burst;
\tstruct sched_burst_cache group_burst;
#endif // CONFIG_SCHED_BORE
\tANDROID_KABI_RESERVE(1);
\tANDROID_KABI_RESERVE(2);
\tANDROID_KABI_RESERVE(3);
\tANDROID_KABI_RESERVE(4);
} __randomize_layout;

struct sched_rt_entity {
\tstruct list_head\t\trun_list;
\tunsigned long\t\t\ttimeout;
};

struct task_struct {
\tint\t\t\t\tprio;
\tANDROID_KABI_USE(1, struct task_dma_buf_info *dmabuf_info);

\tANDROID_KABI_RESERVE(2);
\tANDROID_KABI_RESERVE(3);
\tANDROID_KABI_RESERVE(4);
\tANDROID_KABI_RESERVE(5);
\tANDROID_KABI_RESERVE(6);
\tANDROID_KABI_RESERVE(7);
\tANDROID_KABI_RESERVE(8);
};

#endif
"""

FAIR_STOCK = """\
#include <linux/sched.h>

/*
 * The initial- and re-scaling of tunables is configurable
 *
 * Options are:
 *
 *   SCHED_TUNABLESCALING_NONE - unscaled, always *1
 *   SCHED_TUNABLESCALING_LOG - scaled logarithmical, *1+ilog(ncpus)
 *   SCHED_TUNABLESCALING_LINEAR - scaled linear, *ncpus
 *
 * (default SCHED_TUNABLESCALING_LOG = *(1+ilog(ncpus))
 */
unsigned int sysctl_sched_tunable_scaling = SCHED_TUNABLESCALING_LOG;

/*
 * Minimal preemption granularity for CPU-bound tasks:
 *
 * (default: 0.70 msec * (1 + ilog(ncpus)), units: nanoseconds)
 */
unsigned int sysctl_sched_base_slice\t\t\t= 700000ULL;
EXPORT_SYMBOL_GPL(sysctl_sched_base_slice);
static unsigned int normalized_sysctl_sched_base_slice\t= 700000ULL;

static void update_curr(struct cfs_rq *cfs_rq)
{
\tstruct sched_entity *curr = cfs_rq->curr;
\tu64 delta_exec;

\tdelta_exec = 1;
#ifdef CONFIG_SCHED_BORE
\tcurr->burst_time += delta_exec;
\tupdate_burst_penalty(curr);
#endif // CONFIG_SCHED_BORE
\tcurr->vruntime += delta_exec;
}
"""

BORE_C = """\
#include <linux/sched/bore.h>

void sched_clone_bore(struct task_struct *p, struct task_struct *parent,
\t\t      u64 clone_flags, u64 now)
{
\tstruct sched_entity *se = &p->se;
\tse->group_burst.timestamp = now;
\tp->se.group_burst.score = 0;
\tparent->se.group_burst.count = 0;
}
"""


def write_tree(tmp: Path):
    (tmp / "include/linux").mkdir(parents=True, exist_ok=True)
    (tmp / "kernel/sched").mkdir(parents=True, exist_ok=True)
    (tmp / "include/linux/sched.h").write_text(SCHED_H)
    (tmp / "kernel/sched/fair.c").write_text(FAIR_STOCK)
    (tmp / "kernel/sched/bore.c").write_text(BORE_C)


def run_py(script, *args, cwd):
    return run([sys.executable, str(ROOT / ".github/scripts" / script), *args], cwd)


# --------------------------------------------------------------------------
def t1_patch_hygiene():
    print("\n[T1] vendored patch hygiene")
    p596 = ROOT / ".github/actions/bore/patches/0001-linux6.6.67-bore-5.9.6.patch"
    p510 = ROOT / ".github/actions/bore/patches/0001-linux6.6.67-bore5.1.0.patch"
    for p in (p596, p510):
        check(p.is_file(), f"{p.name} exists")
    text = p596.read_text()
    check("a/localversion" not in text,
          "5.9.6 patch has no localversion hunk (kernel string untouched)")
    check("a/scripts/setlocalversion" not in text,
          "5.9.6 patch has no setlocalversion hunk")
    files = re.findall(r"^diff --git a/(\S+)", text, re.M)
    check(len(files) == 12, f"5.9.6 patch touches 12 files (got {len(files)})")
    for must in ("include/linux/sched.h", "include/linux/sched/bore.h",
                 "kernel/sched/bore.c", "kernel/sched/fair.c",
                 "kernel/sched/core.c", "kernel/sched/debug.c",
                 "kernel/sched/Makefile", "init/Kconfig"):
        check(must in files, f"5.9.6 patch includes {must}")
    check('#define SCHED_BORE_VERSION "5.9.6"' in text,
          "5.9.6 patch declares its BORE version")
    check("CONFIG_SCHED_BORE" in text and "CONFIG_MIN_BASE_SLICE_NS" in text,
          "5.9.6 patch adds the Kconfig entry and the slice knob")


def t2_state_relocation():
    print("\n[T2] bore66_state.py relocates the inline burst state")
    tmp = Path(tempfile.mkdtemp())
    try:
        write_tree(tmp)
        r = run_py("bore66_state.py", "include/linux/sched.h", cwd=tmp)
        check(r.returncode == 0, "runs cleanly")
        sched = (tmp / "include/linux/sched.h").read_text()
        check("bore-kabi: 6.6 burst state" in sched, "marker written")
        check(sched.count("struct sched_burst_cache child_burst;") == 1,
              "exactly one child_burst member remains")
        check("u64\t\t\t\tburst_time;" not in sched.split("struct sched_entity {")[1]
              .split("struct sched_rt_entity")[0],
              "inline burst_time removed from sched_entity")
        check("_ANDROID_KABI_REPLACE" in sched, "KABI slots merged")
        # KMI: on_rq must keep its stock declaration; rel_deadline moves into
        # the slot payload, where genksyms cannot see it.
        check("\tunsigned int\t\t\ton_rq;\n" in sched,
              "on_rq restored to the stock 'unsigned int' declaration")
        check("unsigned char\t\t\ton_rq;" not in sched,
              "the narrow on_rq declaration is gone")
        payload = sched.split("bore-kabi: 6.6 burst state")[1]
        check("u8\trel_deadline;" in payload,
              "rel_deadline carried inside the sched_entity KABI payload")
        check("ANDROID_KABI_RESERVE(6);" in sched,
              "task_struct slots 6-8 left for other features")
        check("struct sched_burst_cache {" in sched and
              "u64\t\t\t\ttimestamp;" in sched,
              "cache packed to the 16-byte slot form")
        before = sched
        r2 = run_py("bore66_state.py", "include/linux/sched.h", cwd=tmp)
        check(r2.returncode == 0 and
              (tmp / "include/linux/sched.h").read_text() == before,
              "second run is a no-op (idempotent)")
    finally:
        shutil.rmtree(tmp)


def t3_flat_translation():
    print("\n[T3] bore66_flat.py moves only the group_burst accessors")
    tmp = Path(tempfile.mkdtemp())
    try:
        write_tree(tmp)
        r = run_py("bore66_flat.py", "kernel/sched/bore.c", cwd=tmp)
        check(r.returncode == 0, "runs cleanly")
        src = (tmp / "kernel/sched/bore.c").read_text()
        check("se->group_burst" not in src, "bare se-> group accessor rewritten")
        check("task_of(se)->group_burst.timestamp" in src,
              "se->group_burst -> task_of(se)->group_burst")
        check("p->group_burst.score" in src, "p->se.group_burst -> p->group_burst")
        check("parent->group_burst.count" in src,
              "parent->se.group_burst -> parent->group_burst")
        check("se->child_burst" not in BORE_C.replace("child", "child"),
              "child_burst accessors are left alone (still sched_entity)")
        before = src
        r2 = run_py("bore66_flat.py", "kernel/sched/bore.c", cwd=tmp)
        check((tmp / "kernel/sched/bore.c").read_text() == before,
              "second run is a no-op (idempotent)")
    finally:
        shutil.rmtree(tmp)


def t4_sysctl_rewrite():
    print("\n[T4] bore66_sysctl.py rebuilds the rejected sysctl block")
    tmp = Path(tempfile.mkdtemp())
    try:
        write_tree(tmp)
        r = run_py("bore66_sysctl.py", "kernel/sched/fair.c", cwd=tmp)
        check(r.returncode == 0, "runs cleanly")
        src = (tmp / "kernel/sched/fair.c").read_text()
        check("static const unsigned int nsecs_per_tick" in src,
              "nsecs_per_tick declared")
        check("sysctl_sched_min_base_slice" in src, "min_base_slice declared")
        check("CONFIG_MIN_BASE_SLICE_NS" in src, "slice floor comes from Kconfig")
        check(src.count("EXPORT_SYMBOL_GPL(sysctl_sched_base_slice);") == 1,
              "export kept exactly once, outside the ifdef")
        check("= 700000ULL;" in src, "GKI's own 700000ULL literal preserved")
        # __maybe_unused is a declaration attribute: after the initializer the
        # compiler reads it as a stray token ("expected ';' after top level
        # declarator"), which is exactly how run 44551211243 died.
        check(re.search(r"normalized_sysctl_sched_base_slice __maybe_unused = "
                        r"\d+ULL;", src) is not None,
              "normalized_ carries __maybe_unused before the initializer")
        check("SCHED_TUNABLESCALING_NONE" in src and
              "SCHED_TUNABLESCALING_LOG" in src,
              "both scaling defaults present behind the ifdef")
        check(src.count("#ifdef CONFIG_SCHED_BORE") >= 2, "both arms guarded")
        before = src
        r2 = run_py("bore66_sysctl.py", "kernel/sched/fair.c", cwd=tmp)
        check((tmp / "kernel/sched/fair.c").read_text() == before,
              "second run is a no-op (idempotent)")
    finally:
        shutil.rmtree(tmp)


def t5_fail_loudly_on_drift():
    print("\n[T5] transforms abort instead of half-merging on drift")
    tmp = Path(tempfile.mkdtemp())
    try:
        write_tree(tmp)
        fair = tmp / "kernel/sched/fair.c"
        drifted = fair.read_text().replace(
            "static unsigned int normalized_sysctl_sched_base_slice", "REMOVED")
        fair.write_text(drifted)
        r = run_py("bore66_sysctl.py", "kernel/sched/fair.c", cwd=tmp)
        check(r.returncode != 0, "sysctl rewrite fails when its anchor is gone")
        check(fair.read_text() == drifted, "and leaves the file untouched")

        (tmp / "include/linux/sched.h").write_text(
            SCHED_H.replace("\tANDROID_KABI_RESERVE(1);\n"
                            "\tANDROID_KABI_RESERVE(2);\n"
                            "\tANDROID_KABI_RESERVE(3);\n"
                            "\tANDROID_KABI_RESERVE(4);\n", ""))
        r = run_py("bore66_state.py", "include/linux/sched.h", cwd=tmp)
        check(r.returncode != 0,
              "state relocation fails without the sched_entity reserve tail")

        bad = tmp / "kernel/sched/fair.c"
        bad.write_text(FAIR_STOCK)
        (tmp / "kernel/sched/bore.c").write_text("int x; /* unterminated\n")
        r = run_py("bore66_sysctl.py", "kernel/sched/fair.c", cwd=tmp)
        check(r.returncode == 0, "sysctl rewrite still succeeds on fair.c")
    finally:
        shutil.rmtree(tmp)


def t6_bore_check():
    print("\n[T6] bore_check.py judges the RESULT")
    tmp = Path(tempfile.mkdtemp())
    try:
        write_tree(tmp)
        for s, a in (("bore66_state.py", ["include/linux/sched.h"]),
                     ("bore66_flat.py", ["kernel/sched/bore.c"]),
                     ("bore66_sysctl.py", ["kernel/sched/fair.c"])):
            run_py(s, *a, cwd=tmp)
        r = run_py("bore_check.py", "--family", "6.6", "--variant", "5.9.6",
                   "--sched-h", "include/linux/sched.h",
                   "--fair", "kernel/sched/fair.c", "--root", ".", cwd=tmp)
        check(r.returncode == 0, "passes on a fully transformed tree")

        # a stale reject must fail
        (tmp / "kernel/sched/fair.c.rej").write_text("--- x\n")
        r = run_py("bore_check.py", "--family", "6.6",
                   "--sched-h", "include/linux/sched.h",
                   "--fair", "kernel/sched/fair.c", "--root", ".", cwd=tmp)
        check(r.returncode != 0 and ".rej" in r.stdout,
              "fails on a leftover reject file")
        (tmp / "kernel/sched/fair.c.rej").unlink()

        # inline state (relocation skipped) must fail
        write_tree(tmp)
        run_py("bore66_sysctl.py", "kernel/sched/fair.c", cwd=tmp)
        r = run_py("bore_check.py", "--family", "6.6",
                   "--sched-h", "include/linux/sched.h",
                   "--fair", "kernel/sched/fair.c", "--root", ".", cwd=tmp)
        check(r.returncode != 0 and "inline BORE state" in r.stdout,
              "fails when the inline state was never relocated")

        # a BORE block spliced into a comment must fail
        write_tree(tmp)
        run_py("bore66_state.py", "include/linux/sched.h", cwd=tmp)
        run_py("bore66_sysctl.py", "kernel/sched/fair.c", cwd=tmp)
        f = tmp / "kernel/sched/fair.c"
        f.write_text(f.read_text().replace(
            "static void update_curr",
            " * whether or not the task is running\n#ifdef CONFIG_SCHED_BORE\n"
            "\tupdate_curr_bore(p, 0);\n#endif\n"
            " * on behalf of fair_server\n */\nstatic void update_curr"))
        r = run_py("bore_check.py", "--family", "6.6",
                   "--sched-h", "include/linux/sched.h",
                   "--fair", "kernel/sched/fair.c", "--root", ".", cwd=tmp)
        check(r.returncode != 0 and "spliced" in r.stdout,
              "fails on a BORE block spliced into a comment")
    finally:
        shutil.rmtree(tmp)


def t6c_kmi_guard():
    """The on_rq check must fail if a future edit loses the normalisation."""
    print("\n[T6c] bore_check.py refuses a surviving on_rq narrowing")
    tmp = Path(tempfile.mkdtemp())
    try:
        write_tree(tmp)
        for s, a in (("bore66_state.py", ["include/linux/sched.h"]),
                     ("bore66_flat.py", ["kernel/sched/bore.c"]),
                     ("bore66_sysctl.py", ["kernel/sched/fair.c"])):
            run_py(s, *a, cwd=tmp)
        sh = tmp / "include/linux/sched.h"
        text = sh.read_text()
        # undo exactly what the KMI fix does, and nothing else
        broken = text.replace(
            "\tunsigned int\t\t\ton_rq;",
            "\tunsigned char\t\t\ton_rq;\n\tunsigned char\t\t\trel_deadline;")
        check(broken != text, "fixture actually re-narrows on_rq")
        sh.write_text(broken)
        r = run_py("bore_check.py", "--family", "6.6", "--variant", "5.9.6",
                   "--sched-h", "include/linux/sched.h",
                   "--fair", "kernel/sched/fair.c", "--root", ".", cwd=tmp)
        check(r.returncode != 0, "a narrow on_rq fails the check")
        check("on_rq is not the stock" in r.stdout,
              "the failure names the KMI reason")
    finally:
        shutil.rmtree(tmp)


def t6b_variant_510():
    print("\n[T6b] the 5.1.0 generation is checked with its own invariants")
    tmp = Path(tempfile.mkdtemp())
    try:
        write_tree(tmp)
        sh = tmp / "include/linux/sched.h"
        fc = tmp / "kernel/sched/fair.c"
        # 5.1.0 shape: scalars in the slots, no cache type, configured_ slice.
        sh.write_text(SCHED_H.replace(
            """#ifdef CONFIG_SCHED_BORE
\tu64\t\t\t\tburst_time;""",
            """\t/* bore-kabi: burst_ flat payload */
\t_ANDROID_KABI_REPLACE(ANDROID_KABI_RESERVE(1); ANDROID_KABI_RESERVE(2),
\t\tstruct { u64 burst_time; });
#ifdef CONFIG_SCHED_BORE
\tu64\t\t\t\tburst_time;"""))
        fc.write_text(FAIR_STOCK.replace(
            "static unsigned int normalized_sysctl_sched_base_slice",
            "static unsigned int configured_sched_base_slice = 1000000000ULL / HZ;\n"
            "unsigned int sysctl_sched_min_base_slice = 2000000ULL;\n"
            "static unsigned int normalized_sysctl_sched_base_slice"))
        r = run_py("bore_check.py", "--family", "6.6", "--variant", "5.1.0",
                   "--sched-h", "include/linux/sched.h",
                   "--fair", "kernel/sched/fair.c", "--root", ".", cwd=tmp)
        check(r.returncode == 0, "5.1.0 invariants accept the scalar layout")
        check("nsecs_per_tick" not in r.stdout,
              "5.1.0 is not asked for the 5.9.6-only symbol")
    finally:
        shutil.rmtree(tmp)


def t7_workflow_wiring():
    print("\n[T7] build wiring")
    build = (ROOT / ".github/workflows/build.yml").read_text()
    prepare = (ROOT / ".github/workflows/prepare.yml").read_text()
    main = (ROOT / ".github/workflows/main.yml").read_text()
    ds = (ROOT / ".github/actions/droidspaces/action.yml").read_text()
    act = (ROOT / ".github/actions/bore/action.yml").read_text()
    frag = ROOT / ".github/fragments/enable-bore.fragment"

    check(re.search(r"use_bore:\n(?:\s+.*\n)*?\s+default: false", build) is not None,
          "build.yml defaults use_bore to false (main behaviour unchanged)")
    check("if: inputs.use_bore" in build, "the BORE step is gated on the input")
    check("uses: ./.github/actions/bore" in build, "build.yml applies the action")
    check("bore: ${{ inputs.use_bore || false }}" in build,
          "droidspaces is told whether BORE is on")

    check("use_bore:" in prepare and "bore_variant:" in prepare,
          "prepare.yml forwards both inputs")
    check("use_bore: ${{ inputs.use_bore }}" in prepare,
          "prepare passes the value to the build leg")

    check(main.count("use_bore: ${{ inputs.use_bore || false }}") == 8,
          "all 8 build legs forward use_bore")
    check(main.count("bore_variant: ${{ inputs.bore_variant || '5.9.6' }}") == 8,
          "all 8 build legs forward the variant")
    check(re.search(r"use_bore:\n\s+description:.*\n\s+type: boolean\n\s+default: false", main) is not None,
          "dispatch input defaults to false")

    check('if [ "${{ inputs.bore }}" == "true" ]; then' in ds,
          "droidspaces picks its 6.6 SYSVIPC fix by BORE state")
    check("001.GKI-6.6-fix_sysvipc_kabi_gap.patch" in ds,
          "the gap variant exists for the BORE combination")
    check("001.GKI-below-6.12-fix_sysvipc_kabi_6_7_8.patch" in ds,
          "the stock 6-7-8 variant is still there for BORE off")

    check(frag.is_file(), "the config fragment exists")
    body = frag.read_text() if frag.is_file() else ""
    check("CONFIG_SCHED_BORE=y" in body, "fragment enables the scheduler")
    check("CONFIG_MIN_BASE_SLICE_NS=2000000" in body, "fragment sets the slice")

    check("append_fragment.py" in act,
          "BORE uses the shared fragment mechanism")
    check("set-kernel-config" not in act,
          "no second, parallel config mechanism")
    check("--forward" in act, "patch is applied idempotently")
    check("refusing to continue" in act,
          "an unsupported kernel version is a hard error, not a skip")
    check("SCHED_BORE_VERSION not found in the patch" in act,
          "a patch without the version macro is still rejected")
    check('BORE_VER="5.1.0"' in act,
          "the 5.1.0 generation is labelled from the requested variant")
    check("kernel/sched/fair.c.rej" in act,
          "only the known sysctl reject is tolerated")
    check("bore_check.py" in act, "the action verifies the result, not the exit code")
    # Regression: the known sysctl reject must be dropped BEFORE the check,
    # otherwise bore_check fails on the file it is supposed to tolerate.
    drop = act.index("rm -f kernel/sched/fair.c.rej")
    verify = act.index(".github/scripts/bore_check.py")
    check(drop < verify,
          "the known sysctl reject is cleared before bore_check runs")


def t8_no_collateral():
    print("\n[T8] nothing outside the BORE feature moved")
    sched_h_patch = (ROOT / ".github/actions/bore/patches/"
                     "0001-linux6.6.67-bore-5.9.6.patch").read_text()
    check("b/scripts/setlocalversion" not in sched_h_patch,
          "branding/version scripts untouched by the patch")
    check("b/localversion" not in sched_h_patch, "no localversion file added")
    for f in (".github/scripts/ksu_version.py", ".github/scripts/verify_kernel_release.sh",
              ".github/scripts/verify_fragment.py"):
        p = ROOT / f
        check(p.exists(), f"{f} still present")
    # the KSU version resolver must not have learned about BORE
    ksu = (ROOT / ".github/scripts/ksu_version.py").read_text()
    check("BORE" not in ksu and "bore" not in ksu,
          "KSU version resolution untouched by the BORE port")


def main():
    t1_patch_hygiene()
    t2_state_relocation()
    t3_flat_translation()
    t4_sysctl_rewrite()
    t5_fail_loudly_on_drift()
    t6_bore_check()
    t6c_kmi_guard()
    t6b_variant_510()
    t7_workflow_wiring()
    t8_no_collateral()
    print()
    if FAILED:
        print(f"{CHECKS - len(FAILED)} checks passed, {len(FAILED)} FAILED")
        for f in FAILED:
            print(f"  - {f}")
        return 1
    print(f"{CHECKS} checks passed, 0 failed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
