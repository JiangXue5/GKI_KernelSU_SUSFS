#!/usr/bin/env python3
"""
bore_compat_matrix.py -- 6.6-family pin-matrix verifier for the wide-compat
BORE patch set (plan: BORE-6.6-family-compat, 2026-11-11).

For every GKI android15-6.6 pin (release tags + surviving release branches)
it assembles the 11 stock files the BORE series touches and runs:

  stage A  `git apply --check` of the CURRENT vendored patch
           -> expectation table reproduces the failure eras from the
              2026-11-10 run logs (proves the harness is faithful)
  stage B  `git apply --check` of the UNIFIED core patch  -> expect PASS
  stage C  apply core, then run the real scripts/bore_compat_apply.sh
           (probe + micro-patch ladder + post-checks)   -> expect PASS
  stage D  post-apply sanity greps (BORE markers, KABI slots 3/4)

Result: markdown matrix + nonzero exit on any stage B/C/D failure.
"""
import json, os, re, shutil, subprocess, sys, time, urllib.request, base64

GS = 'https://android.googlesource.com/kernel/common'
FILES = {
    'kernel/fork.c': 'kernel_fork.c',
    'include/linux/sched.h': 'include_linux_sched.h',
    'kernel/sched/fair.c': 'kernel_sched_fair.c',
    'kernel/sched/core.c': 'kernel_sched_core.c',
    'kernel/sched/debug.c': 'kernel_sched_debug.c',
    'kernel/sched/features.h': 'kernel_sched_features.h',
    'kernel/sched/sched.h': 'kernel_sched_sched.h',
    'kernel/sched/Makefile': 'kernel_sched_Makefile',
    'init/Kconfig': 'init_Kconfig',
    'kernel/Kconfig.hz': 'kernel_Kconfig.hz',
    'scripts/setlocalversion': 'scripts_setlocalversion',
}
CACHE = '/tmp/pins'
OUT = '/home/z/my-project/download/bore-66-compat'
CORE = f'{OUT}/patches/bore/0001-linux6.6-gki-bore-5.9.6.patch'
CUR  = '/home/z/my-project/GKI_KernelSU_SUSFS/patches/bore/0001-linux6.6.67-gki-bore-5.9.6.patch'
SCRIPT = f'{OUT}/scripts/bore_compat_apply.sh'

TAG_PINS = [46, 50, 56, 57, 58, 66, 76, 77, 82, 87, 89, 92, 98, 100, 102, 111,
            116, 118, 119, 123, 127, 129, 138, 139, 142, 143, 144]
# NOTE: android15-6.6-2024-0X-exp branches are deliberately NOT in the matrix:
# they carry experimental pre-ASB content that differs from the released
# android15-2024-XX pins at the same sublevel (e.g. their 6.6.30 fair.c does
# not match the released 2024-07 tree, for which the run logs prove the
# 750-form hunk applied).
BRANCH_PINS = ['android15-6.6-2025-09', 'android15-6.6-2025-10',
               'android15-6.6-2026-01', 'android15-6.6-2026-04',
               'android15-6.6-2026-07', 'android15-6.6-2026-10',
               'android15-6.6-lts']

def fetch(ref, repo_file, dst):
    url = f'{GS}/+/{ref}/{repo_file}?format=TEXT'
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    for attempt in (1, 2):
        try:
            with urllib.request.urlopen(url, timeout=30) as r:
                data = base64.b64decode(r.read())
            if data[:2] not in (b'//', b'/*') and b'Error' in data[:200]:
                return False
            if not data:
                return False
            open(dst, 'wb').write(data)
            return True
        except Exception:
            time.sleep(0.5)
    return False

def pin_ref(p):
    if isinstance(p, int):
        return f'refs/tags/android15-6.6.{p}_r00'
    return f'refs/heads/{p}'

def pin_name(p):
    return f'6.6.{p}' if isinstance(p, int) else p.replace('android15-6.6', 'branch')

def expected_current(p):
    """Era expectations for the CURRENT vendored patch, from the run logs.
    Note: the KABI slot-1/2 consumption (dmabuf_info/user_dumpable) and the
    fork.c dma-buf.h include are on the RELEASE BRANCHES from 2025-08 and
    additionally on the r00 TAGS from 6.6.102 onward; the 6.6.92/98/100 tags
    still carry the pristine slots 1/2."""
    if isinstance(p, int):
        if p <= 58:  return {'kernel/fork.c', 'scripts/setlocalversion'}
        if p <= 89:  return set()
        if p <= 100: return {'kernel/sched/fair.c'}
        return {'include/linux/sched.h', 'kernel/fork.c', 'kernel/sched/fair.c'}
    return {'include/linux/sched.h', 'kernel/fork.c', 'kernel/sched/fair.c'}

def git_apply_check(patch, tree):
    r = subprocess.run(['git', 'apply', '--check', patch], cwd=tree,
                       capture_output=True, text=True)
    txt = (r.stdout or '') + (r.stderr or '')
    bad = sorted(set(re.findall(r'error: patch failed: ([^:]+):', txt)))
    return r.returncode == 0, txt, bad

def build_tree(pin, path):
    shutil.rmtree(path, ignore_errors=True)
    os.makedirs(path)
    ref = pin_ref(pin)
    ok = True
    for repo_file, fname in FILES.items():
        dst = os.path.join(CACHE, pin_name(pin), fname)
        if not os.path.exists(dst):
            ok = fetch(ref, repo_file, dst) and ok
        if not os.path.exists(dst):
            print(f'  FETCH-FAIL {pin_name(pin)} {repo_file}')
            return False
        d = os.path.join(path, repo_file)
        os.makedirs(os.path.dirname(d), exist_ok=True)
        shutil.copy(dst, d)
        if repo_file == 'scripts/setlocalversion':
            os.chmod(d, 0o755)  # real trees carry 100755; tag fetches lose the bit
    subprocess.run(['git', 'init', '-q'], cwd=path, check=True)
    return ok

def main():
    only = sys.argv[1:] or None
    pins = TAG_PINS + BRANCH_PINS
    if only:
        pins = [p for p in pins if pin_name(p) in only or str(p) in only]
    rows, failures = [], []
    for p in pins:
        name = pin_name(p)
        tree = f'/tmp/matrix/{name}'
        print(f'== {name} ==')
        if not build_tree(p, tree):
            rows.append((name, 'FETCH-FAIL', '-', '-', '-'))
            failures.append((name, 'fetch failed'))
            continue
        # stage A: current vendored patch
        okA, _, badA = git_apply_check(CUR, tree)
        expA = expected_current(p)
        matchA = 'OK' if set(badA) == expA else 'MISMATCH'
        # stage B: unified core
        okB, _, badB = git_apply_check(CORE, tree)
        # stage C: apply core + compat script
        okC = False; clog = ''
        if okB:
            r = subprocess.run(['git', 'apply', CORE], cwd=tree, capture_output=True, text=True)
            if r.returncode == 0:
                r2 = subprocess.run(['bash', SCRIPT, tree], capture_output=True, text=True)
                okC = r2.returncode == 0
                clog = (r2.stdout + r2.stderr)[-400:]
            else:
                clog = r.stderr[-400:]
        # stage D: sanity greps
        okD = False
        if okC:
            fair = open(f'{tree}/kernel/sched/fair.c').read()
            sch = open(f'{tree}/include/linux/sched.h').read()
            okD = ('sysctl_sched_min_base_slice' in fair
                   and 'struct sched_burst_cache group_burst;' in sch
                   and 'ANDROID_KABI_RESERVE(1);' in sch
                   and bool(re.search(r'_ANDROID_KABI_REPLACE\(\n\t\tANDROID_KABI_RESERVE\(3\);', sch)))
        verdict = 'PASS' if (matchA == 'OK' and okB and okC and okD) else 'FAIL'
        rows.append((name,
                     f'A(current)={"green" if okA else "red:" + ",".join(badA)}{"~" if matchA!="OK" else ""}',
                     f'B(core)={"green" if okB else "red:" + ",".join(badB)}',
                     f'C(compat)={"green" if okC else "red"}',
                     f'D(post)={"green" if okD else "red"}'))
        if verdict == 'FAIL':
            failures.append((name, clog or badB))
        print(f'   A:{matchA} B:{okB} C:{okC} D:{okD}')

    # report
    rpt = ['# BORE 6.6 wide-compat pin matrix', '',
           f'pins tested: {len(rows)}; failures: {len(failures)}', '',
           '| pin | A vendored (expect=logs) | B unified core | C compat ladder | D post-checks |',
           '|---|---|---|---|---|']
    for r in rows:
        rpt.append('| ' + ' | '.join(str(x) for x in r) + ' |')
    rpt += ['', '## failures', '']
    for name, info in failures:
        rpt.append(f'### {name}\n```\n{info}\n```\n')
    os.makedirs(f'{OUT}/verify', exist_ok=True)
    open(f'{OUT}/verify/bore-compat-matrix.md', 'w').write('\n'.join(rpt) + '\n')
    print('\n'.join(rpt[:6]))
    print(f'report: {OUT}/verify/bore-compat-matrix.md')
    sys.exit(1 if failures else 0)

if __name__ == '__main__':
    main()
