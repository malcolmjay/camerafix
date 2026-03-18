#!/bin/bash
###############################################################################
# fix_starlighteye.sh  (v7)
#
# Repairs a Raspberry Pi 5 (Bookworm) after an apt upgrade overwrote the
# custom StarlightEye (IMX585) libcamera build with stock RPi packages.
#
# v7 CHANGES:
#   - Downloads updated wlf8.py from GitHub (replaces existing copy)
#   - Downloads and extracts icons.zip to ~/icons (replaces existing folder)
#
# IMPORTANT: Run via SSH so the build continues when the desktop stops.
#   ssh pi@<ip-address>
#   sudo bash fix_starlighteye.sh
#
# Expected build time on Pi 5 2GB: 60-90 minutes.
#
# Run as:  sudo bash fix_starlighteye.sh
###############################################################################

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[FIX]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

PI_HOME="/home/pi"

# --- Pre-flight checks -------------------------------------------------------
[[ $EUID -ne 0 ]] && err "This script must be run as root (sudo)."

log "Starting StarlightEye libcamera repair (v7)..."
log "Date: $(date)"
log "Kernel: $(uname -r)"
log "Python3: $(python3 --version 2>&1)"

TOTAL_RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
log "Total RAM: ${TOTAL_RAM_MB}MB"

if [[ $TOTAL_RAM_MB -lt 3000 ]]; then
    log "Low-RAM system detected. Build will use aggressive memory-saving measures."
fi

PYTHON_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
log "Detected Python version: ${PYTHON_VER}"

KERNEL_VER=$(uname -r)
if [[ "$KERNEL_VER" == 6.12.* ]]; then
    DRIVER_BRANCH="6.12.y"
elif [[ "$KERNEL_VER" == 6.6.* ]]; then
    DRIVER_BRANCH="6.6.y"
elif [[ "$KERNEL_VER" == 6.1.* ]]; then
    DRIVER_BRANCH="6.1.y"
else
    warn "Unrecognized kernel version ${KERNEL_VER} — defaulting to 6.6.y driver branch."
    DRIVER_BRANCH="6.6.y"
fi
log "Will use imx585-v4l2-driver branch: ${DRIVER_BRANCH}"

###############################################################################
# PRE-BUILD: MEMORY, THERMAL & POWER SAFETY
###############################################################################

log "=== PRE-BUILD: Maximizing available memory and reducing power draw ==="

# --- Create 4GB swap file ---
SWAP_CREATED=false
if ! swapon --show | grep -q "/swapfile"; then
    log "Creating 4GB swap file (required for 2GB Pi 5)..."
    swapoff /swapfile 2>/dev/null || true
    rm -f /swapfile
    dd if=/dev/zero of=/swapfile bs=1M count=4096 status=progress
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    SWAP_CREATED=true
    log "4GB swap enabled."
else
    log "Swap already active."
    SWAP_SIZE=$(swapon --show --bytes --noheadings | awk '{sum+=$3} END {print int(sum/1024/1024)}')
    if [[ $SWAP_SIZE -lt 2000 ]]; then
        warn "Existing swap is only ${SWAP_SIZE}MB — may not be enough."
    else
        log "Existing swap: ${SWAP_SIZE}MB — sufficient."
    fi
fi

# --- Disable zram if active ---
ZRAM_WAS_ACTIVE=false
if swapon --show | grep -q "zram"; then
    log "Disabling zram to free RAM..."
    for z in /dev/zram*; do
        swapoff "$z" 2>/dev/null || true
    done
    ZRAM_WAS_ACTIVE=true
fi

# --- Stop desktop environment to free ~300-400MB ---
DESKTOP_WAS_RUNNING=false
if systemctl is-active --quiet lightdm 2>/dev/null; then
    log ""
    log "================================================================"
    log "  Stopping desktop environment to free memory for compilation."
    log "  If running locally, the screen will go blank — this is normal."
    log "  The build is still running. The desktop will restart when done."
    log "  For best experience, run this script over SSH instead."
    log "================================================================"
    log ""
    sleep 5
    systemctl stop lightdm 2>/dev/null || true
    DESKTOP_WAS_RUNNING=true
    sleep 2
    log "Desktop stopped. Freed memory:"
    free -h | head -2
fi

# --- Drop filesystem caches ---
sync
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

# --- Cap CPU frequency ---
ORIG_MAX_FREQ=""
MAX_FREQ_PATH="/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq"
if [[ -f "$MAX_FREQ_PATH" ]]; then
    ORIG_MAX_FREQ=$(cat "$MAX_FREQ_PATH")
    echo 1500000 | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq > /dev/null 2>&1 || true
    log "CPU frequency capped at 1.5GHz for build stability."
fi

# --- Check for undervoltage ---
if command -v vcgencmd &>/dev/null; then
    THROTTLE=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2)
    if [[ "$THROTTLE" != "0x0" ]]; then
        warn "Undervoltage/throttling detected (${THROTTLE})!"
        warn "Use the official Pi 5 27W power supply for best results."
    else
        log "Power supply looks good (no throttling detected)."
    fi
fi

# Helper: cooldown pause between heavy phases
cooldown() {
    local TEMP TEMP_C
    TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo "0")
    TEMP_C=$((TEMP / 1000))
    if [[ $TEMP_C -gt 70 ]]; then
        log "CPU at ${TEMP_C}°C — cooling down for 90 seconds..."
        sleep 90
    elif [[ $TEMP_C -gt 60 ]]; then
        log "CPU at ${TEMP_C}°C — cooling down for 45 seconds..."
        sleep 45
    else
        log "CPU at ${TEMP_C}°C — proceeding."
    fi
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
}

log ""
log "Available memory before build:"
free -h | head -2
log ""

###############################################################################
# PHASE 1: NUKE EVERYTHING
###############################################################################

log "=== PHASE 1: Removing all libcamera / picamera2 packages and artifacts ==="

apt-get remove --purge -y \
    python3-libcamera \
    python3-picamera2 \
    libcamera0.5 \
    libcamera0.4 \
    libcamera0.3 \
    libcamera-dev \
    libcamera-ipa \
    libcamera-tools \
    rpicam-apps \
    2>/dev/null || true

apt-get autoremove -y 2>/dev/null || true

rm -f  /usr/lib/aarch64-linux-gnu/libcamera*.so*          2>/dev/null || true
rm -f  /usr/lib/aarch64-linux-gnu/libcamera-base*.so*     2>/dev/null || true
rm -rf /usr/lib/aarch64-linux-gnu/libcamera/              2>/dev/null || true
rm -rf /usr/lib/python3/dist-packages/libcamera/          2>/dev/null || true
rm -f  /usr/lib/python3/dist-packages/_libcamera*.so      2>/dev/null || true
rm -f  /usr/local/lib/aarch64-linux-gnu/libcamera*.so*    2>/dev/null || true
rm -f  /usr/local/lib/aarch64-linux-gnu/libcamera-base*.so* 2>/dev/null || true
rm -rf /usr/local/lib/aarch64-linux-gnu/libcamera/        2>/dev/null || true
rm -rf /usr/local/lib/aarch64-linux-gnu/python3*/site-packages/libcamera/ 2>/dev/null || true
rm -rf /usr/local/lib/python3/dist-packages/libcamera/    2>/dev/null || true
rm -f  /usr/local/bin/rpicam-*                            2>/dev/null || true
rm -f  /usr/local/lib/python${PYTHON_VER}/dist-packages/local-libcamera.pth 2>/dev/null || true
rm -f  /etc/environment.d/starlighteye.conf               2>/dev/null || true
rm -f  /etc/profile.d/starlighteye.sh                     2>/dev/null || true
rm -f  /etc/apt/preferences.d/starlighteye-hold.pref      2>/dev/null || true

ldconfig

log "System cleaned."

###############################################################################
# PHASE 2: INSTALL BUILD DEPENDENCIES
###############################################################################

log "=== PHASE 2: Installing build dependencies ==="

apt-get update

apt-get install -y \
    libboost-dev \
    libgnutls28-dev \
    openssl \
    libtiff5-dev \
    pybind11-dev \
    qtbase5-dev \
    libqt5core5a \
    libqt5gui5 \
    libqt5widgets5 \
    meson \
    cmake \
    python3-yaml \
    python3-ply \
    python3-dev \
    python3-jinja2 \
    libboost-program-options-dev \
    libdrm-dev \
    libexif-dev \
    libepoxy-dev \
    libjpeg-dev \
    libpng-dev \
    ninja-build \
    dkms \
    git \
    unzip

sync
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

log "Dependencies installed."

###############################################################################
# PHASE 3: BUILD FORKED LIBCAMERA FROM SOURCE
###############################################################################

log "=== PHASE 3: Building will127534's forked libcamera ==="
log ""
log "    !! SINGLE-THREADED BUILD — THIS WILL TAKE 45-90 MINUTES !!"
log "    !! ON A 2GB PI 5. THIS IS NORMAL. DO NOT POWER OFF.     !!"
log ""

BUILD_DIR="/home/pi/starlighteye_rebuild"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

rm -rf libcamera
git clone https://github.com/will127534/libcamera.git
cd libcamera

meson setup build \
    --buildtype=release \
    -Dpipelines=rpi/vc4,rpi/pisp \
    -Dipas=rpi/vc4,rpi/pisp \
    -Dv4l2=enabled \
    -Dgstreamer=disabled \
    -Dtest=false \
    -Dlc-compliance=disabled \
    -Dcam=disabled \
    -Dqcam=disabled \
    -Ddocumentation=disabled \
    -Dpycamera=enabled \
    -Dwrap_mode=forcefallback

ninja -j1 -C build
ninja -C build install

ldconfig

log "Forked libcamera built and installed to /usr/local/."

cooldown

###############################################################################
# PHASE 4: BUILD FORKED RPICAM-APPS
###############################################################################

log "=== PHASE 4: Building forked rpicam-apps (single-threaded) ==="
log "    This will take 15-25 minutes."

cd "$BUILD_DIR"
rm -rf rpicam-apps
git clone https://github.com/will127534/rpicam-apps.git
cd rpicam-apps

meson setup build \
    -Denable_libav=disabled \
    -Denable_drm=enabled \
    -Denable_egl=enabled \
    -Denable_qt=enabled \
    -Denable_opencv=disabled \
    -Denable_tflite=disabled

meson compile -j1 -C build
meson install -C build

ldconfig

log "Forked rpicam-apps built and installed."

cooldown

###############################################################################
# PHASE 5: INSTALL PICAMERA2 (apt) — BUT NOT python3-libcamera
###############################################################################

log "=== PHASE 5: Installing python3-picamera2 ==="

apt-get install -y python3-picamera2 2>/dev/null || {
    warn "Failed to install python3-picamera2 via apt."
    warn "Trying pip install as fallback..."
    pip install picamera2 --break-system-packages 2>/dev/null || true
}

log "Removing apt python3-libcamera and libcamera0.5 (wrong ABI)..."
dpkg --force-depends -r python3-libcamera 2>/dev/null || true
dpkg --force-depends -r libcamera0.5      2>/dev/null || true

rm -f  /usr/lib/aarch64-linux-gnu/libcamera*.so*       2>/dev/null || true
rm -f  /usr/lib/aarch64-linux-gnu/libcamera-base*.so*  2>/dev/null || true
rm -rf /usr/lib/aarch64-linux-gnu/libcamera/           2>/dev/null || true
rm -rf /usr/lib/python3/dist-packages/libcamera/       2>/dev/null || true

ldconfig

log "picamera2 installed, stock libcamera packages removed."

###############################################################################
# PHASE 6: WIRE UP PATHS (IPA modules, tuning files, Python bindings)
###############################################################################

log "=== PHASE 6: Wiring up IPA modules, tuning files, and Python paths ==="

# --- 6a: IPA modules ---
IPA_SYS="/usr/lib/aarch64-linux-gnu/libcamera/ipa"
IPA_LOCAL="/usr/local/lib/aarch64-linux-gnu/libcamera/ipa"

mkdir -p "$IPA_SYS"

for f in ipa_rpi_pisp.so ipa_rpi_pisp.so.sign ipa_rpi_vc4.so ipa_rpi_vc4.so.sign; do
    if [[ -f "${IPA_LOCAL}/${f}" ]]; then
        ln -sf "${IPA_LOCAL}/${f}" "${IPA_SYS}/${f}"
        log "  Symlinked ${f}"
    else
        warn "  ${IPA_LOCAL}/${f} not found — skipping"
    fi
done

# --- 6b: Tuning JSON files ---
for subdir in pisp vc4; do
    SRC="/usr/local/share/libcamera/ipa/rpi/${subdir}"
    DST="/usr/share/libcamera/ipa/rpi/${subdir}"
    if [[ -d "$SRC" ]]; then
        mkdir -p "$DST"
        cp -f "${SRC}"/imx585*.json "$DST/" 2>/dev/null && \
            log "  Copied imx585 tuning files to ${DST}/" || \
            warn "  No imx585 tuning files found in ${SRC}/"
    fi
done

# --- 6c: Python bindings ---
PTH_FILE="/usr/local/lib/python${PYTHON_VER}/dist-packages/local-libcamera.pth"
PTH_TARGET="/usr/local/lib/python3/dist-packages"

mkdir -p "$(dirname "$PTH_FILE")"
echo "$PTH_TARGET" > "$PTH_FILE"

log "  Python .pth: ${PTH_FILE} -> ${PTH_TARGET}"

BINDING="${PTH_TARGET}/libcamera/_libcamera.cpython-${PYTHON_VER//./}-aarch64-linux-gnu.so"
if [[ -f "$BINDING" ]]; then
    log "  Local Python binding found: ${BINDING}"
else
    warn "  Local Python binding NOT found at expected path!"
    find /usr/local -name "_libcamera.cpython*" 2>/dev/null | while read -r p; do
        warn "    Found: ${p}"
    done
fi

ldconfig

log "All paths wired up."

###############################################################################
# PHASE 7: REINSTALL IMX585 V4L2 KERNEL DRIVER
###############################################################################

log "=== PHASE 7: Reinstalling IMX585 v4l2 kernel driver (branch: ${DRIVER_BRANCH}) ==="

cd "$BUILD_DIR"
rm -rf imx585-v4l2-driver
git clone https://github.com/will127534/imx585-v4l2-driver.git --branch "$DRIVER_BRANCH"
cd imx585-v4l2-driver
bash ./setup.sh

log "IMX585 kernel driver installed."

###############################################################################
# PHASE 8: UPDATE APPLICATION FILES (wlf8.py + icons)
###############################################################################

log "=== PHASE 8: Updating camera application files ==="

# --- 8a: Download updated wlf8.py ---
WLF_URL="https://raw.githubusercontent.com/malcolmjay/camerafix/main/wlf8.py"
WLF_DEST="${PI_HOME}/wlf8.py"

log "  Downloading updated wlf8.py..."
if [[ -f "$WLF_DEST" ]]; then
    log "  Removing existing wlf8.py..."
    rm -f "$WLF_DEST"
fi

wget -q --show-progress -O "$WLF_DEST" "$WLF_URL" || {
    warn "  wget failed, trying curl..."
    curl -fSL -o "$WLF_DEST" "$WLF_URL" || err "Failed to download wlf8.py from GitHub."
}

chown pi:pi "$WLF_DEST"
chmod 644 "$WLF_DEST"
log "  wlf8.py updated at ${WLF_DEST}"

# --- 8b: Download and extract icons.zip ---
ICONS_URL="https://raw.githubusercontent.com/malcolmjay/camerafix/main/icons.zip"
ICONS_DIR="${PI_HOME}/icons"
ICONS_ZIP="${PI_HOME}/icons.zip"

log "  Downloading icons.zip..."
wget -q --show-progress -O "$ICONS_ZIP" "$ICONS_URL" || {
    warn "  wget failed, trying curl..."
    curl -fSL -o "$ICONS_ZIP" "$ICONS_URL" || err "Failed to download icons.zip from GitHub."
}

# Remove existing icons folder if present
if [[ -d "$ICONS_DIR" ]]; then
    log "  Removing existing icons folder..."
    rm -rf "$ICONS_DIR"
fi

log "  Extracting icons.zip..."
unzip -o -q "$ICONS_ZIP" -d "$PI_HOME"

# Fix ownership
chown -R pi:pi "$ICONS_DIR"

# Clean up zip file
rm -f "$ICONS_ZIP"

if [[ -d "$ICONS_DIR" ]]; then
    ICON_COUNT=$(find "$ICONS_DIR" -type f | wc -l)
    log "  Icons extracted: ${ICON_COUNT} files in ${ICONS_DIR}"
else
    warn "  Icons directory not found after extraction — check zip structure."
    warn "  The zip may extract to a subdirectory. Checking..."
    # Some zips contain a top-level folder — check for it
    EXTRACTED=$(find "$PI_HOME" -maxdepth 1 -type d -name "icons*" ! -name "icons" 2>/dev/null | head -1)
    if [[ -n "$EXTRACTED" ]]; then
        log "  Found ${EXTRACTED} — renaming to ${ICONS_DIR}"
        mv "$EXTRACTED" "$ICONS_DIR"
        chown -R pi:pi "$ICONS_DIR"
    fi
fi

log "Application files updated."

###############################################################################
# PHASE 9: PIN PACKAGES & PROTECT AGAINST FUTURE APT UPGRADES
###############################################################################

log "=== PHASE 9: Pinning packages to prevent future breakage ==="

cat > /etc/apt/preferences.d/starlighteye-hold.pref << 'EOF'
# StarlightEye protection: prevent apt upgrade from overwriting custom builds.

Package: python3-libcamera
Pin: release *
Pin-Priority: -1

Package: libcamera0*
Pin: release *
Pin-Priority: -1

Package: libcamera-dev
Pin: release *
Pin-Priority: -1

Package: libcamera-ipa
Pin: release *
Pin-Priority: -1

Package: libcamera-tools
Pin: release *
Pin-Priority: -1

Package: rpicam-apps
Pin: release *
Pin-Priority: -1

Package: python3-picamera2
Pin: version 0.3.31-1
Pin-Priority: 1001

Package: libpisp*
Pin: version 1.2.1*
Pin-Priority: 1001

Package: libpisp-common
Pin: version 1.2.1*
Pin-Priority: 1001
EOF

log "APT pin file created."

###############################################################################
# PHASE 10: VERIFY CONFIG.TXT
###############################################################################

log "=== PHASE 10: Verifying /boot/firmware/config.txt ==="

CONFIG="/boot/firmware/config.txt"
if [[ -f "$CONFIG" ]]; then
    if grep -q "^camera_auto_detect=0" "$CONFIG" && grep -q "^dtoverlay=imx585" "$CONFIG"; then
        log "config.txt looks correct."
    else
        warn "config.txt may need attention. Ensure it contains:"
        warn "  camera_auto_detect=0"
        warn "  dtoverlay=imx585"
        warn "(Add ',mono' for monochrome sensor: dtoverlay=imx585,mono)"
    fi
else
    warn "Could not find ${CONFIG} — check your boot partition."
fi

###############################################################################
# POST-BUILD: RESTORE SYSTEM
###############################################################################

log "=== POST-BUILD: Restoring system settings ==="

if [[ -n "$ORIG_MAX_FREQ" && -f "$MAX_FREQ_PATH" ]]; then
    echo "$ORIG_MAX_FREQ" | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq > /dev/null 2>&1 || true
    log "CPU frequency restored."
fi

if $ZRAM_WAS_ACTIVE; then
    systemctl restart zramswap 2>/dev/null || true
    log "zram re-enabled."
fi

if $DESKTOP_WAS_RUNNING; then
    log "Restarting desktop environment..."
    systemctl start lightdm 2>/dev/null || true
    log "Desktop restarted."
fi

###############################################################################
# PHASE 11: FINAL VERIFICATION
###############################################################################

log "=== PHASE 11: Running verification checks ==="

echo ""
PASS=true

IPA_SYS="/usr/lib/aarch64-linux-gnu/libcamera/ipa"
PTH_TARGET="/usr/local/lib/python3/dist-packages"

if ls /usr/local/lib/aarch64-linux-gnu/libcamera.so* &>/dev/null; then
    log "  [PASS] Local libcamera .so found"
else
    warn "  [FAIL] Local libcamera .so NOT found"; PASS=false
fi

if ls /usr/lib/aarch64-linux-gnu/libcamera.so* &>/dev/null; then
    warn "  [FAIL] Stock libcamera .so still in /usr/lib/"; PASS=false
else
    log "  [PASS] No stock libcamera .so in /usr/lib/"
fi

if [[ -L "${IPA_SYS}/ipa_rpi_pisp.so" ]]; then
    log "  [PASS] IPA symlink in place"
else
    warn "  [FAIL] IPA symlink missing"; PASS=false
fi

if [[ -f /usr/share/libcamera/ipa/rpi/pisp/imx585_mono.json ]]; then
    log "  [PASS] IMX585 tuning files present"
else
    warn "  [FAIL] IMX585 tuning files missing"; PASS=false
fi

if [[ -f "${PTH_TARGET}/libcamera/_libcamera.cpython-${PYTHON_VER//./}-aarch64-linux-gnu.so" ]]; then
    log "  [PASS] Local Python libcamera binding found"
else
    warn "  [FAIL] Local Python libcamera binding missing"; PASS=false
fi

if dpkg -l python3-libcamera 2>/dev/null | grep -q "^ii"; then
    warn "  [FAIL] apt python3-libcamera still installed"; PASS=false
else
    log "  [PASS] apt python3-libcamera not installed"
fi

if python3 -c "import picamera2" 2>/dev/null; then
    log "  [PASS] picamera2 imports"
else
    warn "  [FAIL] picamera2 import failed"; PASS=false
fi

if python3 -c "import libcamera" 2>/dev/null; then
    log "  [PASS] libcamera imports"
else
    warn "  [FAIL] libcamera import failed"; PASS=false
fi

if [[ -f "${PI_HOME}/wlf8.py" ]]; then
    log "  [PASS] wlf8.py present at ${PI_HOME}/wlf8.py"
else
    warn "  [FAIL] wlf8.py missing from ${PI_HOME}/"; PASS=false
fi

if [[ -d "${PI_HOME}/icons" ]]; then
    ICON_COUNT=$(find "${PI_HOME}/icons" -type f | wc -l)
    log "  [PASS] Icons folder present (${ICON_COUNT} files)"
else
    warn "  [FAIL] Icons folder missing from ${PI_HOME}/"; PASS=false
fi

echo ""
if $PASS; then
    echo "============================================================"
    log "ALL CHECKS PASSED — Repair complete!"
    echo "============================================================"
else
    echo "============================================================"
    warn "SOME CHECKS FAILED — Review warnings above."
    echo "============================================================"
fi

echo ""
echo "  After reboot, test with:"
echo "    rpicam-still -r -o test.jpg -f -t 0"
echo "    sudo python3 wlf8.py"
echo ""

log "Rebooting in 10 seconds..."
sleep 10
sudo reboot
