#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
unit="$repo/build-rootfs/files-systemd/etc/systemd/system/podroid-getty@.service"
grep -Eq '^WantedBy=multi-user\.target$' "$unit" || {
    printf 'primary getty must be enabled from multi-user.target\n' >&2
    exit 1
}
if grep -q 'getty.target' "$unit"; then
    printf 'primary getty unit still depends on masked getty.target\n' >&2
    exit 1
fi
printf 'systemd getty install check passed\n'
