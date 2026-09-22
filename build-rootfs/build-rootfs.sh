#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# Podroid rootfs builder — Kali Linux (arm64) + OpenRC, NO preinstalled desktop.
#
# Runs INSIDE the kalilinux/kali-rolling arm64 Docker stage (via qemu-user on
# x86_64 CI runners). Packages are installed to "/" (the container root) because
# apt-get has no --root option. After installation, rsync copies the system to
# /work/rootfs, which the Dockerfile then squashfs-compresses.
#
# Design goals (low-memory VM first):
#   * NO systemd — OpenRC + sysvinit-core provide /sbin/init, inittab calls
#     /sbin/openrc (keeps the full Podroid podroid-* OpenRC boot pipeline).
#   * NO desktop preinstalled — user installs XFCE on-demand (low-memory first).
#   * Host bloat removed — no avahi/bluez/cups/modemmanager, no apt-daily
#     timers, no man-db/mlocate cron, journald (if present) volatile+small.
#   * Container runtime kept — podman/docker/lxc + overlayfs graph drivers.
# ─────────────────────────────────────────────────────────────────────────────
set -eu
ROOTFS=/

export DEBIAN_FRONTEND=noninteractive
export TZ=UTC

# ── 1. Configure Kali apt sources ─────────────────────────────────────────────
# Use only /etc/apt/sources.list; remove any image-shipped extras.
rm -rf /etc/apt/sources.list.d
mkdir -p /etc/apt/sources.list.d
# Default mirror. The build runs on GitHub Actions (US), so use the official
# host for the build itself (fast there). At the end of the script (before
# rsync into /work/rootfs) we switch the baked-in sources.list to a mirror the
# end user can download from fast — see section 16. The guest also ships
# `podroid-mirror` to switch mirrors at runtime.
cat > /etc/apt/sources.list <<'EOF'
deb http://http.kali.org/kali kali-rolling main contrib non-free non-free-firmware
deb-src http://http.kali.org/kali kali-rolling main contrib non-free non-free-firmware
EOF

# Ensure the keyring is present (kalilinux image ships it; guard anyway).
apt-get update

# ── 2. Kill systemd before it can ever run ────────────────────────────────────
# If systemd-sysv was installed it owns the /sbin/init alternatives link; we
# want sysvinit's. Remove systemd init + its package set (best effort — a
# package that hard-depends on systemd stays put, which is fine as long as
# its init scripts are not enabled).
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
    ipset \
    iptables \
    nftables \
    bridge-utils \
    tcpdump \
    openssh-server \
    openssh-client \
    vim \
    less \
    sudo \
    bash-completion \
    dbus \
    dbus-x11 \
    libpam-modules \
    polkitd \
    pkexec \
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
    usb-modeswitch \
    usb-modeswitch-data \
    openrc \
    sysvinit-core \
    sysvinit-utils \
    procps

# ── 4. Container runtimes (Podman / Docker / LXC) ─────────────────────────────
# Docker is optional-but-expected in Podroid; keep the full stack working.
apt-get install -y --no-install-recommends \
    podman \
    docker.io \
    docker-compose \
    lxc \
    lxc-templates \
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

# ── 5. X11 server stack (no desktop — user installs one on demand) ────────────
# The podroid-x11 service needs Xvnc + pulseaudio at boot to back the in-app
# viewer/audio. XFCE itself is deliberately NOT preinstalled (low-memory
# first); the user installs a desktop on-demand:
#
#   apt install xfce4 xfce4-terminal xfce4-whiskermenu-plugin fonts-dejavu dbus-x11
#   podroid-xfce start        # on DISPLAY :0 (Xvnc is up on 5900)
apt-get install -y --no-install-recommends \
    tigervnc-standalone-server \
    pulseaudio \
    pulseaudio-utils \
    dbus-x11 \
    xauth \
    xfonts-base \
    fonts-dejavu-core

# ── 5b. USB WiFi/NIC firmware + wireless tooling ─────────────────────────────
# The kernel builds in the USB NIC + WiFi drivers (=y, see podroid_kernel.config).
# But USB WiFi adapters need firmware blobs shipped separately, and the aircrack
# toolchain is what the guest uses to capture WiFi handshakes. Install firmware
# for the common monitor-mode sticks + the wireless/aircrack tooling.
# Firmware is best-effort: a single unavailable blob package must not fail the
# whole rootfs build (a USB stick only needs ITS OWN firmware, not every vendor's).
apt-get install -y --no-install-recommends \
    firmware-ath9k-htc \
    firmware-realtek \
    firmware-ralink \
    firmware-mediatek \
    firmware-misc-nonfree \
    firmware-linux-nonfree \
    iw \
    wireless-tools \
    rfkill \
    wpasupplicant \
    aircrack-ng \
    || echo "WARN: one or more wireless/firmware packages failed to install (continuing)"

# ── 5c. Regulatory database variant ──────────────────────────────────────────
# The guest kernel is built from upstream source with
#   CONFIG_CFG80211_REQUIRE_SIGNED_REGDB=y
#   CONFIG_CFG80211_USE_KERNEL_REGDB_KEYS=y
# so cfg80211 only accepts a regulatory.db signed by the upstream key. Debian's
# wireless-regdb ships two variants under update-alternatives and defaults to
# -debian (priority 100), which is signed with Debian's own key — cfg80211
# rejects it *silently*: boot logs "cfg80211: failed to load regulatory.db" and
# `iw reg set` returns 0 while doing nothing. The guest then stays in the world
# (00) domain forever, which marks every 5GHz channel NO-IR/PASSIVE-SCAN and
# makes monitor-mode injection impossible on 5G (2.4G still works, which makes
# this easy to misdiagnose as a driver problem).
# regulatory.db may not exist if wireless-regdb is unavailable; guard the call.
if update-alternatives --list regulatory.db >/dev/null 2>&1; then
    update-alternatives --set regulatory.db /lib/firmware/regulatory.db-upstream 2>/dev/null || true
fi

# ── 5d. Regulatory domain after boot ─────────────────────────────────────────
# The domain CANNOT be set at kernel init: at t≈5s cfg80211 requests
# regulatory.db while the real root is still unmounted (initramfs), so the load
# fails with -ENOENT and even the `cfg80211.ieee80211_regdom=` kernel parameter
# is a no-op. Apply it from userspace instead, once the root is up.
#
# Opt-in and intentionally left unset: wireless transmit rules differ per
# country, so the image must not hardcode one. Set it in the guest with
#   echo 'REGDOMAIN=<your ISO 3166-1 alpha2>' > /etc/default/regdomain
# Leaving it empty keeps the world (00) domain (2.4G only for TX).
mkdir -p /etc/local.d
cat > /etc/local.d/regdom.start <<'EOF'
#!/bin/sh
# Apply the country code chosen in /etc/default/regdomain.
# Empty/commented = stay in the world domain.
[ -r /etc/default/regdomain ] || exit 0
REGDOMAIN=
. /etc/default/regdomain
case "${REGDOMAIN:-}" in
    ?? ) command -v iw >/dev/null 2>&1 && iw reg set "$REGDOMAIN" 2>/dev/null ;;
esac
exit 0
EOF
chmod +x /etc/local.d/regdom.start
# Enable OpenRC's `local` service (runs /etc/local.d/*.start at boot). Guarded
# like section 14 so a missing init script can't break the build.
if [ -e /etc/init.d/local ]; then
    mkdir -p /etc/runlevels/default
    ln -sf /etc/init.d/local /etc/runlevels/default/local
fi

# ── 6. Strip man/docs/locale to shrink the squashfs ───────────────────────────
rm -rf /usr/share/man /usr/share/doc /usr/share/locale /usr/share/info \
       /usr/share/help /usr/share/icons/Adwaita /usr/lib/debug

# ── 7. System-level debloat (low-memory first) ───────────────────────────────
# apt-daily / unattended-upgrades / apt timers — none of these should run in
# a short-lived VM; disable them all.
rm -rf /etc/apt/apt.conf.d/20auto-upgrades \
       /etc/apt/apt.conf.d/50unattended-upgrades \
       /etc/cron.d/apt-compat \
       /etc/cron.daily/apt-compat \
       /lib/systemd/system/apt-daily.timer \
       /lib/systemd/system/apt-daily-upgrade.timer \
       /etc/init.d/unattended-upgrades 2>/dev/null || true

# man-db / mlocate background indexers — disable.
rm -f /etc/cron.daily/man-db /etc/cron.daily/man-db.real 2>/dev/null || true
rm -f /etc/cron.weekly/man-db /etc/cron.weekly/man-db.real 2>/dev/null || true
rm -f /etc/cron.daily/mlocate /etc/cron.daily/plocate 2>/dev/null || true
# Replace the man-db cron with a stub that does nothing.
cat > /etc/cron.daily/man-db <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x /etc/cron.daily/man-db 2>/dev/null || true

# Unwanted always-on services we explicitly do NOT want in the VM.
for svc in avahi-daemon bluetooth cups modemmanager wpa_supplicant \
           network-manager rsyslog syslog-ng cron anacron atd; do
    rm -f "/etc/init.d/$svc" "/etc/init.d/$svc"* 2>/dev/null || true
    rm -f "/etc/runlevels/default/$svc" "/etc/runlevels/boot/$svc" 2>/dev/null || true
done

# Ensure no systemd unit dirs can be picked up by a stray systemd.
rm -rf /lib/systemd 2>/dev/null || true

# ── 8. OpenRC + sysvinit wiring ───────────────────────────────────────────────
# Kali (bookworm+) uses usrmerge: /sbin -> /usr/sbin.
# sysvinit-core may install its init binary under different paths depending on
# the release.  Locate it reliably, then create /sbin/init.
# Step 1: find what sysvinit-core actually shipped.
SYSVINIT_INIT=$(dpkg -L sysvinit-core 2>/dev/null \
    | grep -E '(^|/)init$' | head -1 || true)
if [ -z "$SYSVINIT_INIT" ] || [ ! -x "$SYSVINIT_INIT" ]; then
    # Fallback: search known paths.
    for p in /lib/sysvinit/init /usr/lib/sysvinit/init \
             /sbin/init /usr/sbin/init; do
        [ -x "$p" ] && SYSVINIT_INIT="$p" && break
    done
fi
if [ -n "$SYSVINIT_INIT" ] && [ -x "$SYSVINIT_INIT" ]; then
    echo "build-rootfs.sh: sysvinit init found at $SYSVINIT_INIT"
    # On usrmerge systems /sbin -> /usr/sbin; ln -sf would fail with
    # "are the same file".  Only create the symlink when paths differ.
    REAL_SBIN=$(readlink -f /sbin/init 2>/dev/null || true)
    REAL_NEW=$(readlink -f "$SYSVINIT_INIT" 2>/dev/null || true)
    if [ "$REAL_SBIN" != "$REAL_NEW" ]; then
        ln -sf "$SYSVINIT_INIT" /sbin/init
    fi
    chmod 755 /sbin/init
else
    echo "ERROR: sysvinit init binary not found" >&2
    echo "  sysvinit-core package files:" >&2
    dpkg -L sysvinit-core 2>/dev/null | head -30 >&2
    echo "  searching all known paths:" >&2
    ls -la /lib/sysvinit/    2>/dev/null | head -5 >&2
    ls -la /usr/lib/sysvinit/ 2>/dev/null | head -5 >&2
    ls -la /sbin/init /usr/sbin/init 2>/dev/null >&2
    exit 1
fi
# BusyBox may also provide /sbin/init; make sure ours wins.
ls -la /sbin/init
# Ensure /etc/runlevels exist for OpenRC's inittab calls.
mkdir -p /etc/runlevels/default /etc/runlevels/boot /etc/runlevels/shutdown /etc/runlevels/sysinit

# D-Bus needs a machine-id or dbus-daemon fails to start a session bus
# (which XFCE and many tools require). The kali image ships none.
if [ ! -s /etc/machine-id ] && [ ! -s /var/lib/dbus/machine-id ]; then
    rm -f /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true
    systemd-machine-id-setup 2>/dev/null \
        || dbus-uuidgen --ensure=/var/lib/dbus/machine-id 2>/dev/null \
        || true
    if [ -s /var/lib/dbus/machine-id ]; then
        ln -sf /var/lib/dbus/machine-id /etc/machine-id
    fi
fi

# ── 9. dbus minimal config ────────────────────────────────────────────────────
# Keep only the session bus autostart (XFCE needs it) but disable activation
# of heavy/harmless services we don't use: printer, avahi, colord, upower,
# geoclue, etc. We remove the .service files so D-Bus can't lazy-activate them.
rm -f /usr/share/dbus-1/services/org.freedesktop.ColorManager.service 2>/dev/null || true
rm -f /usr/share/dbus-1/services/org.freedesktop.UPower.service 2>/dev/null || true
rm -f /usr/share/dbus-1/services/org.freedesktop.Avahi.service 2>/dev/null || true
rm -f /usr/share/dbus-1/services/org.freedesktop.GeoClue2.service 2>/dev/null || true
rm -f /usr/share/dbus-1/services/org.freedesktop.PackageKit.service 2>/dev/null || true
rm -f /usr/share/dbus-1/services/org.freedesktop.hostname1.service 2>/dev/null || true
rm -f /usr/share/dbus-1/system-services/org.freedesktop.ColorManager.service 2>/dev/null || true
rm -f /usr/share/dbus-1/system-services/org.freedesktop.UPower.service 2>/dev/null || true
rm -f /usr/share/dbus-1/system-services/org.freedesktop.Avahi.service 2>/dev/null || true
rm -f /usr/share/dbus-1/system-services/org.freedesktop.GeoClue2.service 2>/dev/null || true
rm -f /usr/share/dbus-1/system-services/org.freedesktop.PackageKit.service 2>/dev/null || true

# ── 10. journald (if the systemd-less base ships it) — volatile + tiny ──────
if [ -f /etc/systemd/journald.conf ]; then
    sed -i 's/^#\?Storage=.*/Storage=volatile/' /etc/systemd/journald.conf
    sed -i 's/^#\?SystemMaxUse=.*/SystemMaxUse=16M/' /etc/systemd/journald.conf
fi

# ── 11. No default password (passwordless VM) ────────────────────────────────
# Podroid logs in with NO password: the getty auto-logs-in as root (see
# podroid-getty / podroid-login) and sshd disables password auth (section 11b).
# The old `root:podroid` default is intentionally removed. Lock the password
# field as defense-in-depth so nothing can ever authenticate with a
# known/empty password (autologin uses `login -f`, which bypasses auth).
passwd -l root 2>/dev/null || true
# Ensure sudo is setuid root (sometimes lost on overlay builders).
chmod u+s /usr/bin/sudo 2>/dev/null || true
mkdir -p /etc/sudoers.d
echo '%sudo ALL=(ALL) ALL' > /etc/sudoers.d/sudo
chmod 0440 /etc/sudoers.d/sudo
# Let wheel also sudo (Debian convention keeps wheel members able to su).
echo '%wheel ALL=(ALL) ALL' >> /etc/sudoers.d/sudo
# doas for anyone who prefers it (OpenRC-adjacent convention).
mkdir -p /etc/doas.d
echo 'permit persist :wheel' > /etc/doas.d/doas.conf
chmod 0400 /etc/doas.d/doas.conf 2>/dev/null || true

# ── 11b. Disable SSH password authentication (passwordless VM) ────────────────
# Remote access is key-based only. No account in the VM can authenticate with a
# password over SSH. Users add their own ~/.ssh/authorized_keys if they want in.
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-podroid-nopasswd.conf <<'EOF'
# Podroid: no password authentication anywhere.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
chmod 0644 /etc/ssh/sshd_config.d/10-podroid-nopasswd.conf

# ── 12. Podman/Docker/LXC storage dirs (first-boot speedup) ──────────────────
mkdir -p /var/lib/containers/storage \
         /run/containers/storage \
         /run/libpod \
         /run/crun \
         /var/lib/docker \
         /var/lib/lxc

# ── 13. Copy Podroid system files ─────────────────────────────────────────────
# Init scripts — Podroid's OpenRC services (shebang is #!/sbin/openrc-run,
# works unchanged on Debian's openrc).
for f in podroid-bootstrap podroid-network podroid-terminals podroid-ready \
         podroid-x11 podroid-vsock podroid-hostd podroid-downloads podroid-migrate; do
    cp "/work/files/etc/init.d/$f" "/etc/init.d/$f"
    chmod +x "/etc/init.d/$f"
done

# /usr/local/bin helper scripts.
mkdir -p /usr/local/bin
for f in podroid-resize podroid-terminals podroid-login podroid-getty podroid-getty-extra podroid-backup podroid-update-stats podroid-xfce podroid-mirror; do
    cp "/work/files/usr/local/bin/$f" "/usr/local/bin/$f"
    chmod +x "/usr/local/bin/$f"
done
# podroid-* C agents — already in /usr/local/bin from Dockerfile COPY --from=vsock-builder.
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
cp /work/files/etc/profile.d/podroid-x11.sh   /etc/profile.d/
chmod 0644 /etc/profile.d/podroid-color.sh /etc/profile.d/podroid-x11.sh

# containers/storage.conf — pin Podman to in-kernel overlay.
mkdir -p /etc/containers
cp /work/files/etc/containers/storage.conf /etc/containers/storage.conf
chmod 0644 /etc/containers/storage.conf

# Hostname — /etc/hosts may be a read-only bind mount in Docker buildx+QEMU.
echo "podroid" > /etc/hostname
if [ -w /etc/hosts ] || touch /etc/hosts 2>/dev/null; then
    cat > /etc/hosts <<'EOF'
127.0.0.1 localhost podroid
::1 localhost ip6-localhost
EOF
else
    echo "build-rootfs.sh: /etc/hosts read-only, skipping"
fi

# Login banner — /etc/issue may also be read-only in Docker buildx+QEMU.
if [ -w /etc/issue ] || touch /etc/issue 2>/dev/null; then
    cat > /etc/issue <<'EOF'
Welcome to Podroid-Kali (Kali GNU/Linux)
Kernel \r on \m (\l)

  Login: automatic as root (no password)
  Create a regular user:   adduser --ingroup sudo <name>

EOF
else
    echo "build-rootfs.sh: /etc/issue read-only, skipping"
fi


# ── 14. OpenRC runlevels (direct symlinks — host is x86_64, no chroot) ───────
# rc-update is just `ln -s /etc/init.d/X /etc/runlevels/<level>/X`.
for svc in podroid-migrate podroid-bootstrap podroid-network podroid-terminals \
           docker lxc podroid-x11 podroid-vsock podroid-downloads podroid-hostd \
           podroid-ready; do
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

# ── 15. Clean apt caches ──────────────────────────────────────────────────────
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* /var/cache/apt/archives/partial/* 2>/dev/null || true
rm -rf /tmp/* /var/tmp/* 2>/dev/null || true

# ── 15b. Bake in a China-friendly mirror as the guest default ─────────────────
# The build above used the official host (fast on the GitHub Actions US runner).
# But the end user is typically in China, where http.kali.org is slow. Before we
# rsync to /work/rootfs, rewrite the sources.list that ships inside the squashfs
# to a domestic mirror so the user's `apt install` is fast out of the box. They
# can switch at any time with `podroid-mirror`. Override with KALI_MIRROR=<url>.
KALI_MIRROR="${KALI_MIRROR:-https://mirrors.ustc.edu.cn/kali}"
cat > /etc/apt/sources.list <<EOF
# Kali mirror: $(echo "$KALI_MIRROR" | sed 's#https\?://##; s#/.*##')
deb $KALI_MIRROR kali-rolling main contrib non-free non-free-firmware
deb-src $KALI_MIRROR kali-rolling main contrib non-free non-free-firmware
EOF

# ── 16. Copy the installed system to /work/rootfs ──────────────────────────────
# apt-get installs to /, but we need a clean rootfs dir for mksquashfs.
# rsync with --exclude to avoid copying Docker runtime dirs.
echo "build-rootfs.sh: Copying rootfs to /work/rootfs..."
mkdir -p /work/rootfs
rsync -a --delete \
    --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' \
    --exclude='/run/*' --exclude='/tmp/*' --exclude='/var/tmp/*' \
    --exclude='/work/*' --exclude='/kali-rootfs.squashfs' \
    --exclude='/var/lib/apt/lists/*' --exclude='/var/cache/apt/*' \
    / /work/rootfs/

# Verify /sbin/init is present — switch_root will panic if it's missing.
if [ ! -e /work/rootfs/sbin/init ]; then
    echo "FATAL: /sbin/init missing from rootfs after rsync!" >&2
    echo "  /sbin contents:" >&2
    ls -la /work/rootfs/sbin/ 2>/dev/null | head -20 >&2
    echo "  looking for sysvinit init:" >&2
    find /work/rootfs/lib/sysvinit /work/rootfs/usr/lib/sysvinit -name init 2>/dev/null >&2 || true
    exit 1
fi
echo "build-rootfs.sh: /sbin/init -> $(readlink -f /work/rootfs/sbin/init)"

echo "build-rootfs.sh: Kali rootfs ready"