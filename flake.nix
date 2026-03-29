{
  description = "systemd-cri Go rewrite";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    pre-commit-hooks.url = "github:cachix/pre-commit-hooks.nix";
    gomod2nix.url = "github:nix-community/gomod2nix";
  };

  outputs = { self, nixpkgs, flake-utils, pre-commit-hooks, gomod2nix, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ gomod2nix.overlays.default ];
        };
        goVersion =
          let
            lines = builtins.filter builtins.isString (builtins.split "\n" (builtins.readFile ./go.mod));
            goLine =
              builtins.head (builtins.filter (l: builtins.match "^go [0-9]+\\.[0-9]+(\\.[0-9]+)?$" l != null) lines);
            m = builtins.match "^go ([0-9]+\\.[0-9]+)(\\.[0-9]+)?$" goLine;
          in builtins.elemAt m 0;
        goAttr = "go_${builtins.replaceStrings ["."] ["_"] goVersion}";
        go = builtins.getAttr goAttr pkgs;
        preCommit = pre-commit-hooks.lib.${system}.run {
          src = ./.;
          hooks = {
            gofmt.enable = true;
          };
        };
        app = pkgs.buildGoApplication {
          pname = "systemd-cri";
          version = "0.2.0";
          src = ./.;
          modules = ./gomod2nix.toml;
          subPackages = [ "cmd/systemd-cri" ];
        };

        # Dedicated offline checks
        lintCheck = app.overrideAttrs (old: {
          pname = "systemd-cri-lint";
          nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.golangci-lint ];
          buildPhase = ''
            export GOCACHE=$TMPDIR/go-cache
            export GOPATH=$TMPDIR/go
            export GOLANGCI_LINT_CACHE=$TMPDIR/golangci-lint-cache
            golangci-lint run ./...
          '';
          installPhase = "touch $out";
          doCheck = false;
        });

        govetCheck = app.overrideAttrs (old: {
          pname = "systemd-cri-govet";
          buildPhase = ''
            export GOCACHE=$TMPDIR/go-cache
            export GOPATH=$TMPDIR/go
            go vet ./...
          '';
          installPhase = "touch $out";
          doCheck = false;
        });
        critestTest = pkgs.testers.nixosTest {
          name = "systemd-cri-critest";
          nodes.machine = { pkgs, ... }: {
            environment.systemPackages = [
              app
              pkgs.cri-tools
              pkgs.skopeo
              pkgs.umoci
              pkgs.util-linux
              pkgs.sqlite
            ];
            virtualisation.memorySize = 2048;
            boot.supportedFilesystems = [ "overlay" ];
          };
          testScript = ''
            machine.wait_for_unit("multi-user.target")

            # 1. Start systemd-cri in the background
            machine.execute("${app}/bin/systemd-cri --log-level debug >&2 &")
            machine.wait_for_file("/run/systemd-cri/cri.sock")

            # Define endpoints for crictl
            endpoint = "unix:///run/systemd-cri/cri.sock"
            crictl = f"crictl --runtime-endpoint {endpoint} --image-endpoint {endpoint}"

            # 2. Run basic critest to ensure the server starts and responds
            # We use the critest-runner.sh but it starts its own server, so we might want to be careful.
            # Actually, let's just use crictl directly for the lifecycle test.
            
            machine.succeed(f"{crictl} version")

            # 3. Manually test Pod Sandbox lifecycle and verify .service unit
            machine.log("Testing Pod Sandbox lifecycle...")
            pod_id = machine.succeed(f"{crictl} runp <(echo '{{\"metadata\": {{\"name\": \"test-pod\", \"namespace\": \"default\"}}}}')").strip()
            machine.log(f"Created pod: {pod_id}")

            # Verify .service unit is running
            machine.succeed(f"systemctl is-active cri-pod-{pod_id}.service")

            # Verify sqlite3 database entry
            machine.succeed(f"sqlite3 /var/lib/systemd-cri/state.db \"SELECT data FROM pods WHERE id='{pod_id}'\"")

            # Cleanup
            machine.succeed(f"{crictl} stopp {pod_id}")
            machine.succeed(f"{crictl} rmp {pod_id}")

            # Verify cleanup
            machine.succeed(f"systemctl is-failed cri-pod-{pod_id}.service || ! systemctl is-active cri-pod-{pod_id}.service")
          '';
        };
      in
      {
        devShells.default = pkgs.mkShell {
          packages = [
            go
            pkgs.gopls
            pkgs.gotools
            pkgs.golangci-lint
            pkgs.pre-commit
            pkgs.gomod2nix
            pkgs.cri-tools
            pkgs.skopeo
            pkgs.umoci
          ];
          GO111MODULE = "on";
          shellHook = preCommit.shellHook;
        };

        checks = {
          pre-commit = preCommit;
          gobuild = app;
          lint = lintCheck;
          govet = govetCheck;
          gotest = app.overrideAttrs (_: {
            doCheck = true;
          });
          critest = critestTest;
        };
      });
}
