# poroid-rootfs

Podroid guest system builder — produces the boot initramfs plus guest rootfs
images (arm64). **Kernel is NOT here** — it lives in
[poroid-kernel](https://github.com/nike64542-byte/poroid-kernel) and is shared
by every distro image.

## What are the two artifacts?

The VM boots in **two stages**:

```
vmlinuz-virt (kernel)
   └─ initrd.img (Debian initramfs)  ← boots first, tiny, distro-agnostic
        └─ mounts /dev/vda (user data) + /dev/vdb (squashfs)
        └─ switch_root → the real guest OS's /sbin/init
```

- **`initrd.img` = Debian initramfs** — a minimal "ignition" stage built from
  Debian (bookworm-slim). It only contains `init-podroid` (mounts the
  persistent overlay + the squashfs, then hands off to the real rootfs) and the
  handful of tools it needs (`mount`, `switch_root`, `e2fsprogs`, `kmod`,
  `coreutils`). It is **shared by all distro images** and does not need to be
  rebuilt per distro.
- **`kali/debian/ubuntu-rootfs.squashfs` = the actual guest OS** — the Linux
  system you log into. Each distro is a separate artifact.

The custom kernel has every needed driver built in (`=y`, no modules), and all
distro images use the **same OpenRC/sysvinit boot pipeline** (no systemd), so
the initramfs, kernel, and boot flow are 100% shared. Only the squashfs differs
per distro.

## Artifacts

| Artifact | What it is |
|---|---|
| `initrd.img` | Debian aarch64 initramfs (shared boot stage) |
| `kali-rootfs.squashfs` | Kali Linux (full: podman + docker/lxc + X11 server, OpenRC) |
| `debian-rootfs.squashfs` | Debian 12 minimal (ssh + podman only, OpenRC) |
| `ubuntu-rootfs.squashfs` | Ubuntu 24.04 minimal (ssh + podman only, OpenRC) |

All squashfs use zstd compression (the only compressor compiled into the kernel).

## Build

```bash
./build.sh initramfs     # Debian initramfs only
./build.sh kali          # Kali rootfs only
./build.sh debian        # Debian minimal rootfs only
./build.sh ubuntu        # Ubuntu minimal rootfs only
./build.sh rootfs        # all three distro rootfs
./build.sh all           # initramfs + all three distro rootfs
```

Output lands in `out/`. Requires Docker with arm64 emulation
(`docker/setup-qemu-action` on CI, or a `binfmt_misc` registration locally).

## CI

One run builds **one** image — pick the `distro` when you trigger manually:

- `workflow_dispatch` → `distro` input: `initramfs` / `kali` / `debian` /
  `ubuntu` / `all` (default `kali`).
- `push` to `main` → builds `kali` by default (config change = default distro).

The built artifact is uploaded to the `latest` Release.

## Artifact flow

[poroid-apk](https://github.com/nike64542-byte/poroid-apk) downloads from this
repo's `latest` Release:
- always: `initrd.img`
- plus whichever rootfs the app is configured to boot
  (`kali-rootfs.squashfs` / `debian-rootfs.squashfs` / `ubuntu-rootfs.squashfs`).
