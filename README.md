# poroid-rootfs

Guest system images for Poroid (Android app / aarch64 VM). Produces a shared
Debian initramfs (`initrd.img`) plus one squashfs rootfs per distro. The
matching kernel lives in [poroid-kernel](https://github.com/nike64542-byte/poroid-kernel);
QEMU binaries in [poroid-qemu](https://github.com/nike64542-byte/poroid-qemu).

## Supported distros (10)

| Distro        | Arch  | Init    | Package mgr | Asset                        |
|---------------|-------|---------|-------------|------------------------------|
| Kali          | arm64 | OpenRC  | apt         | `kali-rootfs.squashfs`       |
| Debian 12     | arm64 | OpenRC  | apt         | `debian-rootfs.squashfs`     |
| Ubuntu 24.04  | arm64 | systemd | apt         | `ubuntu-rootfs.squashfs`     |
| Fedora 42     | arm64 | systemd | dnf         | `fedora-rootfs.squashfs`     |
| Rocky 9       | arm64 | systemd | dnf         | `rocky-rootfs.squashfs`      |
| AlmaLinux 9   | arm64 | systemd | dnf         | `alma-rootfs.squashfs`       |
| openSUSE Leap 15.6 | arm64 | systemd | zypper   | `opensuse-rootfs.squashfs`   |
| Arch Linux ARM | arm64 | systemd | pacman     | `arch-rootfs.squashfs`       |
| Manjaro ARM   | arm64 | systemd | pacman      | `manjaro-rootfs.squashfs`    |
| Gentoo        | arm64 | OpenRC  | portage     | `gentoo-rootfs.squashfs`     |

**Not supported:** Linux Mint, EndeavourOS — both ship x86_64 only; Poroid's
VM is aarch64, so no arm64 rootfs exists to build from.

Notes:
- **Arch** uses [Arch Linux ARM](https://archlinuxarm.org) (official Arch repos
  have no aarch64 packages).
- **Manjaro** = Arch Linux ARM base + Manjaro keyring; package transactions
  use ALARM's synchronized aarch64 repositories because the Manjaro ARM
  `arm-stable` database currently references missing package files.
- **Gentoo** installs strictly from official binary packages
  (`--getbinpkg`); the build fails fast if binpkg coverage is missing —
  it never compiles from source under emulation.
- New distros bake **official upstream repos** (no China-mirror swap;
  Ubuntu keeps its existing USTC swap).

## Building

```bash
./build.sh initramfs            # shared Debian initramfs → out/initrd.img
./build.sh fedora               # one distro → out/fedora-rootfs.squashfs
./build.sh rootfs               # all ten rootfs images (slow)
./build.sh all                  # initramfs + all ten
```

CI (GitHub Actions) builds per-distro in parallel via a matrix; dispatch
**构建系统镜像** with `distro=<name>` or `distro=all`. Artifacts also land on
the `latest` Release (`--clobber` overwrite).

## Layout

- `Dockerfile.initramfs` — shared initramfs (Debian-based).
- `build-rootfs/Dockerfile.rootfs[-<distro>]` — one image per distro.
- `build-rootfs/build-rootfs*.sh` — install scripts, split by package manager
  (apt / dnf / zypper / pacman / emerge).
- `build-rootfs/files/` — OpenRC overlay (Kali, Debian, Gentoo).
- `build-rootfs/files-systemd/` — systemd overlay (Ubuntu, Fedora, Rocky,
  Alma, openSUSE, Arch, Manjaro).
- `init-podroid` — initramfs init: switch_root into the chosen rootfs.
