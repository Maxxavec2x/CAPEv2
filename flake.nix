{
  description = "CAPEv2 Python environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      uv2nix,
      pyproject-build-systems,
      pyproject-nix,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };

        workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };
        overlay = workspace.mkPyprojectOverlay { sourcePreference = "wheel"; };

        legacyPackages = [
          "bs4"
          "django-settings-export"
          "netstruct"
          "py-ubjson"
          "python-tlsh"
          "ruamel-yaml-clibz"
          "python-magic"
        ];

        legacyPythonFixes =
          final: prev:
          builtins.listToAttrs (
            map (name: {
              inherit name;
              value = prev.${name}.overrideAttrs (old: {
                nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
                  final.setuptools
                  final.wheel
                ];
              });
            }) legacyPackages
          );

        libvirtFix = final: prev: {
          libvirt-python = prev.libvirt-python.overrideAttrs (old: {
            nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
              pkgs.pkg-config
              final.setuptools
            ];
            buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.libvirt ];
          });
        };

        volatilityFix = final: prev: {
          volatility3 = prev.volatility3.overrideAttrs (old: {
            nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
              pkgs.pkg-config
              final.setuptools
            ];
            buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.libvirt ];
            # le lien pointe hors du store, donc "cassé" au moment du build
            dontCheckForBrokenSymlinks = true;
            postInstall = (old.postInstall or "") + ''
              sp=$out/lib/python3.11/site-packages/volatility3/symbols
              rm -rf "$sp/windows"
              ln -s /var/lib/capev2-symbols/windows "$sp/windows"
            '';
          });
        };
        pythonSet =
          (pkgs.callPackage pyproject-nix.build.packages {
            python = pkgs.python311;
          }).overrideScope
            (
              pkgs.lib.composeManyExtensions [
                pyproject-build-systems.overlays.default
                overlay
                legacyPythonFixes
                libvirtFix
                volatilityFix
              ]
            );

        capev2Env = pythonSet.mkVirtualEnv "capev2-env" workspace.deps.default;
        # Read-only copy of the CAPEv2 source tree, minus flake/VCS
        # cruft and the venv poetry2nix doesn't need to see. This is
        # what the systemd module rsyncs into its state directory.
        capev2Src = pkgs.stdenv.mkDerivation {
          pname = "capev2-src";
          version = "unstable";
          src = ./.;
          dontBuild = true;

          installPhase = ''
            mkdir -p $out/share/capev2

            cp -r --no-preserve=mode . $out/share/capev2/
            mkdir -p $out/share/capev2/data
            ln -sf ${pkgs._7zz}/bin/7zz $out/share/capev2/data/7zz
            rm -rf \
              $out/share/capev2/.git \
              $out/share/capev2/.venv \
              $out/share/capev2/result

            # CAPEv2 contains a broken symlink in the source tree.
            # It is not needed by the host-side CAPE services.
            rm -f $out/share/capev2/data/yara/monitor/yara
          '';
        };
      in
      {
        packages.default = capev2Env;
        packages.capev2Env = capev2Env;
        packages.capev2Src = capev2Src;

        devShells.default = pkgs.mkShell {
          packages = [
            capev2Env
            pkgs.postgresql
            pkgs.yara
            pkgs.uv
            pkgs.python311
            pkgs.pkg-config
            pkgs.libvirt
          ];
        };
      }
    )
    // {
      nixosModules.capev2 =
        { pkgs, ... }:
        {
          imports = [
            (import ./module.nix {
              capev2Src = self.packages.${pkgs.stdenv.hostPlatform.system}.capev2Src;

              capev2Env = self.packages.${pkgs.stdenv.hostPlatform.system}.capev2Env;
            })
          ];
        };
    };
}
