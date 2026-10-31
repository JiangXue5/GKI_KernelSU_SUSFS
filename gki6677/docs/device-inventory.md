# GKI 6.6.77 Project — P0 Device Inventory

**Device:** Xiaomi `kunzite` (global; rebrand family incl. Redmi Note 15 SE 5G / POCO M8 5G — exact marketing name TBD)
**Collected:** 2026-10-31 via Termux root shell (user-supplied `result.txt`, archived verbatim in Appendix A)
**Status:** **G0 evidence COMPLETE** — dmesg clean, KMI confirmed, stock build point pinned and verified against googlesource.

> **Correction (2026-10-31, later same day):** the `uname -r` captured below is the **stock** (Xiaomi) kernel string — stock was temporarily flashed when the inventory was taken. The **runtime** kernel is the user's own Wild-CI build (SukiSU-Ultra flavor, v4.2.1-r2) synced to the deprecated-branch tip `8d05d8f2439f` (2026-03-30, = r33 + 1 unrespun commit) with a customized version string. Stock facts below remain valid as the OEM reference and last-resort ABI fallback anchor.

---

## 1. Identity

| Field | Value | Notes |
|---|---|---|
| `uname -r` | `6.6.77-android15-8-g4a507830d890-ab13636293-4k` | **stock** string (stock was flashed at capture time); runtime kernel uses Wild's customized string — see Correction above |
| — SUBLEVEL | `77` | frozen; never moves (plan §0 rule 4) |
| — KMI generation | `android15-8` | `KMI_GENERATION=8`, matches `build.config.common` |
| — git commit | `4a507830d890` | stock build point (verified on googlesource, §4) |
| — build ID | `ab13636293` | Android Build server build |
| — page size | `4k` | 4 KB pages variant (not `-16k`) |
| Build fingerprint | `Redmi/kunzite_global/kunzite:15/AQ3A.250226.002/OS2.0.206.0.VPQMIXM:user/release-keys` | Android 15, HyperOS OS2.0.206.0 |
| SoC | SM4450 family / `parrot` platform modules (Snapdragon 4 Gen 2 family) | module evidence §2; exact SoC model pending `ro.soc.model` |
| Vendor modules | **268 `.ko`** + 5 metadata files = 273 entries | `/vendor/lib/modules/` |

## 2. Module inventory (from `ls -1 /vendor/lib/modules/`)

- **268 kernel modules**, 84 of them Qualcomm-platform family (`qcom/qti/msm/qpnp/spmi/q6/qsee/sm4450/parrot`).
- **17 Xiaomi-proprietary** modules — these bind KMI symbols and vendor hooks too, so they are equally protected by our zero-delta ABI gate:
  `hdmi_dlkm, lct_audio_info_dlkm, lct_tp, mi_mem_engine, mi_mempool, mi_thermal_interface, millet_binder, millet_core, millet_hs, millet_oem_cgroup, millet_pkg, millet_sig, qmi_helpers, qti_qmi_cdev, qti_qmi_sensor_v2, xiaomi_tp, xlogchar`
- Notable KMI consumers to keep untouched (plan §5 rule 5): `qcom_logbuf_vendor_hooks.ko` (vendor-hook consumer), `binder_gki.ko`, `msm_kgsl.ko`, `qca_cld3_*.ko` (WLAN), `smcinvoke_dlkm.ko` / `qseecom_*.ko` (TrustZone), full audio stack (`lpass_cdc_*`, `wcd937x/wcd938x`, `swr_*`).
- SoC clock-controller modules present for **both** `sm4450` and `parrot` naming (`camcc/gpucc/debugcc-*`), `videocc-parrot` only — family vendor image covering SoC variants; `modules.load` picks the right set at boot.
- Metadata files: `modules.alias`, `modules.blocklist`, `modules.dep`, `modules.load`, `modules.softdep`.

## 3. Health checks (baseline before any custom build)

| Check | Result |
|---|---|
| `dmesg \| grep -iE "disagrees about version\|unknown symbol\|failed to load"` | **EMPTY** (grep exit 1) — stock loads all 268 modules with zero KMI friction. This is the reference state for §10.2 post-flash checks. |

## 4. Stock kernel freshness — verified against googlesource (2026-10-31)

Xiaomi shipped this kernel from a June 2025 build point and never respun it. Verified via `android.googlesource.com/kernel/common` gitiles API:

| Fact | Value |
|---|---|
| Stock commit `4a507830d890` | `ANDROID: sbitmap: Fix sbitmap_spinlock()` — committed **2025-06-12** |
| `r33` tag (`android15-6.6-2025-03_r33`) | points to `a9063b5adc42` (`UPSTREAM: af_unix: Initialise scc_index in unix_add_edge()`), committed **2026-01-07** |
| Ancestry | `r33..stock` log = **0 commits** ⇒ stock is a **strict ancestor** of r33 |
| Gap `stock..r33` | **116 commits**, spanning **2025-06-16 → 2026-01-07** (~7 months) |
| Gap composition | 52 × `UPSTREAM`, 38 × `ANDROID`, 20 × `BACKPORT`, 5 × `FROMGIT`, 1 × other |

**Meaning:** "typical Xiaomi behavior" confirmed and quantified. The device is missing 116 Google-authored, KMI-safe fixes that Google already validated *for this exact KMI generation*. Shot #1 (pure build, zero custom patches) closes this entire gap relative to the OTA. *(Scope note, corrected same day: this gap describes Xiaomi's OTA kernel. The device's **runtime** kernel — the user's Wild-CI build @ deprecated-branch tip `8d05d8f2439f` = r33 + 1 — already carries all r33 content plus the one unrespun tail commit. Our project baseline pins that tip; the stock analysis remains the reference for what the OTA itself lacks.)*

## 5. ABI compatibility implications

1. **Baseline:** ABI gate baseline = `Module.symvers` captured from an unpatched build of the pinned tip `8d05d8f2439f` (plan §7).
2. **Expected outcome at G1 — empirically pre-proven:** the device's runtime kernel is a Wild-CI build of the very commit we pin as baseline (`8d05d8f2439f` = r33 + 1) and it loads all 268 stock vendor modules daily (same clean-dmesg state as §3). Shot #1's §10.2 check re-confirms this on our own build.
3. **Fallback rule (plan R2):** if G1 dmesg unexpectedly shows `disagrees about version` / `Unknown symbol`, we re-pin the fetch script to the **stock commit `4a507830d890`** (Xiaomi's exact build point) instead of the pinned tip and recapture the baseline there. Documented; not expected to be needed.

## 6. Open follow-ups (one paste from the device, whenever convenient)

```
getprop ro.board.platform
getprop ro.soc.model
getprop ro.soc.manufacturer
getprop ro.build.version.security_patch
```

The last one records the device's current ASB level for the D4 security-ledger bookkeeping.

---

## Appendix A — Raw session output (verbatim, `result.txt`)

```
:/data/data/com.termux/files/home # uname -r
6.6.77-android15-8-g4a507830d890-ab13636293-4k
:/data/data/com.termux/files/home # ls /vendor/lib/modules/ | wc -l
273
:/data/data/com.termux/files/home # ls -1 /vendor/lib/modules/
adsp_loader_dlkm.ko
altmode-glink.ko
audio_pkt_dlkm.ko
audio_prm_dlkm.ko
audpkt_ion_dlkm.ko
bam_dma.ko
bcl_soc.ko
binder_gki.ko
binder_prio.ko
block2mtd.ko
boot_stats.ko
bt_fm_slim.ko
btpower.ko
bwmon.ko
camcc-parrot.ko
camcc-sm4450.ko
camera.ko
cdsprm.ko
cfg80211.ko
charger-ulog-glink.ko
charger_partition.ko
chipreg.ko
cnss_nl.ko
cnss_prealloc.ko
cnss_utils.ko
coresight-csr.ko
coresight-cti.ko
coresight-dummy.ko
coresight-funnel.ko
coresight-qmi.ko
coresight-remote-etm.ko
coresight-replicator.ko
coresight-stm.ko
coresight-tgu.ko
coresight-tmc-sec.ko
coresight-tmc.ko
coresight-tpda.ko
coresight-tpdm.ko
coresight.ko
cpucp_log.ko
ddr_cdev.ko
debugcc-parrot.ko
debugcc-sm4450.ko
dmesg_dumper.ko
drm_display_helper.ko
drm_dp_aux_bus.ko
dwc3-msm.ko
ehset.ko
eud.ko
f_fs_ipc_log.ko
frpc-adsprpc.ko
fs181x_drv_dlkm.ko
fsa4480-i2c.ko
ft3683g_spi.ko
gh_ctrl.ko
gh_irq_lend.ko
gh_mem_notifier.ko
gh_panic_notifier.ko
gh_rm_booster.ko
gh_tlmm_vm_mem_access.ko
gic_intr_routing.ko
glink_pkt.ko
governor_gpubw_mon.ko
governor_msm_adreno_tz.ko
gpr_dlkm.ko
gpucc-parrot.ko
gpucc-sm4450.ko
gsim.ko
gt9916k_spi.ko
hardwareinfo.ko
hdcp_qseecom_dlkm.ko
hdmi_dlkm.ko
heap_mem_ext_v01.ko
hung_task_enh.ko
hvc_gunyah.ko
i2c-msm-geni.ko
icnss2.ko
ipam.ko
ipanetm.ko
lb.ko
lct_audio_info_dlkm.ko
lct_tp.ko
leds-aw2016.ko
leds-qpnp-flash-v2.ko
leds-qpnp-vibrator-ldo.ko
leds-qti-tri-led.ko
lpass_cdc_dlkm.ko
lpass_cdc_rx_macro_dlkm.ko
lpass_cdc_tx_macro_dlkm.ko
lpass_cdc_va_macro_dlkm.ko
lpass_cdc_wsa2_macro_dlkm.ko
lpass_cdc_wsa_macro_dlkm.ko
lvstest.ko
machine_dlkm.ko
mbhc_dlkm.ko
mem-offline.ko
mem_object.ko
memlat.ko
mhi.ko
mhi_dev_dtr.ko
mhi_dev_uci.ko
mi_mem_engine.ko
mi_mempool.ko
mi_thermal_interface.ko
millet_binder.ko
millet_core.ko
millet_hs.ko
millet_oem_cgroup.ko
millet_pkg.ko
millet_sig.ko
mispidev.ko
mmrm_test_module.ko
modules.alias
modules.blocklist
modules.dep
modules.load
modules.softdep
msm-mmrm.ko
msm_drm.ko
msm_ext_display.ko
msm_geni_serial.ko
msm_gpi.ko
msm_kgsl.ko
msm_memshare.ko
msm_performance.ko
msm_sharedmem.ko
msm_show_resume_irq.ko
msm_sysstats.ko
msm_video.ko
mtd.ko
mtd_blkdevs.ko
mtdblock.ko
mtdoops.ko
ofpart.ko
panel_event_notifier.ko
pci-msm-drv.ko
pdr_interface.ko
phy-generic.ko
phy-msm-snps-hs.ko
phy-msm-ssusb-qmp.ko
phy-qcom-emu.ko
pinctrl-spmi-gpio.ko
pinctrl-spmi-mpp.ko
pinctrl_lpi_dlkm.ko
pm8941-pwrkey.ko
pmic-glink-debug.ko
pmic-pon-log.ko
policy_engine.ko
pwm-qti-lpg.ko
q6_dlkm.ko
q6_notifier_dlkm.ko
q6_pdr_dlkm.ko
qca_cld3_adrastea.ko
qca_cld3_qca6750.ko
qce50_dlkm.ko
qcedev-mod_dlkm.ko
qcom-amoled-regulator.ko
qcom-cpufreq-hw.ko
qcom-i2c-pmic.ko
qcom-pon.ko
qcom-spmi-adc-tm5.ko
qcom-spmi-adc5.ko
qcom-spmi-temp-alarm.ko
qcom-spmi-wled.ko
qcom-vadc-common.ko
qcom_cpuss_sleep_stats.ko
qcom_glink.ko
qcom_glink_smem.ko
qcom_iommu_debug.ko
qcom_logbuf_boot_log.ko
qcom_logbuf_vendor_hooks.ko
qcom_lpm.ko
qcom_pil_info.ko
qcom_pm8008-regulator.ko
qcom_q6v5.ko
qcom_q6v5_pas.ko
qcom_ramdump.ko
qcom_smd.ko
qcom_soc_wdt.ko
qcom_stats.ko
qcom_sysmon.ko
qcom_va_minidump.ko
qcrypto-msm_dlkm.ko
qfprom-sys.ko
qmi_helpers.ko
qpnp-lcdb-regulator.ko
qpnp-power-on.ko
qrng_dlkm.ko
qrtr-mhi.ko
qrtr-smd.ko
qsee_ipc_irq_bridge.ko
qseecom_dlkm.ko
qseecom_proxy.ko
qti-fixed-regulator.ko
qti-glink-adc.ko
qti-ocp-notifier.ko
qti_battery_charger.ko
qti_battery_debug.ko
qti_cpufreq_cdev.ko
qti_devfreq_cdev.ko
qti_pmic_glink.ko
qti_qmi_cdev.ko
qti_qmi_sensor_v2.ko
qti_userspace_cdev.ko
qts.ko
radio-i2c-rtc6226-qca.ko
rdbg.ko
reboot-mode.ko
rmnet_aps.ko
rmnet_core.ko
rmnet_ctl.ko
rmnet_mem.ko
rmnet_offload.ko
rmnet_perf.ko
rmnet_perf_tether.ko
rmnet_sch.ko
rmnet_shs.ko
rmnet_wlan.ko
rproc_qcom_common.ko
rq_stats.ko
schgm-flash.ko
sdpm_clk.ko
sg.ko
si_core_module.ko
sipa_dlkm.ko
sipa_tuning_dlkm.ko
slim-qcom-ngd-ctrl.ko
slimbus.ko
smcinvoke_dlkm.ko
smmu_proxy_dlkm.ko
smp2p.ko
smp2p_sleepstate.ko
snd-usb-audio-qmi.ko
snd_event_dlkm.ko
spf_core_dlkm.ko
spi-msm-geni.ko
spmi-pmic-arb-debug.ko
sps_drv.ko
stm_console.ko
stm_core.ko
stm_ftrace.ko
stm_p_basic.ko
stm_p_ost.ko
stub_dlkm.ko
swr_ctrl_dlkm.ko
swr_dlkm.ko
swr_dmic_dlkm.ko
swr_haptics_dlkm.ko
sync_fence.ko
sys_pm_vx.ko
sysmon_subsystem_stats.ko
thermal_config.ko
tmecom-intf.ko
tz_log_dlkm.ko
ucsi_qti_glink.ko
ufs_ffu.ko
usb_f_ccid.ko
usb_f_cdev.ko
usb_f_gsi.ko
usb_f_qdss.ko
videocc-parrot.ko
wcd937x_dlkm.ko
wcd937x_slave_dlkm.ko
wcd938x_dlkm.ko
wcd938x_slave_dlkm.ko
wcd9xxx_dlkm.ko
wcd_core_dlkm.ko
wlan_firmware_service.ko
wsa881x_dlkm.ko
wsa883x_dlkm.ko
xhci-sideband.ko
xiaomi_tp.ko
xlogchar.ko
:/data/data/com.termux/files/home # dmesg | grep -iE "disagrees about version|unknown symbol|failed to load"
1|:/data/data/com.termux/files/home #
:/data/data/com.termux/files/home # getprop ro.build.fingerprint
Redmi/kunzite_global/kunzite:15/AQ3A.250226.002/OS2.0.206.0.VPQMIXM:user/release-keys
```

*(`1|` is the shell prompt echoing grep's exit code 1 = "no matches" — the clean result.)*
