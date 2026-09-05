# TFTP-bootable USB-stick flasher for the DS410j.
#
# THE POINT: until this existed, every image change needed a human to pull the
# USB stick and dd it (CLAUDE.md: "a bad image still needs a human"). This boots
# entirely from RAM over TFTP, streams the new image from HTTP straight onto the
# stick, verifies it, and asks the MCU to restart the board - so a reflash is a
# remote operation.
#
# WHY IT IS SAFE. The two-stage bootloader chain is in SPI flash, not on the
# stick. A failed or interrupted write cannot brick anything: our U-Boot finds no
# bootflow, drops to its prompt, and this flasher can simply be booted again.
# Nothing here writes to MTD, ever.
#
# Build:  nix-build /src/kernel/flasher.nix
# Use:    see OPERATIONS.md, "Flashing the USB stick without a human"
{ pkgs ? import <nixpkgs> { } }:

let
  cross = pkgs.pkgsCross.armv5tel-multiplatform;
  crossPrefix = "armv5tel-unknown-linux-gnueabi-";

  kernelPkg = pkgs.linuxKernel.packages.linux_6_12.kernel;
  kernelSrc = kernelPkg.src;
  kernelVersion = kernelPkg.version;

  # Static busybox: no loader, no libc to ship, and it already has wget, dd,
  # sha256sum, ifconfig and stty - the whole flasher is those six tools.
  busyboxStatic = cross.busybox.override { enableStatic = true; };

  cpioSpec = pkgs.writeText "ds410j-flasher.spec" ''
    dir /bin 0755 0 0
    dir /sbin 0755 0 0
    dir /proc 0755 0 0
    dir /sys 0755 0 0
    dir /dev 0755 0 0
    dir /tmp 01777 0 0
    nod /dev/console 0600 0 0 c 5 1
    nod /dev/null 0666 0 0 c 1 3
    nod /dev/tty 0666 0 0 c 5 0
    nod /dev/ttyS0 0600 0 0 c 4 64
    nod /dev/ttyS1 0600 0 0 c 4 65
    file /bin/busybox ${busyboxStatic}/bin/busybox 0755 0 0
    slink /bin/sh /bin/busybox 0777 0 0
    file /init ${./flash-init.sh} 0755 0 0
  '';

  initramfs = pkgs.runCommand "ds410j-flasher-initramfs.cpio"
    { nativeBuildInputs = [ pkgs.gcc ]; }
    ''
      tar xf ${kernelSrc} --wildcards --strip-components=2 'linux-*/usr/gen_init_cpio.c'
      gcc -O2 -o gen_init_cpio gen_init_cpio.c
      ./gen_init_cpio ${cpioSpec} > $out
    '';

  # Deliberately close to kernel/default.nix's bring-up flags. The flasher needs
  # exactly three things beyond booting: USB storage, ethernet, and a serial
  # console. No SATA, no filesystems - the image is written as raw blocks.
  flags = [
    "--enable ARM_APPENDED_DTB"     # so it also boots from the STOCK loader
    "--enable KUSER_HELPERS"        # ARMv5TE; harmless for a static busybox

    # the stick
    "--enable USB"
    "--enable USB_EHCI_HCD"
    "--enable USB_EHCI_HCD_ORION"
    "--enable USB_STORAGE"
    "--enable SCSI"
    "--enable BLK_DEV_SD"

    # the network
    "--enable MV643XX_ETH"
    "--enable MARVELL_PHY"
    "--enable INET"

    # console + the MCU tty, which is how the board is restarted afterwards
    "--enable SERIAL_8250"
    "--enable SERIAL_8250_CONSOLE"

    "--enable BLK_DEV_INITRD"
    "--set-str INITRAMFS_SOURCE ${initramfs}"
    "--enable DEVTMPFS"
    "--enable DEVTMPFS_MOUNT"
    "--enable BINFMT_ELF"
    "--enable BINFMT_SCRIPT"

    # nothing here needs to be large
    "--disable DEBUG_INFO"
    "--disable DEBUG_INFO_BTF"
    "--disable MODULE_SIG"
    "--disable MODULES"
    "--disable SOUND"
    "--disable DRM"
    "--disable FB"
    "--disable WLAN"
    "--enable KERNEL_XZ"

    # THE SAFETY PROPERTY, and the reason these lines are not just size trimming.
    #
    # `--disable MODULES` turns every `=m` in mvebu_v5_defconfig into `=y`, so a
    # flasher built without these came up with SATA_MV, PCI and MTD compiled in.
    # That quietly breaks the two claims this tool rests on:
    #
    #   * that /dev/sda is the USB stick. With sata_mv present the two 3 TB
    #     Toshibas enumerate too, and disk-vs-USB probe order is a timing race -
    #     so `flash.dev=/dev/sda` could land on a data drive.
    #   * that "nothing here writes to MTD, ever". True of the script, but a
    #     kernel with MTD built in leaves /dev/mtd* sitting there next to the one
    #     partition that must never be written (CLAUDE.md: never write mtd0).
    #
    # Removing the drivers makes both structural rather than a matter of care:
    # the flasher cannot reach a SATA drive or the SPI flash because it has no
    # code to do so, and the only block device that can appear is the stick.
    # flash-init.sh still validates the target is USB-attached - defence in
    # depth, so a rebuild that loses these lines is not silently dangerous.
    # `--disable ATA` is the load-bearing one: SATA_MV depends on it, so it
    # disappears from the config entirely rather than needing to be held down.
    # Verified on the built kernel - ATA/SATA_MV/MTD/MMC are all off and the
    # string "sata_mv" does not occur in the zImage.
    #
    # PCI is listed but does NOT stay off: `make olddefconfig` re-selects it
    # from the mvebu platform. That is fine and not worth fighting - PCI with no
    # ATA driver cannot reach the 88SX7042, so the bays stay invisible either
    # way. Do not "fix" this by assuming the line works.
    "--disable PCI"
    "--disable ATA"
    "--disable SATA_MV"
    "--disable MTD"
    "--disable MMC"
  ];

  dtb = "marvell/kirkwood-ds409.dtb";
in
pkgs.stdenv.mkDerivation {
  pname = "ds410j-flasher";
  version = kernelVersion;
  src = kernelSrc;

  nativeBuildInputs = [
    cross.stdenv.cc pkgs.bc pkgs.bison pkgs.flex pkgs.perl pkgs.xz
    pkgs.which pkgs.openssl pkgs.elfutils pkgs.cpio pkgs.ubootTools
  ];

  hardeningDisable = [ "all" ];
  enableParallelBuilding = true;
  postPatch = "patchShebangs scripts";

  configurePhase = ''
    runHook preConfigure
    export ARCH=arm
    export CROSS_COMPILE=${crossPrefix}
    make mvebu_v5_defconfig
    bash ./scripts/config ${builtins.concatStringsSep " " flags}
    make olddefconfig
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    export ARCH=arm
    export CROSS_COMPILE=${crossPrefix}
    make -j$NIX_BUILD_CORES zImage
    make -j$NIX_BUILD_CORES ${dtb}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp arch/arm/boot/zImage $out/zImage
    cp arch/arm/boot/dts/${dtb} $out/kirkwood-ds409.dtb
    cp .config $out/config

    # Two ways in, on purpose. This is a recovery tool, so it must not depend on
    # our own U-Boot in mtd1 being healthy:
    #   zImage      - our U-Boot 2026.07, `bootz` with a separate DTB
    #   uImage      - the STOCK Marvell 1.1.4, which has no `fdt` command, so the
    #                 DTB is appended and the whole thing wrapped as IH_TYPE_KERNEL
    cat $out/zImage $out/kirkwood-ds409.dtb > $out/zImage-dtb
    mkimage -A arm -O linux -T kernel -C none \
      -a 0x00008000 -e 0x00008000 \
      -n "DS410j flasher ${kernelVersion}" \
      -d $out/zImage-dtb $out/uImage

    {
      echo "kernel     : ${kernelVersion}"
      echo "zImage     : $(stat -c %s $out/zImage) bytes"
      echo "uImage     : $(stat -c %s $out/uImage) bytes  (appended DTB, stock loader)"
    } > $out/sizes.txt
    cat $out/sizes.txt
    runHook postInstall
  '';

  dontStrip = true;
  dontPatchELF = true;
  dontFixup = true;
}
