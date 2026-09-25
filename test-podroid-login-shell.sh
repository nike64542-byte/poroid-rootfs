#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
login="$repo/build-rootfs/files/usr/local/bin/podroid-login"
grep -Eq '^exec /bin/bash --login$' "$login" || {
    printf 'podroid-login must start a root Bash login shell directly\n' >&2
    exit 1
}
if grep -q '/bin/login' "$login"; then
    printf 'podroid-login still depends on PAM login sessions\n' >&2
    exit 1
fi
printf 'podroid login shell check passed\n'
