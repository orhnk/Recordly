# Recordly Nix flake
#
# Usage:
#   nix develop                       # Node 22 + native toolchain + X11 dev libs
#   nix build .#recordlySource        # Linux package from source (see caveats below)
#   nix run .#recordly                # run the source-built Linux package
#
# Electron:
#   The Electron binary never comes from npm/GitHub in this flake. nixpkgs
#   builds (and patches) Electron for NixOS, and both the dev shell and the
#   package point at it:
#     * dev shell: ELECTRON_OVERRIDE_DIST_PATH -> ${electron}/bin.
#       npm's `electron` package resolves its dev binary as
#       "$ELECTRON_OVERRIDE_DIST_PATH/`electron`", and nixpkgs' wrapped
#       launcher is ${electron}/bin/electron, so `npm run dev` uses the Nix
#       Electron and does NOT need nix-ld. npm's own ~120 MB binary download
#       is skipped with ELECTRON_SKIP_BINARY_DOWNLOAD=1. A `predev` guard
#       (scripts/ensure-electron-runtime.mjs) fails fast with instructions
#       when the shell was not entered through the flake - that missing
#       override is what produced the old
#       "[nix-ld] FATAL ... Posix(2)" panic.
#     * package:   electron-builder -c.electronDist -> electron.dist
#       (nixpkgs' ${electron}/libexec/electron), so the build never
#       downloads the official Electron dist zip.
#
# Caveats:
#   * The build is pure and runs fully sandboxed (`nix build .#recordly`):
#     the npm registry is prefetched as a fixed-output `npmDeps`
#     (`importNpmLock`), the Electron dist/headers come from nixpkgs, the
#     whisper.cpp source is a `fetchurl` fixed-output input, and
#     ffmpeg/ffprobe come from nixpkgs instead of the ffmpeg-static network
#     installer. No `--option sandbox false` is needed.
#   * `nix run .#recordly` uses the source-built Linux package so the
#     renderer assets are present. A published AppImage is still exposed as a
#     separate output, but that release asset currently omits `dist/` and will
#     not show the UI on its own.
#   * The flake pins nixos-unstable so `pkgs.electron_43` exists (Recordly
#     ships Electron ^43 in package.json). If nixpkgs ever drops electron_43,
#     the binding falls back to `pkgs.electron` (latest).
#   * Only Linux can be packaged from Nix (macOS/Windows release builds are
#     signed upstream). The dev shell still works on macOS for running
#     `npm install` / `npm run dev` / `npm run build:mac` when Xcode CLT and
#     the signing credentials are available.
#   * The app is launched with --no-sandbox because Nix can't ship the SUID
#     chrome-sandbox helper; the app only loads local content.
#
# Runtime GPU + GIO notes (why the wrapper looks the way it does):
#   * Electron's ANGLE frontend dlopens libEGL.so.1 at startup. That dispatch
#     library lives in pkgs.libGL (libglvnd), NOT in pkgs.mesa - and the
#     actual DRI/llvmpipe drivers live in mesa.drivers. Without them the log
#     fills with:
#       "Could not dlopen native EGL: libEGL.so.1: cannot open shared object
#        file: No such file or directory"
#       "Initialization of all (2) EGL display types failed."
#       "Exiting GPU process due to errors during initialization"
#     libGL + mesa.drivers + vulkan-loader are therefore part of the runtime
#     library set and are also put on LD_LIBRARY_PATH by the FHS run script
#     (with LIBGL_DRIVERS_PATH pointing at the DRI drivers).
#   * Host sessions may export GIO_MODULE_DIR (or GIO_EXTRA_MODULES) pointing
#     at a gvfs built against a different glib; those modules then die with
#       "libgvfscommon.so: undefined symbol: g_variant_builder_init_static"
#       "Failed to load module: .../libgvfsdbus.so"
#     The run script unsets both so GIO uses the FHS glib's own module dir.
#     File dialogs keep working through GTK.
#   * The log line about "org.freedesktop.portal.FileChooser ... InvalidArgs"
#     is a harmless capability probe: it only fails when the host session runs
#     an xdg-desktop-portal backend without the FileChooser interface (e.g. a
#     Wayland compositor session without xdg-desktop-portal-gtk installed).
#     Electron then falls back to the native GTK dialog.

{
  description = "Recordly: dev shell + Linux package for the Electron screen recorder";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ] (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true; # Electron dist zip + CUDA tooling
        };
        lib = pkgs.lib;
        isLinux = pkgs.stdenv.isLinux;

        # Version mirrors package.json so bumping the app version is enough.
        version = (builtins.fromJSON (builtins.readFile ./package.json)).version;

        # The Linux CI pipeline runs on Node 22 with a Python 3 + CMake +
        # X11-dev toolchain for the native addons (uiohook-napi, whisper.cpp).
        nodejs = pkgs.nodejs_22;

        # Electron comes from nixpkgs (patched for NixOS) instead of the
        # npm-downloaded zip. Pin the major that package.json requests
        # (^43.1.0); fall back to the latest if nixpkgs drops electron_43.
        electron = pkgs.electron_43 or pkgs.electron;

        # Directory containing the Electron dist that electron-builder packs
        # (-c.electronDist). nixpkgs exposes it as the `dist` passthru
        # (${electron}/libexec/electron on Linux; there is no lib/electron).
        electronDist =
          if isLinux then (electron.dist or "${electron}/libexec/electron") else "";

        # When the Nix daemon builds with `sandbox = false`, Node still uses
        # nixpkgs' CA bundle rather than the host trust store.  On hosts with
        # a locally trusted proxy/root CA this makes npm fail with
        # `UNABLE_TO_GET_ISSUER_CERT_LOCALLY`.  Prefer the host bundle when
        # it is available; otherwise leave Node/npm's normal trust store
        # untouched.  This is deliberately not a TLS-verification bypass.
        configureNodeCertificateTrust = ''
          for recordly_ca_bundle in \
            /etc/ssl/certs/ca-bundle.crt \
            /etc/ssl/certs/ca-certificates.crt; do
            if [ -r "$recordly_ca_bundle" ]; then
              export NODE_EXTRA_CA_CERTS="$recordly_ca_bundle"
              export npm_config_cafile="$recordly_ca_bundle"
              echo "Using host CA bundle for Node/npm: $recordly_ca_bundle"
              break
            fi
          done
        '';

        # X11 development headers required by node-gyp/uiohook-napi on Linux
        # (mirrors the apt list in .github/workflows/build.yml).
        linuxNativeBuildLibs = with pkgs; [
          xorg.libX11
          xorg.libXt
          xorg.libXtst
          xorg.libxkbfile
          xorg.libXi
          xorg.libXrandr
          xorg.libXinerama
        ];

        # Libraries the packaged Electron app loads at runtime. When the app is
        # started from the dev shell (`npm run dev`) these are also needed, so
        # they double as the dev shell's buildInputs (mkShell exposes their lib
        # dirs via LD_LIBRARY_PATH automatically).
        #
        # GL stack notes:
        #   * libGL (libglvnd) provides the libEGL.so.1 / libGL.so.1 dispatch
        #     libraries that Electron's ANGLE frontend dlopens by name at
        #     runtime; mesa alone does NOT provide them.
        #   * mesa.drivers provides the actual DRI drivers (including llvmpipe
        #     software rendering) selected via LIBGL_DRIVERS_PATH.
        #   * vulkan-loader + gst are not strictly required but let
        #     hardware-accelerated decode paths initialize instead of failing.
        linuxRuntimeLibs = with pkgs; [
          libGL
          (pkgs.lib.getLib mesa)
          mesa.drivers
          vulkan-loader
          gtk3
          gsettings-desktop-schemas
          adwaita-icon-theme
          nss
          nspr
          alsa-lib
          cups
          dbus
          libdrm
          libxkbcommon
          libsecret
          libnotify
          at-spi2-core
          libpulseaudio
          # Chromium's WebRTC PipeWire capturer (used for Wayland screen
          # capture through xdg-desktop-portal) dlopens libpipewire-0.3.so.0
          # at runtime. Without it the FHS sandbox falls back to the X11
          # capturer, which cannot capture a native Wayland desktop and
          # getDisplayMedia fails with "Could not start video source".
          (pkgs.lib.getLib pipewire)
          xdg-utils
          # uiohook-napi dlopens these through its prebuild at runtime (global
          # hotkeys / cursor tracking). libXtst + libXt must therefore be in the
          # FHS runtime library set, not only in the build inputs.
          xorg.libX11
          xorg.libXt
          xorg.libXtst
          xorg.libXrandr
          xorg.libXcomposite
          xorg.libXcursor
          xorg.libXdamage
          xorg.libXext
          xorg.libXfixes
          xorg.libXi
          xorg.libXrender
          xorg.libXScrnSaver
          xorg.libXinerama
          xorg.libxcb
        ];

        # Electron-updater cannot install into the immutable Nix store, so the
        # FHS wrapper exports this and the main process skips the updater
        # entirely ("Auto-updates are not supported for this install type.").
        recordlyNixEnvVars = {
          RECORDLY_DISABLE_AUTO_UPDATES = "1";
        };

        # --------------------------------------------------------------------
        # Dev shell
        # --------------------------------------------------------------------
        devShell = pkgs.mkShell {
          name = "recordly-dev-shell";

          nativeBuildInputs =
            [ nodejs pkgs.python3 pkgs.cmake pkgs.pkg-config pkgs.git ]
            ++ lib.optionals isLinux (linuxNativeBuildLibs ++ [ electron ]);

          buildInputs = lib.optionals isLinux linuxRuntimeLibs;

          env = {
            # node-gyp resolves the Python interpreter through this.
            PYTHON = "${pkgs.python3}/bin/python3";
            # Keep native builds on the nix toolchain.
            PKG_CONFIG = "${pkgs.pkg-config}/bin/pkg-config";
          } // lib.optionalAttrs isLinux {
            # Run the Electron from nixpkgs instead of the npm-downloaded
            # binary: it is already patched for NixOS, so `npm run dev` works
            # without any nix-ld setup.
            # npm's `electron` package returns "$OVERRIDE_DIR/`electron`";
            # nixpkgs' wrapped launcher is ${electron}/bin/electron.
            ELECTRON_OVERRIDE_DIST_PATH = "${electron}/bin";
            # Don't let `npm install` pull the ~120 MB Electron zip from GitHub.
            ELECTRON_SKIP_BINARY_DOWNLOAD = "1";
            # Dev parity with the packaged launcher (the FHS wrapper passes
            # --no-sandbox): Nix cannot ship the SUID chrome-sandbox helper.
            ELECTRON_DISABLE_SANDBOX = "1";
            # GL: ANGLE dlopens libEGL.so.1 (libglvnd, in libGL) and needs the
            # DRI drivers from mesa.drivers at runtime. Without these the log
            # floods with "Could not dlopen native EGL: libEGL.so.1" and the
            # GPU process exits at startup.
            LD_LIBRARY_PATH = lib.makeLibraryPath [
              electron
              (pkgs.lib.getLib pkgs.mesa)
              pkgs.mesa.drivers
              pkgs.libGL
              pkgs.vulkan-loader
            ];
            LIBGL_DRIVERS_PATH = "${pkgs.mesa.drivers}/lib/dri";
          };

          shellHook = ''
            echo "🚀 Recordly dev shell (${system})"
            echo "   Node:    $(node --version 2>/dev/null || echo missing)"
            echo "   npm:     $(npm --version 2>/dev/null || echo missing)"
            echo "   CMake:   $(cmake --version 2>/dev/null | head -n1 || echo missing)"
            echo "   Electron: $ELECTRON_OVERRIDE_DIST_PATH/electron"
            echo ""
            echo "Suggested first run:"
            echo "  npm install"
            echo "  npm run dev"
            echo ""
            echo "NOTE: 'npm run dev' uses the Electron from nixpkgs"
            echo "      (ELECTRON_OVERRIDE_DIST_PATH), so no nix-ld setup is"
            echo "      needed. npm install still rebuilds uiohook-napi and"
            echo "      stages whisper.cpp; it needs network access."
          '';
        };

        # --------------------------------------------------------------------
        # Package from source: builds the app like `npm run build:linux` but
        # with the `dir` electron-builder target (release/linux-unpacked),
        # which avoids the AppImage toolchain/fuse and is directly wrappable
        # for Nix.
        #
        # Pure/sandboxed build: every network input is a fixed-output Nix
        # input, so no `--option sandbox false` is needed:
        #   * npm registry  -> `npmDeps` via `importNpmLock` (buildNpmPackage
        #     installs with `npm ci --offline`; the registry is fetched once
        #     in its own FOD, the main build stays offline).
        #   * Electron dist/headers -> nixpkgs `${electron}` (`dist` packed
        #     via `-c.electronDist`, `headers` wired as node-gyp `--nodedir`
        #     so `install-app-deps` never downloads Electron headers).
        #   * whisper.cpp   -> `whisperArchive` fetchurl (wired through
        #     `WHISPER_SRC_ARCHIVE`, see scripts/build-whisper-runtime.mjs).
        #   * ffmpeg/ffprobe -> nixpkgs `pkgs.ffmpeg` symlinked over the
        #     ffmpeg-static network installer (the app also falls back to
        #     `PATH` ffmpeg at runtime, see electron/ipc/ffmpeg/binary.ts).
        # --------------------------------------------------------------------
        whisperArchive = pkgs.fetchurl {
          url = "https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v1.8.4.tar.gz";
          hash = "sha256-sm8w5SwJXMt12kCxaEN3NmBesoDeVzgYh7+eK2XzHmY=";
        };

        recordlyUnwrapped = pkgs.buildNpmPackage {
          pname = "recordly-unwrapped";
          inherit version;
          src = lib.cleanSource ./.;
          npmDepsHash = "sha256-59EEhe7IuzWqajTxMv+hrxJKiN+0vzNKhpl8hxvNTTU=";

          nativeBuildInputs =
            [ nodejs pkgs.python3 pkgs.cmake pkgs.pkg-config pkgs.git ]
            ++ linuxNativeBuildLibs;

          buildInputs = linuxRuntimeLibs;

          dontStrip = true;
          dontConfigure = true;
          enableParallelBuilding = true;
          dontNpmBuild = true;
          dontNpmPrune = true;
          makeCacheWritable = true;
          npmInstallFlags = [ "--ignore-scripts" "--no-audit" "--no-fund" ];
          npmRebuildFlags = [ "--ignore-scripts" ];

          env = {
            ELECTRON_SKIP_BINARY_DOWNLOAD = "1";
          };

          buildPhase = ''
            runHook preBuild
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME"
            ${configureNodeCertificateTrust}

            export ELECTRON_SKIP_BINARY_DOWNLOAD=1
            export ELECTRON_DIST="${electronDist}"
            export npm_config_nodedir="${electron.headers}"
            export WHISPER_SRC_ARCHIVE="${whisperArchive}"

            export jobs="$(nproc)"
            if [ "$jobs" -gt 4 ]; then jobs=4; fi
            export CMAKE_BUILD_PARALLEL_LEVEL="$jobs"
            export npm_config_jobs="$jobs"

            ln -sf "${pkgs.ffmpeg}/bin/ffmpeg" node_modules/ffmpeg-static/ffmpeg
            mkdir -p node_modules/ffprobe-static/bin/linux/x64
            ln -sf "${pkgs.ffmpeg}/bin/ffprobe" node_modules/ffprobe-static/bin/linux/x64/ffprobe

            rm -rf node_modules/uiohook-napi/build
            ./node_modules/.bin/electron-builder install-app-deps

            npm run build:platform-native-helpers
            ./node_modules/.bin/tsc
            ./node_modules/.bin/vite build --config vite.config.ts
            npm run normalize:electron-main-cjs
            npm run smoke:electron-main-cjs
            ./node_modules/.bin/electron-builder --linux dir --publish never -c.electronDist="$ELECTRON_DIST"
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p "$out/libexec/recordly" "$out/bin"
            cp -a release/linux-unpacked/. "$out/libexec/recordly/"
            chmod -R u+w "$out/libexec/recordly"

            if [[ -x "$out/libexec/recordly/recordly" ]]; then
              binName="recordly"
            elif [[ -x "$out/libexec/recordly/Recordly" ]]; then
              binName="Recordly"
            else
              echo "recordly executable not found in release/linux-unpacked" >&2
              ls -la "$out/libexec/recordly" >&2
              exit 1
            fi
            ln -s "$out/libexec/recordly/$binName" "$out/bin/recordly"
            runHook postInstall
          '';

          meta = {
            description = "Creator-focused screen recorder with auto-zoom, cursor effects and editing (unwrapped build)";
            homepage = "https://github.com/webadderallorg/Recordly";
            license = lib.licenses.agpl3Only;
            platforms = lib.platforms.linux;
            mainProgram = "recordly";
          };
        };

        # FHS wrapper: gives the bundled Electron binary a complete runtime
        # environment (GTK, NSS, ALSA, PulseAudio, X11, GL, xdg-utils for
        # shell.openExternal, ...) without chasing transitive library paths
        # by hand.
        recordly = pkgs.buildFHSEnv {
          name = "recordly";
          targetPkgs = pkgs': [ recordlyUnwrapped pkgs.ffmpeg ] ++ linuxRuntimeLibs;
          runScript = ''
            # Host sessions can leak environment that breaks the packaged app:
            #
            # * GIO_MODULE_DIR / GIO_EXTRA_MODULES may point at the host's gvfs
            #   modules, built against a different glib. Loading them fails
            #   with "undefined symbol: g_variant_builder_init_static" and
            #   "Failed to load module: .../libgvfsdbus.so". Unset them so GIO
            #   uses the module dir of the glib inside this FHS environment.
            #   File dialogs keep working through GTK.
            #
            # (The "org.freedesktop.portal.FileChooser ... InvalidArgs" message
            # that can still appear is a harmless probe: the session portal has
            # no FileChooser interface and Electron falls back to the native
            # GTK dialog.)
            unset GIO_MODULE_DIR GIO_EXTRA_MODULES GTK_USE_PORTAL

            # Make the GL stack resolvable by name: ANGLE dlopens libEGL.so.1
            # (libglvnd, in libGL) and EGL needs the DRI drivers from
            # mesa.drivers via LIBGL_DRIVERS_PATH.
            export LD_LIBRARY_PATH="${lib.makeLibraryPath [
              pkgs.libGL
              (pkgs.lib.getLib pkgs.mesa)
              pkgs.mesa.drivers
              pkgs.vulkan-loader
            ]}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            export LIBGL_DRIVERS_PATH="${pkgs.mesa.drivers}/lib/dri"

            # Auto-updates cannot install into the immutable Nix store.
            ${lib.concatStringsSep "\n            " (
              lib.mapAttrsToList (
                name: value: "export ${name}=${lib.strings.escapeShellArg value}"
              ) recordlyNixEnvVars
            )}

            # Run natively on the host's display server: Electron >= 38.2
            # auto-detects the session (Wayland on Wayland sessions, X11
            # elsewhere), so no ozone flag is needed here.
            #
            # IMPORTANT: do not force --ozone-platform=x11. On a Wayland
            # session that would push Chromium onto Xwayland, where X11-based
            # screen capture cannot see the native Wayland desktop (black
            # frames or a "Failed to start recording" error). Screen capture
            # on Wayland requires native Wayland so Chromium captures through
            # xdg-desktop-portal (PipeWire). The HUD overlay has in-app
            # Wayland fallbacks (OS-driven dragging via -webkit-app-region,
            # always-interactive window, programmatic bounds silently
            # ignored), so the X11 compatibility layer is not required;
            # gpuSwitches.ts still selects use-gl=egl for X11 sessions.
            exec recordly --no-sandbox "$@"
          '';
          meta = {
            description = "Recordly – free, creator-focused screen recorder with auto-zoom, cursor effects, backgrounds, annotations, and editing";
            homepage = "https://github.com/webadderallorg/Recordly";
            license = lib.licenses.agpl3Only;
            platforms = lib.platforms.linux;
            mainProgram = "recordly";
          };
        };

        # Alias for compatibility with previous references.
        recordlySource = recordly;

        # AppImage-based release wrapper (only for x86_64-linux, falls back to
        # the source-built package otherwise).
        recordlyRelease =
          if system == "x86_64-linux" then
            pkgs.writeShellApplication
              {
                name = "recordly";
                runtimeInputs = [ pkgs.appimage-run ];
                text = ''
                  export RECORDLY_DISABLE_AUTO_UPDATES=1
                  export RECORDLY_FORCE_SOFTWARE_RENDERING=1
                  exec appimage-run ${pkgs.fetchurl {
                    url = "https://github.com/webadderallorg/Recordly/releases/download/v${version}/Recordly-linux-x64.AppImage";
                    hash = "sha256-wW3pTkaAiNv6r7aAAd5r0eWob6vQUobQV3kK77xbGuM=";
                  }} --no-sandbox "$@"
                '';
              }
          else
            recordlySource;

        recordlyApp = recordly;

        # --------------------------------------------------------------------
        # Checks
        # --------------------------------------------------------------------
        checks = {
          flake-format = pkgs.runCommand "recordly-flake-format"
            {
              nativeBuildInputs = [ pkgs.nixpkgs-fmt ];
            } ''
            nixpkgs-fmt --check ${./flake.nix}
            touch $out
          '';
        };

        # Packaging only makes sense on Linux from Nix; macOS/Windows release
        # artifacts are produced by the upstream CI (macOS needs signing).
        packages = lib.optionalAttrs isLinux {
          inherit recordly recordlyRelease recordlySource recordlyUnwrapped;
          default = recordly;
        };

        formatter = pkgs.nixpkgs-fmt;

      in
      {
        devShells.default = devShell;

        apps = lib.optionalAttrs isLinux {
          default = {
            type = "app";
            program = "${recordlyApp}/bin/recordly";
            meta = {
              description = "Recordly app launcher";
            };
          };

          recordly = {
            type = "app";
            program = "${recordlyApp}/bin/recordly";
            meta = {
              description = "Recordly app launcher";
            };
          };
        };

        inherit packages checks;
      }
    );
}
