# Minimal cross-compiled NixOS for the Synology DS410j (Kirkwood 88F6281, armv5tel).
#
# Boot path this targets (PORTING.md section 5, 10.12, 10.14):
#
#   stock Marvell U-Boot 1.1.4 (mtd0)
#     -> our U-Boot 2026.07 (mtd1)          bootcmd = "usb start; bootflow scan"
#       -> USB stick, extlinux              <- THIS image
#
# U-Boot's bootstd tries, on every partition of every bootdev,
#   "/extlinux/extlinux.conf" then "/boot/extlinux/extlinux.conf"
# (boot/bootstd-uclass.c: default_prefixes[] = {"/", "/boot/", NULL}; and because
# CONFIG_BOOTSTD_FULL is off in our build, the "filename-prefixes" DT override is
# never read, so those two are always what is used). So /boot living *inside* the
# ext4 root partition is fine and needs no separate boot partition - which is the
# same layout nixpkgs' own sd-image-armv7l-multiplatform.nix uses.
{ config, lib, pkgs, modulesPath, ... }:

let
  # Path-scoped autoModules. See gen-driver-modules.py for the rationale; in
  # short, nixpkgs offers only two settings and neither fits:
  #
  #   autoModules = true   (default) - answer "m" to every kconfig question it
  #                        was not given an answer for. ~11k tristate symbols
  #                        reachable, which is why a headless ARMv5 NAS compiles
  #                        DRM drivers and IIO pressure sensors.
  #   autoModules = false  - only the defconfig plus our explicit list. Minimal,
  #                        but an unforeseen USB dongle means a kernel rebuild.
  #
  # The middle ground: kconfig symbols are not path-qualified, but the Kconfig
  # FILES that declare them are. So "every driver under drivers/usb" is a
  # well-defined set, and driver-modules.nix is that set, generated from the
  # kernel source (397 tristate symbols vs ~11k for the whole tree).
  #
  # Each becomes `option module` - the "NAME? m" form generate-config.pl treats
  # as optional - so the many symbols here that belong to other SoCs (AB8500_USB,
  # AM335X_CONTROL_USB, ...) are skipped on unmet dependencies rather than
  # failing the build.
  #
  # NOW ON. The first boot attempt reported "14336K kernel code" and only 57 MB
  # of 128 MB available - autoModules had built the world in. On a 118 MB board
  # that is not a nice-to-have optimisation, it is the difference between
  # booting and an OOM panic.
  useScopedDriverModules = true;

  # Symbols we set deliberately below. The generated list is derived from
  # directory layout, so it inevitably contains some of the same names (USB
  # itself lives in drivers/usb/Kconfig); those must not fight our explicit
  # choices or nixpkgs' common-config.
  explicitKernelSymbols = [
    "USB" "USB_EHCI_HCD" "USB_EHCI_HCD_ORION" "USB_STORAGE"
    "SCSI" "BLK_DEV_SD" "EXT4_FS" "PCI" "PCI_MVEBU" "SATA_MV"
    "KUSER_HELPERS" "SCHED_CLASS_EXT" "CMA" "DMA_CMA"
    "NF_TABLES" "NF_CONNTRACK" "NFT_COMPAT"
  ];

  # mkDefault as well as the exclusion list: anything nixpkgs' common-config has
  # an opinion about should keep winning, since it encodes the requirements
  # systemd and NixOS actually depend on.
  scopedDriverModules = lib.genAttrs
    (lib.subtractLists explicitKernelSymbols (import ./driver-modules.nix))
    (_: lib.mkDefault (lib.kernel.option lib.kernel.module));
in
{
  imports = [
    "${modulesPath}/installer/sd-card/sd-image.nix"
    ./device-tree.nix   # builds and installs our own kirkwood-ds410j.dtb
    ./fan-control.nix   # fan + bay LEDs, which the DTB is a prerequisite for
    ./mcu-driver.nix    # synology-mcu: buttons -> input events, MCU debugfs
    ./mcu-panel.nix     # front-panel power/status lamps, via the board MCU
    ./readonly-root.nix # ro root + tmpfs for everything activation writes
    ./ksmbd.nix         # in-kernel SMB3 server; see PORTING.md §7.2.3 for why
                        # ksmbd rather than Samba (408 MB closure, does not fit)
  ];

  # SMB, not sftp. sshd caps transfers at 4.9 MB/s on this CPU - and that is
  # CPU-bound, not link-bound, so the board's gigabit link does not help it
  # (PORTING.md §7.2.2). Signing and encryption stay off for the same reason;
  # the data at rest is LUKS's job, not the wire's.
  services.ds410j-ksmbd = {
    enable = true;
    user = "nas";
    # The root filesystem is read-only, so a share has to live on the data
    # volume. This path is where the encrypted btrfs is expected to be mounted;
    # ksmbd will refuse the share if it does not exist.
    shares.data = {
      path = "/srv/data";
      comment = "DS410j data";
      validUsers = [ "nas" ];
    };
  };

  #### Cross compilation ######################################################
  # MUST match pkgsCross.armv5tel-multiplatform exactly - that attribute is
  # literally { config = "armv5tel-unknown-linux-gnueabi"; } (checked with
  # lib.systems.examples.armv5tel-multiplatform). Adding anything else here
  # changes store hashes and throws away the cache.nixos.org hits we get for the
  # x86_64 *cross toolchain* (PORTING.md 10.4).
  nixpkgs.buildPlatform = "x86_64-linux";
  nixpkgs.hostPlatform = { config = "armv5tel-unknown-linux-gnueabi"; };

  #### Kernel #################################################################
  # nixpkgs already defaults armv5 to multi_v5_defconfig - see
  # pkgs/os-specific/linux/kernel/generic.nix, which keys off
  # isAarch32 && parsed.cpu.version == "5". That covers Kirkwood, so we only add
  # the board must-haves on top of it and of nixpkgs' common (systemd) config.
  boot.kernelPackages = pkgs.linuxPackagesFor (pkgs.linux_6_12.override (
    {
    structuredExtraConfig = (with lib.kernel; {
      # NON-NEGOTIABLE on ARMv5TE: no LDREX/STREX, so glibc needs the kuser
      # helper page. Without it every glibc binary misbehaves in confusing ways.
      KUSER_HELPERS = yes;

      # The four SATA bays are behind a PCIe 88SX7042, NOT the SoC's native
      # ports (PORTING.md section 1). Lose PCI and you lose all four bays.
      PCI = yes;
      PCI_MVEBU = option yes;
      SATA_MV = option module;

      # sched_ext cannot link on a uniprocessor kernel, and the 88F6281 is
      # single-core so CONFIG_SMP=n is correct here. nixpkgs' common-config
      # turns sched_ext on for any platform with an eBPF JIT
      #   SCHED_CLASS_EXT = whenAtLeast "6.12" (whenPlatformHasEBPFJit yes);
      # and armv5tel qualifies. But kernel/sched/build_policy.c only compiles
      # stop_task.c under #ifdef CONFIG_SMP, while kernel/sched/ext.c refers to
      # stop_sched_class unconditionally, so vmlinux fails to link:
      #   ext.c:5286: undefined reference to `stop_sched_class'
      # Loading BPF schedulers on a single-core 118 MB NAS is pointless anyway.
      SCHED_CLASS_EXT = lib.mkForce no;

      # 16 MB was disappearing into CMA on a 128 MB board:
      #   Memory: 57344K/131072K available (... 16384K cma-reserved ...)
      # Nothing here does large contiguous DMA - no camera, no GPU, no video
      # codec - so this is pure loss.
      #
      # CMA = no does NOT work, and it is worth recording why: nixpkgs'
      # common-config sets CMA_DEBUGFS = yes and CMA_SYSFS = yes in its ARM32
      # block, both of which depend on CMA, so kconfig keeps CMA=y no matter what
      # we ask for. Verified in the built .config - CONFIG_CMA=y survived a
      # lib.mkForce no. Setting the *size* to zero is what actually works, and is
      # what nixpkgs' own comment next to CMA_SIZE_MBYTES points at.
      # Belt and braces with cma=0 on the command line below, since
      # kernel/dma/contiguous.c lets the command line override the built-in size.
      CMA_SIZE_MBYTES = lib.mkForce (freeform "0");

      # NixOS's firewall is iptables-nft. nixpkgs' common-config enables the
      # dependent options (NF_TABLES_INET, NF_TABLES_IPV4, ...) as `yes` but
      # never NF_TABLES itself - with autoModules on, that got set to `m`
      # implicitly, and turning autoModules off took the whole subsystem with it:
      #   firewall.service: iptables: Failed to initialize nft: Protocol not supported
      # These three have to be built IN, not modules: a `yes` option cannot
      # depend on an `m` one, so a modular NF_TABLES would silently drag
      # common-config's NF_TABLES_* down with it. The rest of netfilter comes in
      # as modules via the scoped list (net/netfilter, net/ipv[46]/netfilter).
      NF_TABLES = yes;
      NF_CONNTRACK = yes;
      # NFT_COMPAT can only ever be a module here: it depends on
      # NETFILTER_XTABLES, which common-config leaves as `m`, so kconfig offers
      # only N/m. Answering `y` makes it re-ask the same question and
      # generate-config.pl dies with "repeated question ... line 94" followed by
      # a wall of "Error in reading or end of file." It autoloads fine as a
      # module, which is all iptables-nft needs.
      NFT_COMPAT = module;

      # Root and /boot are on USB. Build the whole path in rather than relying on
      # initrd modules: it removes a class of "module missing from the initrd"
      # failure entirely, and matters more now that autoModules is off.
      USB = yes;
      USB_EHCI_HCD = yes;
      USB_EHCI_HCD_ORION = yes;
      USB_STORAGE = yes;
      SCSI = yes;
      BLK_DEV_SD = yes;
      EXT4_FS = yes;

      # Fan control. The DS410j fan is a 3-bit GPIO speed select on GPIO0
      # 15/16/17 and gpio-fan is the driver for exactly that shape of hardware,
      # but nixpkgs' armv5 defconfig leaves SENSORS_GPIO_FAN unset, so until now
      # there was no gpio-fan driver at all - a correct device tree on its own
      # would still have given no fan control. Built in, not a module: the
      # driver registers a devm action that sets speed 0 (= fan OFF) on removal,
      # and an rmmod that silently stops the fans on a box with no thermal
      # sensor is not a failure mode worth having.
      SENSORS_GPIO_FAN = yes;

      # The only temperature source on this board. There is no hwmon device of
      # any kind here (PORTING.md 3.3); drivetemp reads each SATA drive's own
      # sensor over SCT/SMART and presents it as hwmon, which is what
      # ds410j-fan-control.sh steers by. The alternative was smartmontools in
      # userspace - a C++ cross build in a closure with no binary cache.
      SENSORS_DRIVETEMP = yes;

      # Bay LEDs. LEDS_GPIO is already on via nixpkgs' common config, but the
      # triggers are worth having explicitly: panic is genuinely useful on a
      # headless box, and disk-activity is the zero-cost way to get activity
      # blink (global across all libata devices, so all four bays blink
      # together - per-bay activity needs userspace, see fan-control.nix).
      LEDS_TRIGGER_PANIC = yes;
      LEDS_TRIGGER_DISK = yes;
    }) // lib.optionalAttrs useScopedDriverModules scopedDriverModules;
    }
    // lib.optionalAttrs useScopedDriverModules { autoModules = false; }
  ));

  # NixOS now defaults boot.initrd.systemd.enable = true, which produced a
  # 56.7 MB (uncompressed) initrd: 17 MB of systemd, 6.5 MB of openssl, plus
  # tpm2-tss and libxml2. The board reported only 57 MB free after the kernel
  # and CMA had taken their share, so unpack_to_rootfs died with
  #   Out of memory and no killable processes...
  #   Kernel panic - not syncing: System is deadlocked on memory
  # The classic shell stage-1 does the same job here in a fraction of the space.
  boot.initrd.systemd.enable = false;

  # NixOS's default initrd module list (nixos/modules/system/boot/kernel.nix) is
  # PC hardware: ata_piix, sata_via, nvme, uhci_hcd, ehci_pci, xhci_hcd and so
  # on. None of it exists on Kirkwood, and with autoModules off it is not even
  # built, so make-initrd fails outright:
  #   root module: ata_piix
  #   modprobe: FATAL: Module ata_piix not found in directory .../6.12.104
  # The whole USB -> SCSI -> ext4 path is built into the kernel above, so stage 1
  # needs no storage modules at all to reach root.
  boot.initrd.includeDefaultModules = false;

  boot.kernelParams = [
    "console=ttyS0,115200n8"
    # See CMA_SIZE_MBYTES above. contiguous.c prefers the command line over the
    # compiled-in size, and 0 means "reserve nothing".
    "cma=0"
  ];
  boot.consoleLogLevel = 7;

  # Device tree: see ./device-tree.nix. Bring-up used mainline's
  # kirkwood-ds409.dts, which declares "synology,ds410j" and does boot this
  # board, but it describes a DS409 - swapped LED colours, a fifth bay, a
  # gpio-fan node that cannot probe, and eth1 and the native SATA controller
  # both enabled and fighting over MPP21. We now build kirkwood-ds410j.dtb.

  #### Bootloader #############################################################
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;

  #### Keeping the closure buildable and small ################################
  # There is no binary cache for armv5tel *target* packages (PORTING.md section 6),
  # so every one of these is a from-source cross build. Everything switched off
  # here is something we would otherwise be compiling for hours.

  # sd-image.nix turns this on, which drags in the entire linux-firmware tree.
  # Nothing on this board needs loadable firmware.
  hardware.enableAllHardware = lib.mkForce false;

  # Rust is THE userland blocker on this architecture: armv5te reports a 32-bit
  # max atomic width, so any crate touching AtomicU64 fails to build (CLAUDE.md).
  #
  # CLAUDE.md's documented escape hatch - system.switch.enableNg = false, keeping
  # the Perl switch-to-configuration - is GONE as of nixpkgs 26.11: the option now
  # hard-errors with "no longer has any effect", because switch-to-configuration-ng
  # (Rust) is the only implementation left.
  #
  # system.switch.enable = false is the replacement, and it is a better fit anyway.
  # Its own documentation says "good for image based appliances where updates are
  # handled outside the image", which is exactly this project: we cross-build the
  # whole image on x86_64 and the device must never evaluate nix (118 MB will OOM
  # the evaluator). The cost is that nixos-rebuild does not work on the device -
  # something it could never do here regardless.
  system.switch.enable = false;

  documentation.enable = false;
  documentation.man.enable = false;
  documentation.nixos.enable = false;
  documentation.info.enable = false;
  documentation.doc.enable = false;

  environment.defaultPackages = lib.mkForce [ ];
  programs.command-not-found.enable = false;

  # No nix ON the device. This is not a limitation we are working around, it is
  # the project's rule: 118 MB will OOM the evaluator, so all builds happen on
  # x86_64 (CLAUDE.md). Dropping it removes nix and its C++ dependency tail
  # (boost, lowdown, abseil-cpp, ...) from a from-source cross build.
  nix.enable = false;
  # sd-image.nix defines this unconditionally and it references
  # config.nix.package, which would drag nix back in on its own. Its job is to
  # populate the on-device store DB, which is meaningless with no nix present.
  systemd.services.register-nix-paths.enable = lib.mkForce false;

  # The nixos-* installer tools cannot work on a machine that cannot evaluate
  # nix. nixos-generate-config in particular references every filesystem tool
  # nixpkgs knows about - including bcachefs-tools, which is Rust and would drag
  # the AtomicU64 problem straight back in through the back door.
  system.tools.nixos-install.enable = false;
  system.tools.nixos-generate-config.enable = false;
  system.tools.nixos-enter.enable = false;
  system.tools.nixos-build-vms.enable = false;
  system.tools.nixos-option.enable = false;
  system.tools.nixos-rebuild.enable = false;

  # NOT disabled, despite looking like an easy closure saving. lvm2 is where the
  # device-mapper udev rules live, and without them anything using dm - LUKS
  # above all - hangs rather than failing (PORTING.md §7.2): libdevmapper creates
  # the mapping, then blocks in dm_udev_wait() on a cookie that only lvm2's
  # 95-dm-notify.rules ever releases. Observed on this board past a 900 s
  # timeout, with the mapping already live in the kernel and /dev/mapper holding
  # nothing but `control`. nixpkgs' own option description says it outright:
  # "The lvm2 package contains device-mapper udev rules and without those tools
  # like cryptsetup do not fully function!"
  #
  # services.lvm.enable = false;

  # Stops openssh pulling xauth, and with it libX11/libXmu/libXt/libSM.
  programs.ssh.setXAuthLocation = false;
  boot.enableContainers = false;
  security.polkit.enable = lib.mkDefault false;
  services.udisks2.enable = lib.mkDefault false;
  fonts.fontconfig.enable = lib.mkDefault false;
  xdg.autostart.enable = false;
  xdg.icons.enable = false;
  xdg.mime.enable = false;
  xdg.sounds.enable = false;

  #### Working around armv5te's missing 64-bit atomics ########################
  # CLAUDE.md frames this as a Rust problem, but it is not language-specific:
  # ARMv5TE has no LDREX/STREX, so 64-bit atomics need libatomic's lock-based
  # fallback, and build systems that probe for native atomic builtins fail.
  #
  # protobuf is the C++ instance of it. Its CMake probe fails and then the build
  # falls over on its own error handling rather than degrading gracefully:
  #     -- Performing Test protobuf_HAVE_BUILTIN_ATOMICS - Failed
  #     CMake Error at cmake/protobuf-configure-target.cmake:11:
  #       Cannot specify link libraries for target "libprotobuf"
  #       which is not built by this project.
  #
  # It reaches our closure through exactly one path:
  #   networking module -> environment.corePackages -> pkgs.host -> bind
  #     -> "--enable-dnstap" -> protobufc -> protobuf
  # bind hardcodes --enable-dnstap (pkgs/by-name/bi/bind/package.nix). dnstap is
  # DNS query logging; nothing here wants it. Dropping it removes protobuf and
  # abseil-cpp from the build entirely and keeps host/dig working.
  nixpkgs.overlays = [
    (final: prev: {
      bind = prev.bind.overrideAttrs (old: {
        configureFlags = (lib.remove "--enable-dnstap" old.configureFlags) ++ [ "--disable-dnstap" ];
        buildInputs = lib.filter
          (p: !(lib.elem (lib.getName p) [ "fstrm" "protobuf-c" ])) old.buildInputs;
        nativeBuildInputs = lib.filter
          (p: !(lib.elem (lib.getName p) [ "protobuf-c" ])) old.nativeBuildInputs;
      });
    })
  ];

  #### System #################################################################
  networking.hostName = "ds410j";
  networking.useDHCP = lib.mkDefault true;

  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = lib.mkDefault "yes";

  # v1 is "boots to a login prompt on serial". Change this before the box ever
  # sees a hostile network.
  users.users.root.initialPassword = "ds410j";

  # BENCH KEY - not yours. This is the key the assistant used to drive the box
  # over ssh while bringing up the fan and LEDs; it is here so that a reflash
  # stops wiping it, since /root is about to become a tmpfs and nothing written
  # there by hand will survive a boot at all.
  #
  # The lib.warn fires on every evaluation so this cannot be forgotten quietly.
  users.users.root.openssh.authorizedKeys.keys = [
    (lib.warn
      "ds410j: the bench ssh key in configuration.nix is still enabled - replace it with your own"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEQtO6ReMMo6RZX5tpLvZnSfy3FmBXn0+Y1xTPb4TIGq claude@bench")
  ];

  # 118 MB of RAM (CLAUDE.md). zram buys real headroom for a box this small.
  zramSwap.enable = true;
  zramSwap.memoryPercent = 50;

  system.stateVersion = "26.11";

  #### Image ##################################################################
  image.fileName = "ds410j-nixos.img";   # sdImage.imageName was renamed to this

  sdImage = {
    # dd-able as-is; no zstd step for the user to undo.
    compressImage = false;

    # No growing the root partition on first boot. This is an appliance image:
    # the closure is fixed at build time, `system.switch.enable = false` means it
    # is never rebuilt in place, and leaving the partition at its built size
    # keeps the on-disk layout identical to what was tested. It also leaves the
    # rest of the stick unallocated, which is where a writable /var partition
    # would go if we want persistent logs alongside a read-only root (§7.3).
    expandOnBoot = false;

    # Nothing goes in the firmware partition: our bootloader lives in SPI flash,
    # not on the stick. sd-image always creates the partition, so leave it at the
    # default size (mkfs.vfat -F 32 needs room) and just leave it empty.
    populateFirmwareCommands = "";
    populateRootCommands = ''
      mkdir -p ./files/boot
      ${config.boot.loader.generic-extlinux-compatible.populateCmd} \
        -c ${config.system.build.toplevel} -d ./files/boot

      # Mount points must EXIST in the image, because the root filesystem is
      # mounted read-only (./readonly-root.nix) and stage 1 cannot mkdir them.
      #
      # This is not theoretical - it is the bug that stranded the first
      # read-only boot:
      #   mounting tmpfs on /bin...
      #   mkdir: can't create directory '/mnt-root/bin': Read-only file system
      #   mount: /mnt-root/bin: mount point does not exist.
      # On a writable root, activation creates these at first boot and nobody
      # notices they were missing from the image.
      #
      # Every tmpfs mount point in readonly-root.nix needs an entry here. If you
      # add a mount there, add the directory here too.
      mkdir -p ./files/{etc,var,home,srv,bin,usr,lib}
      mkdir -p ./files/{proc,sys,dev,run,mnt}
      mkdir -p ./files/boot/firmware
      mkdir -p -m 0700 ./files/root
      mkdir -p -m 1777 ./files/tmp
    '';
  };
}
