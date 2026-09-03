# Front-panel power and status lamps, via the board microcontroller.
#
# These two lamps are not GPIOs and cannot be gpio-leds - the MCU on UART1 owns
# them (PORTING.md 7.1). Without this the box runs with its power LED blinking
# forever, because blinking is the MCU's power-on default and nothing ever tells
# it the OS came up. DSM sends '4' when boot completes and '5' during shutdown;
# this reproduces that, which is why the front panel now reads the way a DS410j
# owner expects.
#
# Codes come from nixos/ds410j-mcu.sh, which accepts only the known-safe ones -
# in particular it cannot send '1' (power off).
{ config, lib, pkgs, ... }:

let
  mcu = "${import ./mcu-helper.nix { inherit pkgs; }}/bin/ds410j-mcu";
in
{
  systemd.services.ds410j-panel = {
    description = "DS410j front-panel power and status LEDs";

    # Ordered after multi-user.target so "steady" genuinely means "the system
    # finished booting" rather than "systemd got round to this unit".
    wantedBy = [ "multi-user.target" ];
    after = [ "multi-user.target" ];

    # stty and printf.
    path = [ pkgs.coreutils ];

    serviceConfig = {
      Type = "oneshot";
      # Held "active" so that stopping it - which is what shutdown does - runs
      # ExecStop and puts the lamp back to blinking.
      RemainAfterExit = true;
      ExecStart = [
        "${mcu} 4"   # power LED steady: boot complete
        "${mcu} 8"   # status LED green: nothing wrong
      ];
      ExecStop = [
        "${mcu} 5"   # power LED blinking: going down
      ];
    };
  };
}
