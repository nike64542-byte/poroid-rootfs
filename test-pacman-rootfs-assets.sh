#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
script="$repo/build-rootfs/build-rootfs-pacman.sh"
python3 - "$script" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
for binary in ("podroid-vsock-agent", "podroid-hostd", "podroid-overlay-normalize"):
    assert binary in text
assert 'cp "/usr/local/bin/$f" "$R/usr/local/bin/$f"' in text
print("pacman rootfs asset copy check passed")
PY
