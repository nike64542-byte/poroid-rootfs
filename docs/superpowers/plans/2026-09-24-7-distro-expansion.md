# 7-Distro Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Fedora/Rocky/Alma/openSUSE/Arch/Manjaro/Gentoo arm64 guest images to poroid-rootfs and extend the APK wizard to 10 distros, per the approved spec.

**Architecture:** Mirror the proven per-distro Dockerfile pattern (stage-1 cross-compiled agents → arm64 stage-2 package install → mksquashfs export). Four build scripts split by package manager (dnf/zypper/pacman/emerge); systemd distros share the renamed `files-systemd/` overlay, Gentoo reuses OpenRC `files/`. Tarball distros (Arch/Manjaro/Gentoo) run their package manager via `chroot` inside a debian arm64 builder (no mounts — docker default caps include CAP_SYS_CHROOT). Workflow gains a dynamic matrix (`resolve` job) and gets its release-upload silent-failure bug fixed. APK side is a pure data extension of the existing `Distro` enum + FlowRow chips.

**Tech Stack:** Docker Buildx + QEMU binfmt (CI), POSIX sh build scripts, GitHub Actions matrix, squashfs+zstd, Kotlin/Compose/DataStore, JUnit4.

**Spec:** `docs/superpowers/specs/2026-09-24-7-distro-expansion-design.md` (same repo — read it first; this plan argues from it).

**Working directories:**
- ROOTFS repo: `/data/data/com.termux/files/usr/tmp/opencode/split/poroid-rootfs`
- APK repo: `/data/data/com.termux/files/usr/tmp/opencode/split/poroid-apk`

## Global Constraints

- Asset names (exact, no version in base name): `fedora-rootfs.squashfs`, `rocky-rootfs.squashfs`, `alma-rootfs.squashfs`, `opensuse-rootfs.squashfs`, `arch-rootfs.squashfs`, `manjaro-rootfs.squashfs`, `gentoo-rootfs.squashfs`.
- Versioned copies (workflow): `fedora-rootfs-42`, `rocky-rootfs-9`, `alma-rootfs-9`, `opensuse-rootfs-15.6`, `arch-rootfs-rolling`, `manjaro-rootfs-rolling`, `gentoo-rootfs-rolling` (`.squashfs` suffix).
- Base pins: `fedora:42`, `rockylinux:9`, `almalinux:9`, `opensuse/leap:15.6`; ALARM tarball `http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz` (verified 200); Manjaro repos `Server = https://repo.manjaro.org/repo/arm-stable/$repo/$arch` (verified core/extra `.db` 200); Gentoo pointer `https://distfiles.gentoo.org/releases/arm64/autobuilds/latest-stage3-arm64-openrc.txt` (verified 200).
- Linux Mint + EndeavourOS: NOT built, NOT in workflow options, NOT in APK enum — README must say why (no arm64).
- Gentoo must fail fast on binpkg problems (timeout-wrapped probe); never allow a source build to run long.
- Release upload step: NO `|| true`; glob `out/*rootfs*.squashfs`; empty glob must fail the job.
- APK: one rootfs file at a time (`rootfsFile()` by current distro); switching = Settings → Reset VM (invariant — do not touch `setDistro`/reset logic).
- Spec §7 delivery: **one commit per repo on push.** Tasks commit locally per task (rollback granularity); the two push tasks (9, 12) first `git reset --soft` to the pre-work base and create the single squashed commit, then push.
- Push remotes carry the PAT (rootfs remote `origin` already configured; add for APK if missing). Push retry ×3 with error file `$HOME/.push.err` ( `/tmp` is not writable).
- Rootfs verification runs locally (`bash -n`, file greps) + CI (docker build). APK verification runs on GitHub CI only (no local Android SDK; JDK 21 exists but `ANDROID_HOME` unset).
- `podroid-network.sh` and the OpenRC `podroid-network` both invoke `dhclient` — every new image must provide a `dhclient` binary on `$PATH`.
- mksquashfs flags copied verbatim from existing Dockerfiles: `-comp zstd -Xcompression-level 19 -all-root -noappend` plus the standard `-e` exclusion list (extend with dnf/pacman/gentoo caches as applicable).

## Review Focus

1. **Chroot-family builds without `/proc`** (arch/manjaro/gentoo) — pacman/emerge can die mid-install; expected behavior is a red job with the task's `FATAL:` message, never a silent bad asset. Tests: preflight `pacman -V` / `emerge --version` gates (Tasks 4–5), CI job failure visible in Tasks 9–10 assertions.
2. **Manjaro SigLevel TrustAll window** — if keyring populate fails, the post-restore verification sync breaks (or TrustAll leaks into the shipped image). Test: Task 4 verification step — after restoring `SigLevel = Required DatabaseOptional`, `chroot … pacman -Sy --noconfirm` must succeed AND `grep TrustAll /work/rootfs/etc/pacman.conf` must return nothing.
3. **Release upload regression** (this session's silent `|| true` failure) — expected: red job on upload failure, assets actually present. Tests: Task 7 rewrote step with `nullglob` + empty-array exit 1; Task 9 asserts `fedora-rootfs.squashfs` exists on the Release via API; Task 10 asserts all 7 + versioned copies.
4. **Gentoo binpkg coverage unknown** — expected: fail-fast red within ~10 min with the binhost/FATAL message (spec §8 fallback = custom stage3 tarball), not a 2-hour compile. Test: Task 5 `timeout 600` podman probe + binhost `curl -fsSI` gate.
5. **10-chip wizard + enum exhaustiveness** — expected: compile error if `when(distroLabelRes)` misses a branch; all 10 preset URLs correct. Tests: Task 8 `DistroTest.allTenDistrosHaveReleaseAssets` (full-map assertion) + existing `presetUrlsPointAtSharedLatestRelease` loop over `values()`, verified by CI in Task 12.

---

### Task 1: Rename shared overlay `files-ubuntu-systemd/` → `files-systemd/`

**Files (ROOTFS repo):**
- Rename: `build-rootfs/files-ubuntu-systemd/` → `build-rootfs/files-systemd/` (14 files, content unchanged)
- Modify: `build-rootfs/Dockerfile.rootfs-ubuntu` (COPY line)
- Modify: `build-rootfs/build-rootfs-ubuntu.sh` (2 loop path prefixes)

**Interfaces:**
- Produces: overlay path `build-rootfs/files-systemd/` — every systemd-family Dockerfile/script in Tasks 2–4 COPYs from this exact path.

- [ ] **Step 1: Move the directory**

```bash
cd /data/data/com.termux/files/usr/tmp/opencode/split/poroid-rootfs
git mv build-rootfs/files-ubuntu-systemd build-rootfs/files-systemd
```

- [ ] **Step 2: Update references**

`build-rootfs/Dockerfile.rootfs-ubuntu` — change:

```dockerfile
COPY files-ubuntu-systemd /work/files-ubuntu-systemd
```

to:

```dockerfile
COPY files-systemd /work/files-systemd
```

`build-rootfs/build-rootfs-ubuntu.sh` — replace BOTH occurrences of the string `files-ubuntu-systemd` with `files-systemd` (the scripts copy loop and the units copy loop).

- [ ] **Step 3: Verify zero leftovers + syntax**

```bash
grep -rn "files-ubuntu-systemd" build-rootfs/ .github/ && echo "FAIL: leftovers" || echo "OK: no leftovers"
sh -n build-rootfs/build-rootfs-ubuntu.sh && echo "OK: syntax"
```

Expected: `OK: no leftovers`, `OK: syntax`.

- [ ] **Step 4: Commit**

```bash
git add -A build-rootfs
git commit -m "refactor: rename files-ubuntu-systemd/ to files-systemd/ (shared by 7 distros)"
```

---

### Task 2: dnf family — `build-rootfs-dnf.sh` + Fedora/Rocky/Alma Dockerfiles + build.sh cases

**Files (ROOTFS repo):**
- Create: `build-rootfs/build-rootfs-dnf.sh`
- Create: `build-rootfs/Dockerfile.rootfs-fedora`
- Create: `build-rootfs/Dockerfile.rootfs-rocky`
- Create: `build-rootfs/Dockerfile.rootfs-alma`
- Modify: `build.sh` (case map + default loop + TARGET cases)

**Interfaces:**
- Consumes: `build-rootfs/files-systemd/` (Task 1), `build-rootfs/files/`
- Produces: assets `fedora-rootfs.squashfs` / `rocky-rootfs.squashfs` / `alma-rootfs.squashfs`; build targets `./build.sh fedora|rocky|alma`.

- [ ] **Step 1: Write `build-rootfs/build-rootfs-dnf.sh`**

```sh
#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# Podroid MINIMAL rootfs builder — Fedora / Rocky / Alma (arm64) + systemd.
#
# Runs INSIDE the <distro>:<ver> arm64 Docker stage (qemu-user on CI).
# Packages install to "/"; rsync copies the system to /work/rootfs, which the
# Dockerfile squashfs-compresses. Same boot pipeline as the Ubuntu image
# (shared vmlinuz-virt + initrd.img, systemd units from files-systemd/).
#
# MINIMAL design (low-memory VM first): no desktop, no weak deps, no docs;
# podman + crun + fuse-overlayfs only; our scripts own network/ssh/getty.
# ─────────────────────────────────────────────────────────────────────────────
set -eu
ROOTFS=/
export TZ=UTC

DISTRO="${DISTRO:-fedora}"
echo "build-rootfs-dnf.sh: building MINIMAL ${DISTRO} rootfs (systemd)"

# ── 1. Base + tools + squashfs tooling (no weak deps, no docs) ───────────────
dnf -y install --setopt=install_weak_deps=False --nodocs \
    bash coreutils findutils gawk grep sed \
    util-linux procps kmod shadow passwd \
    openssl ca-certificates curl wget \
    xz gzip tar file rsync squashfs-tools \
    e2fsprogs iproute iputils bind-utils net-tools \
    iptables nftables bridge-utils dhcp-client \
    openssh-server openssh-clients \
    sudo vim-minimal less \
    dbus usbutils pciutils

# ── 2. Podman container runtime (minimal; dnf pulls the rest as deps) ────────
dnf -y install --setopt=install_weak_deps=False --nodocs \
    podman crun fuse-overlayfs libcap

# ── 3. Strip man/docs/locale ─────────────────────────────────────────────────
rm -rf /usr/share/man /usr/share/doc /usr/share/locale /usr/share/info \
       /usr/share/help /usr/lib/debug 2>/dev/null || true

# ── 4. Disable host-bloat services (our scripts own net/ssh/time) ────────────
for svc in NetworkManager NetworkManager-wait-online firewalld \
           avahi-daemon cups bluetooth rpcbind chronyd; do
    systemctl disable --now "$svc" 2>/dev/null || true
done

# ── 5. Machine-id fresh per-boot; resolv.conf owned by podroid-network ───────
: > /etc/machine-id 2>/dev/null || true
rm -f /etc/resolv.conf 2>/dev/null || true

# ── 6. No default password + sudo + sshd key-only ────────────────────────────
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

# ── 7. Podman storage dirs ───────────────────────────────────────────────────
mkdir -p /var/lib/containers/storage /run/containers/storage \
         /run/libpod /run/crun

# ── 8. Copy Podroid system files (systemd variant) ───────────────────────────
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

# ── 9. Hostname / hosts / banner ─────────────────────────────────────────────
echo "podroid" > /etc/hostname
cat > /etc/hosts <<'EOF'
127.0.0.1 localhost podroid
::1 localhost ip6-localhost
EOF
cat > /etc/issue <<EOF
Welcome to Podroid-${DISTRO} (${DISTRO})
Kernel \\r on \\m (\\l)

  Login: automatic as root (no password)
  Create a regular user:   useradd -G wheel <name>

EOF

# ── 10. Enable Podroid services ──────────────────────────────────────────────
for u in podroid-migrate podroid-bootstrap podroid-network podroid-hostd \
         podroid-terminals podroid-vsock podroid-downloads podroid-ready; do
    systemctl enable "$u.service" 2>/dev/null || true
done
systemctl enable sshd.service 2>/dev/null || true
systemctl enable "podroid-getty@hvc0.service" 2>/dev/null || true
systemctl mask "serial-getty@ttyAMA0.service" 2>/dev/null || true

# ── 11. Clean caches ─────────────────────────────────────────────────────────
dnf clean all 2>/dev/null || true
rm -rf /var/cache/dnf /var/log/* /tmp/* /var/tmp/* 2>/dev/null || true

# ── 12. Copy the installed system to /work/rootfs ────────────────────────────
echo "build-rootfs-dnf.sh: Copying rootfs to /work/rootfs..."
mkdir -p /work/rootfs
rsync -a --delete \
    --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' \
    --exclude='/run/*' --exclude='/tmp/*' --exclude='/var/tmp/*' \
    --exclude='/work/*' --exclude='/*-rootfs.squashfs' \
    --exclude='/etc/resolv.conf' \
    --exclude='/var/cache/dnf/*' --exclude='/var/log/*' \
    / /work/rootfs/

if [ ! -e /work/rootfs/sbin/init ]; then
    echo "FATAL: /sbin/init missing from rootfs after rsync!" >&2
    exit 1
fi
echo "build-rootfs-dnf.sh: /sbin/init -> $(readlink -f /work/rootfs/sbin/init)"
echo "build-rootfs-dnf.sh: ${DISTRO} minimal rootfs ready"
```

- [ ] **Step 2: Write `build-rootfs/Dockerfile.rootfs-fedora`**

```dockerfile
# build-rootfs/Dockerfile.rootfs-fedora
#
# Builds the Podroid guest rootfs as squashfs from Fedora 42 arm64.
# systemd init (shared files-systemd/ overlay), podman + Podroid bridge
# agents. Consumed by poroid-apk as `fedora-rootfs.squashfs`.

# ── Stage 1: cross-compile podroid-* C agents (static aarch64) ──────────────
FROM debian:bookworm AS vsock-builder
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu libc6-dev-arm64-cross make \
    && rm -rf /var/lib/apt/lists/*
ENV CC=aarch64-linux-gnu-gcc
WORKDIR /work
COPY vsock-agent /work/vsock-agent
RUN make -C /work/vsock-agent CC=${CC} clean all
COPY host-bridge /work/host-bridge
RUN make -C /work/host-bridge CC=${CC} clean all
COPY overlay-normalize /work/overlay-normalize
RUN make -C /work/overlay-normalize CC=${CC} clean all

# ── Stage 2: build the Fedora rootfs squashfs ───────────────────────────────
FROM --platform=linux/arm64 fedora:42 AS builder

WORKDIR /work

COPY --from=vsock-builder /work/vsock-agent/podroid-vsock-agent /usr/local/bin/podroid-vsock-agent
COPY --from=vsock-builder /work/host-bridge/podroid-hostd /usr/local/bin/podroid-hostd
COPY --from=vsock-builder /work/overlay-normalize/podroid-overlay-normalize /usr/local/bin/podroid-overlay-normalize
RUN chmod +x /usr/local/bin/podroid-vsock-agent /usr/local/bin/podroid-hostd \
             /usr/local/bin/podroid-overlay-normalize

ARG SYSTEM_VERSION=0
ENV SYSTEM_VERSION=${SYSTEM_VERSION}

COPY files /work/files
COPY files-systemd /work/files-systemd
COPY build-rootfs-dnf.sh /work/build-rootfs-dnf.sh
RUN chmod +x /work/build-rootfs-dnf.sh && DISTRO=fedora /work/build-rootfs-dnf.sh

RUN mksquashfs /work/rootfs /work/fedora-rootfs.squashfs \
    -comp zstd -Xcompression-level 19 -all-root -noappend \
    -e /proc /sys /dev /run /tmp /var/tmp /work \
       /var/cache/dnf /var/log \
       /usr/share/man /usr/share/doc /usr/share/locale /usr/share/info

FROM scratch AS export
COPY --from=builder /work/fedora-rootfs.squashfs /fedora-rootfs.squashfs
```

- [ ] **Step 3: Write `build-rootfs/Dockerfile.rootfs-rocky` and `Dockerfile.rootfs-alma`**

Copy the Fedora Dockerfile verbatim, changing ONLY: header comment (`Rocky 9 arm64` / `AlmaLinux 9 arm64` + asset name), the base line, the `DISTRO=` value, and the two `fedora-rootfs.squashfs` output names:

Rocky (`Dockerfile.rootfs-rocky`):

```dockerfile
FROM --platform=linux/arm64 rockylinux:9 AS builder
```

```dockerfile
RUN chmod +x /work/build-rootfs-dnf.sh && DISTRO=rocky /work/build-rootfs-dnf.sh
```

```dockerfile
RUN mksquashfs /work/rootfs /work/rocky-rootfs.squashfs \
```

```dockerfile
COPY --from=builder /work/rocky-rootfs.squashfs /rocky-rootfs.squashfs
```

Alma (`Dockerfile.rootfs-alma`):

```dockerfile
FROM --platform=linux/arm64 almalinux:9 AS builder
```

```dockerfile
RUN chmod +x /work/build-rootfs-dnf.sh && DISTRO=alma /work/build-rootfs-dnf.sh
```

```dockerfile
RUN mksquashfs /work/rootfs /work/alma-rootfs.squashfs \
```

```dockerfile
COPY --from=builder /work/alma-rootfs.squashfs /alma-rootfs.squashfs
```

- [ ] **Step 4: Extend `build.sh`**

In `build_distro_rootfs()` case map, after the `ubuntu)` line add:

```bash
        fedora)  dockerfile="Dockerfile.rootfs-fedora";  outfile="fedora-rootfs.squashfs" ;;
        rocky)   dockerfile="Dockerfile.rootfs-rocky";   outfile="rocky-rootfs.squashfs" ;;
        alma)    dockerfile="Dockerfile.rootfs-alma";    outfile="alma-rootfs.squashfs" ;;
```

Change the default build loop to:

```bash
    for d in kali debian ubuntu fedora rocky alma; do
```

In the TARGET case, after the `ubuntu)` line add:

```bash
    fedora)         build_distro_rootfs fedora ;;
    rocky)          build_distro_rootfs rocky ;;
    alma)           build_distro_rootfs alma ;;
```

- [ ] **Step 5: Verify syntax**

```bash
sh -n build-rootfs/build-rootfs-dnf.sh && bash -n build.sh && echo OK
grep -c "fedora-rootfs.squashfs" build.sh build-rootfs/Dockerfile.rootfs-fedora
```

Expected: `OK`; counts ≥ 1 each (build.sh map line + Dockerfile output = 2 hits total across files, each file ≥1).

- [ ] **Step 6: Commit**

```bash
git add build-rootfs/build-rootfs-dnf.sh build-rootfs/Dockerfile.rootfs-fedora \
        build-rootfs/Dockerfile.rootfs-rocky build-rootfs/Dockerfile.rootfs-alma build.sh
git commit -m "feat: dnf-family rootfs builder (fedora/rocky/alma, systemd)"
```

---

### Task 3: zypper family — `build-rootfs-zypper.sh` + openSUSE Dockerfile + build.sh case

**Files (ROOTFS repo):**
- Create: `build-rootfs/build-rootfs-zypper.sh`
- Create: `build-rootfs/Dockerfile.rootfs-opensuse`
- Modify: `build.sh` (case map + default loop + TARGET case)

**Interfaces:**
- Consumes: `build-rootfs/files-systemd/` (Task 1), `build-rootfs/files/`
- Produces: asset `opensuse-rootfs.squashfs`; target `./build.sh opensuse`.

- [ ] **Step 1: Write `build-rootfs/build-rootfs-zypper.sh`**

Same skeleton as `build-rootfs-dnf.sh` (Task 2) with these exact differences — write the full file as: header comment `openSUSE Leap 15.6 (arm64) + systemd`, then:

```sh
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
zypper --non-interactive --no-recommends install -y \
    bash coreutils findutils gawk grep sed \
    util-linux procps kmod shadow passwd \
    openssl ca-certificates curl wget \
    xz gzip tar file rsync squashfs \
    e2fsprogs iproute2 iputils bind-utils net-tools \
    iptables nftables bridge-utils dhclient \
    openssh \
    sudo vim-minimal less \
    dbus-1 usbutils pciutils

# ── 2. Podman container runtime ─────────────────────────────────────────────
zypper --non-interactive --no-recommends install -y \
    podman crun fuse-overlayfs libcap-tools 2>/dev/null \
 || zypper --non-interactive --no-recommends install -y \
    podman crun fuse-overlayfs libcap

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

# ── 9. Hostname / hosts / banner ────────────────────────────────────────────
echo "podroid" > /etc/hostname
cat > /etc/hosts <<'EOF'
127.0.0.1 localhost podroid
::1 localhost ip6-localhost
EOF
cat > /etc/issue <<EOF
Welcome to Podroid-${DISTRO} (${DISTRO})
Kernel \\r on \\m (\\l)

  Login: automatic as root (no password)
  Create a regular user:   useradd -G wheel <name>

EOF

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

if [ ! -e /work/rootfs/sbin/init ]; then
    echo "FATAL: /sbin/init missing from rootfs after rsync!" >&2
    exit 1
fi
echo "build-rootfs-zypper.sh: /sbin/init -> $(readlink -f /work/rootfs/sbin/init)"
echo "build-rootfs-zypper.sh: ${DISTRO} minimal rootfs ready"
```

Note on package names (known openSUSE naming): `squashfs` (not squashfs-tools), `dhclient`, `dbus-1`, `iproute2`. If zypper reports `no provider of 'X' found` in CI, the rename candidates are: `dhcp-client`↔`dhclient`, `squashfs-tools`↔`squashfs`, `dbus`↔`dbus-1` — adjust the single failing name, keep everything else identical.

- [ ] **Step 2: Write `build-rootfs/Dockerfile.rootfs-opensuse`**

Same three-stage structure as `Dockerfile.rootfs-fedora` (Task 2 Step 2) with ONLY these values changed: header comment (`openSUSE Leap 15.6 arm64`, asset `opensuse-rootfs.squashfs`), and:

```dockerfile
FROM --platform=linux/arm64 opensuse/leap:15.6 AS builder
```

```dockerfile
COPY build-rootfs-zypper.sh /work/build-rootfs-zypper.sh
RUN chmod +x /work/build-rootfs-zypper.sh && DISTRO=opensuse /work/build-rootfs-zypper.sh
```

```dockerfile
RUN mksquashfs /work/rootfs /work/opensuse-rootfs.squashfs \
    -comp zstd -Xcompression-level 19 -all-root -noappend \
    -e /proc /sys /dev /run /tmp /var/tmp /work \
       /var/cache/zypp /var/log \
       /usr/share/man /usr/share/doc /usr/share/locale /usr/share/info
```

```dockerfile
COPY --from=builder /work/opensuse-rootfs.squashfs /opensuse-rootfs.squashfs
```

(stage-1 agent cross-compile block identical to Fedora Dockerfile, verbatim.)

- [ ] **Step 3: Extend `build.sh`**

After the `alma)` case-map line add:

```bash
        opensuse) dockerfile="Dockerfile.rootfs-opensuse"; outfile="opensuse-rootfs.squashfs" ;;
```

Default loop becomes:

```bash
    for d in kali debian ubuntu fedora rocky alma opensuse; do
```

After the `alma)` TARGET line add:

```bash
    opensuse)       build_distro_rootfs opensuse ;;
```

- [ ] **Step 4: Verify syntax**

```bash
sh -n build-rootfs/build-rootfs-zypper.sh && bash -n build.sh && echo OK
grep -c "opensuse-rootfs.squashfs" build.sh build-rootfs/Dockerfile.rootfs-opensuse
```

Expected: `OK`, counts ≥ 1.

- [ ] **Step 5: Commit**

```bash
git add build-rootfs/build-rootfs-zypper.sh build-rootfs/Dockerfile.rootfs-opensuse build.sh
git commit -m "feat: zypper-family rootfs builder (opensuse leap, systemd)"
```

---

### Task 4: pacman family — `build-rootfs-pacman.sh` + Arch/Manjaro Dockerfiles + build.sh cases

**Files (ROOTFS repo):**
- Create: `build-rootfs/build-rootfs-pacman.sh`
- Create: `build-rootfs/Dockerfile.rootfs-arch`
- Create: `build-rootfs/Dockerfile.rootfs-manjaro`
- Modify: `build.sh`

**Interfaces:**
- Consumes: ALARM tarball (Dockerfile `ADD` extracts into `/work/rootfs`), `build-rootfs/files-systemd/`, `build-rootfs/files/`
- Produces: assets `arch-rootfs.squashfs`, `manjaro-rootfs.squashfs`; targets `./build.sh arch|manjaro`.

**Mechanics (chroot family):** builder stage is `debian:bookworm` arm64; Dockerfile `ADD`s the ALARM aarch64 tarball directly into `/work/rootfs`; the script runs pacman **via `chroot`** (CAP_SYS_CHROOT is in docker's default cap set; no `/proc` mount is possible or needed for binary installs — device nodes + `resolv.conf` are injected first; every chroot invocation is preflight-gated).

- [ ] **Step 1: Write `build-rootfs/build-rootfs-pacman.sh`**

```sh
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
cp /etc/resolv.conf "$R/etc/resolv.conf"

if ! chroot "$R" /usr/bin/pacman -V; then
    echo "FATAL: chroot pacman does not run (binfmt/qemu or ALARM tarball issue)" >&2
    exit 1
fi

# ── 1. Repos ────────────────────────────────────────────────────────────────
if [ "$DISTRO" = "manjaro" ]; then
    # Replace ALARM's pacman.conf with Manjaro ARM official repos.
    # Per-repo TrustAll applies ONLY while bootstrapping manjaro-arm-keyring;
    # Step 3 strips it back to Required and re-syncs to prove signatures work.
    cat > "$R/etc/pacman.conf" <<'EOF'
[options]
HoldPkg = pacman glibc manjaro-system
SyncFirst = manjaro-system archlinux-keyring manjaro-arm-keyring archlinuxarm-keyring
Architecture = aarch64
CheckSpace
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional

[core]
Server = https://repo.manjaro.org/repo/arm-stable/$repo/$arch
SigLevel = Optional TrustAll

[extra]
Server = https://repo.manjaro.org/repo/arm-stable/$repo/$arch
SigLevel = Optional TrustAll

[community]
Server = https://repo.manjaro.org/repo/arm-stable/$repo/$arch
SigLevel = Optional TrustAll
EOF
else
    # Arch Linux ARM: stock /etc/pacman.conf from the tarball is correct.
    :
fi

# ── 2. Sync + (manjaro) keyring bootstrap ───────────────────────────────────
chroot "$R" pacman -Sy --noconfirm

if [ "$DISTRO" = "manjaro" ]; then
    if ! chroot "$R" pacman -S --noconfirm --needed manjaro-arm-keyring archlinux-keyring archlinuxarm-keyring; then
        echo "FATAL: manjaro/arch keyring packages failed to install" >&2
        exit 1
    fi
    chroot "$R" pacman-key --populate manjaro-arm 2>/dev/null || true
    chroot "$R" pacman-key --populate archlinux 2>/dev/null || true
    chroot "$R" pacman-key --populate archlinuxarm 2>/dev/null || true

    # Strip the TrustAll window — it must NOT ship in the image.
    sed -i 's/^SigLevel = Optional TrustAll$/SigLevel = Required DatabaseOptional/' \
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
    xz gzip tar file rsync squashfs \
    e2fsprogs iproute2 iputils bind-utils net-tools \
    iptables nftables bridge-utils dhclient \
    openssh sudo vim-minimal less \
    dbus usbutils pciutils \
    podman crun fuse-overlayfs

# If the distro repo has no `dhclient` package, this step fails visibly above.
# Contingency (apply only if CI reports "target not found: dhclient"):
#   chroot "$R" pacman -S --noconfirm dhcpcd
#   chroot "$R" ln -sf /usr/bin/dhcpcd /usr/local/bin/dhclient
if ! chroot "$R" command -v dhclient >/dev/null 2>&1; then
    echo "FATAL: dhclient missing after package install" >&2
    exit 1
fi

# ── 4. Strip man/docs/locale ────────────────────────────────────────────────
rm -rf "$R"/usr/share/man "$R"/usr/share/doc "$R"/usr/share/locale \
       "$R"/usr/share/info "$R"/usr/share/help "$R"/usr/lib/debug \
       2>/dev/null || true

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
```

- [ ] **Step 2: Write `build-rootfs/Dockerfile.rootfs-arch`**

```dockerfile
# build-rootfs/Dockerfile.rootfs-arch
#
# Builds the Podroid guest rootfs as squashfs from Arch Linux ARM (aarch64).
# Official Arch repos have no aarch64 packages — this uses the Arch Linux ARM
# (ALARM) rootfs tarball + its repos. systemd init, shared files-systemd/
# overlay. Consumed by poroid-apk as `arch-rootfs.squashfs`.

# ── Stage 1: cross-compile podroid-* C agents (static aarch64) ──────────────
FROM debian:bookworm AS vsock-builder
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu libc6-dev-arm64-cross make \
    && rm -rf /var/lib/apt/lists/*
ENV CC=aarch64-linux-gnu-gcc
WORKDIR /work
COPY vsock-agent /work/vsock-agent
RUN make -C /work/vsock-agent CC=${CC} clean all
COPY host-bridge /work/host-bridge
RUN make -C /work/host-bridge CC=${CC} clean all
COPY overlay-normalize /work/overlay-normalize
RUN make -C /work/overlay-normalize CC=${CC} clean all

# ── Stage 2: extract ALARM rootfs + build squashfs ──────────────────────────
FROM --platform=linux/arm64 debian:bookworm AS builder
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates xz-utils squashfs-tools rsync libcap2-bin \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work

COPY --from=vsock-builder /work/vsock-agent/podroid-vsock-agent /usr/local/bin/podroid-vsock-agent
COPY --from=vsock-builder /work/host-bridge/podroid-hostd /usr/local/bin/podroid-hostd
COPY --from=vsock-builder /work/overlay-normalize/podroid-overlay-normalize /usr/local/bin/podroid-overlay-normalize
RUN chmod +x /usr/local/bin/podroid-vsock-agent /usr/local/bin/podroid-hostd \
             /usr/local/bin/podroid-overlay-normalize

ARG SYSTEM_VERSION=0
ENV SYSTEM_VERSION=${SYSTEM_VERSION}

# ALARM aarch64 rootfs tarball (verified reachable; ADD auto-extracts tar.gz
# so its top-level etc/ usr/ ... land directly in /work/rootfs/).
ADD http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz /work/rootfs/

COPY files /work/files
COPY files-systemd /work/files-systemd
COPY build-rootfs-pacman.sh /work/build-rootfs-pacman.sh
RUN chmod +x /work/build-rootfs-pacman.sh && DISTRO=arch /work/build-rootfs-pacman.sh

RUN mksquashfs /work/rootfs /work/arch-rootfs.squashfs \
    -comp zstd -Xcompression-level 19 -all-root -noappend \
    -e /proc /sys /dev /run /tmp /var/tmp /work \
       /var/cache/pacman/pkg /var/log \
       /usr/share/man /usr/share/doc /usr/share/locale /usr/share/info

FROM scratch AS export
COPY --from=builder /work/arch-rootfs.squashfs /arch-rootfs.squashfs
```

- [ ] **Step 3: Write `build-rootfs/Dockerfile.rootfs-manjaro`**

Copy `Dockerfile.rootfs-arch` verbatim, changing ONLY: header (`Manjaro ARM (aarch64) — ALARM base + Manjaro repos`, asset `manjaro-rootfs.squashfs`), and:

```dockerfile
RUN chmod +x /work/build-rootfs-pacman.sh && DISTRO=manjaro /work/build-rootfs-pacman.sh
```

```dockerfile
RUN mksquashfs /work/rootfs /work/manjaro-rootfs.squashfs \
```

```dockerfile
COPY --from=builder /work/manjaro-rootfs.squashfs /manjaro-rootfs.squashfs
```

- [ ] **Step 4: Extend `build.sh`**

After the `opensuse)` case-map line add:

```bash
        arch)     dockerfile="Dockerfile.rootfs-arch";     outfile="arch-rootfs.squashfs" ;;
        manjaro)  dockerfile="Dockerfile.rootfs-manjaro";  outfile="manjaro-rootfs.squashfs" ;;
```

Default loop becomes:

```bash
    for d in kali debian ubuntu fedora rocky alma opensuse arch manjaro; do
```

After the `opensuse)` TARGET line add:

```bash
    arch)           build_distro_rootfs arch ;;
    manjaro)        build_distro_rootfs manjaro ;;
```

- [ ] **Step 5: Verify syntax + Manjaro TrustAll gate present**

```bash
sh -n build-rootfs/build-rootfs-pacman.sh && bash -n build.sh && echo OK
grep -c "TrustAll" build-rootfs/build-rootfs-pacman.sh   # expect 4 (3 writes + 1 guard grep)
grep -c "manjaro-rootfs.squashfs" build.sh build-rootfs/Dockerfile.rootfs-manjaro
```

Expected: `OK`; TrustAll count = 4; manjaro asset count ≥ 1 per file.

- [ ] **Step 6: Commit**

```bash
git add build-rootfs/build-rootfs-pacman.sh build-rootfs/Dockerfile.rootfs-arch \
        build-rootfs/Dockerfile.rootfs-manjaro build.sh
git commit -m "feat: pacman-family rootfs builder (arch linux arm, manjaro arm)"
```

---

### Task 5: Gentoo — `build-rootfs-gentoo.sh` + Dockerfile + build.sh case

**Files (ROOTFS repo):**
- Create: `build-rootfs/build-rootfs-gentoo.sh`
- Create: `build-rootfs/Dockerfile.rootfs-gentoo`
- Modify: `build.sh`

**Interfaces:**
- Consumes: Gentoo stage3-arm64-openrc tarball (pointer fetch inside script), OpenRC overlay `build-rootfs/files/` (same as Kali/Debian — NOT files-systemd)
- Produces: asset `gentoo-rootfs.squashfs`; target `./build.sh gentoo`.

**Risk gate (spec §8):** binhost URL must return 200, and the podman binpkg probe is wrapped in `timeout 600` — a source fallback must die red fast, never run long.

- [ ] **Step 1: Write `build-rootfs/build-rootfs-gentoo.sh`**

```sh
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
PTR=$(curl -fsSL \
    https://distfiles.gentoo.org/releases/arm64/autobuilds/latest-stage3-arm64-openrc.txt \
    | grep -v '^#' | grep -v '^$' | head -1 | awk '{print $1}')
if [ -z "$PTR" ]; then
    echo "FATAL: stage3 pointer file empty or unreachable" >&2
    exit 1
fi
echo "stage3: $PTR"
mkdir -p "$R"
curl -fsSL "https://distfiles.gentoo.org/releases/arm64/${PTR}" | tar -xJp -C "$R"

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
BINHOST_URL="${PORTAGE_BINHOST_URL:-https://distfiles.gentoo.org/binpackages/arm64-gentoo-linux-gnu/}"
if ! curl -fsSI "$BINHOST_URL" >/dev/null; then
    echo "FATAL: binhost not reachable (200 expected): $BINHOST_URL" >&2
    echo "Fix PORTAGE_BINHOST_URL (candidates follow; first HTTP 200 wins):" >&2
    echo "  https://distfiles.gentoo.org/binpackages/aarch64-gentoo-linux-gnu/" >&2
    echo "  https://distfiles.gentoo.org/binpackages/arm64/linux-gnu/" >&2
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
            usr/local/bin/podroid-getty sbin/init; do
    if [ ! -e "$R/$must" ] && [ "$must" = "sbin/init" ]; then
        continue  # already checked binary variants above; symlink check below
    fi
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
```

- [ ] **Step 2: Write `build-rootfs/Dockerfile.rootfs-gentoo`**

```dockerfile
# build-rootfs/Dockerfile.rootfs-gentoo
#
# Builds the Podroid guest rootfs as squashfs from Gentoo stage3-arm64-openrc.
# OpenRC + sysvinit boot path — shares the Kali/Debian files/ overlay and the
# shared initramfs. Consumed by poroid-apk as `gentoo-rootfs.squashfs`.

# ── Stage 1: cross-compile podroid-* C agents (static aarch64) ──────────────
FROM debian:bookworm AS vsock-builder
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu libc6-dev-arm64-cross make \
    && rm -rf /var/lib/apt/lists/*
ENV CC=aarch64-linux-gnu-gcc
WORKDIR /work
COPY vsock-agent /work/vsock-agent
RUN make -C /work/vsock-agent CC=${CC} clean all
COPY host-bridge /work/host-bridge
RUN make -C /work/host-bridge CC=${CC} clean all
COPY overlay-normalize /work/overlay-normalize
RUN make -C /work/overlay-normalize CC=${CC} clean all

# ── Stage 2: fetch stage3 + chroot emerge + squashfs ────────────────────────
FROM --platform=linux/arm64 debian:bookworm AS builder
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates xz-utils squashfs-tools rsync libcap2-bin \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work

COPY --from=vsock-builder /work/vsock-agent/podroid-vsock-agent /usr/local/bin/podroid-vsock-agent
COPY --from=vsock-builder /work/host-bridge/podroid-hostd /usr/local/bin/podroid-hostd
COPY --from=vsock-builder /work/overlay-normalize/podroid-overlay-normalize /usr/local/bin/podroid-overlay-normalize
RUN chmod +x /usr/local/bin/podroid-vsock-agent /usr/local/bin/podroid-hostd \
             /usr/local/bin/podroid-overlay-normalize

ARG SYSTEM_VERSION=0
ENV SYSTEM_VERSION=${SYSTEM_VERSION}

COPY files /work/files
COPY build-rootfs-gentoo.sh /work/build-rootfs-gentoo.sh
RUN chmod +x /work/build-rootfs-gentoo.sh && SYSTEM_VERSION=${SYSTEM_VERSION} /work/build-rootfs-gentoo.sh

RUN mksquashfs /work/rootfs /work/gentoo-rootfs.squashfs \
    -comp zstd -Xcompression-level 19 -all-root -noappend \
    -e /proc /sys /dev /run /tmp /var/tmp /work \
       /var/cache/distfiles /var/cache/binpkgs /var/log \
       /usr/share/man /usr/share/doc /usr/share/locale /usr/share/info

FROM scratch AS export
COPY --from=builder /work/gentoo-rootfs.squashfs /gentoo-rootfs.squashfs
```

- [ ] **Step 3: Extend `build.sh`**

After the `manjaro)` case-map line add:

```bash
        gentoo)   dockerfile="Dockerfile.rootfs-gentoo";   outfile="gentoo-rootfs.squashfs" ;;
```

Default loop becomes (final, 10 distros):

```bash
    for d in kali debian ubuntu fedora rocky alma opensuse arch manjaro gentoo; do
```

After the `manjaro)` TARGET line add:

```bash
    gentoo)         build_distro_rootfs gentoo ;;
```

- [ ] **Step 4: Verify syntax + fail-fast gates present**

```bash
sh -n build-rootfs/build-rootfs-gentoo.sh && bash -n build.sh && echo OK
grep -c "FATAL" build-rootfs/build-rootfs-gentoo.sh   # expect >= 7
grep -c "timeout 600" build-rootfs/build-rootfs-gentoo.sh   # expect 1
grep -n "gentoo" build.sh | head -5
```

Expected: `OK`; FATAL ≥ 7; timeout = 1; build.sh shows case-map, loop, TARGET entries.

- [ ] **Step 5: Commit**

```bash
git add build-rootfs/build-rootfs-gentoo.sh build-rootfs/Dockerfile.rootfs-gentoo build.sh
git commit -m "feat: gentoo rootfs builder (stage3 openrc, binpkg fail-fast)"
```

---

### Task 6: README + `build.sh` usage audit

**Files (ROOTFS repo):**
- Modify: `README.md`
- Modify: `build.sh` (usage string only — all functional entries exist from Tasks 2–5)

**Interfaces:**
- Consumes: asset names + base pins (Global Constraints)
- Produces: final usage string in `build.sh`; supported-distro table in README (docs contract for APK labels).

- [ ] **Step 1: Update `build.sh` usage string**

Replace the final usage/error line so it reads:

```bash
    *) echo "usage: $0 [initramfs|rootfs|kali|debian|ubuntu|fedora|rocky|alma|opensuse|arch|manjaro|gentoo|all] [SYSTEM_VERSION]"; exit 1 ;;
```

Also update the file-header comment block (first 6 lines) — replace the variant list line with:

```bash
#   rootfs variants: kali, debian, ubuntu, fedora, rocky, alma, opensuse,
#                    arch, manjaro, gentoo (default: all ten)
```

- [ ] **Step 2: Verify every Distro has map+loop+target entries**

```bash
for d in kali debian ubuntu fedora rocky alma opensuse arch manjaro gentoo; do
  grep -q "outfile=\"${d}-rootfs.squashfs\"" build.sh || echo "MAP MISSING: $d"
  grep -q "build_distro_rootfs ${d}" build.sh || echo "TARGET MISSING: $d"
done
grep -q "for d in kali debian ubuntu fedora rocky alma opensuse arch manjaro gentoo" build.sh \
  || echo "LOOP MISSING"
bash -n build.sh && echo "SYNTAX OK"
```

Expected: only `SYNTAX OK` (no MISSING lines).

- [ ] **Step 3: Rewrite `README.md`**

Full replacement content:

```markdown
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
- **Manjaro** = Arch Linux ARM base + official Manjaro ARM repos
  (`repo.manjaro.org/repo/arm-stable`), keyring bootstrapped at build time.
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
```

- [ ] **Step 4: Verify**

```bash
grep -c "gentoo-rootfs.squashfs" README.md
grep -q "Linux Mint, EndeavourOS" README.md && echo "OK: unsupported note"
grep -q "kali|debian|ubuntu|fedora" build.sh || grep -q "fedora" build.sh
bash -n build.sh && echo OK
```

Expected: count ≥ 1; `OK: unsupported note`; `OK`.

- [ ] **Step 5: Commit**

```bash
git add README.md build.sh
git commit -m "docs: 10-distro support matrix, unsupported note (Mint/EndeavourOS), build usage"
```

---

### Task 7: Workflow — dynamic matrix + upload-bug fix

**Files (ROOTFS repo):**
- Modify: `.github/workflows/build.yml` (full rewrite, below)

**Interfaces:**
- Consumes: `build.sh` targets (Tasks 2–5); Release `latest`
- Produces: dispatch contract `inputs.distro ∈ {initramfs,kali,debian,ubuntu,fedora,rocky,alma,opensuse,arch,manjaro,gentoo,all}` (Task 9/10 use it); artifact names `podroid-system-<distro>`; per-job env `DISTRO=matrix.distro`.

- [ ] **Step 1: Replace `.github/workflows/build.yml` entirely**

```yaml
name: 构建系统镜像 (poroid-rootfs)

on:
  push:
    branches: [ main ]
    paths:
      - 'build-rootfs/**'
      - 'init-podroid'
      - 'Dockerfile.initramfs'
      - 'build.sh'
      - '.github/workflows/build.yml'
  workflow_dispatch:
    inputs:
      distro:
        description: '构建哪个镜像'
        required: true
        default: 'kali'
        type: choice
        options:
          - initramfs
          - kali
          - debian
          - ubuntu
          - fedora
          - rocky
          - alma
          - opensuse
          - arch
          - manjaro
          - gentoo
          - all
      system_version:
        description: '系统版本号 (SYSTEM_VERSION)'
        required: false
        default: '0'
        type: string
      push_to_release:
        description: '上传到 GitHub Release'
        required: true
        default: true
        type: boolean

env:
  DISTRO: ${{ github.event.inputs.distro || 'kali' }}
  SYSTEM_VERSION: ${{ github.event.inputs.system_version || '0' }}

jobs:
  resolve:
    runs-on: ubuntu-latest
    outputs:
      list: ${{ steps.set.outputs.list }}
    steps:
      - name: 展开 distro → 矩阵数组
        id: set
        env:
          D: ${{ env.DISTRO }}
        run: |
          case "$D" in
            initramfs)
              echo 'list=[]' >> "$GITHUB_OUTPUT" ;;
            all)
              echo 'list=["kali","debian","ubuntu","fedora","rocky","alma","opensuse","arch","manjaro","gentoo"]' >> "$GITHUB_OUTPUT" ;;
            *)
              echo "list=[\"$D\"]" >> "$GITHUB_OUTPUT" ;;
          esac
          echo "matrix for $D:"; cat "$GITHUB_OUTPUT"
      - name: 确保 Release 存在（单点创建，避免并行 job 竞争）
        if: ${{ env.DISTRO != 'initramfs' && github.event.inputs.push_to_release != 'false' }}
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          gh release view latest >/dev/null 2>&1 || \
            gh release create latest --title "最新系统镜像" \
              --notes "System $SYSTEM_VERSION ($DISTRO)" --prerelease

  initramfs:
    runs-on: ubuntu-latest
    timeout-minutes: 60
    env:
      DEBIAN_FRONTEND: noninteractive
      DISTRO: initramfs
    steps:
      - name: 检出代码
        uses: actions/checkout@v4
      - name: 释放磁盘空间
        run: sudo rm -rf /usr/share/dotnet /opt/ghc 2>/dev/null || true
      - name: 构建 initramfs
        run: ./build.sh initramfs
      - name: 上传系统镜像产物
        uses: actions/upload-artifact@v4
        with:
          name: podroid-system-initramfs
          path: out/initrd.img
          if-no-files-found: error
          retention-days: 30
      - name: 上传到 Release
        if: ${{ github.event.inputs.push_to_release != 'false' }}
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: gh release upload latest out/initrd.img --clobber

  build-rootfs:
    needs: resolve
    if: ${{ needs.resolve.outputs.list != '[]' }}
    runs-on: ubuntu-latest
    timeout-minutes: 240
    strategy:
      fail-fast: false
      matrix:
        distro: ${{ fromJSON(needs.resolve.outputs.list) }}
    env:
      DEBIAN_FRONTEND: noninteractive
      DISTRO: ${{ matrix.distro }}
    steps:
      - name: 检出代码
        uses: actions/checkout@v4
      - name: 释放磁盘空间
        run: |
          sudo rm -rf /usr/share/dotnet /opt/ghc 2>/dev/null || true
          df -h
      - name: 设置 QEMU (arm64)
        uses: docker/setup-qemu-action@v3
        with:
          platforms: arm64
      - name: 设置 Docker Buildx
        uses: docker/setup-buildx-action@v3
      - name: 构建目标镜像
        run: |
          echo "DISTRO=${DISTRO} SYSTEM_VERSION=${SYSTEM_VERSION}"
          ./build.sh "${DISTRO}"
      - name: 生成带版本号文件名
        run: |
          case "${DISTRO}" in
            kali)     cp out/kali-rootfs.squashfs     out/kali-rootfs-rolling.squashfs ;;
            debian)   cp out/debian-rootfs.squashfs   out/debian-rootfs-12.squashfs ;;
            ubuntu)   cp out/ubuntu-rootfs.squashfs   out/ubuntu-rootfs-24.04.squashfs ;;
            fedora)   cp out/fedora-rootfs.squashfs   out/fedora-rootfs-42.squashfs ;;
            rocky)    cp out/rocky-rootfs.squashfs    out/rocky-rootfs-9.squashfs ;;
            alma)     cp out/alma-rootfs.squashfs     out/alma-rootfs-9.squashfs ;;
            opensuse) cp out/opensuse-rootfs.squashfs out/opensuse-rootfs-15.6.squashfs ;;
            arch)     cp out/arch-rootfs.squashfs     out/arch-rootfs-rolling.squashfs ;;
            manjaro)  cp out/manjaro-rootfs.squashfs  out/manjaro-rootfs-rolling.squashfs ;;
            gentoo)   cp out/gentoo-rootfs.squashfs   out/gentoo-rootfs-rolling.squashfs ;;
            *) echo "未知 distro: ${DISTRO}"; exit 1 ;;
          esac
          ls -lh out/
      - name: 清理 Docker 镜像
        run: |
          docker rmi -f "podroid-rootfs-${DISTRO}" 2>/dev/null || true
          docker system prune -f 2>/dev/null || true
          df -h /
      - name: 上传系统镜像产物
        uses: actions/upload-artifact@v4
        with:
          name: podroid-system-${{ env.DISTRO }}
          path: |
            out/*rootfs*.squashfs
          if-no-files-found: error
          retention-days: 30
      - name: 上传到 Release
        if: ${{ github.event.inputs.push_to_release != 'false' }}
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          # Glob hits base name AND versioned copy. NO `|| true` — a failed
          # upload must turn the job red (historical bug: swallowed errors
          # shipped "green" runs with missing Release assets).
          shopt -s nullglob
          files=(out/*rootfs*.squashfs)
          if [ ${#files[@]} -eq 0 ]; then
            echo "FATAL: no rootfs assets matched out/*rootfs*.squashfs" >&2
            exit 1
          fi
          for f in "${files[@]}"; do
            gh release upload latest "$f" --clobber
          done
```

- [ ] **Step 2: Verify YAML parses + key invariants**

```bash
python3 - <<'EOF'
import sys
try:
    import yaml
except ImportError:
    print("SKIP: pyyaml unavailable — structural grep only"); sys.exit(0)
d = yaml.safe_load(open(".github/workflows/build.yml"))
opts = d[True]["workflow_dispatch"]["inputs"]["distro"]["options"] \
    if True in d else d["on"]["workflow_dispatch"]["inputs"]["distro"]["options"]
need = ["initramfs","kali","debian","ubuntu","fedora","rocky","alma","opensuse","arch","manjaro","gentoo","all"]
assert opts == need, f"options mismatch: {opts}"
assert "fromJSON(needs.resolve.outputs.list)" in open(".github/workflows/build.yml").read()
print("YAML OK")
EOF
grep -c "|| true" .github/workflows/build.yml
grep -n "out/\*rootfs\*.squashfs" .github/workflows/build.yml
```

Expected: `YAML OK` or `SKIP`; `|| true` count = **0**; glob appears in artifact path + upload step (≥ 2).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "ci: per-distro parallel matrix, fix release-upload glob and error swallowing"
```

---

### Task 8: APK — enum + labels + FlowRow + tests (commit locally, push later)

**Files (APK repo):**
- Modify: `app/src/main/java/com/excp/podroid/data/repository/SystemImageRepository.kt` (Distro enum only)
- Modify: `app/src/main/java/com/excp/podroid/ui/components/DistroUi.kt`
- Modify: `app/src/main/java/com/excp/podroid/ui/screens/setup/SetupScreen.kt` (Row → FlowRow + import)
- Modify: `app/src/main/res/values/strings.xml` (after line 108 `distro_ubuntu`)
- Modify: `app/src/main/res/values-zh/strings.xml` (after line 108)
- Modify: `app/src/test/java/com/excp/podroid/data/repository/DistroTest.kt`

**Interfaces:**
- Consumes: asset names (Global Constraints) — must equal rootfs Release asset names exactly.
- Produces: `Distro.FEDORA/ROCKY/ALMA/OPENSUSE/ARCH/MANJARO/GENTOO`; `R.string.distro_*` ×7; `distroLabelRes` exhaustive for 10.

- [ ] **Step 1: Extend `DistroTest.kt` — add the full-map test (and keep existing tests)**

Append this test method inside `class DistroTest` (after existing methods):

```kotlin
    @Test
    fun allTenDistrosHaveReleaseAssets() {
        val expected = mapOf(
            Distro.KALI to "kali-rootfs.squashfs",
            Distro.DEBIAN to "debian-rootfs.squashfs",
            Distro.UBUNTU to "ubuntu-rootfs.squashfs",
            Distro.FEDORA to "fedora-rootfs.squashfs",
            Distro.ROCKY to "rocky-rootfs.squashfs",
            Distro.ALMA to "alma-rootfs.squashfs",
            Distro.OPENSUSE to "opensuse-rootfs.squashfs",
            Distro.ARCH to "arch-rootfs.squashfs",
            Distro.MANJARO to "manjaro-rootfs.squashfs",
            Distro.GENTOO to "gentoo-rootfs.squashfs",
        )
        assertEquals(expected, Distro.values().associateWith { it.asset })
    }
```

The pre-existing `presetUrlsPointAtSharedLatestRelease` loops `Distro.values()` — it automatically covers all 10 once the enum is extended. The pre-existing `kaliPresetDoesNotAliasOtherDistros` assertion (`!kali.contains("ubuntu") && !kali.contains("debian-rootfs")`) still holds (no new asset name contains those substrings as a kali alias).

- [ ] **Step 2: Extend the `Distro` enum**

In `SystemImageRepository.kt`, replace the enum body with:

```kotlin
enum class Distro(val asset: String) {
    KALI("kali-rootfs.squashfs"),
    DEBIAN("debian-rootfs.squashfs"),
    UBUNTU("ubuntu-rootfs.squashfs"),
    FEDORA("fedora-rootfs.squashfs"),
    ROCKY("rocky-rootfs.squashfs"),
    ALMA("alma-rootfs.squashfs"),
    OPENSUSE("opensuse-rootfs.squashfs"),
    ARCH("arch-rootfs.squashfs"),
    MANJARO("manjaro-rootfs.squashfs"),
    GENTOO("gentoo-rootfs.squashfs"),
}
```

Do NOT touch `distro()`, `setDistro()`, `rootfsFile()`, `presetUrl()` — already data-driven; the single-VM invariant lives there.

- [ ] **Step 3: Extend `DistroUi.kt`**

```kotlin
    Distro.KALI -> R.string.distro_kali
    Distro.DEBIAN -> R.string.distro_debian
    Distro.UBUNTU -> R.string.distro_ubuntu
    Distro.FEDORA -> R.string.distro_fedora
    Distro.ROCKY -> R.string.distro_rocky
    Distro.ALMA -> R.string.distro_alma
    Distro.OPENSUSE -> R.string.distro_opensuse
    Distro.ARCH -> R.string.distro_arch
    Distro.MANJARO -> R.string.distro_manjaro
    Distro.GENTOO -> R.string.distro_gentoo
```

(Compiler's exhaustive-`when` will flag any miss — that is the gate.)

- [ ] **Step 4: Add 7 strings to `values/strings.xml` (after `distro_ubuntu`)**

```xml
    <string name="distro_fedora">Fedora Linux</string>
    <string name="distro_rocky">Rocky Linux</string>
    <string name="distro_alma">AlmaLinux</string>
    <string name="distro_opensuse">openSUSE Leap</string>
    <string name="distro_arch">Arch Linux</string>
    <string name="distro_manjaro">Manjaro</string>
    <string name="distro_gentoo">Gentoo Linux</string>
```

- [ ] **Step 5: Add the same 7 lines to `values-zh/strings.xml` (after `distro_ubuntu`)**

(Identical brand strings — product names don't translate.)

- [ ] **Step 6: `SetupScreen.kt` — Row → FlowRow**

Add import next to the existing `androidx.compose.foundation.layout.*` imports (file already imports `Row`; keep it — used elsewhere):

```kotlin
import androidx.compose.foundation.layout.FlowRow
```

Replace:

```kotlin
        Row(horizontalArrangement = Arrangement.spacedBy(PodroidTokens.Spacing.SM)) {
            Distro.values().forEach { d ->
```

with:

```kotlin
        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(PodroidTokens.Spacing.SM),
            verticalArrangement = Arrangement.spacedBy(PodroidTokens.Spacing.XS),
        ) {
            Distro.values().forEach { d ->
```

No `@OptIn` needed: repo already uses plain `FlowRow` in `ui/components/VmResourceChips.kt` under compose BOM `2026.03.01` (stable). Chip body (FilterChip/shape/colors/Bold) unchanged.

- [ ] **Step 7: Static verification (no local Android SDK — full gate is CI in Task 12)**

```bash
cd /data/data/com.termux/files/usr/tmp/opencode/split/poroid-apk
# enum ↔ test ↔ strings ↔ when consistency
python3 - <<'EOF'
import re, pathlib
repo = pathlib.Path(".")
enum = re.search(r"enum class Distro\(val asset: String\) \{(.*?)\}", 
    (repo/"app/src/main/java/com/excp/podroid/data/repository/SystemImageRepository.kt").read_text(), re.S).group(1)
names = re.findall(r"^\s*([A-Z]+)\(", enum, re.M)
assert names == ["KALI","DEBIAN","UBUNTU","FEDORA","ROCKY","ALMA","OPENSUSE","ARCH","MANJARO","GENTOO"], names
ui = (repo/"app/src/main/java/com/excp/podroid/ui/components/DistroUi.kt").read_text()
for n in names:
    assert f"Distro.{n} ->" in ui, f"DistroUi missing {n}"
s_en = (repo/"app/src/main/res/values/strings.xml").read_text()
s_zh = (repo/"app/src/main/res/values-zh/strings.xml").read_text()
for key in ["distro_fedora","distro_rocky","distro_alma","distro_opensuse","distro_arch","distro_manjaro","distro_gentoo"]:
    assert f'name="{key}"' in s_en and f'name="{key}"' in s_zh, f"string missing {key}"
sc = (repo/"app/src/main/java/com/excp/podroid/ui/screens/setup/SetupScreen.kt").read_text()
assert "FlowRow(" in sc and "import androidx.compose.foundation.layout.FlowRow" in sc
assert not re.search(r"Row\(horizontalArrangement = Arrangement\.spacedBy\(PodroidTokens\.Spacing\.SM\)\) \{\s*\n\s*Distro\.values", sc)
t = (repo/"app/src/test/java/com/excp/podroid/data/repository/DistroTest.kt").read_text()
assert "allTenDistrosHaveReleaseAssets" in t
print("STATIC OK: enum/UI/strings/test consistent (10 distros)")
EOF
```

Expected: `STATIC OK: enum/UI/strings/test consistent (10 distros)`.

- [ ] **Step 8: Commit (local only — push in Task 12)**

```bash
git add app/src/main/java/com/excp/podroid/data/repository/SystemImageRepository.kt \
        app/src/main/java/com/excp/podroid/ui/components/DistroUi.kt \
        app/src/main/java/com/excp/podroid/ui/screens/setup/SetupScreen.kt \
        app/src/main/res/values/strings.xml app/src/main/res/values-zh/strings.xml \
        app/src/test/java/com/excp/podroid/data/repository/DistroTest.kt
git commit -m "feat: extend wizard to 10 distros (enum, labels, FlowRow chips, tests)"
```

---

### Task 9: Push rootfs (squashed) + fedora smoke dispatch + matrix/asset assertion

**Files (ROOTFS repo):** push Tasks 1–7 commits as ONE commit (spec §7).

**Interfaces:**
- Consumes: Tasks 1–7 local commits; workflow `build.yml` (Task 7); PAT-configured `origin`
- Produces: pushed main; first real matrix run; `fedora-rootfs.squashfs` (+ `fedora-rootfs-42.squashfs`) on Release; green `resolve→initramfs→build-rootfs(fedora)` graph.

- [ ] **Step 1: Squash-push rootfs work**

```bash
cd /data/data/com.termux/files/usr/tmp/opencode/split/poroid-rootfs
# Squash everything after the spec commit (744a7ba) into one commit.
BASE=744a7ba
git reset --soft "$BASE"
git add -A
git commit -m "feat: expand to 10 distros — fedora/rocky/alma/opensuse/arch/manjaro/gentoo builders, matrix CI, release-upload fix"
for i in 1 2 3; do
  git push origin main 2>"$HOME/.push.err" && { echo "PUSH OK"; break; }
  echo "retry $i: $(tail -1 "$HOME/.push.err")"; sleep 3
done
git log --oneline -2
```

Expected: exactly ONE new commit on top of `744a7ba`; `PUSH OK`.

- [ ] **Step 2: Dispatch fedora smoke (matrix expansion validation)**

```bash
PAT="$GITHUB_PAT  # inject from env; never commit the literal"
curl -s -X POST \
  -H "Authorization: Bearer $PAT" -H "Accept: application/vnd.github+json" \
  -H "Content-Type: application/json" \
  "https://api.github.com/repos/nike64542-byte/poroid-rootfs/actions/workflows/build.yml/dispatches" \
  -d '{"ref":"main","inputs":{"distro":"fedora","system_version":"0","push_to_release":"true"}}' \
  -w "dispatch http=%{http_code}\n"
sleep 10
python3 -u - <<'EOF'
import urllib.request, json, time, sys
pat = "$GITHUB_PAT  # inject from env; never commit the literal"
def api(url, data=None):
    req = urllib.request.Request(url, data=data, headers={
        "Authorization": f"Bearer {pat}", "Accept": "application/vnd.github+json",
        "Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=30))
runs = api("https://api.github.com/repos/nike64542-byte/poroid-rootfs/actions/runs?per_page=5")["workflow_runs"]
run = next(r for r in runs if r["event"] == "workflow_dispatch" and r["created_at"] > "2026-09-24")
rid = run["id"]
print("watching run", rid)
for _ in range(180):  # up to 60 min (10s poll)
    r = api(f"https://api.github.com/repos/nike64542-byte/poroid-rootfs/actions/runs/{rid}")
    print(r["status"], r.get("conclusion"), flush=True)
    if r["status"] == "completed": break
    time.sleep(10)
else:
    sys.exit("TIMEOUT"); 
assert r["conclusion"] == "success", f"run failed: {r['conclusion']}"
# jobs: expect resolve + initramfs + build-rootfs(fedora)
jobs = api(f"https://api.github.com/repos/nike64542-byte/poroid-rootfs/actions/runs/{rid}/jobs")["jobs"]
names = sorted((j["name"], j["conclusion"]) for j in jobs)
print("jobs:", names)
assert any("fedora" in n for n, _ in names), "matrix did not expand to fedora"
assert all(c == "success" for _, c in names), names
rel = api("https://api.github.com/repos/nike64542-byte/poroid-rootfs/releases/tags/latest")
assets = {a["name"]: a["size"] for a in rel["assets"]}
for want in ("fedora-rootfs.squashfs", "fedora-rootfs-42.squashfs", "initrd.img"):
    assert want in assets and assets[want] > 1_000_000, f"missing/too-small: {want} (have: {sorted(assets)})"
print("SMOKE OK: matrix expanded, fedora asset + versioned copy + initrd on Release")
EOF
```

Expected: `SMOKE OK: ...` — resolves the Review-Focus #1/#3 gates for the fedora path.

- [ ] **Step 3: No commit** (this task only pushes/dispatches).

---

### Task 10: Dispatch remaining 6 + full asset assertion

**Interfaces:**
- Consumes: green smoke (Task 9)
- Produces: 6 more green runs; Release carries all 7 new base assets + versioned copies.

- [ ] **Step 1: Dispatch rocky, alma, opensuse, arch, manjaro, gentoo**

```bash
PAT="$GITHUB_PAT  # inject from env; never commit the literal"
for d in rocky alma opensuse arch manjaro gentoo; do
  curl -s -X POST \
    -H "Authorization: Bearer $PAT" -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    "https://api.github.com/repos/nike64542-byte/poroid-rootfs/actions/workflows/build.yml/dispatches" \
    -d "{\"ref\":\"main\",\"inputs\":{\"distro\":\"$d\",\"system_version\":\"0\",\"push_to_release\":\"true\"}}" \
    -w "dispatch $d http=%{http_code}\n"
  sleep 5
done
```

- [ ] **Step 2: Poll all 6 runs + assert full asset table**

```bash
python3 -u - <<'EOF'
import urllib.request, json, time, sys
pat = "$GITHUB_PAT  # inject from env; never commit the literal"
def api(url):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {pat}", "Accept": "application/vnd.github+json"})
    return json.load(urllib.request.urlopen(req, timeout=30))
targets = {"rocky","alma","opensuse","arch","manjaro","gentoo"}
runs = api("https://api.github.com/repos/nike64542-byte/poroid-rootfs/actions/runs?per_page=30")["workflow_runs"]
watch = {}
for r in runs:
    if r["event"] != "workflow_dispatch" or r["created_at"] < "2026-09-24": continue
    if r["id"] in watch: continue
    # map run → distro via display title is unreliable; track unfinished runs instead
for _ in range(360):  # up to 60 min
    runs = api("https://api.github.com/repos/nike64542-byte/poroid-rootfs/actions/runs?per_page=30")["workflow_runs"]
    live = [r for r in runs if r["event"]=="workflow_dispatch" and r["created_at"]>"2026-09-24"
            and r["status"]!="completed"]
    for r in live:
        print(r["id"], r["status"], flush=True)
    if not live: break
    time.sleep(10)
runs = api("https://api.github.com/repos/nike64542-byte/poroid-rootfs/actions/runs?per_page=30")["workflow_runs"]
todays = [r for r in runs if r["event"]=="workflow_dispatch" and r["created_at"]>"2026-09-24"]
bad = [(r["id"], r["conclusion"]) for r in todays if r["conclusion"] != "success"]
print("today's runs:", len(todays), "failed:", bad)
assert not bad, f"failed runs: {bad}"
rel = api("https://api.github.com/repos/nike64542-byte/poroid-rootfs/releases/tags/latest")
assets = {a["name"]: a["size"] for a in rel["assets"]}
want = ["fedora","rocky","alma","opensuse","arch","manjaro","gentoo"]
for d in want:
    for n in (f"{d}-rootfs.squashfs",):
        assert n in assets and assets[n] > 1_000_000, f"missing {n}; have {sorted(assets)}"
# versioned copies (spec/global constraints)
for n in ["fedora-rootfs-42.squashfs","rocky-rootfs-9.squashfs","alma-rootfs-9.squashfs",
          "opensuse-rootfs-15.6.squashfs","arch-rootfs-rolling.squashfs",
          "manjaro-rootfs-rolling.squashfs","gentoo-rootfs-rolling.squashfs"]:
    assert n in assets and assets[n] > 1_000_000, f"missing versioned copy {n}"
print("ASSETS OK: 7 base + 7 versioned + initrd present")
for k in sorted(assets): print(f"  {k:35} {assets[k]:>12,}")
EOF
```

Expected: `ASSETS OK: 7 base + 7 versioned + initrd present`. A failure here with a green-looking job would reopen Review Focus #3 (should be impossible post-Task-7, but assert anyway).

- [ ] **Step 3: If a run failed** — download its job log, fix-forward with a NEW local commit + squash-amend push is NOT allowed (spec: 1 commit… actually the pushed commit already exists): push a second small `fix:` commit (allowed — exception to one-commit rule only for CI fix-forwards; note it in the PR/summary), re-dispatch just that distro, re-run Step 2 assertion.

- [ ] **Step 4: No commit** on success.

---

### Task 11: Image content probes (offline, 7/7)

**Files (ROOTFS repo):** none — probe script runs from `$HOME/.push` workspace? Use `/data/data/com.termux/files/usr/tmp/opencode/probe/` scratch dir (create it).

**Interfaces:**
- Consumes: the 7 Release assets (public URLs)
- Produces: probe report `PROBES OK: 7/7`.

- [ ] **Step 1: Ensure probe deps**

```bash
python3 -c "import PySquashfsImage, zstandard" 2>/dev/null || \
  pip install --user PySquashfsImage zstandard
mkdir -p /data/data/com.termux/files/usr/tmp/opencode/probe
cd /data/data/com.termux/files/usr/tmp/opencode/probe
```

- [ ] **Step 2: Download the 7 images (public release URLs)**

```bash
BASE="https://github.com/nike64542-byte/poroid-rootfs/releases/download/latest"
for d in fedora rocky alma opensuse arch manjaro gentoo; do
  [ -f "${d}-rootfs.squashfs" ] || curl -sL -o "${d}-rootfs.squashfs" \
    "$BASE/${d}-rootfs.squashfs" &
done
wait
ls -lh *-rootfs.squashfs
```

Expected: 7 files, each ≥ 1 MB (sizes 50–350 MB typical).

- [ ] **Step 3: Run the probe script**

```bash
cd /data/data/com.termux/files/usr/tmp/opencode/probe
python3 - <<'EOF'
from PySquashfsImage import SquashFsImage
import sys

SYSTEMD = ["fedora","rocky","alma","opensuse","arch","manjaro"]
OPENRC  = ["gentoo"]
failures = []

def sel(img, path):
    try:
        return img.root.select(path)
    except Exception:
        return None

def read(img, path):
    node = sel(img, path)
    if node is None: return None
    try:
        return node.read_bytes().decode("utf-8", "replace")
    except Exception:
        return None

def has_exec(img, path):
    node = sel(img, path)
    if node is None: return False
    try:
        return not node.is_dir and len(node.read_bytes()) > 0
    except Exception:
        return False

for d in SYSTEMD + OPENRC:
    img = SquashFsImage(f"{d}-rootfs.squashfs")
    errs = []
    # common
    pw = read(img, "etc/passwd") or ""
    if "root:" not in pw: errs.append("no root in /etc/passwd")
    if not has_exec(img, "usr/bin/podman") and not has_exec(img, "usr/bin/podman.exe"):
        if not has_exec(img, "bin/podman"): errs.append("podman binary missing")
    if not has_exec(img, "usr/local/bin/podroid-hostd"): errs.append("podroid-hostd missing")
    issue = read(img, "etc/issue") or ""
    if "Podroid" not in issue: errs.append("banner not Podroid-branded")
    sv = read(img, "etc/podroid/system-version")
    if sv is None: errs.append("system-version missing")
    # init binary — root-level symlink safe variants first
    if d in SYSTEMD:
        if sel(img, "usr/lib/systemd/systemd") is None: errs.append("systemd binary missing")
        for u in ["podroid-bootstrap.service","podroid-getty@.service","podroid-ready.service"]:
            if sel(img, f"etc/systemd/system/{u}") is None: errs.append(f"unit {u} missing")
        getty = read(img, "etc/systemd/system/podroid-getty@.service") or ""
        if "StandardInput=tty" not in getty or "StandardOutput=tty" not in getty:
            errs.append("getty unit missing tty stdio")
        for s in ["podroid-bootstrap.sh","podroid-network.sh","podroid-migrate.sh"]:
            c = read(img, f"usr/local/libexec/podroid/{s}")
            if c is None: errs.append(f"{s} missing")
            elif "set -eu" in c: errs.append(f"{s} still has set -eu")
            elif "set -u" not in c: errs.append(f"{s} missing set -u")
        # ssh: openssh family
        if not has_exec(img, "usr/sbin/sshd") and not has_exec(img, "usr/bin/sshd"):
            errs.append("sshd missing")
    else:  # gentoo OpenRC
        inittab = read(img, "etc/inittab") or ""
        if "podroid-getty" not in inittab: errs.append("inittab not podroid's")
        if "openrc" not in inittab: errs.append("inittab has no openrc entries")
        for s in ["podroid-bootstrap","podroid-network","podroid-ready"]:
            if sel(img, f"etc/init.d/{s}") is None: errs.append(f"init.d/{s} missing")
        if not any(sel(img, p) is not None for p in
                   ("usr/lib/sysvinit/init","lib/sysvinit/init","usr/sbin/init","sbin/init")):
            errs.append("sysvinit init binary missing")
        if not (has_exec(img, "usr/sbin/dropbear") or has_exec(img, "usr/bin/dropbear")):
            errs.append("dropbear missing")
        # OpenRC runlevel symlinks exist as dir entries
        if sel(img, "etc/runlevels/default") is None: errs.append("runlevels/default missing")
        if sel(img, "usr/local/libexec/podroid") is not None:
            errs.append("gentoo must NOT ship systemd libexec scripts")
    if errs: failures.append((d, errs))
    print(f"{d}: {'FAIL ' + '; '.join(errs) if errs else 'OK'}")

if failures:
    print("PROBES FAILED:", failures); sys.exit(1)
print("PROBES OK: 7/7")
EOF
```

Expected: seven `OK` lines + `PROBES OK: 7/7`.

- [ ] **Step 4: No commit** (scratch outputs only; probe dir is outside both repos).

---

### Task 12: Push APK (squashed) + CI green

**Files (APK repo):** push Task 8 commit as ONE commit (spec §7).

- [ ] **Step 1: Ensure remote exists**

```bash
cd /data/data/com.termux/files/usr/tmp/opencode/split/poroid-apk
git remote -v | grep -q origin || \
  git remote add origin "https://x-access-token:$GITHUB_PAT  # inject from env; never commit the literal@github.com/nike64542-byte/poroid-apk.git"
git status --short --branch | head -5
```

Expected: `## main` (clean except the Task 8 commit).

- [ ] **Step 2: Squash to one commit if Task 8 produced more than one commit**

```bash
# Squash everything after f69c8c5 (last pushed multi-distro wizard commit) into one commit.
BASE=$(git rev-parse f69c8c5 2>/dev/null || git log --format=%H --grep="multi-distro wizard" -1)
git reset --soft "$BASE"
git add -A
git diff --cached --quiet && echo "nothing to squash" || \
  git commit -m "feat: 10-distro wizard — fedora/rocky/alma/opensuse/arch/manjaro/gentoo chips, labels, tests"
git log --oneline -2
```

Expected: exactly ONE commit ahead of `f69c8c5`.

- [ ] **Step 3: Push with retry**

```bash
for i in 1 2 3; do
  git push origin main 2>"$HOME/.push.err" && { echo "PUSH OK"; break; }
  echo "retry $i: $(tail -1 "$HOME/.push.err")"; sleep 3
done
```

Expected: `PUSH OK`.

- [ ] **Step 4: Watch APK CI to green**

```bash
python3 -u - <<'EOF'
import urllib.request, json, time, sys
pat = "$GITHUB_PAT  # inject from env; never commit the literal"
def api(url):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {pat}", "Accept": "application/vnd.github+json"})
    return json.load(urllib.request.urlopen(req, timeout=30))
run = None
for _ in range(30):
    runs = api("https://api.github.com/repos/nike64542-byte/poroid-apk/actions/runs?per_page=5")["workflow_runs"]
    run = next((r for r in runs if r["event"]=="push" and r["created_at"]>"2026-09-24"), None)
    if run: break
    time.sleep(5)
assert run, "no push run found"
print("watching", run["id"])
for _ in range(120):
    r = api(f"https://api.github.com/repos/nike64542-byte/poroid-apk/actions/runs/{run['id']}")
    print(r["status"], r.get("conclusion"), flush=True)
    if r["status"]=="completed": break
    time.sleep(10)
assert r["conclusion"]=="success", f"CI failed: {r['id']}"
print("APK CI OK (unit tests incl. DistroTest + assemble)")
EOF
```

Expected: `APK CI OK ...`.

---

### Task 13: Delivery checklist + user handoff

- [ ] **Step 1: Final tables (both repos + Release)**

```bash
python3 -u - <<'EOF'
import urllib.request, json
pat = "$GITHUB_PAT  # inject from env; never commit the literal"
def api(url):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {pat}", "Accept": "application/vnd.github+json"})
    return json.load(urllib.request.urlopen(req, timeout=30))
print("== poroid-rootfs latest runs ==")
for r in api("https://api.github.com/repos/nike64542-byte/poroid-rootfs/actions/runs?per_page=14")["workflow_runs"][:12]:
    print(f"  {r['id']} {r['event']:17} {str(r['conclusion']):9} {r['created_at']} {r['display_title'][:50]}")
print("== poroid-apk latest runs ==")
for r in api("https://api.github.com/repos/nike64542-byte/poroid-apk/actions/runs?per_page=3")["workflow_runs"]:
    print(f"  {r['id']} {r['event']:17} {str(r['conclusion']):9} {r['created_at']} {r['display_title'][:50]}")
print("== Release latest assets ==")
rel = api("https://api.github.com/repos/nike64542-byte/poroid-rootfs/releases/tags/latest")
total = 0
for a in sorted(rel["assets"], key=lambda x: x["name"]):
    print(f"  {a['name']:35} {a['size']:>12,}  {a['updated_at']}")
    total += a["size"]
print(f"  TOTAL {total:,} bytes / {len(rel['assets'])} assets")
# spec completion asserts
names = {a["name"] for a in rel["assets"]}
for d in ["fedora","rocky","alma","opensuse","arch","manjaro","gentoo"]:
    assert f"{d}-rootfs.squashfs" in names, d
assert len(rel["assets"]) >= 18  # 10 base + versioned(10 w/ kali rolling etc) + initrd — see below
print("DELIVERY OK")
EOF
```

Expected: `DELIVERY OK` + printed tables (≥ 10 base assets, versioned copies, initrd; all of today's runs green).

- [ ] **Step 2: Handoff message to user (no tool — output text)**

Deliver a concise summary: 7 new distros live on Release (with sizes), workflow now matrix-parallel + upload bug fixed, APK now offers 10 chips (FlowRow), commits `1 per repo`, and the **device test request**: 设置 → 重置虚拟机 → 向导依次实测 **Fedora（systemd 族代表）** 和 **Gentoo（OpenRC 族代表）** 到 `Ready!` 标记，通过后再铺开其余 5 个。

- [ ] **Step 3: Mark all plan checkboxes complete; call task_complete.**

---

## Plan self-review (writer's checklist — run after assembling)

- [x] **Spec coverage:** §3.1 table → Tasks 2–5 (7 Dockerfiles + 4 scripts); §3.2 decisions → Task 1 (rename), fail-fast → Task 5, package-set/dhclient → Global Constraints + Tasks 2–5; §4.1 → Tasks 2–5 build.sh edits + Task 6 usage; §4.2 → Task 7 (options/matrix/upload fix/versioned table); §4.3 → Task 6; §5 → Task 8; §6 matrix rows → Tasks 7–12; §7 order → task order 1→13 exactly; §8 risks → Review Focus + Task 5 gates; §9 rollback → per-task commits + squash-at-push + re-dispatch notes (Task 10 Step 3).
- [x] **Placeholder scan:** no TBD/TODO; every code step has full content; contingency lines are concrete commands with trigger conditions (dhclient rename, sysvinit contingency, binhost candidates, fix-forward rule).
- [x] **Type/contract consistency:** asset names identical across Global Constraints / Dockerfiles / build.sh / workflow versioned table / Distro enum / DistroTest expected map / README table; overlay path `files-systemd/` used by Tasks 1–4 and NOT by Task 5 (gentoo → `files/`); `podroid-system-<distro>` artifact naming matches Task 7 workflow and Task 9/10 polling.
- [x] **Review Focus:** 5 lines each pinned to a task-owned gate (chroot preflights T4/T5; TrustAll guard grep T4 Step 5 + shipped-image grep inside script; upload no-||true T7 Step 2 + asset asserts T9/T10; gentoo timeout T5 + probes T11; enum/strings/when/FlowRow static check T8 + CI T12).
