#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# Podroid MINIMAL rootfs builder — Arch Linux ARM / Manjaro ARM (pacman).
#
# Runs INSIDE a debian:bookworm arm64 Docker stage. The ALARM aarch64 rootfs
# tarball is extracted to /work/rootfs by the Dockerfile (ADD). All package
# work happens via chroot (no mounts — /dev nodes and resolv.conf are injected,
# /proc is intentionally absent; binary installs tolerate that).
#
# DISTRO=arch   → stock Arch Linux ARM repos (pacman.conf from the tarball)
# DISTRO=manjaro→ Manjaro ARM official repos (repo.manjaro.org arm-stable),
#                 keyring bootstrapped under a short-lived TrustAll window
#                 that is REMOVED before any further sync (verified below).
# ─────────────────────────────────────────────────────────────────────────────
set -eu

DISTRO="${DISTRO:-arch}"
R=/work/rootfs
echo "build-rootfs-pacman.sh: building MINIMAL ${DISTRO} rootfs (systemd, chroot)"

# ── 0. Preflight: device nodes + DNS + chroot pacman must run ───────────────
mkdir -p "$R/dev" "$R/proc" "$R/sys" "$R/tmp" "$R/etc" "$R/var/cache/pacman/pkg"
for n in urandom null zero tty random console ptmx; do
    [ -e "/dev/$n" ] && cp -a "/dev/$n" "$R/dev/$n" 2>/dev/null || true
done
if [ ! -d "$R/etc" ]; then
    rm -f "$R/etc"
    mkdir -p "$R/etc"
fi
rm -f "$R/etc/mtab"
printf 'rootfs / rootfs rw 0 0\n' > "$R/etc/mtab"
rm -f "$R/etc/resolv.conf"
cp /etc/resolv.conf "$R/etc/resolv.conf"

if ! chroot "$R" /usr/bin/pacman -V; then
    echo "FATAL: chroot pacman does not run (binfmt/qemu or ALARM tarball issue)" >&2
    exit 1
fi

# ── 1. Repos ────────────────────────────────────────────────────────────────
if [ "$DISTRO" = "manjaro" ]; then
    # Replace ALARM's pacman.conf with Manjaro ARM official repos.
    # Per-repo TrustAll applies ONLY while bootstrapping manjaro-keyring;
    # Step 3 strips it back to Required and re-syncs to prove signatures work.
    cat > "$R/etc/pacman.conf" <<'EOF'
[options]
HoldPkg = pacman glibc manjaro-system
DisableSandbox
Architecture = aarch64
CheckSpace
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional TrustAll

[core]
Server = https://mirrors.manjaro.org/repo/arm-stable/$repo/$arch
SigLevel = Optional TrustAll

[extra]
Server = https://mirrors.manjaro.org/repo/arm-stable/$repo/$arch
SigLevel = Optional TrustAll

[community]
Server = https://mirrors.manjaro.org/repo/arm-stable/$repo/$arch
SigLevel = Optional TrustAll
EOF
else
    # Arch Linux ARM: stock /etc/pacman.conf from the tarball is correct.
    if ! grep -q '^DisableSandbox$' "$R/etc/pacman.conf"; then
        sed -i '/^\[options\]/a DisableSandbox' "$R/etc/pacman.conf"
    fi
fi

# ── 2. Sync + (manjaro) keyring bootstrap ───────────────────────────────────
chroot "$R" pacman -Sy --noconfirm
if ! chroot "$R" pacman-key --init; then
    echo "FATAL: pacman-key initialization failed" >&2
    exit 1
fi
if [ "$DISTRO" != "manjaro" ]; then
    chroot "$R" pacman-key --populate archlinux archlinuxarm 2>/dev/null || true
fi

if [ "$DISTRO" = "manjaro" ]; then
    if ! chroot "$R" pacman -S --noconfirm --needed archlinux-keyring archlinuxarm-keyring; then
        echo "FATAL: arch keyring packages failed to install" >&2
        exit 1
    fi
    MANJARO_KEYRING_URL="${MANJARO_KEYRING_URL:-https://repo.manjaro.org/repo/stable/core/x86_64/manjaro-keyring-20251003-1-any.pkg.tar.zst}"
    if ! curl -fsSL "$MANJARO_KEYRING_URL" -o "$R/tmp/manjaro-keyring.pkg.tar.zst"; then
        echo "FATAL: manjaro keyring download failed" >&2
        exit 1
    fi
    if ! chroot "$R" pacman -U --noconfirm /tmp/manjaro-keyring.pkg.tar.zst; then
        echo "FATAL: manjaro keyring install failed" >&2
        exit 1
    fi
    rm -f "$R/tmp/manjaro-keyring.pkg.tar.zst"
    chroot "$R" pacman-key --populate manjaro 2>/dev/null || true
    chroot "$R" pacman-key --populate archlinux 2>/dev/null || true
    chroot "$R" pacman-key --populate archlinuxarm 2>/dev/null || true

    # Strip the TrustAll window — it must NOT ship in the image.
    sed -i 's/^SigLevel = Optional TrustAll$/SigLevel = Required DatabaseOptional/' \
        "$R/etc/pacman.conf"
    sed -i 's/^LocalFileSigLevel = Optional TrustAll$/LocalFileSigLevel = Optional/' \
        "$R/etc/pacman.conf"
    if grep -q "TrustAll" "$R/etc/pacman.conf"; then
        echo "FATAL: TrustAll still present in pacman.conf" >&2
        exit 1
    fi
    # Verification sync: signatures must now validate WITHOUT TrustAll.
    if ! chroot "$R" pacman -Sy --noconfirm; then
        echo "FATAL: pacman -Sy failed after keyring populate (signature trust broken)" >&2
        exit 1
    fi
fi

# ── 3. Base + tools + podman stack ──────────────────────────────────────────
chroot "$R" pacman -S --noconfirm --needed \
    bash coreutils findutils gawk grep sed \
    util-linux procps kmod shadow \
    openssl ca-certificates curl wget \
    xz gzip tar file rsync \
    e2fsprogs iproute2 iputils net-tools \
    iptables nftables dhclient \
    openssh sudo vim-minimal less \
    dbus usbutils pciutils

if [ "$DISTRO" = "manjaro" ]; then
    for pkg in \
        podman-6.1.2-1-aarch64.pkg.tar.xz \
        crun-1.29.1-1-aarch64.pkg.tar.xz \
        fuse-overlayfs-1.18-1-aarch64.pkg.tar.xz \
        squashfs-tools-4.7.5-1-aarch64.pkg.tar.xz; do
        curl -fsSL --retry 3 \
            "http://mirror.archlinuxarm.org/aarch64/extra/$pkg" \
            -o "$R/tmp/$pkg"
    done
    chroot "$R" pacman -U --noconfirm \
        /tmp/podman-6.1.2-1-aarch64.pkg.tar.xz \
        /tmp/crun-1.29.1-1-aarch64.pkg.tar.xz \
        /tmp/fuse-overlayfs-1.18-1-aarch64.pkg.tar.xz \
        /tmp/squashfs-tools-4.7.5-1-aarch64.pkg.tar.xz
    rm -f "$R"/tmp/podman-*.pkg.tar.xz "$R"/tmp/crun-*.pkg.tar.xz \
          "$R"/tmp/fuse-overlayfs-*.pkg.tar.xz \
          "$R"/tmp/squashfs-tools-*.pkg.tar.xz
else
    chroot "$R" pacman -S --noconfirm --needed \
        podman crun fuse-overlayfs squashfs-tools
fi

# If the distro repo has no `dhclient` package, this step fails visibly above.
# Contingency (apply only if CI reports "target not found: dhclient"):
#   chroot "$R" pacman -S --noconfirm dhcpcd
#   chroot "$R" ln -sf /usr/bin/dhcpcd /usr/local/bin/dhclient
if ! chroot "$R" /bin/sh -c 'command -v dhclient >/dev/null 2>&1'; then
    echo "FATAL: dhclient missing after package install" >&2
    exit 1
fi

# ── 4. Strip man/docs/locale ────────────────────────────────────────────────
rm -rf "$R"/usr/share/man "$R"/usr/share/doc "$R"/usr/share/locale \
       "$R"/usr/share/info "$R"/usr/share/help "$R"/usr/lib/debug \
       2>/dev/null || true
rm -f "$R/etc/mtab"
ln -s /proc/self/mounts "$R/etc/mtab"

# ── 5. Disable host-bloat services ──────────────────────────────────────────
for svc in NetworkManager NetworkManager-wait-online firewalld \
           avahi-daemon cups bluetooth rpcbind systemd-timesyncd; do
    chroot "$R" systemctl disable --now "$svc" 2>/dev/null || true
done

# ── 6. Machine-id fresh per-boot; resolv.conf owned by podroid-network ──────
: > "$R/etc/machine-id" 2>/dev/null || true
rm -f "$R/etc/resolv.conf" 2>/dev/null || true

# ── 7. No default password + sudo + sshd key-only ───────────────────────────
chroot "$R" passwd -l root 2>/dev/null || true
chmod u+s "$R/usr/bin/sudo" 2>/dev/null || true
mkdir -p "$R/etc/sudoers.d"
echo '%wheel ALL=(ALL) ALL' > "$R/etc/sudoers.d/sudo"
chmod 0440 "$R/etc/sudoers.d/sudo"
# Arch stock sudoers already grants %wheel ALL=(ALL) ALL — ours makes it
# explicit and identical across distros.
mkdir -p "$R/etc/ssh/sshd_config.d"
cat > "$R/etc/ssh/sshd_config.d/10-podroid-nopasswd.conf" <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
chmod 0644 "$R/etc/ssh/sshd_config.d/10-podroid-nopasswd.conf"

# ── 8. Podman storage dirs ──────────────────────────────────────────────────
mkdir -p "$R/var/lib/containers/storage" "$R/run/containers/storage" \
         "$R/run/libpod" "$R/run/crun"

# ── 9. Copy Podroid system files (systemd variant) ──────────────────────────
mkdir -p "$R/usr/local/bin" "$R/usr/local/libexec/podroid"
for f in podroid-resize podroid-terminals podroid-login podroid-getty \
         podroid-getty-extra podroid-backup podroid-update-stats podroid-mirror; do
    cp "/work/files/usr/local/bin/$f" "$R/usr/local/bin/$f"
    chmod +x "$R/usr/local/bin/$f"
done
for f in podroid-bootstrap.sh podroid-network.sh podroid-migrate.sh podroid-getty.sh; do
    cp "/work/files-systemd/usr/local/libexec/podroid/$f" \
       "$R/usr/local/libexec/podroid/$f"
    chmod +x "$R/usr/local/libexec/podroid/$f"
done
ln -sf podroid-hostd "$R/usr/local/bin/podroid-notify"
ln -sf podroid-hostd "$R/usr/local/bin/podroid-forward"
ln -sf podroid-hostd "$R/usr/local/bin/podroid-open"
ln -sf podroid-hostd "$R/usr/local/bin/podroid-power"
ln -sf podroid-hostd "$R/usr/local/bin/podroid-headless"
ln -sf podroid-hostd "$R/usr/local/bin/podroid-server"
chmod +x "$R/usr/local/bin/podroid-"* 2>/dev/null || true

mkdir -p "$R/etc/systemd/system"
for f in podroid-bootstrap.service podroid-migrate.service podroid-network.service \
         podroid-hostd.service podroid-terminals.service podroid-ready.service \
         podroid-vsock.service podroid-downloads.service podroid-getty@.service \
         podroid-resize@.service; do
    cp "/work/files-systemd/etc/systemd/system/$f" "$R/etc/systemd/system/$f"
done

mkdir -p "$R/etc/podroid/migrations" "$R/etc/conf.d" "$R/etc/containers"
cp /work/files/etc/podroid/forwards.conf "$R/etc/podroid/forwards.conf"
cp /work/files/etc/podroid/migrations/README "$R/etc/podroid/migrations/README"
printf '%s\n' "${SYSTEM_VERSION:-0}" > "$R/etc/podroid/system-version"
chmod 0644 "$R/etc/podroid/system-version"
cp /work/files/etc/conf.d/podroid "$R/etc/conf.d/podroid"
cp /work/files/etc/containers/storage.conf "$R/etc/containers/storage.conf"
chmod 0644 "$R/etc/containers/storage.conf"

# ── 10. Hostname / hosts / banner ───────────────────────────────────────────
echo "podroid" > "$R/etc/hostname"
cat > "$R/etc/hosts" <<'EOF'
127.0.0.1 localhost podroid
::1 localhost ip6-localhost
EOF
cat > "$R/etc/issue" <<EOF
Welcome to Podroid-${DISTRO} (${DISTRO})
Kernel \\r on \\m (\\l)

  Login: automatic as root (no password)
  Create a regular user:   useradd -G wheel <name>

EOF

# ── 11. Enable Podroid services ─────────────────────────────────────────────
for u in podroid-migrate podroid-bootstrap podroid-network podroid-hostd \
         podroid-terminals podroid-vsock podroid-downloads podroid-ready; do
    chroot "$R" systemctl enable "$u.service" 2>/dev/null || true
done
chroot "$R" systemctl enable sshd.service 2>/dev/null || true
chroot "$R" systemctl enable "podroid-getty@hvc0.service" 2>/dev/null || true
chroot "$R" systemctl mask "serial-getty@ttyAMA0.service" 2>/dev/null || true

# ── 12. Clean caches ────────────────────────────────────────────────────────
rm -rf "$R/var/cache/pacman/pkg/"* "$R/var/log/pacman.log" \
       "$R/tmp/"* "$R/var/tmp/"* 2>/dev/null || true

# ── 13. In-place rootfs sanity (/work/rootfs already IS the rootfs) ─────────
if [ ! -e "$R/sbin/init" ] && [ ! -e "$R/usr/lib/systemd/systemd" ]; then
    echo "FATAL: no /sbin/init and no usr/lib/systemd/systemd in rootfs" >&2
    exit 1
fi
# ALARM ships systemd; guarantee the sbin/init path systemd images rely on.
if [ ! -e "$R/sbin/init" ] && [ -e "$R/usr/lib/systemd/systemd" ]; then
    ln -sf /usr/lib/systemd/systemd "$R/sbin/init"
fi
echo "build-rootfs-pacman.sh: ${DISTRO} minimal rootfs ready"
