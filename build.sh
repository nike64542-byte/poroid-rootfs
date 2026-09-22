#!/bin/bash
# Podroid guest system builder — produces initrd.img (Alpine initramfs) and
# kali-rootfs.squashfs (Kali arm64 guest rootfs).
#
# Usage: ./build.sh [initramfs|rootfs|all] [SYSTEM_VERSION]
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

build_rootfs() {
    log "Building Kali rootfs squashfs (Docker)..."
    docker build -f "${SCRIPT_DIR}/build-rootfs/Dockerfile.rootfs" \
        -t podroid-rootfs:latest \
        --platform linux/arm64 \
        --build-arg "SYSTEM_VERSION=${SYSTEM_VERSION}" \
        --output type=local,dest="${OUT}" \
        "${SCRIPT_DIR}/build-rootfs/"
    ls -lh "${OUT}/kali-rootfs.squashfs"
}

case "${TARGET}" in
    initramfs) build_initramfs ;;
    rootfs)    build_rootfs ;;
    all)       build_initramfs && build_rootfs ;;
    *) echo "usage: $0 [initramfs|rootfs|all]"; exit 1 ;;
esac
echo "Artifacts in: ${OUT}"
