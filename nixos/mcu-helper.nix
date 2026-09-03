# The MCU helper as a single executable path.
#
# Shared by mcu-panel.nix and fan-control.nix. It exists as its own derivation
# rather than being invoked as "${runtimeShell} ${./ds410j-mcu.sh}" because that
# form contains a space, and systemd's Environment= splits unquoted values on
# whitespace - so passing it to the fan daemon would have silently become two
# broken assignments rather than one working one.
{ pkgs }:

pkgs.runCommand "ds410j-mcu" { } ''
  mkdir -p $out/bin
  substitute ${./ds410j-mcu.sh} $out/bin/ds410j-mcu \
    --replace-fail '#!/bin/sh' '#!${pkgs.runtimeShell}'
  chmod +x $out/bin/ds410j-mcu
''
