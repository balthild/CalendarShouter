{
  # Only the helper is built here. The app itself stays on the Xcode toolchain
  # (SwiftPM and xcstringstool need it) and signing stays in the Makefile
  # (it talks to 1Password), so there is nothing else for this flake to own.
  description = "Builds the CalendarShouter keychain helper with a pinned toolchain.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # macOS only: the helper links against the Security framework.
      systems = [ "aarch64-darwin" ];

      perSystem = { pkgs, ... }: rec {
        packages.keychain-helper = pkgs.stdenv.mkDerivation {
          pname = "CalendarShouterKeychainHelper";
          version = "1.0";

          # Only the source: the built helper is committed alongside it, and
          # letting that in would make the derivation depend on its own output.
          src = pkgs.lib.fileset.toSource {
            root = ./Tools/KeychainHelper;
            fileset = ./Tools/KeychainHelper/main.c;
          };

          dontConfigure = true;

          # No stripping, no install-name rewriting, no re-signing at fixup time.
          # The bytes must be a pure function of the source and the pinned
          # toolchain, because macOS pins the helper's keychain items to its
          # cdhash — a change there makes every user authorise again.
          dontFixup = true;

          buildPhase = ''
            runHook preBuild
            $CC -O2 -Wl,-no_uuid \
              -framework Security -framework CoreFoundation \
              -o CalendarShouterKeychainHelper main.c
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            install -m 755 CalendarShouterKeychainHelper $out/bin/
            runHook postInstall
          '';
        };

        packages.default = packages.keychain-helper;
      };
    };
}
