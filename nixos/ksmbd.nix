# ksmbd - the in-kernel SMB3 server (PORTING.md §7.2.3).
#
# WHY NOT SAMBA. Both cross-build for armv5tel, but the closures decide it:
# Samba 4.23.10 is 97 paths / 408 MB and drags a whole python3 for armv5tel into
# the image, while ksmbd-tools is 10 paths / 63 MB with no Rust and no Python -
# and most of that 63 MB is glibc the image already has. The root partition is
# 581 MB and currently 100% full, so Samba does not merely cost something, it
# does not fit.
#
# ksmbd-tools is NOT a Samba front-end: it has its own config parser, its own
# user database (ksmbdpwd.db, not smbpasswd) and talks to the kernel server over
# generic netlink - hence libnl in its closure and nothing of talloc/tdb/tevent.
#
# WHY THIS IS A HAND-ROLLED MODULE. nixpkgs ships samba.nix and samba-wsdd.nix
# but has no ksmbd module at all - nothing under nixos/modules references it. The
# upstream systemd unit in the package is a fine starting point but hardcodes
# /etc/ksmbd paths that do not work on a read-only root, so the unit is rewritten
# here rather than reused.
#
# THE TRANSPORT MATTERS MORE THAN THE CIPHER (§7.2.3). sshd caps transfers at
# 4.9 MB/s on this box - CPU-bound, not link-bound, so a gigabit link does not
# help it. SMB without signing or encryption should hand the disk path back its
# throughput, which is the whole reason this exists.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.ds410j-ksmbd;

  # Written to /etc rather than /run: it is not secret, and a store symlink under
  # a tmpfs /etc is exactly what environment.etc is for.
  ksmbdConf = pkgs.writeText "ksmbd.conf" ''
    [global]
        netbios name = ${cfg.netbiosName}
        server string = ${cfg.serverString}
        workgroup = ${cfg.workgroup}

        # Bind to the wired port only. The box has one populated NIC (eth1 is
        # disabled in the DTS - see kirkwood-ds410j.dts note 3).
        interfaces = ${cfg.interface}
        bind interfaces only = yes

        # THE POINT OF USING SMB HERE. Signing and encryption are what make ssh
        # cost 4.9 MB/s of a CPU that has nothing to spare; turning them on would
        # give that back. Leave them off on a trusted LAN, and understand that
        # doing so means the traffic is neither authenticated per-packet nor
        # confidential in transit.
        server signing = ${if cfg.signing then "mandatory" else "disabled"}
        smb3 encryption = ${if cfg.encryption then "yes" else "no"}

        # 88F6281 is single-core; more worker threads than that buys queueing,
        # not throughput.
        max active sessions = 10
    ''
    + lib.concatStringsSep "\n" (lib.mapAttrsToList (name: share: ''

      [${name}]
          path = ${share.path}
          ${lib.optionalString (share.comment != null) "comment = ${share.comment}"}
          read only = ${if share.readOnly then "yes" else "no"}
          ${lib.optionalString (share.validUsers != []) "valid users = ${lib.concatStringsSep ", " share.validUsers}"}
          guest ok = ${if share.guestOk then "yes" else "no"}
    '') cfg.shares);

  # The user database is a secret and must not live in the nix store. /etc and
  # /var are both tmpfs here (readonly-root.nix), so there is nowhere persistent
  # to keep it anyway - it is rebuilt from passwordFile on every boot, into /run
  # where it is root-only and never touches the USB stick.
  pwddb = "/run/ksmbd/ksmbdpwd.db";

  passwordFile =
    if cfg.passwordFile != null then cfg.passwordFile
    else pkgs.writeText "ksmbd-password" (lib.warn ''
      ds410j-ksmbd: services.ds410j-ksmbd.passwordFile is unset, so the share
      password is the placeholder "${cfg.placeholderPassword}" baked into the nix
      store WORLD-READABLE. Fine for a bench, wrong for anything else. Point
      passwordFile at a real secret before this box sees a network you do not own.
    '' cfg.placeholderPassword);
in
{
  options.services.ds410j-ksmbd = {
    enable = lib.mkEnableOption "the in-kernel SMB3 server (ksmbd)";

    netbiosName = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "NetBIOS name announced to clients.";
    };

    serverString = lib.mkOption {
      type = lib.types.str;
      default = "DS410j";
      description = "Server description string.";
    };

    workgroup = lib.mkOption {
      type = lib.types.str;
      default = "WORKGROUP";
      description = "SMB workgroup.";
    };

    interface = lib.mkOption {
      type = lib.types.str;
      default = "eth0";
      description = ''
        Interface to bind to. eth0 is the only populated port on this board;
        eth1 is disabled in the device tree.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "nas";
      description = ''
        The single SMB user. It must also exist as a system user, because ksmbd
        maps SMB sessions onto real uids for file access.
      '';
    };

    passwordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a file containing the SMB password, read at service start. Must
        NOT be a path in the nix store, which is world-readable. If null, a
        placeholder is used and a build-time warning is emitted.
      '';
    };

    placeholderPassword = lib.mkOption {
      type = lib.types.str;
      default = "ds410j";
      description = "Bench placeholder, used only when passwordFile is null.";
    };

    signing = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        SMB packet signing. Off by default deliberately: this CPU has no cycles
        to spare and signing is the cost that makes ssh unusable here (§7.2.3).
      '';
    };

    encryption = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        SMB3 transport encryption. Off by default for the same reason as signing.
        The data at rest is already encrypted by LUKS; this is about the wire.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open TCP 445.";
    };

    shares = lib.mkOption {
      default = { };
      description = "SMB shares, keyed by share name.";
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          path = lib.mkOption {
            type = lib.types.str;
            description = ''
              Directory to export. It must be writable, so on this image it has
              to live on the data volume - the root filesystem is read-only.
            '';
          };
          comment = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
          };
          readOnly = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };
          guestOk = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };
          validUsers = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
          };
        };
      });
    };
  };

  config = lib.mkIf cfg.enable {
    # SMB_SERVER is absent from the shipped kernel. It pulls in everything it
    # needs by itself (NLS_UTF8, NLS_UCS2_UTILS, the CCM/GCM/CMAC crypto, ASN1,
    # OID_REGISTRY, CRC32), so this one symbol is the whole kernel delta.
    #
    # `module`, not `yes`: the server is only useful while shares are exported,
    # and this way the code is not resident on a 118 MB box when it is not.
    boot.kernelPatches = [{
      name = "ksmbd";
      patch = null;
      structuredExtraConfig = with lib.kernel; {
        SMB_SERVER = module;
      };
    }];

    environment.systemPackages = [ pkgs.ksmbd-tools ];

    environment.etc."ksmbd/ksmbd.conf".source = ksmbdConf;

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.user;
      description = "ksmbd share owner";
    };
    users.groups.${cfg.user} = { };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ 445 ];

    systemd.services.ksmbd = {
      description = "ksmbd in-kernel SMB3 server (userspace daemon)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      # The kernel side is a module; load it before the daemon tries to talk to
      # it over netlink.
      path = [ pkgs.ksmbd-tools pkgs.kmod ];

      serviceConfig = {
        Type = "forking";
        PIDFile = "/run/ksmbd.lock";
        RuntimeDirectory = "ksmbd";
        RuntimeDirectoryMode = "0700";
        ExecStart = "${pkgs.ksmbd-tools}/sbin/ksmbd.mountd --config /etc/ksmbd/ksmbd.conf --pwddb ${pwddb}";
        ExecReload = "${pkgs.ksmbd-tools}/sbin/ksmbd.control --reload";
        ExecStop = "${pkgs.ksmbd-tools}/sbin/ksmbd.control --shutdown";
        Restart = "on-failure";
      };

      preStart = ''
        modprobe ksmbd

        # Rebuilt every boot: /run is tmpfs and the password never persists on
        # the stick.
        #
        # Argument order follows the documented synopsis - USER is positional and
        # comes last; --add takes no argument. Note --password puts the password
        # in this process's argv for the moment it runs, which is visible in
        # /proc. Acceptable on a single-user appliance, and the alternative
        # (prompting on stdin) needs a tty this has no business having.
        rm -f ${pwddb}
        ${pkgs.ksmbd-tools}/bin/ksmbd.adduser \
          --pwddb ${pwddb} --add --password "$(cat ${passwordFile})" ${cfg.user}
      '';
    };
  };
}
