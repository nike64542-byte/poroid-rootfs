#!/bin/sh
# Podroid getty wrapper — systemd @instance port.
# %I is the tty name (hvc0, hvc3, ...). Same logic as the OpenRC-era
# podroid-getty / podroid-getty-extra wrappers.
TTY="$1"
[ -n "$TTY" ] || TTY="${INSTANCE:-hvc0}"

# Wait briefly for the node (timing varies per backend).
for _i in $(seq 1 30); do
    [ -c "/dev/$TTY" ] && break
    sleep 1
done
[ -c "/dev/$TTY" ] || exec sleep 2147483647

printf '\033[3J\033[2J\033[H' > "/dev/$TTY" 2>/dev/null
exec /sbin/getty -L -a root -l /usr/local/bin/podroid-login 115200 "$TTY" xterm-256color