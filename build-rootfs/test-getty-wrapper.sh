#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
for relative in \
    build-rootfs/files/usr/local/bin/podroid-getty \
    build-rootfs/files/usr/local/bin/podroid-getty-extra \
    build-rootfs/files-systemd/usr/local/libexec/podroid/podroid-getty.sh; do
    file="$repo/$relative"
    [ -f "$file" ] || { printf 'missing %s\n' "$relative" >&2; exit 1; }
    grep -Eq '^[[:space:]]*exec[[:space:]]+[^[:space:]]*agetty([[:space:]]|$)' "$file" || {
        printf '%s does not exec agetty\n' "$relative" >&2
        exit 1
    }
    if grep -Eq '^[[:space:]]*exec[[:space:]]+/sbin/getty([[:space:]]|$)' "$file"; then
        printf '%s still execs missing /sbin/getty\n' "$relative" >&2
        exit 1
    fi
done
printf 'getty wrapper check passed\n'
