#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# Podroid MINIMAL rootfs builder — Gentoo (arm64) + OpenRC.
#
# Runs INSIDE a debian:bookworm arm64 Docker stage. Fetches the official
# stage3-arm64-openrc tarball (pointer file → dated path) into /work/rootfs,
# then chroot-installs our package set with EMERGE_DEFAULT_OPTS="--getbinpkg".
#
# Fail-fast contract (spec §3.2/§8): binhost must be reachable (HTTP 200) and
# the podman probe must complete as a BINARY install within `timeout 600`.
# A source build under qemu-user will trip the timeout and abort — we never
# let compilation run.
#
# Uses the OpenRC overlay (files/) exactly like the Kali/Debian images:
# inittab + runlevels + dropbear, no systemd.
# ─────────────────────────────────────────────────────────────────────────────
set -eu

R=/work/rootfs
DISTRO=gentoo
echo "build-rootfs-gentoo.sh: building MINIMAL gentoo rootfs (OpenRC, chroot)"

# ── 0. Fetch stage3 via official pointer ────────────────────────────────────
# Pointer file is PGP-clearsigned; take the stage3 path line, not armor headers.
PTR=$(curl -fsSL \
    https://distfiles.gentoo.org/releases/arm64/autobuilds/latest-stage3-arm64-openrc.txt \
    | grep -E 'stage3-.*\.tar\.xz[[:space:]]' | head -1 | awk '{print $1}')
if [ -z "$PTR" ]; then
    echo "FATAL: stage3 pointer file empty or unreachable" >&2
    exit 1
fi
echo "stage3: $PTR"
mkdir -p "$R"
# Pointer paths are relative to releases/arm64/autobuilds/, not releases/arm64/.
curl -fsSL "https://distfiles.gentoo.org/releases/arm64/autobuilds/${PTR}" \
    | tar -xJp -C "$R"

# ── 1. Preflight: device nodes + DNS + emerge/sinit must exist ──────────────
mkdir -p "$R/dev" "$R/proc" "$R/sys" "$R/tmp" "$R/etc" "$R/etc/portage"
for n in urandom null zero tty random console ptmx; do
    [ -e "/dev/$n" ] && cp -a "/dev/$n" "$R/dev/$n" 2>/dev/null || true
done
cp /etc/resolv.conf "$R/etc/resolv.conf"

if ! chroot "$R" emerge --version; then
    echo "FATAL: chroot emerge does not run (binfmt/qemu or stage3 issue)" >&2
    exit 1
fi
if [ ! -e "$R/sbin/init" ] && [ ! -e "$R/lib/sysvinit/init" ] \
   && [ ! -e "$R/usr/lib/sysvinit/init" ]; then
    echo "FATAL: stage3 has no sysvinit init binary (inittab boot path broken)" >&2
    echo "Contingency: chroot emerge sys-apps/sysvinit && ln -sf <init> /sbin/init" >&2
    exit 1
fi

# ── 2. Binhost fail-fast (spec §3.2) ────────────────────────────────────────
BINHOST_URL="${PORTAGE_BINHOST_URL:-https://distfiles.gentoo.org/releases/arm64/binpackages/23.0/arm64/}"
if ! curl -fsSI "$BINHOST_URL" >/dev/null; then
    echo "FATAL: binhost not reachable (200 expected): $BINHOST_URL" >&2
    echo "Fix PORTAGE_BINHOST_URL (candidates follow; first HTTP 200 wins):" >&2
    echo "  https://distfiles.gentoo.org/releases/arm64/binpackages/23.0/arm64/" >&2
    echo "  https://distfiles.gentoo.org/releases/arm64/binpackages/" >&2
    exit 1
fi
printf 'PORTAGE_BINHOST="%s"\n' "$BINHOST_URL" >> "$R/etc/portage/make.conf"
echo "binhost: $BINHOST_URL"

# ── 3. Probe: podman must install as BINPKG within 10 min ───────────────────
#      (source fallback under qemu trips `timeout` → red FATAL, per spec §8)
if ! timeout 600 chroot "$R" env \
        FEATURES="-sandbox -usersandbox" \
        EMERGE_DEFAULT_OPTS="--getbinpkg -v --ask=n" \
        emerge --oneshot app-emulation/podman; then
    echo "FATAL: podman binpkg probe failed/timed out (binpkg coverage gap)" >&2
    echo "Spec §8 fallback: build a custom stage3 tarball with podman preinstalled" >&2
    echo "and publish it on the Release, then pin its URL here." >&2
    exit 1
fi

# ── 4. Full package set (all via binpkg; sandbox off — chroot, no /proc) ────
chroot "$R" env \
    FEATURES="-sandbox -usersandbox" \
    EMERGE_DEFAULT_OPTS="--getbinpkg -v --ask=n" \
    emerge --oneshot \
    app-emulation/crun sys-fs/fuse-overlayfs \
    net-misc/dropbear app-admin/sudo net-misc/dhclient net-misc/iptables \
    sys-apps/usbutils sys-apps/pciutils app-misc/ca-certificates

if ! chroot "$R" command -v dhclient >/dev/null 2>&1; then
    echo "FATAL: dhclient missing after emerge" >&2
    exit 1
fi
chroot "$R" passwd -l root 2>/dev/null || true

# ── 5. Strip man/docs/locale + caches ───────────────────────────────────────
rm -rf "$R"/usr/share/man "$R"/usr/share/doc "$R"/usr/share/locale \
       "$R"/usr/share/info "$R"/usr/share/help "$R"/usr/lib/debug \
       "$R"/var/cache/distfiles/* "$R"/var/cache/binpkgs/* \
       "$R"/var/cache/portage/distfiles/* \
       "$R"/tmp/* "$R"/var/tmp/* 2>/dev/null || true

# ── 6. Copy Podroid system files (OpenRC variant — mirrors build-rootfs-minimal.sh §10-11)
mkdir -p "$R/usr/local/bin" "$R/usr/local/libexec/podroid"
for f in podroid-bootstrap podroid-network podroid-terminals podroid-ready \
         podroid-vsock podroid-hostd podroid-downloads podroid-migrate podroid-resize; do
    cp "/work/files/etc/init.d/$f" "$R/etc/init.d/$f"
    chmod +x "$R/etc/init.d/$f"
done
for f in podroid-resize podroid-terminals podroid-login podroid-getty \
         podroid-getty-extra podroid-backup podroid-update-stats podroid-mirror; do
    cp "/work/files/usr/local/bin/$f" "$R/usr/local/bin/$f"
    chmod +x "$R/usr/local/bin/$f"
done
ln -sf podroid-hostd "$R/usr/local/bin/podroid-notify"
ln -sf podroid-hostd "$R/usr/local/bin/podroid-forward"
ln -sf podroid-hostd "$R/usr/local/bin/podroid-open"
ln -sf podroid-hostd "$R/usr/local/bin/podroid-power"
ln -sf podroid-hostd "$R/usr/local/bin/podroid-headless"
ln -sf podroid-hostd "$R/usr/local/bin/podroid-server"
chmod +x "$R/usr/local/bin/podroid-"* 2>/dev/null || true

mkdir -p "$R/etc/conf.d" "$R/etc/podroid/migrations" "$R/etc/containers"
cp /work/files/etc/conf.d/podroid "$R/etc/conf.d/podroid"
cp /work/files/etc/podroid/forwards.conf "$R/etc/podroid/forwards.conf"
chmod 0644 "$R/etc/podroid/forwards.conf"
cp /work/files/etc/podroid/migrations/README "$R/etc/podroid/migrations/README"
printf '%s\n' "${SYSTEM_VERSION:-0}" > "$R/etc/podroid/system-version"
chmod 0644 "$R/etc/podroid/system-version"

cp /work/files/etc/inittab "$R/etc/inittab"
cp /work/files/etc/rc.conf "$R/etc/rc.conf"
mkdir -p "$R/etc/profile.d"
cp /work/files/etc/profile.d/podroid-color.sh "$R/etc/profile.d/"
chmod 0644 "$R/etc/profile.d/podroid-color.sh"
cp /work/files/etc/containers/storage.conf "$R/etc/containers/storage.conf"
chmod 0644 "$R/etc/containers/storage.conf"

echo "podroid" > "$R/etc/hostname"
cat > "$R/etc/hosts" <<'EOF'
127.0.0.1 localhost podroid
::1 localhost ip6-localhost
EOF
cat > "$R/etc/issue" <<'EOF'
Welcome to Podroid-gentoo (gentoo)
Kernel \r on \m (\l)

  Login: automatic as root (no password)
  Create a regular user:   useradd -G wheel <name>

EOF

# ── 7. OpenRC runlevels (direct symlinks — host is arm64 container, no rc-update needed)
mkdir -p "$R/etc/runlevels/default" "$R/etc/runlevels/boot" \
         "$R/etc/runlevels/shutdown" "$R/etc/runlevels/sysinit"
for svc in podroid-migrate podroid-bootstrap podroid-network podroid-terminals \
           podroid-vsock podroid-downloads podroid-hostd podroid-ready \
           dropbear; do
    if [ -e "$R/etc/init.d/$svc" ]; then
        ln -sf "/etc/init.d/$svc" "$R/etc/runlevels/default/$svc"
    else
        echo "WARN: init script $svc missing, skipping runlevel symlink"
    fi
done
for svc in hwclock networking sysctl bootmisc syslog; do
    rm -f "$R/etc/runlevels/boot/$svc" "$R/etc/runlevels/default/$svc" 2>/dev/null || true
done

mkdir -p "$R/var/lib/containers/storage" "$R/run/containers/storage" \
         "$R/run/libpod" "$R/run/crun"

# ── 8. Sanity: OpenRC boot path must be complete ────────────────────────────
for must in etc/inittab etc/init.d/podroid-bootstrap etc/init.d/dropbear \
            usr/local/bin/podroid-getty; do
    [ -e "$R/$must" ] || { echo "FATAL: missing $must" >&2; exit 1; }
done
if [ ! -e "$R/sbin/init" ]; then
    for cand in usr/lib/sysvinit/init lib/sysvinit/init usr/sbin/init; do
        if [ -e "$R/$cand" ]; then
            ln -sf "/$cand" "$R/sbin/init"
            break
        fi
    done
    [ -e "$R/sbin/init" ] || { echo "FATAL: cannot create /sbin/init symlink" >&2; exit 1; }
fi
grep -q podroid-getty "$R/etc/inittab" || { echo "FATAL: inittab not podroid's" >&2; exit 1; }

echo "build-rootfs-gentoo.sh: gentoo minimal rootfs ready"
