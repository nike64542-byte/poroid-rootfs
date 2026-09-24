#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# Podroid MINIMAL rootfs builder — Ubuntu (arm64) + systemd.
#
# NOTE: Ubuntu's repos dropped OpenRC (unlike Debian/Kali), so this image keeps
# systemd as PID 1 and runs the Podroid services as systemd units. The boot
# pipeline differs from the Kali/Debian images (OpenRC) — the initramfs and
# kernel are still shared; only how the rootfs brings up services changes.
#
# Runs INSIDE the ubuntu:24.04 arm64 Docker stage (via qemu-user on x86_64 CI
# runners). Packages are installed to "/"; rsync then copies the system to
# /work/rootfs, which the Dockerfile squashfs-compresses.
#
# MINIMAL design (low-memory VM first):
#   * systemd as init (Ubuntu default).
#   * NO desktop / X11.
#   * podman + crun + fuse-overlayfs only (no docker/lxc).
#   * Host bloat removed — no avahi/bluez/cups, no apt-daily timers.
# ─────────────────────────────────────────────────────────────────────────────
set -eu
ROOTFS=/

export DEBIAN_FRONTEND=noninteractive
export TZ=UTC

DISTRO="${DISTRO:-ubuntu}"
echo "build-rootfs-ubuntu.sh: building MINIMAL ${DISTRO} rootfs (systemd)"

# ── 1. Configure apt sources ─────────────────────────────────────────────────
# arm64 Ubuntu uses ports.ubuntu.com (archive.ubuntu.com is amd64-only).
# Include noble-updates + noble-security: the ubuntu:24.04 base image ships
# point-release packages (e.g. libsystemd0 *.17); building against bare noble
# makes systemd's strict `=x.y` dependency unresolvable (broken packages).
rm -rf /etc/apt/sources.list.d
mkdir -p /etc/apt/sources.list.d
cat > /etc/apt/sources.list <<'EOF'
deb http://ports.ubuntu.com/ubuntu-ports noble main universe
deb http://ports.ubuntu.com/ubuntu-ports noble-updates main universe
deb http://ports.ubuntu.com/ubuntu-ports noble-security main universe
deb-src http://ports.ubuntu.com/ubuntu-ports noble main universe
EOF
apt-get update

# ── 2. Base + tools (no recommends → keep it slim) ───────────────────────────
apt-get install -y --no-install-recommends \
    bash \
    login \
    passwd \
    openssl \
    ca-certificates \
    curl \
    wget \
    xz-utils \
    gzip \
    tar \
    procps \
    kmod \
    util-linux \
    mount \
    e2fsprogs \
    iproute2 \
    iputils-ping \
    dnsutils \
    net-tools \
    iptables \
    nftables \
    bridge-utils \
    openssh-server \
    openssh-client \
    vim-tiny \
    less \
    sudo \
    bash-completion \
    dbus \
    systemd \
    systemd-sysv \
    libpam-modules \
    gawk \
    sed \
    grep \
    findutils \
    coreutils \
    file \
    rsync \
    busybox \
    usbutils \
    pciutils \
    systemd-resolved

# ── 3. Podman container runtime (minimal) ────────────────────────────────────
apt-get install -y --no-install-recommends \
    podman \
    crun \
    fuse-overlayfs \
    fuse3 \
    uidmap \
    slirp4netns \
    passt \
    aardvark-dns \
    netavark \
    catatonit \
    libcap2-bin

# ── 4. Strip man/docs/locale ─────────────────────────────────────────────────
rm -rf /usr/share/man /usr/share/doc /usr/share/locale /usr/share/info \
       /usr/share/help /usr/lib/debug

# ── 5. Disable host-bloat timers/services ────────────────────────────────────
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer \
    systemd-timesyncd 2>/dev/null || true
for svc in avahi-daemon cups bluetooth rsyslog NetworkManager wpa_supplicant; do
    systemctl disable "$svc" 2>/dev/null || true
done

# ── 6. Machine-id (fresh per-boot) + resolved link ───────────────────────────
: > /etc/machine-id 2>/dev/null || true
if [ -L /etc/resolv.conf ] && [ ! -e /run/systemd/resolve/stub-resolv.conf ]; then
    rm -f /etc/resolv.conf 2>/dev/null || true
fi

# ── 7. No default password (passwordless VM) ─────────────────────────────────
passwd -l root 2>/dev/null || true
chmod u+s /usr/bin/sudo 2>/dev/null || true
mkdir -p /etc/sudoers.d
echo '%sudo ALL=(ALL) ALL' > /etc/sudoers.d/sudo
chmod 0440 /etc/sudoers.d/sudo

# Disable SSH password authentication (key-based only).
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-podroid-nopasswd.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
chmod 0644 /etc/ssh/sshd_config.d/10-podroid-nopasswd.conf

# ── 8. Podman storage dirs ───────────────────────────────────────────────────
mkdir -p /var/lib/containers/storage \
         /run/containers/storage \
         /run/libpod \
         /run/crun

# ── 9. Copy Podroid system files ─────────────────────────────────────────────
mkdir -p /usr/local/bin /usr/local/libexec/podroid

# Shared helper scripts (used by both OpenRC and systemd images).
for f in podroid-resize podroid-terminals podroid-login podroid-getty \
         podroid-getty-extra podroid-backup podroid-update-stats podroid-mirror; do
    cp "/work/files/usr/local/bin/$f" "/usr/local/bin/$f"
    chmod +x "/usr/local/bin/$f"
done

# systemd-only bootstrap/network/migrate scripts.
for f in podroid-bootstrap.sh podroid-network.sh podroid-migrate.sh \
         podroid-getty.sh; do
    cp "/work/files-systemd/usr/local/libexec/podroid/$f" \
       "/usr/local/libexec/podroid/$f"
    chmod +x "/usr/local/libexec/podroid/$f"
done

# argv[0]-dispatch symlinks onto the multi-call hostd binary.
ln -sf podroid-hostd /usr/local/bin/podroid-notify
ln -sf podroid-hostd /usr/local/bin/podroid-forward
ln -sf podroid-hostd /usr/local/bin/podroid-open
ln -sf podroid-hostd /usr/local/bin/podroid-power
ln -sf podroid-hostd /usr/local/bin/podroid-headless
ln -sf podroid-hostd /usr/local/bin/podroid-server
chmod +x /usr/local/bin/podroid-* 2>/dev/null || true

# systemd unit files.
mkdir -p /etc/systemd/system
for f in podroid-bootstrap.service podroid-migrate.service podroid-network.service \
         podroid-hostd.service podroid-terminals.service podroid-ready.service \
         podroid-vsock.service podroid-downloads.service podroid-getty@.service \
         podroid-resize@.service; do
    cp "/work/files-systemd/etc/systemd/system/$f" "/etc/systemd/system/$f"
done

# Config + migration dirs.
mkdir -p /etc/podroid
cp "/work/files/etc/podroid/forwards.conf" /etc/podroid/forwards.conf
mkdir -p /etc/podroid/migrations
cp "/work/files/etc/podroid/migrations/README" /etc/podroid/migrations/README
printf '%s\n' "${SYSTEM_VERSION:-0}" > /etc/podroid/system-version
chmod 0644 /etc/podroid/system-version
mkdir -p /etc/conf.d
cp "/work/files/etc/conf.d/podroid" /etc/conf.d/podroid

# containers/storage.conf — pin Podman to in-kernel overlay.
mkdir -p /etc/containers
cp "/work/files/etc/containers/storage.conf" /etc/containers/storage.conf
chmod 0644 /etc/containers/storage.conf

# Hostname + hosts.
echo "podroid" > /etc/hostname
if [ -w /etc/hosts ] || touch /etc/hosts 2>/dev/null; then
    cat > /etc/hosts <<'EOF'
127.0.0.1 localhost podroid
::1 localhost ip6-localhost
EOF
fi

# Login banner.
if [ -w /etc/issue ] || touch /etc/issue 2>/dev/null; then
    cat > /etc/issue <<EOF
Welcome to Podroid-Ubuntu (Ubuntu)
Kernel \r on \m (\l)

  Login: automatic as root (no password)
  Create a regular user:   adduser --ingroup sudo <name>

EOF
fi

# ── 10. Enable Podroid services ──────────────────────────────────────────────
# Systemd ordering through [Unit] After=/Wants=; just enable and let the
# dependency graph order them. set -e: `systemctl enable` is chroot-safe
# (writes symlinks, no daemon interaction).
for u in podroid-migrate podroid-bootstrap podroid-network podroid-hostd \
         podroid-terminals podroid-vsock podroid-downloads podroid-ready; do
    systemctl enable "$u.service" 2>/dev/null || true
done

# Primary terminal getty (hvc0). Avoid a getty on the QEMU boot-log console.
systemctl enable "podroid-getty@hvc0.service" 2>/dev/null || true
systemctl mask "serial-getty@ttyAMA0.service" 2>/dev/null || true

# ── 11. Clean apt caches + China mirror ──────────────────────────────────────
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* /var/cache/apt/archives/partial/* 2>/dev/null || true
rm -rf /tmp/* /var/tmp/* 2>/dev/null || true

UBUNTU_MIRROR="${UBUNTU_MIRROR:-https://mirrors.ustc.edu.cn/ubuntu-ports}"
cat > /etc/apt/sources.list <<EOF
deb $UBUNTU_MIRROR noble main universe
deb $UBUNTU_MIRROR noble-updates main universe
deb $UBUNTU_MIRROR noble-security main universe
deb-src $UBUNTU_MIRROR noble main universe
EOF

# ── 12. Copy the installed system to /work/rootfs ────────────────────────────
echo "build-rootfs-ubuntu.sh: Copying rootfs to /work/rootfs..."
mkdir -p /work/rootfs
rsync -a --delete \
    --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' \
    --exclude='/run/*' --exclude='/tmp/*' --exclude='/var/tmp/*' \
    --exclude='/work/*' --exclude='/*-rootfs.squashfs' \
    --exclude='/var/lib/apt/lists/*' --exclude='/var/cache/apt/*' \
    / /work/rootfs/

# Verify /sbin/init exists (-> systemd).
if [ ! -e /work/rootfs/sbin/init ]; then
    echo "FATAL: /sbin/init missing from rootfs after rsync!" >&2
    ls -la /work/rootfs/sbin/ 2>/dev/null | head -20 >&2
    exit 1
fi
echo "build-rootfs-ubuntu.sh: /sbin/init -> $(readlink -f /work/rootfs/sbin/init)"

echo "build-rootfs-ubuntu.sh: ${DISTRO} minimal rootfs ready"