{
  description = "systemd-cri Go rewrite";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        go = pkgs.go_1_22;
      in
      {
        devShells.default = pkgs.mkShell {
          packages = [
            go
            pkgs.gopls
            pkgs.gotools
            pkgs.golangci-lint
          ];
          GO111MODULE = "on";
        };

        checks = {
          gofmt = pkgs.runCommand "gofmt-check" {
            nativeBuildInputs = [ go pkgs.findutils ];
          } ''
            set -euo pipefail
            cd ${self}
            unformatted=$(find cmd internal -type f -name "*.go" -print0 | xargs -0 ${go}/bin/gofmt -l)
            if [ -n "$unformatted" ]; then
              echo "gofmt needed on:"
              echo "$unformatted"
              exit 1
            fi
            mkdir -p $out
          '';

          gotest = pkgs.runCommand "gotest" {
            nativeBuildInputs = [ go ];
          } ''
            set -euo pipefail
            cd ${self}
            if [ -f vendor/modules.txt ]; then
              export GOPROXY=off
              ${go}/bin/go test ./...
            else
              echo "vendor/modules.txt not found; skipping go test"
            fi
            mkdir -p $out
          '';
        };
      });
}
