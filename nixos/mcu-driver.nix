# The board microcontroller as a kernel driver, replacing the userspace tty.
#
# synology-mcu binds UART1 as a serdev client, which means /dev/ttyS1 STOPS
# EXISTING: a serdev client owns the port exclusively and no tty is registered
# for it. That is deliberate - it is what lets the buttons become real input
# events - but it is also the one thing that can break other parts of this
# system, so:
#
#   - nixos/ds410j-mcu.sh now writes to the driver's debugfs "send" file and
#     only falls back to /dev/ttyS1. mcu-panel.nix and the fan daemon call that
#     helper, so both keep working unchanged.
#   - Power-off is NOT affected. It never went through the tty: mainline's
#     qnap-poweroff (CONFIG_POWER_RESET_QNAP=y) binds the separate
#     "synology,power-off" node from kirkwood-synology.dtsi, ioremaps the UART
#     registers itself and polls out '1'. Both drivers touching 0x12100 is
#     exactly what happens today with the 8250, so nothing changes there.
#
# The DT side is in kirkwood-ds410j.dts: a child node of &uart1 carrying
# compatible = "synology,ds410j-mcu", which is what serdev binds against.
{ config, lib, pkgs, ... }:

let
  kernel = config.boot.kernelPackages.kernel;

  synology-mcu = pkgs.stdenv.mkDerivation {
    pname = "synology-mcu";
    version = kernel.version;
    src = ./synology-mcu;

    nativeBuildInputs = kernel.moduleBuildDependencies;

    # Kernel modules are built with the kernel's own flags; nixpkgs' userspace
    # hardening defaults do not apply and break the build if left on.
    hardeningDisable = [ "pic" "format" ];

    # Set the cross flags explicitly rather than inheriting kernel.makeFlags:
    # that list is for building the kernel itself and carries O=$(buildRoot) and
    # --eval=undefine, which an out-of-tree module build has no buildRoot for -
    # make fails with "empty variable name".
    makeFlags = [
      "ARCH=${pkgs.stdenv.hostPlatform.linuxArch}"
      "CROSS_COMPILE=${pkgs.stdenv.cc.targetPrefix}"
      "KERNEL_DIR=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
    ];
    buildFlags = [ "all" ];
    installFlags = [ "INSTALL_MOD_PATH=${placeholder "out"}" ];
    installTargets = [ "modules_install" ];

    meta = {
      description = "Synology DS410j front-panel microcontroller (UART1 serdev)";
      license = lib.licenses.gpl2Only;
    };
  };
in
{
  boot.extraModulePackages = [ synology-mcu ];

  # The module matches by device tree compatible, so udev would load it from the
  # modalias on its own. Naming it here as well means a missing or mismatched
  # DTB shows up as a module that loaded and found no device, which is a much
  # clearer failure than silence.
  boot.kernelModules = [ "synology-mcu" ];
}
