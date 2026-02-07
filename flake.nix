{
  description = "systemd-cri - Container Runtime Interface using systemd";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      # Per-system outputs
      perSystemOutputs = flake-utils.lib.eachDefaultSystem (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # Common build inputs for tests
          zigBuildInputs = [
            pkgs.systemd
            pkgs.rocksdb
            pkgs.protobufc
            pkgs.nghttp2
          ];

          zigNativeBuildInputs = [
            pkgs.zig
            pkgs.protobuf
            pkgs.protobufc
          ];

          # Helper to create a test derivation
          mkZigTest = { name, testStep }: pkgs.stdenv.mkDerivation {
            pname = "systemd-cri-${name}";
            version = "0.1.0";

            src = ./.;

            nativeBuildInputs = zigNativeBuildInputs;
            buildInputs = zigBuildInputs;

            buildPhase = ''
              export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-cache"
              export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
              zig build ${testStep}
            '';

            installPhase = ''
              mkdir -p $out
              touch $out/success
            '';
          };
        in
        {
          packages.default = pkgs.stdenv.mkDerivation {
            pname = "systemd-cri";
            version = "0.1.0";

            src = ./.;

            nativeBuildInputs = zigNativeBuildInputs;
            buildInputs = zigBuildInputs;

            buildPhase = ''
              export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-cache"
              export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
              zig build -Doptimize=ReleaseSafe
            '';

            installPhase = ''
              mkdir -p $out/bin
              cp zig-out/bin/systemd-cri $out/bin/
            '';
          };

          # Garnix CI checks
          checks = {
            # Build check (release build)
            build = self.packages.${system}.default;

            # Unit tests
            unit-tests = mkZigTest {
              name = "unit-tests";
              testStep = "test";
            };

            # Integration tests (RocksDB, image store, etc.)
            integration-tests = mkZigTest {
              name = "integration-tests";
              testStep = "test-integration";
            };

            # Full integration tests (skips tests requiring root/dbus)
            full-integration-tests = mkZigTest {
              name = "full-integration-tests";
              testStep = "test-full";
            };

          };

          # Apps for development tasks
          apps.update-proto = {
            type = "app";
            program = toString (pkgs.writeShellScript "update-proto" ''
              set -euo pipefail

              # Ensure we have the required tools
              export PATH="${pkgs.lib.makeBinPath [ pkgs.curl pkgs.protobufc ]}"

              # Run the update script
              exec ${./scripts/update-proto.sh}
            '');
          };

          devShells.default = pkgs.mkShell {
            name = "systemd-cri-dev";

            buildInputs = [
              # Build tools
              pkgs.zig
              pkgs.zls

              # Runtime dependencies
              pkgs.systemd
              pkgs.pkg-config
              pkgs.rocksdb

              # gRPC/protobuf for CRI
              pkgs.protobuf
              pkgs.protobufc
              pkgs.nghttp2

              # Development tools
              pkgs.gdb
              pkgs.valgrind

              # For testing CRI
              pkgs.cri-tools

              # For image management (Phase 4)
              pkgs.skopeo
              pkgs.umoci
            ];

            shellHook = ''
              # Set up zig cache directories to avoid sandbox permission issues
              export ZIG_LOCAL_CACHE_DIR="$PWD/.zig-cache"
              export ZIG_GLOBAL_CACHE_DIR="$HOME/.cache/zig"
              mkdir -p "$ZIG_LOCAL_CACHE_DIR" "$ZIG_GLOBAL_CACHE_DIR"

              echo "systemd-cri development environment"
              echo "  zig version: $(zig version)"
              echo ""
              echo "Commands:"
              echo "  zig build        - Build the project"
              echo "  zig build run    - Build and run"
              echo "  zig build test   - Run tests"
              echo ""
            '';
          };
        }
      );
    in
    perSystemOutputs // {
      # NixOS module
      nixosModules.default = { config, lib, pkgs, ... }: {
        imports = [ ./nix/module.nix ];

        # Provide the package from this flake
        services.systemd-cri.package = lib.mkDefault self.packages.${pkgs.system}.default;
      };

      nixosModules.systemd-cri = self.nixosModules.default;
    };
}
