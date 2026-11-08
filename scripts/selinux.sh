#!/usr/bin/env bash
# SELinux rule injection for the Tenebrion module - v3 wrapper.
# The rules.c discovery + D4 KSU-flavor guard lived in the old momentx
# action step; as a `kind: script` manifest entry the script is
# self-contained (plan v3.0.0 SS3.3 #5). Body below is the original
# selinux.sh, byte-identical. Contract: $1 = TARGET_DIR (kernel tree root).
# Author: Kanagawa Yamada (adapted from the SuiKernel pattern).
set -euo pipefail
TARGET_DIR="${1:?usage: selinux.sh <target_dir>}"
cd "$TARGET_DIR"

# --- D4 discovery + guard (verbatim logic from the proven action step) ----
RULES_FILE=$(find -L drivers/kernelsu -type f -name "rules.c" 2>/dev/null | head -1 || true)
if [[ -z "$RULES_FILE" ]]; then
  # '|| true' matters: a no-match grep exits 1, and under
  # 'set -euo pipefail' the assignment would abort the script
  # before the warn+skip guard below is ever reached.
  RULES_FILE=$(grep -rl "ksu_allow" . --include="rules.c" 2>/dev/null | head -1 || true)
fi
if [[ -z "$RULES_FILE" ]]; then
  # D4 (plan): warn + skip instead of failing the job. The SELinux
  # rules need a KernelSU-family rules.c (ksu_allow table); on other
  # root flavors the MomenToMoiX driver still builds - manager-side
  # rules may then be needed for full function.
  echo "WARNING: no KernelSU-family rules.c found in this tree (root flavor without a ksu_allow table?); SKIPPING MomenToMoiX SELinux rules." >&2
  echo "         The MomenToMoiX driver is still built; manager-side rules may be needed for full function." >&2
  exit 0
fi
export SELINUX_RULES_C="$RULES_FILE"

# --- original selinux.sh body: byte-identical to the v3 original EXCEPT +1
# --- ksu_allow below (2026-11-08 kunzite AVC fix, see PATCHES.yml
# --- momentomoix-selinux notes) ------------
set -euo pipefail

if [[ -z "${SELINUX_RULES_C:-}" ]]; then
    echo "selinux.sh: ERROR — variabel SELINUX_RULES_C belum di-set oleh caller"
    exit 1
fi

if [[ ! -f "$SELINUX_RULES_C" ]]; then
    echo "selinux.sh: ERROR — $SELINUX_RULES_C tidak ditemukan"
    exit 1
fi

MARKER='rcu_assign_pointer(selinux_state.policy, pol);'

if ! grep -qF "$MARKER" "$SELINUX_RULES_C"; then
    echo "selinux.sh: ERROR — marker line tidak ditemukan di $SELINUX_RULES_C"
    exit 1
fi

if ! grep -q "ksu_allow" "$SELINUX_RULES_C"; then
    echo "selinux.sh: ERROR — fungsi ksu_allow tidak ditemukan di $SELINUX_RULES_C"
    exit 1
fi

BEFORE_LINES=$(wc -l < "$SELINUX_RULES_C")

echo "selinux.sh: Injecting Tenebrion SELinux rules ke $SELINUX_RULES_C..."

sed -i "/${MARKER//\//\\/}/i\\
    ksu_allow(db, \"kernel\", \"sysfs_leds\", \"dir\", \"search\");\\
    ksu_allow(db, \"kernel\", \"sysfs_leds\", \"dir\", \"getattr\");\\
    ksu_allow(db, \"kernel\", \"sysfs_leds\", \"file\", \"read\");\\
    ksu_allow(db, \"kernel\", \"sysfs_leds\", \"file\", \"open\");\\
    ksu_allow(db, \"kernel\", \"sysfs_leds\", \"file\", \"getattr\");\\
    ksu_allow(db, \"kernel\", \"sysfs_backlight\", \"dir\", \"search\");\\
    ksu_allow(db, \"kernel\", \"sysfs_backlight\", \"dir\", \"getattr\");\\
    ksu_allow(db, \"kernel\", \"sysfs_backlight\", \"file\", \"read\");\\
    ksu_allow(db, \"kernel\", \"sysfs_backlight\", \"file\", \"open\");\\
    ksu_allow(db, \"kernel\", \"sysfs_backlight\", \"file\", \"getattr\");\\
    ksu_allow(db, \"kernel\", \"sysfs_drm\", \"dir\", \"search\");\\
    ksu_allow(db, \"kernel\", \"sysfs_drm\", \"dir\", \"getattr\");\\
    ksu_allow(db, \"kernel\", \"sysfs_drm\", \"file\", \"read\");\\
    ksu_allow(db, \"kernel\", \"sysfs_drm\", \"file\", \"open\");\\
    ksu_allow(db, \"kernel\", \"sysfs_drm\", \"file\", \"getattr\");\\
    ksu_allow(db, \"kernel\", \"sysfs_type\", \"dir\", \"search\");\\
    ksu_allow(db, \"kernel\", \"sysfs_type\", \"dir\", \"getattr\");\\
    ksu_allow(db, \"kernel\", \"sysfs_type\", \"file\", \"read\");\\
    ksu_allow(db, \"kernel\", \"sysfs_type\", \"file\", \"open\");\\
    ksu_allow(db, \"kernel\", \"sysfs_type\", \"file\", \"getattr\");\\
    ksu_allow(db, \"kernel\", \"sysfs\", \"dir\", \"search\");\\
    ksu_allow(db, \"kernel\", \"sysfs\", \"dir\", \"getattr\");\\
    ksu_allow(db, \"kernel\", \"sysfs\", \"file\", \"read\");\\
    ksu_allow(db, \"kernel\", \"sysfs\", \"file\", \"write\");\\
    ksu_allow(db, \"kernel\", \"sysfs\", \"file\", \"open\");\\
    ksu_allow(db, \"kernel\", \"sysfs\", \"file\", \"getattr\");\\
    ksu_allow(db, \"kernel\", \"sysfs_devices_system_cpu\", \"file\", \"write\");\\
    ksu_allow(db, \"kernel\", \"cgroup\", \"dir\", \"search\");\\
    ksu_allow(db, \"kernel\", \"cgroup\", \"dir\", \"write\");\\
    ksu_allow(db, \"kernel\", \"cgroup\", \"dir\", \"getattr\");\\
    ksu_allow(db, \"kernel\", \"cgroup\", \"file\", \"read\");\\
    ksu_allow(db, \"kernel\", \"cgroup\", \"file\", \"write\");\\
    ksu_allow(db, \"kernel\", \"cgroup\", \"file\", \"open\");\\
    ksu_allow(db, \"kernel\", \"cgroup\", \"file\", \"getattr\");\\
    ksu_allow(db, \"kernel\", \"sysfs_memory\", \"dir\", \"search\");\\
    ksu_allow(db, \"kernel\", \"sysfs_memory\", \"dir\", \"getattr\");\\
    ksu_allow(db, \"kernel\", \"sysfs_memory\", \"file\", \"read\");\\
    ksu_allow(db, \"kernel\", \"sysfs_memory\", \"file\", \"write\");\\
    ksu_allow(db, \"kernel\", \"sysfs_memory\", \"file\", \"open\");\\
    ksu_allow(db, \"kernel\", \"sysfs_memory\", \"file\", \"getattr\");\\
    ksu_allow(db, \"kernel\", \"sysfs_thermal\", \"dir\", \"search\");\\
    ksu_allow(db, \"kernel\", \"sysfs_thermal\", \"dir\", \"getattr\");\\
    ksu_allow(db, \"kernel\", \"sysfs_thermal\", \"file\", \"read\");\\
    ksu_allow(db, \"kernel\", \"sysfs_thermal\", \"file\", \"open\");\\
    ksu_allow(db, \"kernel\", \"sysfs_thermal\", \"file\", \"getattr\");\\
    ksu_allow(db, \"kernel\", \"sysfs_battery_supply\", \"dir\", \"search\");\\
    ksu_allow(db, \"kernel\", \"sysfs_battery_supply\", \"dir\", \"getattr\");\\
    ksu_allow(db, \"kernel\", \"sysfs_battery_supply\", \"file\", \"read\");\\
    ksu_allow(db, \"kernel\", \"sysfs_battery_supply\", \"file\", \"open\");\\
    ksu_allow(db, \"kernel\", \"sysfs_battery_supply\", \"file\", \"getattr\");" \
    "$SELINUX_RULES_C"

AFTER_LINES=$(wc -l < "$SELINUX_RULES_C")

if [[ "$AFTER_LINES" -le "$BEFORE_LINES" ]]; then
    echo "selinux.sh: ERROR — injeksi GAGAL, jumlah baris tidak bertambah ($BEFORE_LINES → $AFTER_LINES)"
    exit 1
fi

echo "selinux.sh: ✅ Tenebrion SELinux rules berhasil di-inject ($BEFORE_LINES → $AFTER_LINES baris)"