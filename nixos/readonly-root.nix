# Read-only root: nothing on the USB stick is written after it is flashed.
#
# WHY, on this box specifically: this machine is restarted abruptly more than
# most. Warm reboot now works (PORTING.md 3.3 - the MCU takes a 'C'), so a clean
# `systemctl reboot` is finally available, but the box still has no watchdog
# reset path of its own and a stranded box is still recovered by cutting mains.
# A read-only root removes the corruption failure mode rather than mitigating
# it, which is worth keeping even now that the common case is clean.
#
# The clean mechanism, `system.etc.overlay`, is unavailable: it asserts
# `boot.initrd.systemd.enable`, and the systemd initrd came to 56.7 MB and OOM'd
# on 128 MB of RAM (see configuration.nix). So this is built the older way, out
# of tmpfs mounts over the paths NixOS activation writes to.
#
# WHAT ACTUALLY GETS WRITTEN, measured on the running box rather than guessed -
# activation rewrites all of these on every boot:
#
#     /etc   160 K   regenerated wholesale by setup-etc.pl
#     /var   7.8 M   of which 7.4 M is the journal; see journald below
#     /bin           /bin/sh
#     /usr           /usr/bin/env
#     /lib           /lib/ld-linux*.so.3
#     /home /root /srv /tmp   directories and a handful of files, 44 K all told
#
# With the journal moved to /run (already tmpfs), the whole writable set is under
# 1 MB. The "118 MB will not allow a stateless root" worry does not survive
# contact with the numbers - tmpfs costs only what is stored in it, and these
# sizes are caps, not allocations.
#
# ORDERING, which is the part that would otherwise silently break: activation
# runs in stage 2, *before* systemd mounts most filesystems. A tmpfs mounted on
# /etc after activation would hide the /etc that activation had just populated,
# and the box would come up with an empty /etc. NixOS already lists /etc, /var,
# /var/log, /var/lib, /usr in utils.nix `pathsNeededForBoot`, so those are
# mounted in stage 1 and are safe. The rest are NOT in that list, so they carry
# `neededForBoot = true` explicitly. Removing it would produce exactly the silent
# breakage described above.
{ config, lib, pkgs, ... }:

let
  # Sizes are upper bounds, not reservations: an empty tmpfs occupies nothing.
  # They exist to stop a runaway from eating the RAM sshd and the fan daemon
  # need, not to budget for expected use.
  volatile = size: {
    device = "tmpfs";
    fsType = "tmpfs";
    options = [ "size=${size}" "mode=0755" "nosuid" "nodev" ];
    neededForBoot = true;
  };
in
{
  # The root filesystem itself. sd-image declares it without options; this adds
  # ro to that declaration rather than replacing it.
  fileSystems."/".options = [ "ro" ];

  fileSystems = {
    "/etc"  = volatile "8M";     # 160 K in practice
    "/var"  = volatile "32M";    # journal goes to /run, so this stays tiny
    "/home" = volatile "8M";
    "/root" = volatile "8M";
    "/srv"  = volatile "1M";
    # These three exist only for FHS compatibility symlinks that activation
    # recreates every boot: /bin/sh, /usr/bin/env, /lib/ld-linux*.so.3.
    "/bin"  = volatile "1M";
    "/usr"  = volatile "1M";
    "/lib"  = volatile "1M";
  };

  boot.tmp.useTmpfs = true;
  boot.tmp.tmpfsSize = "32M";

  # The journal is the only thing here with any real appetite. Volatile puts it
  # in /run, which is already tmpfs, so /var stays under a megabyte.
  #
  # 1M is deliberately tiny - on the order of a few thousand lines - so
  # `journalctl` on the box is a recent-history window, not a record. That is an
  # acceptable trade because ForwardToConsole below sends everything to ttyS0 as
  # it happens and the bench captures that to kernel/logs/serial.log. The serial
  # console is the real log; this is just enough to run journalctl against after
  # something goes wrong.
  #
  # RuntimeMaxFileSize has to stay below RuntimeMaxUse or systemd clamps it and
  # complains. 128K is systemd's own 1/8-of-the-cap rule, made explicit.
  services.journald.storage = "volatile";
  services.journald.extraConfig = ''
    RuntimeMaxUse=1M
    RuntimeMaxFileSize=128K
  '';

  # Logs do not survive a reboot now, so make sure they reach the serial console
  # while the box is up - that is what the bench captures to kernel/logs/.
  services.journald.console = "/dev/ttyS0";


  #### Consequences of statelessness ##########################################
  #
  # SSH HOST KEYS REGENERATE ON EVERY BOOT. They live in /etc/ssh/ssh_host_*
  # as real files, not store symlinks, so a tmpfs /etc means a new host identity
  # each time and "REMOTE HOST IDENTIFICATION HAS CHANGED" for any client that
  # checks. This is the one genuinely annoying consequence of a fully stateless
  # root, and it is not fixed here because every fix has a cost:
  #
  #   - baking host keys into the image puts private keys in the Nix store,
  #     which is world-readable. Not acceptable even on a home LAN.
  #   - a small writable partition (say /persist) with /etc/ssh and /var/lib
  #     bind-mounted onto it is the standard answer, and the space is now free
  #     because expandOnBoot is off. That is the recommended fix if the churn
  #     becomes irritating - see PORTING.md 7.3.
  #
  # Until then, clients need StrictHostKeyChecking=no, which is what
  # kernel/install-bench.sh already uses.
  #
  # /var/lib/nixos is also tmpfs now, so the uid/gid map is rebuilt each boot.
  # That is deterministic for declaratively-defined users, which is all we have.

  # With /etc on tmpfs, systemd would generate a fresh machine-id on every boot.
  # Pin it: the DHCP client derives its DUID from the machine-id, so a changing
  # one can mean a changing lease, and a NAS that moves address every reboot is
  # its own kind of annoying. Must be exactly 32 lowercase hex digits - systemd
  # rejects anything else, and it is a read-only symlink into the store here,
  # which systemd handles by bind-mounting a writable copy from /run.
  environment.etc."machine-id".text = "d5410d5410d5410d5410d5410d541000\n";
}
