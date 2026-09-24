#!/bin/sh
# Podroid system migrations — systemd edition (port of the OpenRC
# podroid-migrate start()). Runs versioned upgrade scripts once, before other
# Podroid services start.
#
# No `set -e`: mirrors OpenRC's eend 0 — a failed migration script must not
# kill the oneshot mid-flight (system-version bookkeeping still completes).
set -u

SYSVER_FILE="/etc/podroid/system-version"
APPLIED_FILE="/mnt/persist/.podroid/applied-version"
MIGRATIONS_DIR="/etc/podroid/migrations"

mkdir -p /mnt/persist/.podroid 2>/dev/null

current=$(cat "$SYSVER_FILE" 2>/dev/null || echo 0)
applied=$(cat "$APPLIED_FILE" 2>/dev/null || echo "")

# Fresh install (no marker): seed the marker, run nothing.
if [ -z "$applied" ]; then
    printf '%s\n' "$current" > "$APPLIED_FILE.tmp" && mv "$APPLIED_FILE.tmp" "$APPLIED_FILE"
    exit 0
fi

# Fast path / downgrade: nothing to do.
if [ "$current" -le "$applied" ] 2>/dev/null; then
    exit 0
fi

# Run each migrations/<v>.sh with applied < v <= current, ascending.
for base in $(ls "$MIGRATIONS_DIR" 2>/dev/null | sed -n 's/\.sh$//p' | sort -n); do
    case "$base" in *[!0-9]*) continue ;; esac
    if [ "$base" -gt "$applied" ] 2>/dev/null && [ "$base" -le "$current" ] 2>/dev/null; then
        echo "podroid-migrate: applying $base" > /dev/console
        sh "$MIGRATIONS_DIR/$base.sh" > /dev/console 2>&1 \
            || echo "podroid-migrate: $base failed (continuing)" > /dev/console
    fi
done

printf '%s\n' "$current" > "$APPLIED_FILE.tmp" && mv "$APPLIED_FILE.tmp" "$APPLIED_FILE"
exit 0