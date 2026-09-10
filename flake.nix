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
#   * Building still needs network access (npm registry, Electron headers for
#     the uiohook-napi rebuild, whisper.cpp sources, ffmpeg-static binary), so
#     Nix's default sandbox blocks it. Build with:
#         nix build .#recordly --option sandbox false
#   * `nix run .#recordly` uses the source-built Linux package so the
#     renderer assets are present. A published AppImage is still exposed as a
#     separate output, but that release asset currently omits `dist/` and will
#     not show the UI on its own.
#   * `nix build .#recordlySource` still runs `npm ci` + `electron-builder`,
#     both of which download binaries from the network (Electron dist,
#     whisper.cpp sources, ffmpeg-static, ...). Nix's default sandbox blocks
#     that, so build with:
#         nix build .#recordlySource --option sandbox false
#     (or configure `sandbox = false` in nix.conf if you build often).
#     Every network step is wrapped in a hard `timeout`, so a flaky network
#     fails the build loudly instead of hanging it forever.
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
        # --------------------------------------------------------------------
        recordlyUnwrapped = pkgs.stdenv.mkDerivation {
          pname = "recordly-unwrapped";
          inherit version;
          src = lib.cleanSource ./.;

          nativeBuildInputs =
            [ nodejs pkgs.python3 pkgs.cmake pkgs.pkg-config pkgs.git ]
            ++ linuxNativeBuildLibs;

          buildInputs = linuxRuntimeLibs;

          dontStrip = true; # electron-builder ships pre-stripped binaries
          enableParallelBuilding = true;

          configurePhase = ''
            runHook preConfigure
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME"
            ${configureNodeCertificateTrust}

            # Impure-but-practical build environment:
            # * keep npm/electron caches in /tmp so failed/retried builds do not
            #   re-download hundreds of MB (cleared on reboot, recreated here)
            # * fail fast on unreachable hosts instead of npm retrying silently
            #   for tens of minutes
            # * cap C++ jobs so weak machines don't swap-thrash while compiling
            #   whisper.cpp
            export npm_config_cache="/tmp/nix-recordly-cache/npm"
            export XDG_CACHE_HOME="/tmp/nix-recordly-cache/xdg"
            export ELECTRON_BUILDER_CACHE="/tmp/nix-recordly-cache/electron-builder"
            mkdir -p "$npm_config_cache" "$XDG_CACHE_HOME" "$ELECTRON_BUILDER_CACHE"

            export npm_config_fetch_retries=0
            export npm_config_fetch_timeout=60000

            # The packaged app uses the Electron from nixpkgs (electronDist
            # below), so never let npm/electron-builder download its own.
            export ELECTRON_SKIP_BINARY_DOWNLOAD=1

            export jobs="$(nproc)"
            if [ "$jobs" -gt 4 ]; then jobs=4; fi
            export CMAKE_BUILD_PARALLEL_LEVEL="$jobs"
            export npm_config_jobs="$jobs"

            # `npm ci` is scripts-free here, mirroring the Linux CI pipeline
            # (build.yml uses `npm ci --ignore-scripts`). The repo postinstall
            # used to download the Electron zip and whisper.cpp sources from
            # GitHub and could stall indefinitely - that was the hang. Binary
            # downloads and native rebuilds now run explicitly in buildPhase,
            # each behind a hard `timeout` so nothing can hang forever again.
            # npm hides progress bars without a TTY, so print a heartbeat that
            # shows whether the cache is growing (= downloading) or stalled.
            echo "npm ci: downloading registry dependencies (heartbeat every 20s)..."
            timeout 1200 npm ci --ignore-scripts --no-audit --no-fund &
            npm_pid=$!
            while kill -0 "$npm_pid" 2>/dev/null; do
              sleep 20
              echo "[nix] npm ci still running; npm cache: $(du -sh "$npm_config_cache" 2>/dev/null | cut -f1)"
            done
            wait "$npm_pid"
            echo "npm ci: done."
            runHook postConfigure
          '';

          buildPhase = ''
            runHook preBuild
            export HOME="$TMPDIR/home"
            ${configureNodeCertificateTrust}

            # Same impure build environment as configurePhase (see above).
            export npm_config_cache="/tmp/nix-recordly-cache/npm"
            export XDG_CACHE_HOME="/tmp/nix-recordly-cache/xdg"
            export ELECTRON_BUILDER_CACHE="/tmp/nix-recordly-cache/electron-builder"
            mkdir -p "$npm_config_cache" "$XDG_CACHE_HOME" "$ELECTRON_BUILDER_CACHE"
            export npm_config_fetch_retries=0
            export npm_config_fetch_timeout=60000
            export ELECTRON_SKIP_BINARY_DOWNLOAD=1
            export jobs="$(nproc)"
            if [ "$jobs" -gt 4 ]; then jobs=4; fi
            export CMAKE_BUILD_PARALLEL_LEVEL="$jobs"
            export npm_config_jobs="$jobs"

            # Electron dist provided by nixpkgs (already patched for NixOS).
            # electron-builder reads it via `electronDist` and never downloads
            # the official zip. If it complains about a version mismatch with
            # node_modules/electron, pin `electron` in this flake to the exact
            # version from package-lock.json.
            export ELECTRON_DIST="${electronDist}"

            # Mirrors the Linux CI job in .github/workflows/build.yml:
            # ffmpeg-static's binary is fetched explicitly (its postinstall
            # does not run because npm ci was scripts-free)...
            timeout 600 node node_modules/ffmpeg-static/install.js
            # ...and uiohook-napi is rebuilt against the pinned Electron.
            rm -rf node_modules/uiohook-napi/build
            timeout 1200 ./node_modules/.bin/electron-builder install-app-deps

            # Whisper runtime (downloads whisper.cpp sources, cmake build).
            timeout 1800 npm run build:platform-native-helpers
            ./node_modules/.bin/tsc
            ./node_modules/.bin/vite build --config vite.config.ts
            npm run normalize:electron-main-cjs
            npm run smoke:electron-main-cjs
            timeout 1200 ./node_modules/.bin/electron-builder --linux dir --publish never -c.electronDist="$ELECTRON_DIST"
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
          targetPkgs = pkgs': [ recordlyUnwrapped ] ++ linuxRuntimeLibs;
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
