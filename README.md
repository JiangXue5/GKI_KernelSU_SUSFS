# feature/patches — kernel feature patches (contributor guide)

**Repo:** `chandr1000/GKI_KernelSU_SUSFS` · **Branch:** `feature/patches` · **Status:** operative, boot-validated 2026-11-08

`PATCHES.yml` on this branch is **not documentation — it is the build input**. The kernel CI
on `main-chandr1000` parses it and applies whatever it says, in list order. If you edit it,
you are changing what gets flashed on real devices. This README tells you how the pipeline
consumes this branch and which mistakes have already been made here once, so you don't
repeat them. Each rule below is a past incident with a real run ID.

---

## 1. What lives on this branch

| path | role |
|---|---|
| `PATCHES.yml` | the operative manifest — single source of truth for what is enabled |
| `patches/<family>/NNNN-*.patch` | strict `git apply` diffs, one file per feature |
| `scripts/*.sh` | helper scripts for `kind: script` entries (fixups, SELinux injection) |
| `THIRD_PARTY_NOTICES.md` | upstream credits — keep it in sync when you vendor code |

There is **no workflow code here**. The runner (workflow steps, composite action
`.github/actions/feature-patches`, `abi-gate.sh`) lives on `main-chandr1000`.

**Branch topology:**

| ref | role |
|---|---|
| `main-chandr1000` | live CI: workflows, composite actions, ABI gate |
| `feature/patches` ← **this branch** | manifest + patch content, consumed via the `patches_ref` input |
| `gki6677` | android15-6.6 backport series (98 patches) — the environment the ABI tooling was originally built for |
| kernel source pin | android15-6.6 @ `8d05d8f2439f` (6.6.77, android15-2025-03) — the tree every diff is cut against |

---

## 2. How a build consumes this branch

```
dispatch (main.yml)
 └─ build.yml inputs:
      patches_ref   branch (default feature/patches) or pinned SHA for reproducible builds
      patches       default | off | comma-list of ids to FORCE-ENABLE (never disables!)
      abi_gate      warn | enforce | +fail-new | off
      ├─ fetch kernel tree @ pin → apply workflow patches (KSU hooks, SUSFS,
      │  DroidSpaces sysvipc KABI fix, …) — these run BEFORE this branch's patches
      ├─ LEG A: pristine tree (no feature patches) → build → Module.symvers
      │        (ABI-gate baseline; skipped when abi_gate=off)
      ├─ LEG B: the applier parses PATCHES.yml
      │        → kernel-version gate: entries' `kernels` are matched against
      │          VERSION/PATCHLEVEL read from the tree's own Makefile (not dispatch inputs)
      │        → depends_on validated at parse time
      │        → per entry: strict `git apply --check` then `git apply`
      │          (failure: best_effort=false ⇒ red build · true ⇒ warning + skip)
      │        → `config:` entries emitted into the set-kernel-config step
      │        → build → Module.symvers
      └─ abi-gate.sh: diff LEG A vs LEG B
           existing symbols zero-delta policy · sentinels: module_layout,
           struct_module, __this_module · verdict per abi_gate mode
```

Key consequences:

- **A disabled entry cannot be re-enabled from the dispatch input.** The `patches` input
  only *force-enables*. To disable a feature you must flip `enabled: false` in
  `PATCHES.yml` and **commit** it (Rule 6).
- **List order = apply order.** Entries that consume symbols from other entries must be
  listed after their provider, and declare `depends_on`.
- **Patches never touch defconfig.** All feature config goes through the manifest's
  `config:` field — that is the only supported path.

---

## 3. PATCHES.yml anatomy

```yaml
patches:
  - id: governor-vorpal              # stable id — referenced by depends_on & force-enable
    enabled: true                    # flip + COMMIT to disable (Rule 6)
    kind: patch                      # patch | script
    patch: patches/vorpal/0001-…patch
    kernels: ["5.15", "6.1", "6.6", "6.12"]   # gated on the tree's own Makefile
    depends_on: []                   # ids that must be applied first
    best_effort: false               # false ⇒ apply failure = red build
    config: [CONFIG_CPU_FREQ_GOV_VORPAL=y]    # emitted into set-kernel-config
    provides: [sched_gaming_active, …]        # symbols this entry defines
    title / author / port            # attribution (port = upstream commit refs)
    notes: >                         # the entry's incident log — keep it current
```

Semantics you must respect:

- `depends_on`: a disabled **or failed** dependency auto-skips its dependents *loudly*
  (visible in the step summary). Example: `fair-gaming-bias` depends on `bore-scheduler`,
  so disabling BORE also disables the gaming bias — intended behavior, not a fault.
- `provides` + `depends_on` are how symbol-sharing works: the Vorpal shim
  (`rfx_gki510_compat.c`) is the *sole definer* of `sched_gaming_active`; Bara-no-Seidou
  and the fair.c bias both consume it. Disabling Vorpal silently removes that symbol from
  the tree — dependents must skip, not break.
- Mutually exclusive entries exist: `bore-scheduler` (5.9.6 generation) vs
  `bore-scheduler-66-510` (5.1.0 generation). Only one may be enabled; flipping is an
  A/B done **in the manifest**, there is no dispatch knob.
- `notes` is where the war stories live (incident run IDs, KABI analysis, anchor
  provenance). When you learn something hard-won about your entry, write it there — the
  next contributor will only read the manifest.

---

## 4. The rules — each one is a past incident

### Rule 1 — Never widen an ABI-exported struct
`CONFIG_KSM=y` opened an `#ifdef CONFIG_KSM` block **inside `struct mm_struct`**
(`include/linux/mm_types.h` @ pin, lines 981–997, adds KSM accounting fields). `mm_struct`
is transitively reachable from ~65% of the GKI export table → **5,965 of 9,082 symbols
drifted**, including the `module_layout` canary (`0x4e276f37` → `0x676ffd21`). The device
enforces MODVERSIONS → *every* stock vendor module rejected at first-stage init ("disagrees
about version of symbol module_layout", UFS stack included) → init timed out →
"Attempted to kill init" panic ~10.3 s, no boot animation, no pstore. **Silent, total
no-boot from one config line.** The same class has happened from a raw struct field edit:
BORE's `on_rq` hunk in `sched_entity` was genksyms-visible and its delta propagated to
`module_layout` — the original kunzite boot panic (dmesg-ramoops-0 captured 2026-11-07).

If a struct field must change: use an `ANDROID_KABI_RESERVE` slot (see Rule 3), or hide
the change from genksyms with a `__GENKSYMS__` shield, and record the reasoning in the
manifest `notes`.

### Rule 2 — Initializer expressions move CRCs too
genksyms hashes **initializer token streams**, not just types. BORE changed one exported
symbol's initializer (`sysctl_sched_base_slice = 750000ULL` → `= nsecs_per_tick`) and one
`SCHED_FEAT()` entry in `kernel/sched/features.h` (which expands into the initializer
arrays `sched_feat_names[]` / `sched_feat_keys[]`) — that alone is a deterministic
3-symbol delta in every BORE-applied run. Those three are scheduler-internal data symbols
and benign for vendor modules, but they still red a zero-delta gate. **Any feature cost
must be exactly known and documented** (see §5), never "probably harmless".

### Rule 3 — Know the KABI slot map before you touch `task_struct` / `sched_entity`
At the time the feature applier runs, the DroidSpaces sysvipc KABI fix has **already**
converted `ANDROID_KABI_RESERVE(6)/(7)/(8)` of `task_struct` into
`#ifdef CONFIG_SYSVIPC ANDROID_KABI_USE/_REPLACE` — a hunk whose pre-image anchors on
those reserve lines no longer exists and fails, even though it applied cleanly against the
pristine base (incident run 42292466832). Current slot map:

| struct | slots |
|---|---|
| `task_struct` | 1/2 BORE `group_burst` · 3/4/5 free · 6/7/8 DroidSpaces sysvipc |
| `sched_entity` | 1–4 BORE |

Take free slots only, and keep your hunk's pre/post-image **byte-identical against both
the pristine base and the runtime tree** so one hunk serves both.

### Rule 4 — `git apply` is strict: anchor hunks defensively
The applier uses strict `git apply --check` then `git apply`: hunks match **only at their
stated line**, no fuzz, no offset search, and insertions need context on **both** sides —
EOF appends included. Never EOF-anchor: the root-setup step appends
`obj-$(CONFIG_KSU) += kernelsu/` to the EOF region of `drivers/Makefile` before your hunk
runs, and your EOF-anchored hunk then rejects (the root cause of the run 42248382967
cascade). Anchor insertions **between stable neighbors** (e.g. between `build_policy` and
`build_utility`), and keep Kconfig inserts inside the `menu`/`endif` block. On failure the
applier collects the `.rej`/`.log` files as CI artifacts — read them instead of guessing.

### Rule 5 — The runtime tree ≠ your base: verify the pre-image survives both
Diffs are cut against the recorded base (`series.base` = pristine 6.6.77 @ pin) but apply
to a tree that already carries workflow patches. A hunk may be pristine-green and
runtime-red. Test both, and when a fixup lands (include order, decl hoists, re-anchors),
**re-generate the whole patch** rather than stacking fuzz — a regen from a stale source
snapshot has already re-broken a fixed file once (incident run 42300760345, re-land of
`1f085491`).

### Rule 6 — Enablement is manifest-only and commit-only
- Disabling a feature = flip `enabled: false` in `PATCHES.yml` + a proper commit.
  The workflow `patches` input **cannot disable** anything.
- **Web UI quick-edits do not survive re-lands.** A "Disable BORE temporarily" edit was
  erased when a later mbox series was applied onto a reset tip — two A/B runs were
  analyzed under the false belief BORE was off (web edit `2695771`, no longer in history).
  After any mbox re-land, verify the branch tip blob is what you think it is.
- The kernel banner is **not** a feature indicator (the `-bore` suffix was removed from
  it). The truth about what was applied is the run's config-enumeration step
  (`CONFIG_SCHED_BORE=y` present or absent) and the step summary's applied/selected lines.

### Rule 7 — Every `config:` entry needs proof, not folklore
Before adding a config entry, verify **both**:
1. **Stock resolution** — pristine `arch/arm64/configs/gki_defconfig` @ pin, plus a
   built-kernel IKCONFIG capture. `CONFIG_DMA_CMA=y` was believed to be a structural flip
   and recorded as such in the manifest — stock is already `=y` (line 748), so the removal
   was a no-op and the note's attribution was wrong for a week.
2. **genksyms visibility** — a flip from stock `=n` that adds fields to an exported struct
   is forbidden (that is the Rule 1 KSM flood). Entries that are stock no-ops
   (`SUSPEND`, `COMPACTION`, `PSI`, `UCLAMP*`, … on this tree) or genksyms-type-silent are
   fine, but they must be *verified* as such, not assumed.
3. **Runtime reachability** — `CONFIG_TRANSPARENT_HUGEPAGE=y` is a no-op on devices whose
   cmdline carries `transparent_hugepage=never`. A config that cannot take effect at
   runtime is dead weight that still has to be re-audited forever.

### Rule 8 — Compile hygiene: include what you use, anchor your Makefile lines
Three separate rounds of breakage came from TUs compiling "via transitive-include luck":
the sched-family TUs need `cputime.h` hoisted **above** `sched.h` (fair.c order), and a
regen that silently dropped that include broke the build three patches later. Under
`-Werror` there is no luck. Same for Makefile inserts: keep them anchored between stable
neighbors so an earlier patch's failure cannot cascade into yours (run 42248382967).

### Rule 9 — Green ≠ applied, green ≠ boots
- A `best_effort: true` entry that warn+skips produces a **green build without the
  feature**. The fair.c gaming-bias anchors were cut against pre-EEVDF shapes that do not
  exist on android15-6.6 — the old injection step *never applied on this base* while
  builds stayed green the entire time. Read the step summary's applied/skipped lines on every
  run; expect the `applied N/M` line to match your intent.
- The decisive experiment is a **device boot**. CI passing with zero CRC deltas is
  necessary, not sufficient. After flashing:
  ```
  dmesg | grep -i "disagrees about version"   # must be empty
  cat /proc/modules | wc -l                   # compare against the known-good baseline (440)
  cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors
  ```
  and capture pstore/ramoops either way — it is armed (`0x200000@0x80D00000`), but console
  ramoops only surfaces content from the *previous* boot, so a failing boot without
  pstore output means the panic killed ramoops too, not that ramoops is broken.

---

## 5. The known ABI ledger (6.6 family, as of 2026-11-08)

| entry | enabled | measured CRC cost vs pristine baseline |
|---|---|---|
| `governor-reflex` | ✅ | **0** |
| `governor-vorpal` (+ shim) | ✅ | **0** |
| `governor-bara-no-seidou` | ✅ | **0** |
| `momentomoix-driver` (+ `momentomoix-selinux`) | ✅ | **0** after D18 (KSM/DMA_CMA removed from its config block) |
| `fair-gaming-bias` | ✅ | **0** — currently loud-skips: `depends_on` BORE, which is disabled |
| `bore-scheduler` (5.9.6) | ❌ disabled | exactly **3** data symbols when on: `sched_feat_keys`, `sched_feat_names`, `sysctl_sched_base_slice`; `module_layout` untouched |
| `bore-scheduler-66-510` (5.1.0) | ❌ | **unknown** — manifest A/B warning: audit its sched.h hunks for raw struct edits *before* enabling |

Baseline reference: 9,082 symbols; pristine `module_layout` = `0x4e276f37`. The
known-good state — manifest 5/12 applied (the three governors + momx driver/selinux,
BORE family skipped, `fair-gaming-bias` loud-skipped), `CRC deltas: 0 missing: 0
new: 0`, gate PASS, device boot PASS on Kunzite QRD with 440 vendor modules live, zero
version disagreements, all three governors registered, momx operational, KSM absent —
is frozen and archived by the maintainer as the device diff reference.

**Re-enabling BORE later:** its 3-symbol cost is documented and `module_layout` stays
intact, so vendor modules remain loadable — but the currently boot-validated state is
BORE-off. A BORE-on kernel must get its own boot A/B before daily use, and enabling BORE
re-enables `fair-gaming-bias` with it.

---

## 6. Pre-flight checklist (before you push)

**ABI safety**
- [ ] No field added/removed/re-typed in any struct reachable from the export table
      (`mm_types.h`, `sched.h`, `device.h`, `netdevice.h`, `skbuff.h`, …) — or it is in a
      KABI reserve slot / `__GENKSYMS__`-shielded with the rationale in `notes`
- [ ] No exported symbol's initializer changed, and no initializer-array header touched
      (`features.h`-style), unless the delta is counted in §5's ledger and in `notes`
- [ ] `module_layout`, `struct_module`, `__this_module` cannot appear in any delta —
      if they do, do not ship

**Patch mechanics**
- [ ] Every hunk has context on both sides; nothing EOF-anchored; Makefile/Kconfig inserts
      anchored between stable neighbors
- [ ] Pre-image lines are byte-identical against the pristine base **and** the runtime
      (post-workflow-patches) tree; no `ANDROID_KABI_RESERVE(6)/(7)/(8)` in task_struct
      pre-images
- [ ] `#include`s self-sufficient (cputime.h-before-sched.h order for sched TUs); compiles
      under `-Werror` without transitive luck

**Manifest**
- [ ] `kernels` matches the tree the patch targets (gated from the tree's Makefile)
- [ ] `depends_on`/`provides` correct; mutually exclusive families left exclusive
- [ ] `config:` entries verified per Rule 7 (stock resolution + genksyms visibility +
      runtime reachability)
- [ ] `notes` updated — including what you measured, not just what you changed
- [ ] One commit per feature; disabling/flip is its own commit, never a drive-by hunk

**Validation**
- [ ] CI run in `abi_gate=warn`: expect `CRC deltas: 0` for new features; step summary
      `applied N/M` matches intent; no silent warn+skips of things you meant to enable
- [ ] Device boot test + the four Rule 9 commands; archive dmesg/modules capture next to
      the known-good baseline

---

## 7. Attribution & licensing

Every vendored file keeps its original copyright header **byte-for-byte**, and original
commit subjects are quoted verbatim; full credits in `THIRD_PARTY_NOTICES.md`. Series
license: GPL-2.0. When you vendor or port code, add the upstream author + commit refs to
your entry's `author`/`port` fields and to the notices file — no exceptions.

## 8. Deeper background

The full ABI/KABI forensics (CRC mechanics, run-by-run evidence, gate design rationale)
and the flood-era analysis are maintained separately by the maintainer; the distilled
lessons are exactly the rules above. If you need the underlying evidence for a decision,
ask for it — do not reverse-engineer it from run logs. The authoritative per-entry history
is the `notes` field of each `PATCHES.yml` entry; keep it that way.
