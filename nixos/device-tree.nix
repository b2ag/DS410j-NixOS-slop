# Build and install our own kirkwood-ds410j.dtb instead of using mainline's
# kirkwood-ds409.dtb.
#
# kirkwood-ds409.dts boots this board and was the right call for bring-up, but it
# describes a DS409: the bay LED colours are swapped, it declares a fifth bay,
# the gpio-fan node cannot probe, and it enables both eth1 and the SoC's native
# SATA controller - neither of which exists here, and which collide over MPP21.
# kirkwood-ds410j.dts carries the reasoning for each difference.
#
# The DTS is compiled standalone rather than added to the kernel tree, because
# the kernel is a from-source cross build with no binary cache (PORTING.md 3.4):
# in-tree would mean a full kernel rebuild per DTS edit, this way it is seconds.
{ config, lib, pkgs, ... }:

let
  kernel = config.boot.kernelPackages.kernel;

  # cpp needs the marvell board .dtsi files plus the dt-bindings headers. The
  # kernel's -dev output keeps scripts/dtc/include-prefixes but NOT
  # arch/arm/boot/dts/marvell (nixpkgs trims the source to the vendor dirs that
  # ship headers), so take them from the kernel tarball we are already building.
  # Using kernel.src rather than a pinned tarball means the .dtsi files can never
  # drift from the kernel that will consume the .dtb.
  dtsIncludes = pkgs.runCommandLocal "kirkwood-dts-includes" { } ''
    mkdir -p $out
    tar -xf ${kernel.src} -C $out --strip-components=1 --wildcards \
      'linux-*/arch/arm/boot/dts/marvell' \
      'linux-*/include/dt-bindings' \
      'linux-*/include/uapi/linux' \
      'linux-*/scripts/dtc/include-prefixes'
  '';

  ds410jDtbs = pkgs.stdenv.mkDerivation {
    name = "kirkwood-ds410j-dtbs";
    nativeBuildInputs = [ pkgs.buildPackages.dtc ];
    # $CC is only ever used as a preprocessor here, so the cross compiler is fine.
    buildCommand = ''
      mkdir -p $out
      $CC -E -nostdinc \
        -I ${dtsIncludes}/arch/arm/boot/dts/marvell \
        -I ${dtsIncludes}/include \
        -I ${dtsIncludes}/scripts/dtc/include-prefixes \
        -undef -D__DTS__ -x assembler-with-cpp ${./kirkwood-ds410j.dts} \
        | dtc -I dts -O dtb -@ -o $out/kirkwood-ds410j.dtb
      echo "built $(stat -c %s $out/kirkwood-ds410j.dtb) byte kirkwood-ds410j.dtb"
    '';
  };
in
{
  hardware.deviceTree.enable = true;

  # dtbSource replaces the kernel's whole dtbs directory, so /boot carries one
  # 28 KB .dtb instead of mainline's 225 (about 8 MB). That is a real saving on a
  # 30 MB boot partition, and it removes any chance of the bootloader picking a
  # different board's tree.
  hardware.deviceTree.dtbSource = ds410jDtbs;
  hardware.deviceTree.name = "kirkwood-ds410j.dtb";
}
