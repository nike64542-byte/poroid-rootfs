#!/bin/bash
# Podroid guest system builder — produces initrd.img (Alpine initramfs) and
# guest rootfs squashfs images (kali / debian / ubuntu, arm64).
#
# Usage: ./build.sh [initramfs|rootfs|all] [SYSTEM_VERSION]
#   rootfs variants: kali, debian, ubuntu (default: all three)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${SCRIPT_DIR}/out"
TARGET="${1:-all}"
SYSTEM_VERSION="${2:-0}"

log() { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
mkdir -p "${OUT}"

build_initramfs() {
    log "Building Alpine initramfs (Docker)..."
    docker build --network=host \
        -t podroid-initramfs-builder \
        -f "${SCRIPT_DIR}/Dockerfile.initramfs" \
        --output type=local,dest="${OUT}" \
        "${SCRIPT_DIR}"
    ls -lh "${OUT}/initrd.img"
}

build_distro_rootfs() {
    local distro="$1"
    local dockerfile="Dockerfile.rootfs"
    local outfile="kali-rootfs.squashfs"
    case "${distro}" in
        kali)   dockerfile="Dockerfile.rootfs";  outfile="kali-rootfs.squashfs" ;;
        debian) dockerfile="Dockerfile.rootfs-debian";  outfile="debian-rootfs.squashfs" ;;
        ubuntu) dockerfile="Dockerfile.rootfs-ubuntu";  outfile="ubuntu-rootfs.squashfs" ;;
        *) echo "unknown distro: ${distro}"; exit 1 ;;
    esac
    log "Building ${distro} rootfs squashfs (Docker)..."
    docker build -f "${SCRIPT_DIR}/build-rootfs/${dockerfile}" \
        -t "podroid-rootfs-${distro}:latest" \
        --platform linux/arm64 \
        --build-arg "SYSTEM_VERSION=${SYSTEM_VERSION}" \
        --output type=local,dest="${OUT}" \
        "${SCRIPT_DIR}/build-rootfs/"
    ls -lh "${OUT}/${outfile}"
}

build_rootfs() {
    # Default: build all three distro rootfs images.
    for d in kali debian ubuntu; do
        build_distro_rootfs "$d"
    done
}

case "${TARGET}" in
    initramfs)      build_initramfs ;;
    rootfs)         build_rootfs ;;
    kali)           build_distro_rootfs kali ;;
    debian)         build_distro_rootfs debian ;;
    ubuntu)         build_distro_rootfs ubuntu ;;
    all)            build_initramfs && build_rootfs ;;
    *) echo "usage: $0 [initramfs|rootfs|kali|debian|ubuntu|all] [SYSTEM_VERSION]"; exit 1 ;;
esac
echo "Artifacts in: ${OUT}"
