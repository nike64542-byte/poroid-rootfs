#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
script="$repo/init-podroid"
grep -Eq '^mkdir -p /mnt/overlay/proc /mnt/overlay/sys /mnt/overlay/dev$' "$script" || {
    printf 'init-podroid must create proc sys and dev overlay mountpoints\n' >&2
    exit 1
}
printf 'init-podroid mountpoint check passed\n'
