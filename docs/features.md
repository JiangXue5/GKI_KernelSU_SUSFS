# Kernel Features - Documentation Index

Per-feature documentation for the GKI2 kernels built from this repository.

---

## Root Implementations

Kernel-based su and root access management for Android.

| Root Flavor | Description | Source |
| ------------- | ------------- | -------- |
| KernelSU | Original implementation by [tiann](https://github.com/tiann) — the foundation from which all other variants are derived. | [tiann/KernelSU](https://github.com/tiann/KernelSU) |
| KernelSU-Next | Created by [rifsxd](https://github.com/rifsxd). SUSFS-integrated builds sourced from pershoot. | [KernelSU-Next/KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next) (upstream) · [pershoot/KernelSU-Next](https://github.com/pershoot/KernelSU-Next) (SUSFS-integrated) |
| BakaSU (formerly ReSukiSU) | Fork of SukiSU Ultra/KernelSU with the goal of enhancing stability and security; also has its own SUSFS-integrated support, in addition to multi-support for other KSU fork managers. | [Baka-SU/BakaSU](https://github.com/Baka-SU/BakaSU) |
| FinaSU | KernelSU fork with built-in SUSFS support (kernel-side supercall dispatch, selinux sid tracking); manager with FolkZygisk. | [LyraVoid/FinaSU](https://github.com/LyraVoid/FinaSU) |
| SukiSU Ultra | Fork of KernelSU with built-in SUSFS support, KPM support, and more. | [SukiSU Ultra](https://github.com/sukisu-ultra/sukisu-ultra) |
| KowSU | Fork of KernelSU maintained by [KOWX712](https://github.com/KOWX712). | [KowSU](https://github.com/KOWX712/KernelSU) |

---

## Root Hiding

| Feature | Description | Source |
| --------- | ------------- | -------- |
| susfs4ksu | Root-hiding add-on for KernelSU using kernel patches and a userspace module. Recommended module: [sidex15/susfs4ksu-module](https://github.com/sidex15/susfs4ksu-module). | [simonpunk/susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu) |
| Ptrace Leak Fix | Fixes ptrace info leak on kernels older than 5.16. Internal to root hiding. | [patch](https://github.com/WildKernels/kernel_patches/blob/main/gki_ptrace.patch) |
| Unicode Fix | Prevents path traversal via non-printable Unicode (experimental). Internal to root hiding. | [patch 6.1-](https://github.com/WildKernels/kernel_patches/blob/main/common/unicode_bypass_fix_6.1-.patch) · [patch 6.1+](https://github.com/WildKernels/kernel_patches/blob/main/common/unicode_bypass_fix_6.1+.patch) |

---

## Meta Module

| Module | Description | Source |
|--------|-------------|--------|
| NoMount | Metamodule providing mount-related functionality alongside root implementations. | [maxsteeel/nomount](https://github.com/maxsteeel/nomount) |
| Mountify | Globally mounted modules via OverlayFS. | [backslashxx/mountify](https://github.com/backslashxx/mountify) |

> [!NOTE]
> Only one is required if mounting modules.

<details>
<summary>Which one should I use?</summary>

- **NoMount** — recommended, bundled as `nomount-metamodule` in CI.
- **Mountify** — alternative OverlayFS approach, not bundled — install latest compatible module manually.

</details>

---

## Security

| Feature | Description | Source |
|---------|-------------|--------|
| Baseband Guard | Lightweight LSM blocking unauthorized writes to critical partitions and device nodes. | [vc-teahouse/Baseband-guard](https://github.com/vc-teahouse/Baseband-guard) |

---

## Networking

| Feature | Description | Source |
| --------- | ------------- | -------- |
| TCP Congestion Control | BBRv1, BBRv3, CUBIC, BIC, Westwood, HTCP | `CONFIG_TCP_CONG_BBR` / `CONFIG_TCP_CONG_CUBIC` etc |
| WireGuard | Built-in VPN support | `CONFIG_WIREGUARD` |
| IP Set / IPv6 NAT | Advanced firewall capabilities | `CONFIG_IP_SET` / `CONFIG_IP6_NF_NAT` |
| Conntrack / connmark | Connection marking for packet classification | `CONFIG_NF_CONNTRACK` / `CONFIG_NET_ACT_CONNMARK` |
| CIFS | SMB/CIFS network filesystem | `CONFIG_CIFS` |
| TTL Target | Network packet manipulation | `CONFIG_IP_NF_TARGET_TTL` / `CONFIG_IP6_NF_TARGET_HL` |

---

## Debugging, Tracing & BPF

| Feature | Description | Source |
|---------|-------------|--------|
| BTF / eBPF / FUSE-BPF | BPF Type Format, extended BPF, FUSE-BPF interaction | `CONFIG_DEBUG_INFO_BTF` / `CONFIG_BPF_SYSCALL` / `CONFIG_FUSE_BPF` |

---

## Performance

| Feature | Description | Source |
|---------|-------------|--------|
| NTSync | High-performance synchronization primitives compatible with Windows NT kernel API. | [WildKernels/kernel_patches](https://github.com/WildKernels/kernel_patches/tree/main/common/ntsync) |
| Performance Tuning | Kernel configuration and tuning options | [WildKernels/kernel_patches](https://github.com/WildKernels/kernel_patches/tree/main/common) |

---

## Container Runtime

| Feature | Description | Source |
|---------|-------------|--------|
| DroidSpaces-OSS | LXC-inspired container runtime for Android/Linux | [ravindu644/Droidspaces-OSS](https://github.com/ravindu644/Droidspaces-OSS) |

---

## Build summary

Every leg's persisted `<file_name>-BuildInfo` artifact lists the two dynamically
injected patch series with per-entry runtime verdicts — generated at run time
from repository/CI data (PATCHES.yml, series.conf, `gki<digits>` branch
discovery, applier verdicts); nothing is hardcoded:

| Section | Data source | Notes |
|---------|-------------|-------|
| Feature patches (manifest-driven) | `PATCHES.yml` on the `feature/patches` content ref (sidecar `feature-patches-verdict/v1`) | per-entry applied/skipped/failed verdicts; `features: off` renders a one-liner |
| Google upstream backport series | `series.conf` on the auto-discovered `gki<V><P><sublevel>` branch (sidecar `google-backport-series/v1`) | patches grouped by canonical category — **Security backports (ASB/CVE)**, **Stability & bug fixes**, **Maintenance & cleanups**, plus an *Other* catch-all for future batches |

The same data ships machine-readable: each sidecar JSON (also in the
`patch-apply-logs` artifact on failures) and a `features` block inside the
Verified Metadata JSON fence of every BuildInfo. Adding a patch to the
manifest or a `Batch C` line to `series.conf` updates the summary
automatically — no renderer changes.

---

> [!TIP]
> **Installation** — see [Installation Guide](installation.md).
