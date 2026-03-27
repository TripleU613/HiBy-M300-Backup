# HiBy M300 Full Backup & Restore

Full partition-level backup of a working HiBy Digital M300 (QCM6125W/Trinket) running firmware v1.60+ (OTA build `eng.HiBy.20250418.122933`) with Magisk 30.7 root.

## Device Info

- **SoC**: Qualcomm QCM6125W (Trinket) - `nicobar_IoT_modem`
- **Storage**: UFS (4096-byte logical blocks)
- **Slot**: A/B with UEFI bootloader
- **Android**: Stock HiBy firmware v1.60+ (OTA build 20250418)
- **Root**: Magisk v30.7 (patched boot_b)
- **Serial HWID**: `0x001750e1`

## The Problem (and how we fixed it)

### Corrupt Vendor Partition

After a bad flash, the vendor partition (inside `super`) was corrupted, causing a bootloop. Reflashing required understanding several quirks of this device:

### Quirk 1: UEFI Bootloader Does NOT Support Flash Writes

The M300 uses a UEFI bootloader. While `fastboot` connects fine in bootloader mode (vol down + power), **flash commands fail with "unknown command"** after the first session. The write capability seems to be a one-shot deal after a fresh power cycle.

**Solution**: Use **fastbootd** (userspace fastboot) instead:
```bash
fastboot reboot fastboot    # from bootloader → fastbootd
fastboot getvar is-userspace  # should say "yes"
# NOW flash commands work reliably
```

### Quirk 2: Modem Partition Requires 4096-Byte Sector FAT16

The UFS storage uses 4096-byte logical blocks. The stock `modem.img` firmware file uses 512-byte FAT16 sectors. The kernel FAT driver **refuses to mount** a 512-byte sector FAT on a 4K logical block device, returning an I/O error even though raw reads work fine.

**Symptoms**: WiFi and Bluetooth completely non-functional. `dmesg` shows:
```
servloc: pd_locator_work: Failed to get process domains for wlan/fw for client ICNSS-WLAN rc:21
```
The modem subsystem stays in `OFFLINING` state because the firmware partition (`/vendor/firmware_mnt`) never mounts.

**Solution**: Rebuild the modem image with 4096-byte sectors:
```bash
mkdir -p /tmp/modem_extract
7z x -o/tmp/modem_extract modem.img               # extract files from 512-byte image
dd if=/dev/zero of=modem_4k.img bs=4096 count=46080  # create blank image (same size)
mkfs.vfat -F 16 -S 4096 -s 1 modem_4k.img          # format with 4K sectors
mmd -i modem_4k.img ::image ::verinfo               # create directories
mcopy -i modem_4k.img /tmp/modem_extract/image/* ::image/
mcopy -i modem_4k.img /tmp/modem_extract/verinfo/* ::verinfo/
# Flash modem_4k.img instead of the original
```

The `modem_a.img` in this backup already has the correct 4K sector format.

### Quirk 3: Persist Partition Was Corrupt

The persist partition (`/dev/block/sda5`) had a destroyed ext4 superblock. This partition holds WiFi calibration data and Bluetooth config. Without it, neither WiFi nor Bluetooth can initialize.

**Solution**: Recreate it:
```bash
adb shell su -c "mke2fs -t ext4 /dev/block/sda5"
# Reboot - init will mount it and services recreate their directories
```

### Quirk 4: A/B Slot Management

The bootloader doesn't support `fastboot set_active` in bootloader mode, but **fastbootd does**. Always flash to explicit slot suffixes (`_a` or `_b`) and set active slot from fastbootd.

### Quirk 5: EDL Won't Work Without Correct Firehose

The device identifies as `nicobar_IoT_modem` (HWID `0x001750e1`) in EDL mode. A `prog_emmc_firehose_8953_ddr.mbn` programmer will NOT work - it's the wrong chipset entirely. You need a firehose for SDX55/nicobar/QCM6125.

## What's Included

58 partition images (5.1GB total):

| Category | Partitions |
|----------|-----------|
| Bootloader | `xbl_a`, `xbl_config_a`, `abl_a`, `rpm_a` |
| TrustZone/Security | `tz_a`, `hyp_a`, `keymaster_a`, `cmnlib_a`, `cmnlib64_a`, `devcfg_a`, `uefisecapp_a`, `mdtp_a`, `mdtpsecapp_a` |
| Boot/Recovery | `boot_a` (Magisk patched), `recovery_a`, `dtbo_a`, `vbmeta_a`, `vbmeta_system_a` |
| Radio/Connectivity | `modem_a` (4K sector FAT16), `bluetooth_a`, `dsp_a`, `qupfw_a` |
| System | `super` (system + vendor + product + system_ext) |
| Device-specific | `persist`, `splash`, `modemst1`, `modemst2`, `fsg`, `nvdata1`, `nvdata2`, `cdt`, `ddr` |
| Misc | `metadata`, `misc`, `keystore`, `frp`, `devinfo`, `secdata`, `uefivarstore`, + others |

**NOT included**: `userdata` (110GB, user data), `rawdump`, `logdump`

## After Every OTA Update

OTA updates will **break WiFi and Bluetooth every time**. The update_engine writes a stock `modem_b` (or `modem_a`) image with 512-byte FAT16 sectors, which the UFS kernel driver refuses to mount. You must rebuild the modem image with 4K sectors after every OTA.

### Symptoms After OTA

- WiFi toggle does nothing, no `wlan0` interface appears
- Bluetooth stays OFF
- `dmesg` shows: `servloc: pd_locator_work: Failed to get process domains for wlan/fw`
- `/vendor/firmware_mnt/` is empty (modem partition failed to mount)

### Fix (requires root)

```bash
# 1. Dump the new modem partition (check which slot is active first)
adb shell su -c "getprop ro.boot.slot_suffix"   # returns _a or _b
adb shell su -c "dd if=/dev/block/by-name/modem_b of=/sdcard/modem_raw.img bs=4096"
adb pull /sdcard/modem_raw.img /tmp/modem_raw.img

# 2. Extract files from 512-byte sector image
mkdir -p /tmp/modem_extract
7z x -o/tmp/modem_extract /tmp/modem_raw.img -y

# 3. Rebuild with 4096-byte sectors
dd if=/dev/zero of=/tmp/modem_4k.img bs=4096 count=46080
mkfs.vfat -F 16 -S 4096 -s 1 /tmp/modem_4k.img
mmd -i /tmp/modem_4k.img ::image ::verinfo
mcopy -i /tmp/modem_4k.img /tmp/modem_extract/image/* ::image/
mcopy -i /tmp/modem_4k.img /tmp/modem_extract/verinfo/* ::verinfo/

# 4. Flash back and reboot
adb push /tmp/modem_4k.img /sdcard/modem_4k.img
adb shell su -c "dd if=/sdcard/modem_4k.img of=/dev/block/by-name/modem_b bs=4096 && sync"
adb reboot
```

Replace `modem_b` with `modem_a` if you're on slot A.

### OTA + Magisk Workflow

**OTA updates will NOT work out of the box** if your boot image is Magisk-patched. The update_engine uses delta/incremental updates that read specific blocks from the current boot partition and apply binary diffs. Since Magisk modifies the boot image, the source block hashes won't match and the update aborts immediately with:

```
ERROR: The hash of the source data on disk for this operation doesn't match the expected value.
ERROR: Failed to perform BROTLI_BSDIFF operation 0 in partition "boot"
```

You **must** restore the stock boot image before applying any OTA. This can be done live without rebooting:

```bash
# 1. Keep a copy of the stock boot image (from the firmware package or dump before patching)
# 2. Write stock boot to the active slot (no reboot needed)
adb shell su -c "dd if=/sdcard/stock_boot.img of=/dev/block/by-name/boot_b bs=4096 && sync"

# 3. Reset the update engine (clears previous failure state)
adb shell su -c "update_engine_client --reset_status"

# 4. Apply OTA - either tap "Install" in system settings, or via CLI:
#    First extract payload offset from the OTA zip metadata, then:
adb shell su -c "update_engine_client \
  --update \
  --payload=file:///data/ota_package/update.zip \
  --offset=OFFSET --size=SIZE \
  --headers='FILE_HASH=...\nFILE_SIZE=...\nMETADATA_HASH=...\nMETADATA_SIZE=...' \
  --follow"

# 5. OTA writes to the INACTIVE slot. Dump the new boot and patch with Magisk:
adb shell su -c "dd if=/dev/block/by-name/boot_a of=/sdcard/boot_new.img bs=4096"
#    Open Magisk app > Install > Select and Patch a File > pick boot_new.img
#    Then flash the patched image back:
adb shell su -c "dd if=/sdcard/Download/magisk_patched-XXXXX.img of=/dev/block/by-name/boot_a bs=4096 && sync"

# 6. Fix modem 4K sectors on the new slot (see above)

# 7. Reboot into the updated firmware
adb reboot
```

**Important**: Always keep a copy of the stock (unpatched) boot image for your current firmware version. Without it, you cannot apply OTA updates.

## How to Restore

### Prerequisites

- `fastboot` (Android SDK platform-tools)
- USB cable + device in fastboot mode

### Full Restore

```bash
bash flash_restore.sh --full
```

This will:
1. Wait for device in fastboot
2. Reboot to fastbootd automatically
3. Flash all partitions to slot A
4. Set slot A active
5. Optionally wipe userdata (factory reset)
6. Reboot

### Firmware Only (keep userdata)

```bash
bash flash_restore.sh --firmware-only
```

### Single Partition

```bash
bash flash_restore.sh --partition boot_a
```

### Manual Flash (if script doesn't work)

```bash
# Get into fastbootd
fastboot reboot fastboot

# Flash what you need
fastboot flash boot_a boot_a.img
fastboot flash super super.img
fastboot flash modem_a modem_a.img
# ... etc

# Set active slot and reboot
fastboot set_active a
fastboot reboot
```

## Root (Magisk)

The `boot_a.img` is already Magisk-patched. After first boot:

1. Install Magisk APK: `adb install Magisk-v30.7.apk` (not included, download latest from GitHub)
2. Open Magisk app to complete setup

If Magisk uninstalls itself, the boot image doesn't match. Patch the stock boot yourself:
1. Push stock boot: `adb push boot_stock.img /sdcard/boot.img`
2. Open Magisk > Install > Select and Patch a File > pick boot.img
3. Pull patched image and flash via fastbootd
