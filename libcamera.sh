#!/bin/bash
###############################################################################
# fix_starlighteye.sh  (v4 — final)
#
# Repairs a Raspberry Pi 5 (Bookworm) after an apt upgrade overwrote the
# custom StarlightEye (IMX585) libcamera build with stock RPi packages.
#
# LESSONS LEARNED (baked into this script):
#
#   - python3-libcamera from apt must NEVER be installed. It ships a
#     _libcamera.so Python binding compiled against libcamera 0.5, which
#     is ABI-incompatible with the forked libcamera 0.6 build. The forked
#     build with -Dpycamera=enabled already produces the correct binding.
#
#   - python3-picamera2 from apt is fine — it's pure Python on top.
#     But it depends on python3-libcamera, so we install with --no-install-recommends
#     and force-remove python3-libcamera afterward.
#
#   - The apt python3-libcamera package pulls in libcamera0.5 which drops
#     stock .so files into /usr/lib/ AND stale IPA modules into
#     /usr/lib/aarch64-linux-gnu/libcamera/ipa/. These must be cleaned.
#
#   - The locally-built IPA modules live at /usr/local/lib/.../libcamera/ipa/
#     but libcamera searches /usr/lib/.../libcamera/ipa/ by default.
#     We symlink the local ones into the system path.
#
#   - Tuning JSON files (imx585.json, imx585_mono.json) are installed to
#     /usr/local/share/ but libcamera looks in /usr/share/. We copy them.
#
#   - The .pth file must point to /usr/local/lib/python3/dist-packages
#     (where the forked _libcamera.so actually lives), NOT to
#     /usr/local/lib/aarch64-linux-gnu/python3.XX/site-packages.
#
# Run as:  sudo bash fix_starlighteye.sh
#
# Tested on Raspberry Pi 5, Bookworm, Python 3.11, kernel 6.6.x
# Against StarlightEye Quick Start Guide (Jan 2026 revision)
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

log "Starting StarlightEye libcamera repair (v4)..."
log "Date: $(date)"
log "Kernel: $(uname -r)"
log "Python3: $(python3 --version 2>&1)"

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
# PHASE 1: NUKE EVERYTHING
###############################################################################

log "=== PHASE 1: Removing all libcamera / picamera2 packages and artifacts ==="

# Remove every apt package that could conflict
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

# Nuke ALL libcamera shared objects from system path
rm -f  /usr/lib/aarch64-linux-gnu/libcamera*.so*          2>/dev/null || true
rm -f  /usr/lib/aarch64-linux-gnu/libcamera-base*.so*     2>/dev/null || true
rm -rf /usr/lib/aarch64-linux-gnu/libcamera/              2>/dev/null || true

# Nuke system Python libcamera bindings
rm -rf /usr/lib/python3/dist-packages/libcamera/          2>/dev/null || true
rm -f  /usr/lib/python3/dist-packages/_libcamera*.so      2>/dev/null || true

# Nuke ALL local (previous build) artifacts
rm -f  /usr/local/lib/aarch64-linux-gnu/libcamera*.so*    2>/dev/null || true
rm -f  /usr/local/lib/aarch64-linux-gnu/libcamera-base*.so* 2>/dev/null || true
rm -rf /usr/local/lib/aarch64-linux-gnu/libcamera/        2>/dev/null || true
rm -rf /usr/local/lib/aarch64-linux-gnu/python3*/site-packages/libcamera/ 2>/dev/null || true
rm -rf /usr/local/lib/python3/dist-packages/libcamera/    2>/dev/null || true
rm -f  /usr/local/bin/rpicam-*                            2>/dev/null || true

# Remove old .pth files
rm -f /usr/local/lib/python${PYTHON_VER}/dist-packages/local-libcamera.pth 2>/dev/null || true

# Remove old environment variable files
rm -f /etc/environment.d/starlighteye.conf  2>/dev/null || true
rm -f /etc/profile.d/starlighteye.sh        2>/dev/null || true

# Remove old APT pin file
rm -f /etc/apt/preferences.d/starlighteye-hold.pref 2>/dev/null || true

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
    git

log "Dependencies installed."

###############################################################################
# PHASE 3: BUILD FORKED LIBCAMERA FROM SOURCE
###############################################################################

log "=== PHASE 3: Building will127534's forked libcamera ==="

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

ninja -C build
ninja -C build install

ldconfig

log "Forked libcamera built and installed to /usr/local/."

###############################################################################
# PHASE 4: BUILD FORKED RPICAM-APPS
###############################################################################

log "=== PHASE 4: Building forked rpicam-apps ==="

cd "$BUILD_DIR"
rm -rf rpicam-apps
git clone https://github.com/will127534/rpicam-apps.git
cd rpicam-apps

# libav DISABLED — Bookworm's libavcodec is too old (AV_PROFILE_UNKNOWN missing)
# This does not affect Picamera2 or rpicam-still/rpicam-vid basic capture.
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

log "Forked rpicam-apps built and installed."

###############################################################################
# PHASE 5: INSTALL PICAMERA2 (apt) — BUT NOT python3-libcamera
###############################################################################

log "=== PHASE 5: Installing python3-picamera2 ==="

# We ONLY want picamera2 (pure Python). We do NOT want python3-libcamera
# from apt because it ships _libcamera.so compiled against libcamera 0.5,
# which is ABI-incompatible with our forked 0.6 build.
#
# However, python3-picamera2 declares a dependency on python3-libcamera.
# So we install picamera2 first, then immediately force-remove
# python3-libcamera and libcamera0.5 (which it pulled in).

apt-get install -y python3-picamera2 2>/dev/null || {
    warn "Failed to install python3-picamera2 via apt."
    warn "Trying pip install as fallback..."
    pip install picamera2 --break-system-packages 2>/dev/null || true
}

# Force-remove the apt python3-libcamera and libcamera0.5 that got dragged in.
# Use dpkg --force to avoid dependency complaints.
log "Removing apt python3-libcamera and libcamera0.5 (wrong ABI)..."
dpkg --force-depends -r python3-libcamera 2>/dev/null || true
dpkg --force-depends -r libcamera0.5      2>/dev/null || true

# Clean out everything apt just dropped into system paths
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
# libcamera searches /usr/lib/.../libcamera/ipa/ by default.
# Our good IPA modules are at /usr/local/lib/.../libcamera/ipa/.
# Symlink them into the system path.

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
# libcamera looks for sensor tuning files in /usr/share/libcamera/ipa/rpi/
# but the forked build installs them to /usr/local/share/libcamera/ipa/rpi/.

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
# The forked build installs _libcamera.cpython-3XX.so to:
#   /usr/local/lib/python3/dist-packages/libcamera/
# We need Python to find this. Create a .pth file.

PTH_FILE="/usr/local/lib/python${PYTHON_VER}/dist-packages/local-libcamera.pth"
PTH_TARGET="/usr/local/lib/python3/dist-packages"

mkdir -p "$(dirname "$PTH_FILE")"
echo "$PTH_TARGET" > "$PTH_FILE"

log "  Python .pth: ${PTH_FILE} -> ${PTH_TARGET}"

# Verify the binding exists
BINDING="${PTH_TARGET}/libcamera/_libcamera.cpython-${PYTHON_VER//./}-aarch64-linux-gnu.so"
if [[ -f "$BINDING" ]]; then
    log "  Local Python binding found: ${BINDING}"
else
    warn "  Local Python binding NOT found at expected path!"
    warn "  Looking for it..."
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
# PHASE 8: PIN PACKAGES & PROTECT AGAINST FUTURE APT UPGRADES
###############################################################################

log "=== PHASE 8: Pinning packages to prevent future breakage ==="

cat > /etc/apt/preferences.d/starlighteye-hold.pref << 'EOF'
# StarlightEye protection: prevent apt upgrade from overwriting custom builds.
#
# Block ALL libcamera system packages from being installed/upgraded.
# The forked libcamera is built from source and lives in /usr/local/.

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

# Pin picamera2 to prevent it pulling in a newer python3-libcamera
Package: python3-picamera2
Pin: version 0.3.31-1
Pin-Priority: 1001

# Pin libpisp to prevent ABI mismatch with locally-built IPA modules
Package: libpisp*
Pin: version 1.2.1*
Pin-Priority: 1001

Package: libpisp-common
Pin: version 1.2.1*
Pin-Priority: 1001
EOF

log "APT pin file created at /etc/apt/preferences.d/starlighteye-hold.pref"

###############################################################################
# PHASE 9: VERIFY CONFIG.TXT
###############################################################################

log "=== PHASE 9: Verifying /boot/firmware/config.txt ==="

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
# PHASE 10: FINAL VERIFICATION
###############################################################################

log "=== PHASE 10: Running verification checks ==="

echo ""
PASS=true

# Check 1: Local libcamera .so exists
if [[ -f /usr/local/lib/aarch64-linux-gnu/libcamera.so.0.6 ]]; then
    log "  [PASS] Local libcamera.so.0.6 found"
else
    warn "  [FAIL] Local libcamera.so.0.6 NOT found"
    PASS=false
fi

# Check 2: No stock libcamera .so in system path
if ls /usr/lib/aarch64-linux-gnu/libcamera.so* &>/dev/null; then
    warn "  [FAIL] Stock libcamera .so still exists in /usr/lib/"
    PASS=false
else
    log "  [PASS] No stock libcamera .so in /usr/lib/"
fi

# Check 3: IPA symlinks in place
if [[ -L "${IPA_SYS}/ipa_rpi_pisp.so" ]]; then
    log "  [PASS] IPA symlink in place"
else
    warn "  [FAIL] IPA symlink missing"
    PASS=false
fi

# Check 4: Tuning files present
if [[ -f /usr/share/libcamera/ipa/rpi/pisp/imx585_mono.json ]]; then
    log "  [PASS] IMX585 tuning files present in /usr/share/"
else
    warn "  [FAIL] IMX585 tuning files missing from /usr/share/"
    PASS=false
fi

# Check 5: Python binding
if [[ -f "${PTH_TARGET}/libcamera/_libcamera.cpython-${PYTHON_VER//./}-aarch64-linux-gnu.so" ]]; then
    log "  [PASS] Local Python libcamera binding found"
else
    warn "  [FAIL] Local Python libcamera binding missing"
    PASS=false
fi

# Check 6: No apt python3-libcamera installed
if dpkg -l python3-libcamera 2>/dev/null | grep -q "^ii"; then
    warn "  [FAIL] apt python3-libcamera is still installed — remove it!"
    PASS=false
else
    log "  [PASS] apt python3-libcamera not installed"
fi

# Check 7: picamera2 importable
if python3 -c "import picamera2" 2>/dev/null; then
    log "  [PASS] picamera2 imports successfully"
else
    warn "  [FAIL] picamera2 import failed"
    PASS=false
fi

# Check 8: libcamera importable from local binding
if python3 -c "import libcamera; print(f'libcamera loaded from: {libcamera.__file__}')" 2>/dev/null; then
    log "  [PASS] libcamera Python module imports successfully"
else
    warn "  [FAIL] libcamera Python module import failed"
    PASS=false
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
echo "  Next steps:"
echo "    1. Reboot:  sudo reboot"
echo "    2. Test:    rpicam-still -r -o test.jpg -f -t 0"
echo "    3. Then:    sudo python3 wlf8.py"
echo ""
echo "  If issues persist, check:"
echo "    dmesg | grep imx585"
echo "    sudo python3 -c 'from picamera2 import Picamera2; print(Picamera2.global_camera_info())'"
echo ""
