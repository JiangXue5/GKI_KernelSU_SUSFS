# gki6677 — GKI 6.6.77 backport project

Backport Google's active `android15-6.6` patch stream onto the frozen
`6.6.77-android15-8` KMI generation: no KMI breakage, `SUBLEVEL` stays `77`,
`uname -r` keeps the `6.6.77-android15-8-g<hash>` prefix, all builds run on
GitHub Actions CI. Master plan: `GKI_6.6.77_Upgrade_Plan.md` v1.2 (2026-10-31).

## Baseline pin

| What | Value |
|---|---|
| Source | `android.googlesource.com/kernel/common` |
| Ref | `deprecated/android15-6.6-2025-03` |
| Commit | `8d05d8f2439f6a6659b324db458b27fb2f53bb50` (2026-03-30 = `r33` + 1 unrespun commit) |
| Fallback pin | tag `android15-6.6-2025-03_r33` = `a9063b5adc42` (2026-01-07) |
| Device | Xiaomi `kunzite` (SM4450 family, KMI `6.6-android15-8`, 268 vendor `.ko`) — see `docs/device-inventory.md` |

The device already daily-drives a build of the pinned commit with all stock
vendor modules loaded (clean dmesg) — the baseline choice is empirically
pre-proven, not theoretical.

## Layout (plan §2 — target state of this directory)

```
gki6677/
├── README.md                      # this file
├── series.conf                    # ordered quilt series (empty seed: pure = pinned tip)
├── config-fragment-6677.conf      # delta vs gki_defconfig (added when a delta is first needed)
├── patches/                       # 0001-*.patch, 0002-*.patch … (first batch: P3)
├── abi-baseline/
│   └── Module.symvers.baseline    # captured at G1 from an unpatched build of the pin
├── docs/
│   └── device-inventory.md        # P0/G0 evidence
└── scripts/                       # fetch-googlesource.sh, apply-series.sh,
                                   # abi-gate.sh, build-ak3.sh (landed, P1)
```

`../.github/workflows/gki-6677-backport.yml` and the four scripts are live
(P1). CI triggers: **push** to this branch touching the series/scripts
(primary — the workflow_dispatch UI only lists default-branch workflows, and
the WildKernels engine on `main-chandr1000` stays untouched), or
**workflow_dispatch** with an optional `release_tag` once the file also
lands on the default branch. Shot #1 (G1) runs in ABI **capture mode** and
its artifact `Module.symvers.baseline` must be committed to `abi-baseline/`
before any patch batch is gated. The WildKernels engine elsewhere in this
repo stays untouched and keeps serving the KernelSU/SUSFS flavor (plan §2,
P6).

## Rules every patch obeys (plan §5, short form)

1. The frozen KMI symbol list (`abi_gki_aarch64.stg` + `abi_gki_aarch64_qcom`)
   is the constitution — no signature, type or struct-layout change to any
   listed symbol.
2. Struct growth only via `ANDROID_KABI_RESERVE(n)` / `ANDROID_KABI_USE(n, …)`
   slots; no free slot ⇒ the patch is deferred and logged.
3. Prefer Google's own frozen-branch variant of a fix over upstream's raw one.
4. Vendor hooks (`android_vh_*` / `android_rvh_*`) are KMI too.
5. The gate decides: zero CRC delta vs `abi-baseline/Module.symvers.baseline`,
   no exceptions — a red gate never produces a flashable zip.

## How batches land (plan §3.4 / §10.7)

Patches authored by the assistant ship as one `git format-patch` mbox per
batch — cover letter first, then the commits — and are applied with:

```
git checkout gki6677 && git pull
git am -3 --empty=drop gki6677-<batch>-YYYYMMDD.patch
git push
```

`--empty=drop` (git ≥ 2.26) makes `git am` skip the cover letter message
instead of stopping on it with "Patch is empty".

Apply project mboxes on **this branch**, not on `main-chandr1000` — the
latter carries the untouched WildKernels engine for the daily-driver flavor.
