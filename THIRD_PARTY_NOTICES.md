# Third-Party Notices — GKI_KernelSU_SUSFS

> [!NOTE]
> This file lists third-party code fetched during CI and included in the build's output zip(s). None of it is vendored in this repo — each dependency is pulled fresh at build time and retains its own original license.

| Component | Upstream | License |
|-----------|----------|---------|
| Kernel Source | [kernel/common](https://android.googlesource.com/kernel/common) | GPL-2.0 |
| KernelSU | [tiann/KernelSU](https://github.com/tiann/KernelSU) | GPL-3.0 |
| KernelSU-Next | [KernelSU-Next/KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next) | GPL-3.0 |
| ReSukiSU | [ReSukiSU/ReSukiSU](https://github.com/ReSukiSU/ReSukiSU) | GPL-3.0 |
| SukiSU-Ultra | [SukiSU-Ultra/SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra) | GPL-3.0 |
| KowSU | [KOWX712/KernelSU](https://github.com/KOWX712/KernelSU) | GPL-3.0 |
| KSU-Next SUSFS | [pershoot/KernelSU-Next](https://github.com/pershoot/KernelSU-Next) | GPL-3.0 |
| susfs4ksu | [simonpunk/susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu) | GPL-3.0+ |
| NoMount | [maxsteeel/nomount](https://github.com/maxsteeel/nomount) | GPL-3.0 |
| kernel_patches | [WildKernels/kernel_patches](https://github.com/WildKernels/kernel_patches) | GPL-2.0 |
| Baseband Guard | [vc-teahouse/Baseband-guard](https://github.com/vc-teahouse/Baseband-guard) | GPL-2.0 |
| AnyKernel3 | [WildKernels/AnyKernel3](https://github.com/WildKernels/AnyKernel3) | BSD |
| magiskboot | [topjohnwu/Magisk](https://github.com/topjohnwu/Magisk) via AnyKernel3 | GPL-3.0 |
| DroidSpaces | [ravindu644/Droidspaces-OSS](https://github.com/ravindu644/Droidspaces-OSS) | GPL-3.0 |

<details>
<summary> About magiskboot binaries</summary>

`magiskboot` / `magiskpolicy` are prebuilt binaries bundled inside `AnyKernel3/tools/`. Source at [topjohnwu/Magisk](https://github.com/topjohnwu/Magisk) (GPL-3.0). They are not separate clones — shipped only via AnyKernel3.

</details>

## Vendored feature patches (`feature/patches` series)

> [!NOTE]
> Unlike the table above, the following **are vendored in this repo**
> (`.github/actions/{bore,governor,momentx}/`, `.github/scripts/bore*.py`,
> pointer file `PATCHES.yml`). Every original copyright header is preserved
> byte-for-byte and the original commit subjects are quoted in the series'
> commit messages. All GPL-2.0.

| Component | Author(s) | Upstream | License | Vendored at |
|-----------|-----------|----------|---------|-------------|
| BORE scheduler patches | Masahito Suzuki (firelzrd) | [firelzrd/bore-scheduler](https://github.com/firelzrd/bore-scheduler) | GPL-2.0 | `.github/actions/bore/patches/` |
| BORE KMI/KABI relocation scripts | TheWildJames (WildKernels) | [WildKernels/GKI_KernelSU_SUSFS](https://github.com/WildKernels/GKI_KernelSU_SUSFS) (`27cb8b3e`, `eba7eac4`, `c606cc2a`, `06488106`) | GPL-2.0 | `.github/scripts/bore*.py` |
| BORE composite action (version map, retry + git fallback) | TheWildJames (WildKernels) | WildKernels/GKI_KernelSU_SUSFS (`27cb8b3e` `feat(bore): BORE scheduler for all GKI families`) | GPL-2.0 | `.github/actions/bore/action.yml` |
| Reflex CPUFreq governor | Masahito Suzuki (firelzrd) | [firelzrd/reflex](https://github.com/firelzrd/reflex) — header: `Copyright (C) 2026 Masahito Suzuki` | GPL-2.0 | `.github/actions/governor/patches/reflex/` |
| Vorpal CPUFreq Governor v2.0 (Perfect Gaming & Thermal Edition) | Templar Dev (Steambot12) | via [kusonekoworld-max/MomenToMoiX-Kernel-GKI](https://github.com/kusonekoworld-max/MomenToMoiX-Kernel-GKI) — header: `Author: Templar Dev (Steambot12)` | GPL-2.0 | `.github/actions/governor/patches/vorpal/cpufreq_vorpal.c` |
| GKI compat shim (`rfx_gki510_compat.c`) | Nao-YM (GKI port artifact) | [Nao-YM/GKI_KernelSU_SUSFS](https://github.com/Nao-YM/GKI_KernelSU_SUSFS) (`a60fcf3f`) | GPL-2.0 | `.github/actions/governor/patches/vorpal/rfx_gki510_compat.c` |
| Bara-no-Seidou CPUFreq governor | kusonekoworld-max (koneko_dev) | MomenToMoiX-Kernel-GKI (intro `aeacdbf`, 2026-07-30) — header: `Copyright (C) 2026 kusonekoworld-max` | GPL-2.0 | `.github/actions/governor/patches/bara-no-seidou/` |
| fair.c gaming-mode bias (`sched_gaming_active`) | MomenToMoiX project (koneko_dev) | MomenToMoiX-Kernel-GKI | GPL-2.0 | `.github/actions/governor/action.yml` (fair.c step) |
| MomenToMoiX (Tenebrion) driver | koneko_dev | MomenToMoiX-Kernel-GKI | GPL-2.0 | `.github/actions/momentx/patches/tenebrion/MomenToMoiX.c` |
| Tenebrion SELinux rules | Kanagawa Yamada (LoggingNewMemory) — header: `Author: Kanagawa Yamada`, adapted from the SuiKernel pattern | MomenToMoiX-Kernel-GKI | GPL-2.0 | `.github/actions/momentx/patches/tenebrion/selinux.sh` |
| Composite-action packaging layer (governor / momentx) | Nao-YM | [Nao-YM/GKI_KernelSU_SUSFS](https://github.com/Nao-YM/GKI_KernelSU_SUSFS) (`a60fcf3f`, `f1c0fc5f`, `69a2d582`, `25ae398b`) | GPL-2.0 | `.github/actions/{governor,momentx}/action.yml` |

> [!IMPORTANT]
> If we have used your code and not credited you correctly, or have listed the wrong license, please let us know — open an issue or reach out and we'll fix it promptly. No omission is intentional; we want to credit everyone properly.
