#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
script="$repo/build-rootfs/build-rootfs-gentoo.sh"
grep -Eq '^if ! timeout 1800 emerge --oneshot =app-containers/podman-5\.8\.2; then$' "$script" || {
    printf 'Gentoo podman binpkg probe timeout must be 1800 seconds\n' >&2
    exit 1
}
printf 'Gentoo probe timeout check passed\n'
