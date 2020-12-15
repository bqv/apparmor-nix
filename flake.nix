{
  description = "Alternative apparmor nixos infrastructure flake";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: let

    modules = {
      fontconfig = ./nixos/modules/config/fonts/fontconfig.nix;
      malloc = ./nixos/modules/config/malloc.nix;
      apparmor = ./nixos/modules/security/apparmor.nix;
      includes = ./nixos/modules/security/apparmor/includes.nix;
      profiles = ./nixos/modules/security/apparmor/profiles.nix;
      pam = ./nixos/modules/security/pam.nix;
      default = ./nixos/modules/security/wrappers/default.nix;
      transmission = ./nixos/modules/services/torrent/transmission.nix;
      network-interfaces = ./nixos/modules/tasks/network-interfaces.nix;
      lxc = ./nixos/modules/virtualisation/lxc.nix;
      lxd = ./nixos/modules/virtualisation/lxd.nix;
    };

  in {

    nixosModules = builtins.mapAttrs (_: m: import m) modules;

    nixosModule = { ... }: rec {
      imports = builtins.attrValues modules;
      disabledModules = builtins.map (m:
        nixpkgs.lib.removePrefix (toString ./nixos/modules + "/") (toString m)
      ) (builtins.attrValues modules) ++ [
        "security/apparmor-suid.nix"
      ];
    };

    overlays.apparmor = final: prev: let
      apparmor = final.callPackages ./pkgs/os-specific/linux/apparmor { python = final.python3; };
    in rec {
      inherit (apparmor)
        libapparmor apparmor-utils apparmor-bin-utils apparmor-parser apparmor-pam
        apparmor-profiles apparmor-kernel-patches apparmorRulesFromClosure;
    };
    overlays.transmission = final: prev: {
      inherit (self.packages.${final.system}) transmission transmission-gtk transmission-qt;
    };
    overlays.iputils = final: prev: { inherit (self.packages.${final.system}) iputils; };
    overlays.inetutils = final: prev: { inherit (self.packages.${final.system}) inetutils; };

    overlay = final: prev: nixpkgs.lib.composeManyExtensions (builtins.attrValues self.overlays) final prev;

    packages = nixpkgs.lib.genAttrs ["x86_64-linux" "i686-linux" "aarch64-linux"] (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      local = self.overlay pkgs pkgs;
    in builtins.removeAttrs local [ "apparmorRulesFromClosure" ] // rec {
      transmission = pkgs.callPackage ./pkgs/applications/networking/p2p/transmission {
        inherit (local) apparmorRulesFromClosure;
      };
      transmission-gtk = transmission.override { enableGTK3 = true; };
      transmission-qt = transmission.override { enableQt = true; };
      iputils = pkgs.callPackage ./pkgs/os-specific/linux/iputils {
        inherit (local) apparmorRulesFromClosure;
      };
      inetutils = pkgs.callPackage ./pkgs/tools/networking/inetutils {
        inherit (local) apparmorRulesFromClosure;
      };
    });

    checks = nixpkgs.lib.genAttrs ["x86_64-linux" "i686-linux" "aarch64-linux"] (system: {
      inherit (import nixpkgs {
        inherit system;
        overlays = [ self.overlay ];
      }) apparmor-utils apparmor-bin-utils apparmor-parser apparmor-pam apparmor-profiles apparmor-kernel-patches;
    });

  };
}
