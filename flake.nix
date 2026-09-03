{
  description = "Recordly development environment (TS/JS + C++/CUDA + Swift-ready)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem
      [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ]
      (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config = {
              allowUnfree = true; # needed for some CUDA-related packages/drivers
            };
          };

          lib = pkgs.lib;
          isLinux = pkgs.stdenv.isLinux;
          isDarwin = pkgs.stdenv.isDarwin;

          # Choose an LTS Node line suitable for modern TS toolchains.
          # If your repo enforces a different version, swap this to nodejs_18/nodejs_22.
          nodejs = pkgs.nodejs_20;

          commonBuildInputs = with pkgs; [
            # JS/TS toolchain
            nodejs
            pnpm
            yarn
            npm-check-updates
            typescript
            typescript-language-server
            nodePackages.eslint
            nodePackages.prettier

            # General dev utilities
            git
            curl
            wget
            jq
            gnupg
            unzip
            zip
            which
            gnumake
            just

            # Native build stack (Node native addons / C++ libs)
            cmake
            ninja
            pkg-config
            python3
            clang
            llvmPackages.libclang
          ]
          ++ lib.optionals isLinux (with pkgs; [
            gcc
            gdb
            lldb
            valgrind
            patchelf
            strace
          ])
          ++ lib.optionals isDarwin (with pkgs; [
            lldb
            # On macOS, Apple SDK/Xcode provides many system toolchain pieces.
            # Keep shell lightweight; clang from nixpkgs is still included above.
          ]);

          # Linux-only CUDA tooling (optional at runtime depending on host driver/hardware)
          linuxCudaInputs = with pkgs; [
            cudaPackages.cudatoolkit
          ];

          shellInputs = commonBuildInputs
            ++ lib.optionals isLinux linuxCudaInputs;

        in
        {
          devShells.default = pkgs.mkShell {
            packages = shellInputs;

            # Environment for node-gyp / native extensions
            env = {
              # Ensure node-gyp uses nix python
              PYTHON = "${pkgs.python3}/bin/python3";

              # Prefer pkg-config from nix
              PKG_CONFIG = "${pkgs.pkg-config}/bin/pkg-config";

              # Useful default for many native builds
              CXXFLAGS = "-O2";
            } // lib.optionalAttrs isLinux {
              # CUDA paths on Linux
              CUDA_PATH = "${pkgs.cudaPackages.cudatoolkit}";
              CUDA_HOME = "${pkgs.cudaPackages.cudatoolkit}";
            };

            shellHook = ''
              echo "🚀 Recordly dev shell (${system})"
              echo "Node: $(node --version)"
              echo "pnpm: $(pnpm --version || true)"
              echo "npm:  $(npm --version)"
              echo "yarn: $(yarn --version || true)"
              echo "cmake: $(cmake --version | head -n1)"
              echo "clang: $(clang --version | head -n1)"

              ${if isLinux then ''
                echo "CUDA toolkit: ${pkgs.cudaPackages.cudatoolkit.version or "enabled"}"
                echo "Note: CUDA runtime requires compatible NVIDIA driver on host."
              '' else ''
                echo "CUDA disabled on this platform (non-Linux)."
              ''}

              echo ""
              echo "Suggested first run:"
              echo "  pnpm install   (or npm install / yarn)"
            '';
          };

          # Optional formatter so `nix fmt` works.
          formatter = pkgs.nixpkgs-fmt;
        });
}
