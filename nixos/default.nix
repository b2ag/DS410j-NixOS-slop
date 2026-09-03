# Cross-compiled NixOS for the DS410j. Build on x86_64 ONLY - never evaluate nix
# on the device, 118 MB will OOM the evaluator (CLAUDE.md).
#
#   nix-build /src/nixos -A image     # the dd-able disk image
#   nix-build /src/nixos -A toplevel  # just the system closure
{ nixpkgs ? <nixpkgs> }:

let
  eval = import (nixpkgs + "/nixos/lib/eval-config.nix") {
    # null: the platform comes from nixpkgs.buildPlatform / hostPlatform in
    # configuration.nix, which is what makes this a cross build.
    system = null;
    modules = [ ./configuration.nix ];
  };
in
{
  inherit (eval) config options pkgs;
  toplevel = eval.config.system.build.toplevel;
  image = eval.config.system.build.sdImage;
}
