# Fan and bay-LED control for the DS410j.
#
# The board has no temperature sensor of its own (PORTING.md 3.3), so the fan
# cannot be driven from the kernel's thermal framework - there is nothing for a
# thermal zone to read. CONFIG_SENSORS_DRIVETEMP turns each SATA drive's own
# sensor into an ordinary hwmon device, which is enough to steer by and costs
# nothing in the closure, and this daemon closes the loop in userspace.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.ds410jFan;
  speeds = [ 2200 2500 3000 3300 3700 3800 4200 ];
in
{
  options.services.ds410jFan = {
    baselineRpm = lib.mkOption {
      type = lib.types.enum speeds;
      default = 2200;
      description = ''
        Speed the fan holds whenever no drive is hot. This is a floor, not a
        target: the fan never runs slower than this.

        Deliberately the quietest available speed rather than the 3300 rpm
        U-Boot pins at boot - that figure is an arbitrary safe-speed pick from
        bring-up (`uboot/default.nix`, `DS410J_FAN_SPEED`), not a hardware
        default, so anchoring to it would only inherit a guess. Raise it if you
        would rather trade noise for headroom.

        Only the speeds in the gpio-fan speed map are selectable; 0 is excluded
        because it means fan OFF.
      '';
    };

    boardEscalateAboveC = lib.mkOption {
      type = lib.types.int;
      default = 55;
      description = ''
        Board sensor temperature at which the fan starts ramping above baseline.

        Separate from drives on purpose: the LM75 at I2C 0x48 idles around 46 C,
        only a few degrees under the drive threshold, so a shared number would
        leave the fan escalated permanently. Each input is measured in degrees
        above its own threshold and the more urgent one wins.
      '';
    };

    boardWarnC = lib.mkOption {
      type = lib.types.int;
      default = 70;
      description = ''
        Board temperature at which the front-panel status lamp goes orange. The
        LM75's own limit registers read 80/75 C, which is the chip's ceiling
        rather than the board's, but it anchors this.
      '';
    };

    driveEscalateAboveC = lib.mkOption {
      type = lib.types.int;
      default = 50;
      description = ''
        Temperature of the hottest drive at which the fan starts ramping above
        the baseline. 3.5" drives are generally rated to 55-60 C, so this leaves
        real headroom while keeping the fan quiet for ordinary use.
      '';
    };

    stepEveryC = lib.mkOption {
      type = lib.types.int;
      default = 3;
      description = "One speed step up per this many degrees above escalateAboveC.";
    };

    hysteresisC = lib.mkOption {
      type = lib.types.int;
      default = 3;
      description = ''
        Once escalated, return to the baseline only when the hottest drive has
        dropped this far below escalateAboveC. Stops the fan hunting at the
        threshold.
      '';
    };

    driveWarnC = lib.mkOption {
      type = lib.types.int;
      default = 55;
      description = ''
        At or above this, the bay's LED goes amber and the front-panel status
        lamp goes orange. Distinct from escalateAboveC: escalation is the fan
        reacting, this is the box telling you about it.
      '';
    };

    pollSeconds = lib.mkOption {
      type = lib.types.int;
      default = 30;
      description = ''
        Seconds between polls. Note drivetemp has no standby check, so each poll
        wakes a parked drive - relevant only if drive spindown is ever enabled.
      '';
    };
  };

  config = {
    systemd.services.ds410j-fan-control = {
      description = "DS410j fan and bay-LED control";
      wantedBy = [ "multi-user.target" ];
      # Let the SATA drives enumerate first, otherwise the first poll sees an
      # empty chassis and idles the fan for one interval.
      after = [ "local-fs.target" ];

      # readlink and sleep; everything else the script uses is a shell builtin.
      path = [ pkgs.coreutils ];

      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.runtimeShell} ${./ds410j-fan-control.sh}";

        Environment = [
          "BASELINE_RPM=${toString cfg.baselineRpm}"
          "BOARD_ESCALATE_C=${toString cfg.boardEscalateAboveC}"
          "BOARD_WARN_C=${toString cfg.boardWarnC}"
          "DRIVE_ESCALATE_C=${toString cfg.driveEscalateAboveC}"
          "STEP_C=${toString cfg.stepEveryC}"
          "HYST_C=${toString cfg.hysteresisC}"
          "DRIVE_WARN_C=${toString cfg.driveWarnC}"
          "POLL=${toString cfg.pollSeconds}"
          # Lets the daemon drive the front-panel status lamp on the same fault
          # condition as the amber bay LEDs. The helper accepts only known-safe
          # codes, so this cannot power the box off.
          "MCU=${import ./mcu-helper.nix { inherit pkgs; }}/bin/ds410j-mcu"
        ];

        # Deliberately no ExecStop that parks the fan: stopping this unit must
        # leave the fan spinning at whatever it last selected. The only safe
        # failure mode on a box with no thermal sensor is "keep cooling".
        Restart = "on-failure";
        RestartSec = "30s";
      };

      # If the fan really is uncontrollable - CONFIG_SENSORS_GPIO_FAN missing, or
      # the DT node failing to probe - give up after five tries and show up in
      # `systemctl --failed` rather than retrying forever in the background.
      startLimitIntervalSec = 300;
      startLimitBurst = 5;
    };
  };
}
