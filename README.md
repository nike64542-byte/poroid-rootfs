# poroid-rootfs

Podroid guest system builder — the operating system that runs inside the
aarch64 micro-VM. Produces two artifacts:

- `initrd.img` — Alpine aarch64 initramfs (podman/netavark/fuse-overlayfs +
  custom `init-podroid` init), packed as gzip cpio.
- `kali-rootfs.squashfs` — Kali Linux arm64 guest rootfs with a lightweight
  XFCE desktop, OpenRC init and the Podroid bridge agents.

Consumed by [poroid-apk](https://github.com/nike64542-byte/poroid-apk): its CI
downloads both artifacts from this repo's `latest` GitHub Release. The matching
kernel `vmlinuz-virt` ships from [poroid-kernel](https://github.com/nike64542-byte/poroid-kernel).

## Build

```bash
./build.sh             # both initramfs + rootfs
./build.sh initramfs   # Alpine initramfs only
./build.sh rootfs      # Kali squashfs only
```

Output lands in `out/`. Requires Docker with arm64 emulation
(`docker/setup-qemu-action` on CI, or a `binfmt_misc` registration locally).

## CI

- `push` to `main` (when `build-rootfs/**`, `init-podroid`,
  `Dockerfile.initramfs` change) or `workflow_dispatch` builds both artifacts
  and uploads them to the `latest` Release.
