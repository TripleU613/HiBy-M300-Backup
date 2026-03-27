#!/bin/bash
#
# HiBy M300 Full Restore Script
# QCM6125W (Trinket) - A/B device, UFS storage, UEFI fastboot
# Backup date: 2026-03-27
# Firmware: v1.60 (20241130-1654) + Magisk root
#
# IMPORTANT NOTES:
# - This device has a UEFI bootloader that does NOT support flash writes
#   in bootloader fastboot mode. You MUST use fastbootd (userspace fastboot).
# - Modem partition uses 4096-byte sector FAT16 (UFS requirement).
# - Super partition is NOT sparse - fastbootd handles raw images fine.
#
# USAGE:
#   1. Boot device into fastboot (vol down + power, or 'adb reboot bootloader')
#   2. Run: bash flash_restore.sh [--full | --firmware-only | --partition NAME]
#   3. Device will reboot automatically when done.
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FB="${FASTBOOT:-fastboot}"

# Verify fastboot is available
if ! command -v "$FB" &>/dev/null; then
    echo "ERROR: fastboot not found. Set FASTBOOT= or add to PATH."
    exit 1
fi

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
        echo "ERROR: Not in fastbootd. Cannot flash this device from bootloader fastboot."
        exit 1
    fi
    echo "In fastbootd - ready to flash."
}

flash_partition() {
    local name="$1"
    local img="$SCRIPT_DIR/${name}.img"
    if [ ! -f "$img" ]; then
        echo "SKIP: $name (no image file)"
        return
    fi
    local size
    size=$(stat -c%s "$img" 2>/dev/null || stat -f%z "$img" 2>/dev/null)
    local size_mb=$((size / 1048576))
    echo ">> $name (${size_mb}MB)"
    $FB flash "$name" "$img"
}

# Slot A firmware partitions (flashable with slot suffix)
SLOT_A_PARTS="xbl_b xbl_config_b rpm_b tz_b hyp_b modem_b bluetooth_b mdtpsecapp_b mdtp_b abl_b dsp_b keymaster_b boot_b cmnlib_b cmnlib64_b devcfg_b qupfw_b vbmeta_b dtbo_b imagefv_b uefisecapp_b recovery_b vbmeta_system_b"

# Critical non-slotted partitions
NONSLOT_CRITICAL="persist modemst1 modemst2 fsg fsc misc keystore super metadata splash devinfo dip apdp ssd nvdata1 nvdata2 teedata cdt ddr secdata uefivarstore storsec multiimgoem multiimgqti spunvm"

# Additional non-slotted
NONSLOT_EXTRA="cateloader catefv catecontentfv toolsfv logfs limits qpdata1 qpdata2 frp vbmeta_system_b"

do_full_flash() {
    echo "=== FULL RESTORE ==="
    echo "This will flash ALL partitions to slot A."
    echo ""

    for p in $SLOT_A_PARTS; do
        flash_partition "$p"
    done

    for p in $NONSLOT_CRITICAL $NONSLOT_EXTRA; do
        flash_partition "$p"
    done

    echo ""
    echo "=== Setting active slot to A ==="
    $FB set_active a 2>&1 || echo "WARN: set_active failed (may need to set manually)"

    echo ""
    echo "=== Factory reset (wipe userdata) ==="
    read -rp "Wipe userdata? [y/N] " yn
    if [ "$yn" = "y" ] || [ "$yn" = "Y" ]; then
        $FB -w 2>&1 || echo "WARN: -w failed in fastbootd, wipe from recovery instead"
    fi
}

do_firmware_only() {
    echo "=== FIRMWARE-ONLY RESTORE (no super/userdata) ==="
    for p in $SLOT_A_PARTS; do
        flash_partition "$p"
    done
    for p in persist modemst1 modemst2 fsg misc keystore metadata devinfo vbmeta_system_a; do
        flash_partition "$p"
    done
    $FB set_active a 2>&1 || true
}

do_single() {
    local part="$1"
    echo "=== Flashing single partition: $part ==="
    flash_partition "$part"
}

# --- Main ---
MODE="${1:---full}"

wait_for_fastboot
enter_fastbootd

case "$MODE" in
    --full)
        do_full_flash
        ;;
    --firmware-only)
        do_firmware_only
        ;;
    --partition)
        if [ -z "$2" ]; then
            echo "Usage: $0 --partition NAME"
            exit 1
        fi
        do_single "$2"
        ;;
    *)
        echo "Usage: $0 [--full | --firmware-only | --partition NAME]"
        exit 1
        ;;
esac

echo ""
echo "=== Rebooting ==="
$FB reboot
echo "DONE!"
