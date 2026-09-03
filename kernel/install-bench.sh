#!/usr/bin/env bash
# Install the device-side bench tools (ds410j-bench.sh + libgpiod) on the DS410j.
#
# libgpiod is needed because the fan pins have to be driven directly: the NixOS
# kernel currently ships with CONFIG_SENSORS_GPIO_FAN unset, so there is no
# gpio-fan hwmon device to write to (PORTING.md 7.1). It cross-builds in about a
# minute and is not part of the system closure - it lives in /root/gpiod.
set -euo pipefail

DS=${DS:-192.168.50.138}
KEY=${KEY:-$HOME/.ssh/ds410j}
SSH=(ssh -i "$KEY" -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

echo "==> cross-building libgpiod for armv5tel"
LG=$(TMPDIR=${TMPDIR:-/tmp/nixbuild} nix-build '<nixpkgs>' \
       -A pkgsCross.armv5tel-multiplatform.libgpiod --no-out-link)

echo "==> staging"
stage=$(mktemp -d)
mkdir -p "$stage/gpiod"
for b in gpioset gpioget gpioinfo gpiodetect gpiomon; do
  cp -L "$LG/bin/$b" "$stage/gpiod/"
done
cp -L "$LG/lib/libgpiod.so.3" "$stage/gpiod/"
chmod +x "$stage/gpiod"/*

echo "==> copying to $DS"
tar cf - -C "$stage" gpiod | "${SSH[@]}" "root@$DS" 'tar xf - -C /root && chmod +x /root/gpiod/*'
scp -q -i "$KEY" -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR "$(dirname "$0")/ds410j-bench.sh" "root@$DS:/root/ds410j-bench.sh"
"${SSH[@]}" "root@$DS" 'chmod +x /root/ds410j-bench.sh && /root/ds410j-bench.sh fan get'
rm -rf "$stage"

echo "==> done. On the box: /root/ds410j-bench.sh"
