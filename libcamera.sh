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
  fail "Please run this script as the pi user, not as root. Use: bash reinstall_will_libcamera.sh"
fi

cd "$HOME"

log "Updating package lists"
sudo apt update

log "Installing libcamera build dependencies"
sudo apt install -y \
  git \
  meson \
  ninja-build \
  python3-pip \
  python3-jinja2 \
  python3-ply \
  python3-yaml \
  libyaml-dev \
  libboost-program-options-dev \
  libdrm-dev \
  libexif-dev \
  libepoxy-dev \
  libjpeg-dev \
  libtiff5-dev \
  libpng-dev \
  libavcodec-dev \
  libavdevice-dev \
  libavformat-dev \
  libswresample-dev \
  cmake

log "Removing existing libcamera source directory"
rm -rf "$HOME/libcamera"

log "Cloning Will Whang's libcamera repository"
git clone https://github.com/will127534/libcamera.git "$HOME/libcamera"

log "Configuring libcamera"
cd "$HOME/libcamera"
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

log "Installing rpicam-apps build dependencies"
sudo apt install -y \
  cmake \
  libboost-program-options-dev \
  libdrm-dev \
  libexif-dev \
  libepoxy-dev \
  libjpeg-dev \
  libtiff5-dev \
  libpng-dev \
  meson \
  ninja-build \
  libavcodec-dev \
  libavdevice-dev \
  libavformat-dev \
  libswresample-dev

log "Removing existing rpicam-apps source directory"
rm -rf "$HOME/rpicam-apps"

log "Cloning Will Whang's rpicam-apps repository"
cd "$HOME"
git clone https://github.com/will127534/rpicam-apps.git "$HOME/rpicam-apps"

log "Configuring rpicam-apps"
cd "$HOME/rpicam-apps"
meson setup build \
  -Denable_libav=enabled \
  -Denable_drm=enabled \
  -Denable_egl=enabled \
  -Denable_qt=enabled \
  -Denable_opencv=disabled \
  -Denable_tflite=disabled

log "Building rpicam-apps"
meson compile -C build

log "Installing rpicam-apps"
sudo meson install -C build

log "Refreshing linker cache"
sudo ldconfig

log "Reinstall complete"
echo "You should reboot now."
echo "Command: sudo reboot"
