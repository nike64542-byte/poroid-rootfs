#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# Podroid MINIMAL rootfs builder — Debian / Ubuntu (arm64) + OpenRC.
#
# Runs INSIDE the debian:bookworm / ubuntu:24.04 arm64 Docker stage (via
# qemu-user on x86_64 CI runners). Packages are installed to "/" (the
# container root). After installation, rsync copies the system to
# /work/rootfs, which the Dockerfile then squashfs-compresses.
#
# Same boot pipeline as the Kali image: sysvinit + OpenRC (NO systemd),
# podroid-* OpenRC services, hvc gettys from inittab. Because initramfs
# switch_roots to /sbin/init and every driver is built into the kernel,
# this minimal image boots identically under the shared vmlinuz-virt +
# initrd.img — no kernel/initramfs rebuild needed.
#
# Design (MINIMAL — low-memory VM first):
#   * NO systemd — openrc + sysvinit-core provide /sbin/init.
#   * NO desktop / X11 — headless; user installs what they want.
#   * NO wireless/firmware/aircrack — Kali-only pentest stack.
#   * NO docker/lxc — podman + crun + fuse-overlayfs only.
#   * Host bloat removed — no avahi/bluez/cups, no apt timers.
# ─────────────────────────────────────────────────────────────────────────────
set -eu
ROOTFS=/

export DEBIAN_FRONTEND=noninteractive
export TZ=UTC

DISTRO="${DISTRO:-debian}"
echo "build-rootfs-minimal.sh: building MINIMAL ${DISTRO} rootfs"

# ── 1. Configure apt sources ─────────────────────────────────────────────────
# The build runs on GitHub Actions (US); use the official hosts for the build
# itself. At the end (section 12) we switch the baked-in sources.list to a
# China-friendly mirror the end user can download from fast.
rm -rf /etc/apt/sources.list.d
mkdir -p /etc/apt/sources.list.d

if [ "${DISTRO}" = "ubuntu" ]; then
    cat > /etc/apt/sources.list <<'EOF'
deb http://archive.ubuntu.com/ubuntu noble main universe
deb-src http://archive.ubuntu.com/ubuntu noble main universe
EOF
else
    cat > /etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian bookworm main non-free-firmware
deb-src http://deb.debian.org/debian bookworm main non-free-firmware
EOF
fi

apt-get update

# ── 2. Kill systemd before it can ever run ────────────────────────────────────
for p in systemd-sysv systemd systemd-timesyncd systemd-coredump; do
    apt-get purge -y --allow-remove-essential "$p" 2>/dev/null || true
done

# ── 3. Base + init + tools (no recommends → keep it slim) ────────────────────
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
    libpam-modules \
    gawk \
    sed \
    grep \
    findutils \
    coreutils \
    file \
    rsync \
    dosfstools \
    busybox \
    udhcpc \
    usbutils \
    pciutils \
    openrc \
    sysvinit-core \
    sysvinit-utils

# ── 4. Podman container runtime (no docker/lxc — keep it minimal) ────────────
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

# ── 5. Strip man/docs/locale to shrink the squashfs ───────────────────────────
rm -rf /usr/share/man /usr/share/doc /usr/share/locale /usr/share/info \
       /usr/share/help /usr/lib/debug

# ── 6. System-level debloat ───────────────────────────────────────────────────
rm -rf /etc/apt/apt.conf.d/20auto-upgrades \
       /etc/apt/apt.conf.d/50unattended-upgrades \
       /etc/cron.d/apt-compat \
       /etc/cron.daily/apt-compat \
       /lib/systemd/system/apt-daily.timer \
       /lib/systemd/system/apt-daily-upgrade.timer 2>/dev/null || true

for svc in avahi-daemon bluetooth cups rsyslog syslog-ng cron anacron atd \
           network-manager wpa_supplicant; do
    rm -f "/etc/init.d/$svc" "/etc/init.d/$svc"* 2>/dev/null || true
    rm -f "/etc/runlevels/default/$svc" "/etc/runlevels/boot/$svc" 2>/dev/null || true
done

rm -rf /lib/systemd 2>/dev/null || true

# ── 7. OpenRC + sysvinit wiring ───────────────────────────────────────────────
SYSVINIT_INIT=$(dpkg -L sysvinit-core 2>/dev/null \
    | grep -E '(^|/)init$' | head -1 || true)
if [ -z "$SYSVINIT_INIT" ] || [ ! -x "$SYSVINIT_INIT" ]; then
    for p in /lib/sysvinit/init /usr/lib/sysvinit/init \
             /sbin/init /usr/sbin/init; do
        [ -x "$p" ] && SYSVINIT_INIT="$p" && break
    done
fi
if [ -n "$SYSVINIT_INIT" ] && [ -x "$SYSVINIT_INIT" ]; then
    REAL_SBIN=$(readlink -f /sbin/init 2>/dev/null || true)
    REAL_NEW=$(readlink -f "$SYSVINIT_INIT" 2>/dev/null || true)
    if [ "$REAL_SBIN" != "$REAL_NEW" ]; then
        ln -sf "$SYSVINIT_INIT" /sbin/init
    fi
    chmod 755 /sbin/init
else
    echo "ERROR: sysvinit init binary not found" >&2
    dpkg -L sysvinit-core 2>/dev/null | head -30 >&2
    ls -la /lib/sysvinit/ /usr/lib/sysvinit/ /sbin/init /usr/sbin/init 2>/dev/null >&2
    exit 1
fi
mkdir -p /etc/runlevels/default /etc/runlevels/boot /etc/runlevels/shutdown /etc/runlevels/sysinit

# D-Bus needs a machine-id or dbus-daemon fails.
if [ ! -s /etc/machine-id ] && [ ! -s /var/lib/dbus/machine-id ]; then
    rm -f /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true
    dbus-uuidgen --ensure=/var/lib/dbus/machine-id 2>/dev/null || true
    [ -s /var/lib/dbus/machine-id ] && ln -sf /var/lib/dbus/machine-id /etc/machine-id
fi

# ── 8. No default password (passwordless VM) ──────────────────────────────────
passwd -l root 2>/dev/null || true
chmod u+s /usr/bin/sudo 2>/dev/null || true
mkdir -p /etc/sudoers.d
echo '%sudo ALL=(ALL) ALL' > /etc/sudoers.d/sudo
chmod 0440 /etc/sudoers.d/sudo

# Disable SSH password authentication (key-based only, like Kali image).
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-podroid-nopasswd.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
chmod 0644 /etc/ssh/sshd_config.d/10-podroid-nopasswd.conf

# ── 9. Podman storage dirs (first-boot speedup) ───────────────────────────────
mkdir -p /var/lib/containers/storage \
         /run/containers/storage \
         /run/libpod \
         /run/crun

# ── 10. Copy Podroid system files ─────────────────────────────────────────────
# Init scripts — Podroid's OpenRC services.
for f in podroid-bootstrap podroid-network podroid-terminals podroid-ready \
         podroid-vsock podroid-hostd podroid-downloads podroid-migrate podroid-resize; do
    cp "/work/files/etc/init.d/$f" "/etc/init.d/$f"
    chmod +x "/etc/init.d/$f"
done

# /usr/local/bin helper scripts.
mkdir -p /usr/local/bin
for f in podroid-resize podroid-terminals podroid-login podroid-getty podroid-getty-extra podroid-backup podroid-update-stats podroid-mirror; do
    cp "/work/files/usr/local/bin/$f" "/usr/local/bin/$f"
    chmod +x "/usr/local/bin/$f"
done
# argv[0]-dispatch symlinks onto the multi-call hostd binary.
ln -sf podroid-hostd /usr/local/bin/podroid-notify
ln -sf podroid-hostd /usr/local/bin/podroid-forward
ln -sf podroid-hostd /usr/local/bin/podroid-open
ln -sf podroid-hostd /usr/local/bin/podroid-power
ln -sf podroid-hostd /usr/local/bin/podroid-headless
ln -sf podroid-hostd /usr/local/bin/podroid-server
chmod +x /usr/local/bin/podroid-* 2>/dev/null || true

# Config + conf.d + migration dirs.
mkdir -p /etc/conf.d
cp /work/files/etc/conf.d/podroid /etc/conf.d/podroid
mkdir -p /etc/podroid
cp /work/files/etc/podroid/forwards.conf /etc/podroid/forwards.conf
chmod 0644 /etc/podroid/forwards.conf
mkdir -p /etc/podroid/migrations
cp /work/files/etc/podroid/migrations/README /etc/podroid/migrations/README
printf '%s\n' "${SYSTEM_VERSION:-0}" > /etc/podroid/system-version
chmod 0644 /etc/podroid/system-version

# inittab + rc.conf (Podroid's OpenRC/sysvinit wiring).
cp /work/files/etc/inittab /etc/inittab
cp /work/files/etc/rc.conf /etc/rc.conf

# profile.d hooks.
mkdir -p /etc/profile.d
cp /work/files/etc/profile.d/podroid-color.sh /etc/profile.d/
chmod 0644 /etc/profile.d/podroid-color.sh

# containers/storage.conf — pin Podman to in-kernel overlay.
mkdir -p /etc/containers
cp /work/files/etc/containers/storage.conf /etc/containers/storage.conf
chmod 0644 /etc/containers/storage.conf

# Hostname.
echo "podroid" > /etc/hostname
if [ -w /etc/hosts ] || touch /etc/hosts 2>/dev/null; then
    cat > /etc/hosts <<'EOF'
127.0.0.1 localhost podroid
::1 localhost ip6-localhost
EOF
else
    echo "build-rootfs-minimal.sh: /etc/hosts read-only, skipping"
fi

# Login banner.
if [ -w /etc/issue ] || touch /etc/issue 2>/dev/null; then
    cat > /etc/issue <<EOF
Welcome to Podroid-${DISTRO} (${DISTRO})
Kernel \r on \m (\l)

  Login: automatic as root (no password)
  Create a regular user:   adduser --ingroup sudo <name>

EOF
else
    echo "build-rootfs-minimal.sh: /etc/issue read-only, skipping"
fi

# ── 11. OpenRC runlevels (direct symlinks — host is x86_64, no chroot) ───────
for svc in podroid-migrate podroid-bootstrap podroid-network podroid-terminals \
           podroid-vsock podroid-downloads podroid-hostd podroid-ready; do
    if [ -e "/etc/init.d/$svc" ]; then
        ln -sf "/etc/init.d/$svc" "/etc/runlevels/default/$svc"
    else
        echo "WARN: init script /etc/init.d/$svc missing, skipping runlevel symlink"
    fi
done

# Disable services we don't need in the VM (initramfs handles them, or noise).
for svc in hwclock networking sysctl bootmisc syslog; do
    rm -f "/etc/runlevels/boot/$svc" "/etc/runlevels/default/$svc" 2>/dev/null || true
done

# ── 12. Clean apt caches + bake in a China-friendly mirror ────────────────────
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* /var/cache/apt/archives/partial/* 2>/dev/null || true
rm -rf /tmp/* /var/tmp/* 2>/dev/null || true

if [ "${DISTRO}" = "ubuntu" ]; then
    UBUNTU_MIRROR="${UBUNTU_MIRROR:-https://mirrors.ustc.edu.cn/ubuntu}"
    cat > /etc/apt/sources.list <<EOF
deb $UBUNTU_MIRROR noble main universe
deb-src $UBUNTU_MIRROR noble main universe
EOF
else
    DEBIAN_MIRROR="${DEBIAN_MIRROR:-https://mirrors.ustc.edu.cn/debian}"
    cat > /etc/apt/sources.list <<EOF
deb $DEBIAN_MIRROR bookworm main non-free-firmware
deb-src $DEBIAN_MIRROR bookworm main non-free-firmware
EOF
fi

# ── 13. Copy the installed system to /work/rootfs ──────────────────────────────
echo "build-rootfs-minimal.sh: Copying rootfs to /work/rootfs..."
mkdir -p /work/rootfs
rsync -a --delete \
    --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' \
    --exclude='/run/*' --exclude='/tmp/*' --exclude='/var/tmp/*' \
    --exclude='/work/*' --exclude='/*-rootfs.squashfs' \
    --exclude='/var/lib/apt/lists/*' --exclude='/var/cache/apt/*' \
    / /work/rootfs/

# Verify /sbin/init is present — switch_root will panic if it's missing.
if [ ! -e /work/rootfs/sbin/init ]; then
    echo "FATAL: /sbin/init missing from rootfs after rsync!" >&2
    ls -la /work/rootfs/sbin/ 2>/dev/null | head -20 >&2
    exit 1
fi
echo "build-rootfs-minimal.sh: /sbin/init -> $(readlink -f /work/rootfs/sbin/init)"

echo "build-rootfs-minimal.sh: ${DISTRO} minimal rootfs ready"
