#!/usr/bin/env bash
set -Eeuo pipefail

log() {
  echo
  echo "[INFO] $*"
}

fail() {
  echo
  echo "[ERROR] $*" >&2
  exit 1
}

cleanup_on_error() {
  echo
  echo "[ERROR] The reinstall script stopped because a command failed." >&2
  echo "[ERROR] Review the messages above to see which step failed." >&2
}
trap cleanup_on_error ERR

if [[ "${EUID}" -eq 0 ]]; then
  fail "Please run this script as the pi user, not as root. Use: bash libcamera.sh"
fi

cd "$HOME"

log "Checking kernel version"
uname -r

log "Updating package lists"
sudo apt update

log "Installing required build dependencies"
sudo apt install -y \
  git \
  meson \
  ninja-build \
  cmake \
  pkg-config \
  python3-pip \
  python3-jinja2 \
  python3-ply \
  python3-yaml \
  python3-dev \
  libyaml-dev \
  libboost-program-options-dev \
  libdrm-dev \
  libudev-dev \
  libexif-dev \
  libepoxy-dev \
  libjpeg-dev \
  libpng-dev \
  libtiff-dev \
  libtiff5-dev \
  libgnutls28-dev \
  openssl \
  libavcodec-dev \
  libavdevice-dev \
  libavformat-dev \
  libswresample-dev \
  pybind11-dev

log "Removing existing libcamera source directory"
rm -rf "$HOME/libcamera"

log "Cloning Will Whang's libcamera repository"
git clone https://github.com/will127534/libcamera.git "$HOME/libcamera"

log "Entering libcamera directory"
cd "$HOME/libcamera"

log "Removing any old libcamera build directory"
rm -rf build

log "Configuring libcamera"
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

log "Building libcamera"
ninja -C build

log "Installing libcamera"
sudo ninja -C build install

log "Refreshing linker cache after libcamera install"
sudo ldconfig

log "Removing existing rpicam-apps source directory"
rm -rf "$HOME/rpicam-apps"

log "Cloning Will Whang's rpicam-apps repository"
cd "$HOME"
git clone https://github.com/will127534/rpicam-apps.git "$HOME/rpicam-apps"

log "Entering rpicam-apps directory"
cd "$HOME/rpicam-apps"

log "Removing any old rpicam-apps build directory"
rm -rf build

log "Configuring rpicam-apps"
meson setup build \
  -Denable_libav=disabled \
  -Denable_drm=enabled \
  -Denable_egl=enabled \
  -Denable_qt=disabled \
  -Denable_opencv=disabled \
  -Denable_tflite=disabled

log "Building rpicam-apps"
meson compile -C build

log "Installing rpicam-apps"
sudo meson install -C build

log "Refreshing linker cache"
sudo ldconfig

log "Repair install completed"
echo
echo "[SUCCESS] libcamera and rpicam-apps were reinstalled."
echo "[SUCCESS] Please reboot now with:"
echo
echo "sudo reboot"
