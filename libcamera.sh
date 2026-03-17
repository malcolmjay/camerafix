#!/bin/bash
###############################################################################
# fix_starlighteye.sh
#
# Repairs a Raspberry Pi 5 (Bookworm) after an apt upgrade overwrote the
# custom StarlightEye (IMX585) libcamera build with stock RPi packages.
#
# What this does:
#   1. Purges system libcamera + picamera2 packages
#   2. Cleans any leftover shared libraries
#   3. Rebuilds will127534's forked libcamera from source
#   4. Rebuilds forked rpicam-apps from source (libav disabled for Bookworm)
#   5. Reinstalls pinned python3-libcamera & python3-picamera2 packages
#   6. Reinstalls the IMX585 v4l2 kernel driver via DKMS
#   7. Pins libcamera/picamera2 packages so future apt upgrades won't
#      overwrite them again
#   8. Verifies config.txt is correct
#
# Run as:  sudo bash fix_starlighteye.sh
#
# Tested against the StarlightEye Quick Start Guide (Jan 2026 revision)
###############################################################################

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[FIX]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# --- Pre-flight checks -------------------------------------------------------
[[ $EUID -ne 0 ]] && err "This script must be run as root (sudo)."

log "Starting StarlightEye libcamera repair..."
log "Date: $(date)"
log "Kernel: $(uname -r)"
log "Python3: $(python3 --version 2>&1)"

# Detect Python site-packages path (Bookworm = 3.11, Trixie = 3.13)
PYTHON_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
log "Detected Python version: ${PYTHON_VER}"

# Detect kernel branch for the v4l2 driver
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

# --- Step 1: Purge broken system packages ------------------------------------
log "Step 1/8: Removing system libcamera and picamera2 packages..."

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

# --- Step 2: Clean leftover shared objects -----------------------------------
log "Step 2/8: Cleaning leftover libcamera shared objects..."

# Remove any system-installed libcamera .so files that conflict
rm -f /usr/lib/aarch64-linux-gnu/libcamera*.so* 2>/dev/null || true
rm -f /usr/lib/aarch64-linux-gnu/python3/dist-packages/_libcamera*.so 2>/dev/null || true
rm -rf /usr/lib/aarch64-linux-gnu/libcamera/ 2>/dev/null || true

# Also clean the local install prefix (from previous ninja install)
rm -f /usr/local/lib/aarch64-linux-gnu/libcamera*.so* 2>/dev/null || true
rm -rf /usr/local/lib/aarch64-linux-gnu/libcamera/ 2>/dev/null || true
rm -rf /usr/local/lib/aarch64-linux-gnu/python3*/site-packages/libcamera/ 2>/dev/null || true

# Clean rpicam-apps
rm -f /usr/local/bin/rpicam-* 2>/dev/null || true

ldconfig

# --- Step 3: Install build dependencies -------------------------------------
log "Step 3/8: Installing build dependencies..."

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
    git

# --- Step 4: Build forked libcamera from source ------------------------------
log "Step 4/8: Building will127534's forked libcamera..."

BUILD_DIR="/home/pi/starlighteye_rebuild"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Clean any previous clone
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

ninja -C build
ninja -C build install

ldconfig

log "Forked libcamera installed successfully."

# --- Step 5: Build forked rpicam-apps ----------------------------------------
log "Step 5/8: Building forked rpicam-apps..."

cd "$BUILD_DIR"
rm -rf rpicam-apps

git clone https://github.com/will127534/rpicam-apps.git
cd rpicam-apps

# NOTE: libav is DISABLED because Bookworm ships an older libavcodec that
# is incompatible with rpicam-apps (AV_PROFILE_UNKNOWN / AV_LEVEL_UNKNOWN
# symbols missing). This does not affect Picamera2 or rpicam-still/rpicam-vid
# basic functionality. If you need libav encoding, upgrade FFmpeg first.
meson setup build \
    -Denable_libav=disabled \
    -Denable_drm=enabled \
    -Denable_egl=enabled \
    -Denable_qt=enabled \
    -Denable_opencv=disabled \
    -Denable_tflite=disabled

meson compile -C build
meson install -C build

ldconfig

log "Forked rpicam-apps installed successfully."

# --- Step 6: Reinstall pinned picamera2 packages -----------------------------
log "Step 6/8: Installing pinned python3-libcamera and python3-picamera2..."

# Install the specific versions the fork is built against
apt-get install -y --allow-downgrades \
    python3-libcamera=0.6.0+rpt20251202-1 \
    python3-picamera2=0.3.33-1 \
    2>/dev/null || {
        warn "Pinned package versions not available in current repo."
        warn "Trying to install latest available versions instead..."
        apt-get install -y python3-libcamera python3-picamera2 || true
    }

# Set up the .pth file so Python finds the locally-built libcamera bindings
PTH_DIR="/usr/local/lib/python${PYTHON_VER}/dist-packages"
LOCAL_SITE="/usr/local/lib/aarch64-linux-gnu/python${PYTHON_VER}/site-packages"

mkdir -p "$PTH_DIR"

echo "$LOCAL_SITE" | tee "${PTH_DIR}/local-libcamera.pth"

log "Python path configured: ${PTH_DIR}/local-libcamera.pth -> ${LOCAL_SITE}"

# --- Step 7: Reinstall IMX585 v4l2 kernel driver -----------------------------
log "Step 7/8: Reinstalling IMX585 v4l2 kernel driver (branch: ${DRIVER_BRANCH})..."

cd "$BUILD_DIR"
rm -rf imx585-v4l2-driver

git clone https://github.com/will127534/imx585-v4l2-driver.git --branch "$DRIVER_BRANCH"
cd imx585-v4l2-driver

# The setup.sh script handles DKMS registration
bash ./setup.sh

log "IMX585 kernel driver installed."

# --- Step 8: Pin packages to prevent future breakage -------------------------
log "Step 8/8: Pinning libcamera packages to prevent apt upgrade breakage..."

cat > /etc/apt/preferences.d/starlighteye-hold.pref << 'EOF'
# Hold libcamera and picamera2 at their current versions to prevent
# apt upgrade from overwriting the StarlightEye custom build.

Package: python3-libcamera
Pin: version 0.6.0+rpt20251202-1
Pin-Priority: 1001

Package: python3-picamera2
Pin: version 0.3.33-1
Pin-Priority: 1001

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
EOF

log "APT pin file created at /etc/apt/preferences.d/starlighteye-hold.pref"

# --- Verify config.txt -------------------------------------------------------
log "Verifying /boot/firmware/config.txt..."

CONFIG="/boot/firmware/config.txt"
if [[ -f "$CONFIG" ]]; then
    if grep -q "^camera_auto_detect=0" "$CONFIG" && grep -q "^dtoverlay=imx585" "$CONFIG"; then
        log "config.txt looks correct (camera_auto_detect=0, dtoverlay=imx585 present)."
    else
        warn "config.txt may need attention. Ensure it contains:"
        warn "  camera_auto_detect=0"
        warn "  dtoverlay=imx585"
        warn "(Add ',mono' to the dtoverlay line if using a monochrome sensor)"
    fi
else
    warn "Could not find ${CONFIG} — check your boot partition."
fi

# --- Done --------------------------------------------------------------------
echo ""
echo "============================================================"
log "Repair complete!"
echo "============================================================"
echo ""
echo "  Next steps:"
echo "    1. Reboot:  sudo reboot"
echo "    2. Test:    rpicam-still -r -o test.jpg -f -t 0"
echo "    3. Then:    sudo python3 wlf8.py"
echo ""
echo "  If issues persist, check:"
echo "    dmesg | grep imx585"
echo "    python3 -c 'from picamera2 import Picamera2; print(\"OK\")'"
echo ""
