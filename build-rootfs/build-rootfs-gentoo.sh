#!/bin/bash
set -euo pipefail

R=/
EXPORT_ROOT=/work/rootfs
DISTRO=gentoo
export FEATURES="-sandbox -usersandbox"
export EMERGE_DEFAULT_OPTS="--getbinpkg -v --ask=n"

echo "build-rootfs-gentoo.sh: building MINIMAL gentoo rootfs (OpenRC, native stage3)"

if ! emerge --version; then
    echo "FATAL: emerge does not run in the stage3 image" >&2
    exit 1
fi

PROFILE_DIR=$(find /var/db/repos/gentoo/profiles/default/linux/arm64 -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)
if [ -z "$PROFILE_DIR" ]; then
    echo "FATAL: no arm64 Gentoo profile found" >&2
    exit 1
fi
rm -rf /etc/portage/make.profile
ln -s "$PROFILE_DIR" /etc/portage/make.profile

BINHOST_URL="${PORTAGE_BINHOST_URL:-https://distfiles.gentoo.org/releases/arm64/binpackages/23.0/arm64/}"
printf 'PORTAGE_BINHOST="%s"\n' "$BINHOST_URL" >> /etc/portage/make.conf
if ! command -v curl >/dev/null 2>&1; then
    emerge --getbinpkg --oneshot net-misc/curl
fi
if ! curl -fsSI "$BINHOST_URL" >/dev/null; then
    echo "FATAL: binhost not reachable (200 expected): $BINHOST_URL" >&2
    exit 1
fi

if ! timeout 1800 emerge --oneshot =app-containers/podman-5.8.2; then
    echo "FATAL: podman binpkg probe failed/timed out" >&2
    exit 1
fi

emerge --oneshot \
    app-containers/crun sys-fs/fuse-overlayfs \
    net-misc/dropbear app-admin/sudo net-misc/dhcp net-firewall/iptables \
    sys-apps/usbutils sys-apps/pciutils app-misc/ca-certificates app-arch/tar

if ! command -v dhclient >/dev/null 2>&1; then
    echo "FATAL: dhclient missing after emerge" >&2
    exit 1
fi
passwd -l root 2>/dev/null || true

rm -rf /usr/share/man /usr/share/doc /usr/share/locale \
       /usr/share/info /usr/share/help /usr/lib/debug \
       /var/cache/distfiles/* /var/cache/binpkgs/* \
       /var/cache/portage/distfiles/* \
       /tmp/* /var/tmp/* 2>/dev/null || true

mkdir -p /usr/local/bin /usr/local/libexec/podroid
for f in podroid-bootstrap podroid-network podroid-terminals podroid-ready \
         podroid-vsock podroid-hostd podroid-downloads podroid-migrate podroid-resize; do
    cp "/work/files/etc/init.d/$f" "/etc/init.d/$f"
    chmod +x "/etc/init.d/$f"
done
for f in podroid-resize podroid-terminals podroid-login podroid-getty \
         podroid-getty-extra podroid-backup podroid-update-stats podroid-mirror; do
    cp "/work/files/usr/local/bin/$f" "/usr/local/bin/$f"
    chmod +x "/usr/local/bin/$f"
done
ln -sf podroid-hostd /usr/local/bin/podroid-notify
ln -sf podroid-hostd /usr/local/bin/podroid-forward
ln -sf podroid-hostd /usr/local/bin/podroid-open
ln -sf podroid-hostd /usr/local/bin/podroid-power
ln -sf podroid-hostd /usr/local/bin/podroid-headless
ln -sf podroid-hostd /usr/local/bin/podroid-server
chmod +x /usr/local/bin/podroid-* 2>/dev/null || true

mkdir -p /etc/conf.d /etc/podroid/migrations /etc/containers
cp /work/files/etc/conf.d/podroid /etc/conf.d/podroid
cp /work/files/etc/podroid/forwards.conf /etc/podroid/forwards.conf
chmod 0644 /etc/podroid/forwards.conf
cp /work/files/etc/podroid/migrations/README /etc/podroid/migrations/README
printf '%s\n' "${SYSTEM_VERSION:-0}" > /etc/podroid/system-version
chmod 0644 /etc/podroid/system-version

cp /work/files/etc/inittab /etc/inittab
cp /work/files/etc/rc.conf /etc/rc.conf
mkdir -p /etc/profile.d
cp /work/files/etc/profile.d/podroid-color.sh /etc/profile.d/
chmod +x /etc/profile.d/podroid-color.sh
cp /work/files/etc/containers/storage.conf /etc/containers/storage.conf
chmod 0644 /etc/containers/storage.conf

mkdir -p /etc/runlevels/default /etc/runlevels/boot \
         /etc/runlevels/shutdown /etc/runlevels/sysinit
for svc in podroid-migrate podroid-bootstrap podroid-network podroid-terminals \
           podroid-vsock podroid-downloads podroid-hostd podroid-ready \
           dropbear; do
    if [ -e "/etc/init.d/$svc" ]; then
        ln -sf "/etc/init.d/$svc" "/etc/runlevels/default/$svc"
    else
        echo "WARN: init script $svc missing, skipping runlevel symlink"
    fi
done
for svc in hwclock networking sysctl bootmisc syslog; do
    rm -f "/etc/runlevels/boot/$svc" "/etc/runlevels/default/$svc" 2>/dev/null || true
done

mkdir -p /var/lib/containers/storage /run/containers/storage \
         /run/libpod /run/crun

for must in etc/inittab etc/init.d/podroid-bootstrap etc/init.d/dropbear \
            usr/local/bin/podroid-getty; do
    [ -e "/$must" ] || { echo "FATAL: missing $must" >&2; exit 1; }
done
if [ ! -e /sbin/init ]; then
    for cand in usr/lib/sysvinit/init lib/sysvinit/init usr/sbin/init; do
        if [ -e "/$cand" ]; then
            ln -sf "/$cand" /sbin/init
            break
        fi
    done
    [ -e /sbin/init ] || { echo "FATAL: cannot create /sbin/init symlink" >&2; exit 1; }
fi
grep -q podroid-getty /etc/inittab || { echo "FATAL: inittab not podroid's" >&2; exit 1; }

rm -rf "$EXPORT_ROOT"
mkdir -p "$EXPORT_ROOT"
tar --xattrs --xattrs-include='*.*' --numeric-owner \
    --exclude='./proc' --exclude='./sys' --exclude='./dev' \
    --exclude='./run' --exclude='./tmp' --exclude='./var/tmp' \
    --exclude='./work' --exclude='./var/cache/distfiles' \
    --exclude='./var/cache/binpkgs' --exclude='./var/log' \
    -C / -cpf - . | \
tar --xattrs --xattrs-include='*.*' --numeric-owner \
    -C "$EXPORT_ROOT" -xpf -
rm -f "$EXPORT_ROOT/etc/resolv.conf"
printf 'podroid\n' > "$EXPORT_ROOT/etc/hostname"
cat > "$EXPORT_ROOT/etc/hosts" <<'EOF'
127.0.0.1 localhost podroid
::1 localhost ip6-localhost
EOF
cat > "$EXPORT_ROOT/etc/issue" <<'EOF'
Welcome to Podroid-gentoo (gentoo)
Kernel \r on \m (\l)

  Login: automatic as root (no password)
  Create a regular user:   useradd -G wheel <name>

EOF

echo "build-rootfs-gentoo.sh: gentoo minimal rootfs ready"
