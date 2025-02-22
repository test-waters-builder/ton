{
  inputs = {
    nixpkgs-stable.url = "github:nixos/nixpkgs/nixos-22.05";
    nixpkgs-trunk.url = "github:nixos/nixpkgs";
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs-stable, nixpkgs-trunk, flake-compat, flake-utils }:
    let
      ton = { host, pkgs ? host, stdenv ? pkgs.stdenv, staticGlibc ? false
        , staticMusl ? false, staticExternalDeps ? staticGlibc }:
        with host.lib;
        stdenv.mkDerivation {
          pname = "ton";
          version = "dev";

          src = ./.;

          nativeBuildInputs = with host;
            [ cmake ninja pkg-config git ] ++
            optionals stdenv.isLinux [ dpkg rpm createrepo_c pacman ];
          buildInputs = with pkgs;
          # at some point nixpkgs' pkgsStatic will build with static glibc
          # then we can skip these manual overrides
          # and switch between pkgsStatic and pkgsStatic.pkgsMusl for static glibc and musl builds
            if !staticExternalDeps then [
              openssl_1_1
              zlib
              libmicrohttpd
            ] else
              [
                (openssl_1_1.override { static = true; }).dev
                (zlib.override { shared = false; }).dev
                pkgsStatic.libmicrohttpd.dev
              ] ++ optional staticGlibc glibc.static;

          cmakeFlags = [ "-DTON_USE_ABSEIL=OFF" "-DNIX=ON" ] ++ optionals staticMusl [
            "-DCMAKE_CROSSCOMPILING=OFF" # pkgsStatic sets cross
          ] ++ optionals (staticGlibc || staticMusl) [
            "-DCMAKE_LINK_SEARCH_START_STATIC=ON"
            "-DCMAKE_LINK_SEARCH_END_STATIC=ON"
          ];

          LDFLAGS = optional staticExternalDeps (concatStringsSep " " [
            (optionalString stdenv.cc.isGNU "-static-libgcc")
            "-static-libstdc++"
          ]);

          postInstall = ''
            moveToOutput bin "$bin"
          '';

          outputs = [ "bin" "out" ];
        };
      hostPkgs = system:
        import nixpkgs-stable {
          inherit system;
          overlays = [
            (self: super: {
              zchunk = nixpkgs-trunk.legacyPackages.${system}.zchunk;
            })
          ];
        };
    in with flake-utils.lib;
    (nixpkgs-stable.lib.recursiveUpdate
      (eachSystem (with system; [ x86_64-linux aarch64-linux ]) (system:
        let
          host = hostPkgs system;
          # look out for https://github.com/NixOS/nixpkgs/issues/129595 for progress on better infra for this
          #
          # nixos 19.09 ships with glibc 2.27
          # we could also just override glibc source to a particular release
          # but then we'd need to port patches as well
          nixos1909 = (import (builtins.fetchTarball {
            url = "https://channels.nixos.org/nixos-19.09/nixexprs.tar.xz";
            sha256 = "1vp1h2gkkrckp8dzkqnpcc6xx5lph5d2z46sg2cwzccpr8ay58zy";
          }) { inherit system; });
          glibc227 = nixos1909.glibc // { pname = "glibc"; };
          stdenv227 = let
            cc = host.wrapCCWith {
              cc = nixos1909.buildPackages.gcc-unwrapped;
              libc = glibc227;
              bintools = host.binutils.override { libc = glibc227; };
            };
          in (host.overrideCC host.stdenv cc);
        in rec {
          packages = rec {
            ton-normal = ton { inherit host; };
            ton-static = ton {
              inherit host;
              stdenv = host.makeStatic host.stdenv;
              staticGlibc = true;
            };
            ton-musl =
              let pkgs = nixpkgs-stable.legacyPackages.${system}.pkgsStatic;
              in ton {
                inherit host;
                inherit pkgs;
                stdenv =
                  pkgs.gcc12Stdenv; # doesn't build on aarch64-linux w/default GCC 9
                staticMusl = true;
              };
            ton-oldglibc = (ton {
              inherit host;
              stdenv = stdenv227;
              staticExternalDeps = true;
            });
            ton-oldglibc_staticbinaries = host.symlinkJoin {
              name = "ton";
              paths = [ ton-musl.bin ton-oldglibc.out ];
            };
          };
          devShells.default =
            host.mkShell { inputsFrom = [ packages.ton-normal ]; };
        })) (eachSystem (with system; [ x86_64-darwin aarch64-darwin ]) (system:
          let host = hostPkgs system;
          in rec {
            packages = rec {
              ton-normal = ton { inherit host; };
              ton-static = ton {
                inherit host;
                stdenv = host.makeStatic host.stdenv;
                staticExternalDeps = true;
              };
              ton-staticbin-dylib = host.symlinkJoin {
                name = "ton";
                paths = [ ton-static.bin ton-normal.out ];
              };
            };
            devShells.default =
              host.mkShell { inputsFrom = [ packages.ton-normal ]; };
          })));
}
