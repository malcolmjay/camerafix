#!/bin/bash
# WLV-01 Recovery Script
# Camera Hacks by Malcolm-Jay
# Flashes wlv01.gz from USB drive to SD card

set -e

IMG_NAME="wlv01.gz"
SD_CARD="/dev/mmcblk0"
USB_MOUNT="/mnt/usb_recovery"

# Must run as root
if [ "$EUID" -ne 0 ]; then
    echo "Error: Please run with sudo"
    echo "  sudo bash recovery_wlv01.sh"
    exit 1
fi

# Verify we're on a Raspberry Pi
if [ ! -f /proc/device-tree/model ]; then
    echo "Error: This doesn't appear to be a Raspberry Pi."
    exit 1
fi

MODEL=$(tr -d '\0' < /proc/device-tree/model)
echo "Detected: $MODEL"
echo ""

# Verify SD card exists
if [ ! -b "$SD_CARD" ]; then
    echo "Error: SD card not found at $SD_CARD"
    exit 1
fi

# Find USB drive
# Look for /dev/sda (advise customer to remove all other USB devices)
USB_DEV=""
for dev in /dev/sd[a-z]; do
    if [ -b "$dev" ]; then
        USB_DEV="$dev"
        break
    fi
done

if [ -z "$USB_DEV" ]; then
    echo "Error: No USB drive detected."
    echo "Please insert the USB drive containing $IMG_NAME and try again."
    exit 1
fi

USB_SIZE=$(lsblk -b -d -n -o SIZE "$USB_DEV" 2>/dev/null)
USB_SIZE_GB=$(echo "scale=1; $USB_SIZE / 1073741824" | bc)
echo "Found USB drive: $USB_DEV (${USB_SIZE_GB}GB)"

# Mount the USB drive
mkdir -p "$USB_MOUNT"

# Try to find and mount the first partition, fall back to the device itself
USB_PART="${USB_DEV}1"
if [ ! -b "$USB_PART" ]; then
    USB_PART="$USB_DEV"
fi

# Unmount if already mounted somewhere
umount "$USB_PART" 2>/dev/null || true

mount -o ro "$USB_PART" "$USB_MOUNT" 2>/dev/null
if [ $? -ne 0 ]; then
    echo "Error: Could not mount USB drive."
    echo "Make sure the USB drive is formatted as FAT32, exFAT, or ext4."
    rmdir "$USB_MOUNT" 2>/dev/null
    exit 1
fi

# Look for the image file
IMG_PATH="$USB_MOUNT/$IMG_NAME"
if [ ! -f "$IMG_PATH" ]; then
    # Check one directory deep
    IMG_PATH=$(find "$USB_MOUNT" -maxdepth 2 -name "$IMG_NAME" -type f | head -1)
    if [ -z "$IMG_PATH" ]; then
        echo "Error: $IMG_NAME not found on USB drive."
        echo "Please make sure $IMG_NAME is on the root of the USB drive."
        umount "$USB_MOUNT"
        rmdir "$USB_MOUNT" 2>/dev/null
        exit 1
    fi
fi

IMG_SIZE=$(stat -c%s "$IMG_PATH")
IMG_SIZE_GB=$(echo "scale=2; $IMG_SIZE / 1073741824" | bc)
echo "Found image: $IMG_PATH (${IMG_SIZE_GB}GB compressed)"
echo ""

# Final confirmation
echo "============================================"
echo "  WLV-01 RECOVERY"
echo "============================================"
echo ""
echo "  Source:  $IMG_PATH"
echo "  Target:  $SD_CARD"
echo ""
echo "  WARNING: This will erase EVERYTHING on"
echo "  the SD card and replace it with a fresh"
echo "  WLV-01 installation."
echo ""
echo "============================================"
echo ""
read -p "Type YES to proceed: " CONFIRM

if [ "$CONFIRM" != "YES" ]; then
    echo "Cancelled."
    umount "$USB_MOUNT"
    rmdir "$USB_MOUNT" 2>/dev/null
    exit 0
fi

echo ""
echo "Flashing $IMG_NAME to SD card..."
echo "This will take several minutes. Do not unplug anything."
echo ""

# Sync and drop caches before flashing
sync
echo 3 > /proc/sys/vm/drop_caches

# Decompress and flash the image
gunzip -c "$IMG_PATH" | dd of="$SD_CARD" bs=4M status=progress conv=fsync 2>&1

sync
echo ""
echo "============================================"
echo "  Recovery complete!"
echo ""
echo "  The system will reboot in 10 seconds."
echo "  Remove the USB drive after shutdown."
echo "============================================"
echo ""

# Cleanup
umount "$USB_MOUNT" 2>/dev/null
rmdir "$USB_MOUNT" 2>/dev/null

sleep 10
reboot
