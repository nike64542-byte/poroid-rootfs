#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# Podroid MINIMAL rootfs builder — openSUSE Leap (arm64) + systemd.
# Runs INSIDE opensuse/leap:15.6 arm64 Docker stage (qemu-user on CI).
# Same contract as build-rootfs-dnf.sh: install to /, rsync to /work/rootfs.
# ─────────────────────────────────────────────────────────────────────────────
set -eu
ROOTFS=/
export TZ=UTC

DISTRO="${DISTRO:-opensuse}"
echo "build-rootfs-zypper.sh: building MINIMAL ${DISTRO} rootfs (systemd)"

# ── 1. Base + tools + squashfs tooling (no recommends) ──────────────────────
zypper --non-interactive --gpg-auto-import-keys refresh
zypper --non-interactive install --no-recommends -y \
    bash coreutils findutils gawk grep sed \
    util-linux procps kmod shadow \
    openssl ca-certificates curl wget \
    xz gzip tar file rsync squashfs \
    e2fsprogs iproute2 iputils bind-utils net-tools \
    iptables nftables bridge-utils dhcp-client \
    openssh \
    sudo vim less \
    dbus-1 usbutils pciutils

# ── 2. Podman container runtime ─────────────────────────────────────────────
zypper --non-interactive install --no-recommends -y \
    podman crun fuse-overlayfs

# ── 3. Strip man/docs/locale ─────────────────────────────────────────────────
rm -rf /usr/share/man /usr/share/doc /usr/share/locale /usr/share/info \
       /usr/share/help /usr/lib/debug 2>/dev/null || true

# ── 4. Disable host-bloat services ──────────────────────────────────────────
for svc in NetworkManager NetworkManager-wait-online firewalld \
           avahi-daemon cups bluetooth rpcbind chronyd; do
    systemctl disable --now "$svc" 2>/dev/null || true
done

# ── 5. Machine-id fresh per-boot; resolv.conf owned by podroid-network ──────
: > /etc/machine-id 2>/dev/null || true
rm -f /etc/resolv.conf 2>/dev/null || true

# ── 6. No default password + sudo + sshd key-only ───────────────────────────
passwd -l root 2>/dev/null || true
chmod u+s /usr/bin/sudo 2>/dev/null || true
mkdir -p /etc/sudoers.d
echo '%sudo ALL=(ALL) ALL' > /etc/sudoers.d/sudo
chmod 0440 /etc/sudoers.d/sudo
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-podroid-nopasswd.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
chmod 0644 /etc/ssh/sshd_config.d/10-podroid-nopasswd.conf

# ── 7. Podman storage dirs ──────────────────────────────────────────────────
mkdir -p /var/lib/containers/storage /run/containers/storage \
         /run/libpod /run/crun

# ── 8. Copy Podroid system files (systemd variant) ──────────────────────────
mkdir -p /usr/local/bin /usr/local/libexec/podroid
for f in podroid-resize podroid-terminals podroid-login podroid-getty \
         podroid-getty-extra podroid-backup podroid-update-stats podroid-mirror; do
    cp "/work/files/usr/local/bin/$f" "/usr/local/bin/$f"
    chmod +x "/usr/local/bin/$f"
done
for f in podroid-bootstrap.sh podroid-network.sh podroid-migrate.sh podroid-getty.sh; do
    cp "/work/files-systemd/usr/local/libexec/podroid/$f" \
       "/usr/local/libexec/podroid/$f"
    chmod +x "/usr/local/libexec/podroid/$f"
done
ln -sf podroid-hostd /usr/local/bin/podroid-notify
ln -sf podroid-hostd /usr/local/bin/podroid-forward
ln -sf podroid-hostd /usr/local/bin/podroid-open
ln -sf podroid-hostd /usr/local/bin/podroid-power
ln -sf podroid-hostd /usr/local/bin/podroid-headless
ln -sf podroid-hostd /usr/local/bin/podroid-server
chmod +x /usr/local/bin/podroid-* 2>/dev/null || true

mkdir -p /etc/systemd/system
for f in podroid-bootstrap.service podroid-migrate.service podroid-network.service \
         podroid-hostd.service podroid-terminals.service podroid-ready.service \
         podroid-vsock.service podroid-downloads.service podroid-getty@.service \
         podroid-resize@.service; do
    cp "/work/files-systemd/etc/systemd/system/$f" "/etc/systemd/system/$f"
done

mkdir -p /etc/podroid/migrations /etc/conf.d /etc/containers
cp /work/files/etc/podroid/forwards.conf /etc/podroid/forwards.conf
cp /work/files/etc/podroid/migrations/README /etc/podroid/migrations/README
printf '%s\n' "${SYSTEM_VERSION:-0}" > /etc/podroid/system-version
chmod 0644 /etc/podroid/system-version
cp /work/files/etc/conf.d/podroid /etc/conf.d/podroid
cp /work/files/etc/containers/storage.conf /etc/containers/storage.conf
chmod 0644 /etc/containers/storage.conf

# ── 9. Hostname / hosts / issue deferred to after rsync ────────────────────
# Docker mounts /etc/hostname, /etc/hosts, and often /etc/issue read-only
# during buildx+QEMU builds — write them into the exported rootfs below.

# ── 10. Enable Podroid services ─────────────────────────────────────────────
for u in podroid-migrate podroid-bootstrap podroid-network podroid-hostd \
         podroid-terminals podroid-vsock podroid-downloads podroid-ready; do
    systemctl enable "$u.service" 2>/dev/null || true
done
systemctl enable sshd.service 2>/dev/null || true
systemctl enable "podroid-getty@hvc0.service" 2>/dev/null || true
systemctl mask "serial-getty@ttyAMA0.service" 2>/dev/null || true

# ── 11. Clean caches ────────────────────────────────────────────────────────
zypper clean --all 2>/dev/null || true
rm -rf /var/cache/zypp/* /var/log/* /tmp/* /var/tmp/* 2>/dev/null || true

# ── 12. Copy the installed system to /work/rootfs ───────────────────────────
echo "build-rootfs-zypper.sh: Copying rootfs to /work/rootfs..."
mkdir -p /work/rootfs
rsync -a --delete \
    --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' \
    --exclude='/run/*' --exclude='/tmp/*' --exclude='/var/tmp/*' \
    --exclude='/work/*' --exclude='/*-rootfs.squashfs' \
    --exclude='/etc/resolv.conf' \
    --exclude='/var/cache/zypp/*' --exclude='/var/log/*' \
    / /work/rootfs/

# Docker mounts /etc/hostname and /etc/hosts read-only during build — write
# them into the exported rootfs after rsync instead.
printf 'podroid\n' > /work/rootfs/etc/hostname
cat > /work/rootfs/etc/hosts <<'EOF'
127.0.0.1 localhost podroid
::1 localhost ip6-localhost
EOF
cat > /work/rootfs/etc/issue <<EOF
Welcome to Podroid-${DISTRO} (${DISTRO})
Kernel \\r on \\m (\\l)

  Login: automatic as root (no password)
  Create a regular user:   useradd -G wheel <name>

EOF

if [ ! -e /work/rootfs/sbin/init ]; then
    echo "FATAL: /sbin/init missing from rootfs after rsync!" >&2
    exit 1
fi
echo "build-rootfs-zypper.sh: /sbin/init -> $(readlink -f /work/rootfs/sbin/init)"
echo "build-rootfs-zypper.sh: ${DISTRO} minimal rootfs ready"
