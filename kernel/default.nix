# Minimal mainline kernel for the Synology DS410j (Kirkwood 88F6281, armv5tel).
#
# Produces a TFTP-bootable image for PORTING.md M3: a 6.12 LTS kernel with an
# embedded static-busybox initramfs and kirkwood-ds409.dtb appended, wrapped as
# a legacy uImage for the stock Marvell U-Boot 1.1.4 on this board.
#
# Build:  nix-build /src/kernel -A uboot-image
{ pkgs ? import <nixpkgs> { } }:

let
  # PORTING.md §6 says pkgsCross.sheevaplug; that attribute no longer exists in
  # nixpkgs. armv5tel-multiplatform is the current name for the same triple,
  # armv5tel-unknown-linux-gnueabi.
  cross = pkgs.pkgsCross.armv5tel-multiplatform;
  crossPrefix = "armv5tel-unknown-linux-gnueabi-";

  kernelPkg = pkgs.linuxKernel.packages.linux_6_12.kernel;
  kernelSrc = kernelPkg.src;
  kernelVersion = kernelPkg.version;

  busyboxStatic = cross.busybox.override { enableStatic = true; };

  # gen_init_cpio spec. Built this way rather than from a directory tree because
  # the initramfs needs real device nodes: without /dev/console the kernel cannot
  # attach stdio to init and the serial console stays silent.
  cpioSpec = pkgs.writeText "ds410j-initramfs.spec" ''
    dir /bin 0755 0 0
    dir /sbin 0755 0 0
    dir /proc 0755 0 0
    dir /sys 0755 0 0
    dir /dev 0755 0 0
    dir /tmp 01777 0 0
    dir /root 0700 0 0
    nod /dev/console 0600 0 0 c 5 1
    nod /dev/null 0666 0 0 c 1 3
    nod /dev/tty 0666 0 0 c 5 0
    nod /dev/ttyS0 0600 0 0 c 4 64
    file /bin/busybox ${busyboxStatic}/bin/busybox 0755 0 0
    slink /bin/sh /bin/busybox 0777 0 0
    file /init ${./init.sh} 0755 0 0
  '';

  initramfs = pkgs.runCommand "ds410j-initramfs.cpio"
    { nativeBuildInputs = [ pkgs.gcc ]; }
    ''
      tar xf ${kernelSrc} --wildcards --strip-components=2 'linux-*/usr/gen_init_cpio.c'
      gcc -O2 -o gen_init_cpio gen_init_cpio.c
      ./gen_init_cpio ${cpioSpec} > $out
    '';

  # Applied over mvebu_v5_defconfig via scripts/config, then olddefconfig.
  # Shared by both variants below.
  baseFlags = [
    # boot path: this U-Boot has no `fdt` command, so the DTB must be appended
    "--enable ARM_APPENDED_DTB"

    # ARMv5TE: no LDREX/STREX, userspace atomics go via kuser_helpers.
    # Non-negotiable - without it every glibc binary misbehaves.
    "--enable KUSER_HELPERS"

    # The 88SX7042 is behind PCIe, so all four bays depend on these.
    "--enable PCI"
    "--enable PCI_MVEBU"
    "--enable ATA"
    "--enable SATA_MV"

    # rootfs + console plumbing
    "--enable EXT4_FS"
    "--enable TMPFS"
    "--enable DEVTMPFS"
    "--enable DEVTMPFS_MOUNT"
    "--enable BINFMT_ELF"
    "--enable BINFMT_SCRIPT"

    # network
    "--enable MV643XX_ETH"
    "--enable MARVELL_PHY"

    # board integration
    "--enable POWER_RESET_QNAP"
    "--enable SENSORS_GPIO_FAN"
    "--enable LEDS_GPIO"
    "--enable I2C_MV64XXX"
    "--enable RTC_DRV_RS5C372"
    "--enable RTC_DRV_S35390A"
    "--enable SPI_ORION"
    "--enable MTD"
    "--enable MTD_SPI_NOR"
    "--enable MTD_BLOCK"
    "--enable USB"
    "--enable USB_EHCI_HCD"
    "--enable USB_EHCI_HCD_ORION"
    "--enable USB_STORAGE"
    "--enable CRYPTO_DEV_MARVELL_CESA"
    "--enable MV_XOR"

    # keep the build fast and the image small
    "--disable DEBUG_INFO"
    "--disable DEBUG_INFO_BTF"
    "--disable MODULE_SIG"
  ];

  # Bring-up image: embedded busybox initramfs, gzip, boots to a serial shell.
  bringupFlags = baseFlags ++ [
    "--enable BLK_DEV_INITRD"
    "--set-str INITRAMFS_SOURCE ${initramfs}"
  ];

  # Flash-candidate image: no initramfs, XZ, everything not needed to reach an
  # ext4 root on the PCIe SATA controller removed. This is the image whose size
  # matters against the 2 MB / 3.25 MB flash budget in PORTING.md section 3.1.
  minimalFlags = baseFlags ++ [
    "--disable BLK_DEV_INITRD"
    "--enable KERNEL_XZ"

    # only Kirkwood, not the other ARMv5 mvebu platforms
    "--disable ARCH_ORION5X"
    "--disable ARCH_MV78XX0"
    "--disable ARCH_DOVE"

    # no modules: everything needed is built in
    "--disable MODULES"

    # large subsystems this board does not need to reach root
    "--disable SOUND"
    "--disable SND"
    "--disable WLAN"
    "--disable CFG80211"
    "--disable LIB80211"
    "--disable MAC80211"
    "--disable LIBERTAS"
    "--disable LIBERTAS_SDIO"
    "--disable MMC"
    "--disable DRM"
    "--disable FB"
    "--disable IPV6"
    "--disable NETFILTER"
    "--disable NFS_FS"
    "--disable NFSD"
    "--disable SUNRPC"
    "--disable ROOT_NFS"
    "--disable JFFS2_FS"
    "--disable UBIFS_FS"
    "--disable BTRFS_FS"
    "--disable XFS_FS"
    "--disable F2FS_FS"
    "--disable NILFS2_FS"
    "--disable HID"
    "--disable USB_HID"
    "--disable HID_SUPPORT"
    "--disable INPUT"
    "--disable PTP_1588_CLOCK"
    "--disable WATCHDOG"
    "--disable IOSCHED_BFQ"
    "--disable MQ_IOSCHED_KYBER"

    # USB is not on the fallback boot path (root is ext4 on SATA)
    "--disable USB_SUPPORT"
    "--disable USB"
    "--disable USB_STORAGE"
    "--disable USB_EHCI_HCD"
    "--disable USB_EHCI_HCD_ORION"
  ];

  mkKernel = { variant, flags }: pkgs.stdenv.mkDerivation {
    pname = "linux-ds410j-${variant}";
    version = kernelVersion;
    src = kernelSrc;

    nativeBuildInputs = [
      cross.stdenv.cc
      pkgs.bc
      pkgs.bison
      pkgs.flex
      pkgs.perl
      pkgs.xz
      pkgs.which
      pkgs.openssl
      pkgs.elfutils
      pkgs.cpio
      pkgs.ubootTools
    ];

    # nixpkgs hardening flags are not applicable to kernel builds.
    hardeningDisable = [ "all" ];
    enableParallelBuilding = true;

    # kernel helper scripts use #!/usr/bin/env, which does not exist in the sandbox
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
      make -j$NIX_BUILD_CORES marvell/kirkwood-ds409.dtb
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp arch/arm/boot/zImage                            $out/zImage
      cp arch/arm/boot/dts/marvell/kirkwood-ds409.dtb    $out/kirkwood-ds409.dtb
      cp .config                                         $out/config

      # appended DTB: the decompressor looks for the blob directly after zImage
      cat $out/zImage $out/kirkwood-ds409.dtb > $out/zImage-dtb

      # Kirkwood loads the kernel at 0x00008000. -C none because zImage
      # self-decompresses; U-Boot must not touch the payload.
      mkimage -A arm -O linux -T kernel -C none \
        -a 0x00008000 -e 0x00008000 \
        -n "DS410j linux ${kernelVersion}" \
        -d $out/zImage-dtb $out/uImage

      {
        echo "kernel   : ${kernelVersion}"
        echo "dtb      : kirkwood-ds409.dtb (compatible: synology,ds410j)"
        echo "zImage   : $(stat -c %s $out/zImage) bytes"
        echo "dtb      : $(stat -c %s $out/kirkwood-ds409.dtb) bytes"
        echo "zImage-dtb: $(stat -c %s $out/zImage-dtb) bytes"
        echo "uImage   : $(stat -c %s $out/uImage) bytes"
      } > $out/sizes.txt
      cat $out/sizes.txt
      runHook postInstall
    '';

    dontStrip = true;
    dontPatchELF = true;
    dontFixup = true;
  };

in rec {
  inherit initramfs busyboxStatic mkKernel;

  # boots to a serial shell over TFTP (M3 bring-up)
  kernel = mkKernel { variant = "bringup"; flags = bringupFlags; };

  # size candidate for the NOR flash slot (PORTING.md section 3.1)
  kernelMin = mkKernel { variant = "minimal"; flags = minimalFlags; };

  uboot-image = kernel;
}
