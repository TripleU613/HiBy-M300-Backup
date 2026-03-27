#!/bin/bash
#
# HiBy M300 Full Restore Script
# QCM6125W (Trinket) - A/B device, UFS storage, UEFI fastboot
# Backup: v1.60+ OTA build 20250418, Magisk 30.7, Slot B
#
# IMPORTANT:
# - UEFI bootloader does NOT support flash writes. Must use fastbootd.
# - Fastbootd can only flash slotted partitions + super + a few others.
# - Non-slotted partitions (persist, modemst, nvdata, etc.) must be
#   flashed via adb+root (dd) after the device boots.
# - Modem image has 4096-byte sector FAT16 (required for UFS).
# - Factory reset (wipe) does NOT work in fastbootd. Use recovery.
#
# USAGE:
#   1. Boot device into fastboot (vol down + power, or 'adb reboot bootloader')
#   2. Run: bash flash_restore.sh [--full | --firmware-only | --partition NAME]
#   3. After reboot, run: bash flash_restore.sh --post-boot
#      to flash non-slotted partitions via adb root (dd).
#   4. Factory reset via recovery (vol up + power > wipe data).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FB="${FASTBOOT:-fastboot}"
ADB="${ADB:-adb}"

# --- Partition lists ---

# Slot B firmware (flashable via fastbootd)
SLOT_PARTS="xbl_b xbl_config_b rpm_b tz_b hyp_b modem_b bluetooth_b
  mdtpsecapp_b mdtp_b abl_b dsp_b keymaster_b boot_b cmnlib_b cmnlib64_b
  devcfg_b qupfw_b vbmeta_b dtbo_b imagefv_b uefisecapp_b recovery_b
  vbmeta_system_b"

# Non-slotted partitions that fastbootd CAN flash
FASTBOOTD_NONSLOT="misc ssd storsec vbmeta_system_a super"

# Non-slotted partitions that ONLY work via dd (adb root)
# Fastbootd returns "No such file or directory" for these
DD_ONLY_PARTS="persist modemst1 modemst2 fsg fsc keystore metadata splash
  devinfo dip apdp nvdata1 nvdata2 teedata cdt ddr secdata uefivarstore
  multiimgoem multiimgqti spunvm cateloader catefv catecontentfv toolsfv
  logfs limits qpdata1 qpdata2 frp"

# --- Helper functions ---

wait_for_fastboot() {
    echo "Waiting for fastboot device..."
    while ! $FB devices 2>/dev/null | grep -q fastboot; do sleep 1; done
    echo "Device found: $($FB devices | head -1)"
}

enter_fastbootd() {
    echo "Rebooting to fastbootd (userspace fastboot)..."
    $FB reboot fastboot 2>&1
    sleep 3
    while ! $FB devices 2>/dev/null | grep -q fastboot; do sleep 1; done
    local is_userspace
    is_userspace=$($FB getvar is-userspace 2>&1 | grep -o "yes\|no")
    if [ "$is_userspace" != "yes" ]; then
        echo "ERROR: Not in fastbootd. Cannot flash from bootloader fastboot."
        exit 1
    fi
    echo "In fastbootd - ready to flash."
}

flash_partition() {
    local name="$1"
    local img="$SCRIPT_DIR/${name}.img"
    if [ ! -f "$img" ]; then
        echo "  SKIP: $name (no image file)"
        return 1
    fi
    local size
    size=$(stat -c%s "$img" 2>/dev/null || stat -f%z "$img" 2>/dev/null)
    local size_mb=$((size / 1048576))
    echo ">> $name (${size_mb}MB)"
    if ! $FB flash "$name" "$img" 2>&1; then
        echo "  FAILED: $name"
        return 1
    fi
}

wait_for_adb_root() {
    echo "Waiting for device with adb root..."
    while ! $ADB devices 2>/dev/null | grep -q "device$"; do sleep 2; done
    echo "Device online. Checking root..."
    if ! $ADB shell su -c "id" 2>/dev/null | grep -q "uid=0"; then
        echo "ERROR: Root (su) not available. Install Magisk first, then re-run --post-boot."
        exit 1
    fi
    echo "Root confirmed."
}

dd_flash_partition() {
    local name="$1"
    local img="$SCRIPT_DIR/${name}.img"
    if [ ! -f "$img" ]; then
        echo "  SKIP: $name (no image file)"
        return
    fi
    local size
    size=$(stat -c%s "$img" 2>/dev/null || stat -f%z "$img" 2>/dev/null)
    local size_mb=$((size / 1048576))

    # Check if partition exists on device
    if ! $ADB shell su -c "test -e /dev/block/by-name/$name" 2>/dev/null; then
        echo "  SKIP: $name (partition not found on device)"
        return
    fi

    echo ">> $name (${size_mb}MB) via dd"
    $ADB push "$img" /sdcard/_flash_tmp.img 2>/dev/null
    $ADB shell su -c "dd if=/sdcard/_flash_tmp.img of=/dev/block/by-name/$name bs=4096 2>/dev/null && sync"
    $ADB shell su -c "rm /sdcard/_flash_tmp.img"
}

# --- Flash modes ---

do_full_flash() {
    echo "============================================"
    echo "  HiBy M300 FULL RESTORE (Slot B)"
    echo "============================================"
    echo ""
    echo "Phase 1: Flash via fastbootd (slotted + super)"
    echo "Phase 2: After boot, run --post-boot for non-slotted partitions"
    echo "Phase 3: Factory reset via recovery (vol up + power)"
    echo ""

    echo "--- Slot B firmware partitions ---"
    local failed=0
    for p in $SLOT_PARTS; do
        flash_partition "$p" || ((failed++))
    done

    echo ""
    echo "--- Non-slotted (fastbootd-compatible) ---"
    for p in $FASTBOOTD_NONSLOT; do
        flash_partition "$p" || ((failed++))
    done

    echo ""
    echo "=== Setting active slot to B ==="
    $FB set_active b 2>&1 || echo "WARN: set_active failed"

    echo ""
    echo "============================================"
    echo "  Phase 1 complete. $failed partition(s) skipped/failed."
    echo ""
    echo "  NEXT STEPS:"
    echo "  1. Device will reboot now."
    echo "  2. After boot, install Magisk if not already rooted."
    echo "  3. Run: bash $0 --post-boot"
    echo "     to flash non-slotted partitions via adb."
    echo "  4. Factory reset: boot to recovery (vol up + power)"
    echo "     and select 'Wipe data/factory reset'."
    echo "============================================"
}

do_firmware_only() {
    echo "=== FIRMWARE-ONLY RESTORE (Slot B, no super) ==="
    for p in $SLOT_PARTS; do
        flash_partition "$p" || true
    done
    flash_partition "vbmeta_system_a" || true
    echo ""
    echo "=== Setting active slot to B ==="
    $FB set_active b 2>&1 || true
}

do_post_boot() {
    echo "============================================"
    echo "  Phase 2: Flash non-slotted partitions via dd"
    echo "============================================"
    echo ""
    echo "These partitions cannot be flashed via fastbootd."
    echo "Requires: adb connection + Magisk root (su)"
    echo ""

    wait_for_adb_root

    local count=0
    local total=0
    for p in $DD_ONLY_PARTS; do
        ((total++))
        if dd_flash_partition "$p"; then
            ((count++))
        fi
    done

    echo ""
    echo "============================================"
    echo "  Done. Flashed $count/$total non-slotted partitions."
    echo "  Reboot to apply: adb reboot"
    echo "============================================"
}

do_single() {
    local part="$1"
    echo "=== Flashing single partition: $part ==="
    flash_partition "$part"
}

# --- Main ---

MODE="${1:---full}"

case "$MODE" in
    --full)
        wait_for_fastboot
        enter_fastbootd
        do_full_flash
        echo ""
        echo "=== Rebooting ==="
        $FB reboot
        ;;
    --firmware-only)
        wait_for_fastboot
        enter_fastbootd
        do_firmware_only
        echo ""
        echo "=== Rebooting ==="
        $FB reboot
        ;;
    --post-boot)
        do_post_boot
        ;;
    --partition)
        if [ -z "${2:-}" ]; then
            echo "Usage: $0 --partition NAME"
            exit 1
        fi
        # If device is in fastboot, use fastbootd. Otherwise try dd.
        if $FB devices 2>/dev/null | grep -q fastboot; then
            enter_fastbootd
            do_single "$2"
        elif $ADB devices 2>/dev/null | grep -q "device$"; then
            echo "Device in adb mode, flashing via dd..."
            wait_for_adb_root
            dd_flash_partition "$2"
        else
            echo "ERROR: No device found in fastboot or adb mode."
            exit 1
        fi
        ;;
    *)
        echo "HiBy M300 Restore Script"
        echo ""
        echo "Usage: $0 MODE"
        echo ""
        echo "Modes:"
        echo "  --full           Full restore via fastbootd (boot/firmware/super)"
        echo "  --post-boot      Flash non-slotted partitions via adb root (dd)"
        echo "  --firmware-only  Flash firmware partitions only (no super)"
        echo "  --partition NAME Flash a single partition (auto-detects method)"
        echo ""
        echo "Typical restore flow:"
        echo "  1. Boot to fastboot (vol down + power)"
        echo "  2. bash $0 --full"
        echo "  3. After boot, install Magisk, grant root"
        echo "  4. bash $0 --post-boot"
        echo "  5. Factory reset via recovery (vol up + power)"
        echo "  6. adb reboot"
        exit 0
        ;;
esac

echo "DONE!"
