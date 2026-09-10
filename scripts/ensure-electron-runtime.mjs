import { readFileSync } from "node:fs";
import { platform } from "node:os";

// `npm run dev` launches the Electron binary managed by npm's `electron`
// package. On NixOS that stock binary is not patchelf'd for the Nix store, so
// the kernel's nix-ld fallback execs it and dies with:
//
//   [nix-ld] FATAL: panicked at src/main.rs:187:55:
//   called `Result::unwrap()` on an `Err` value: Posix(2)
//
// nixpkgs' Electron is already patched for NixOS, and the flake dev shell
// exports ELECTRON_OVERRIDE_DIST_PATH so the npm package uses it. This guard
// fails fast with the remedy instead of letting vite crash later.

if (platform() !== "linux") process.exit(0);

// The flake dev shell sets this; it is also what npm's `electron` package
// consumes, so if it is present the right Electron is already wired up.
if (process.env.ELECTRON_OVERRIDE_DIST_PATH) process.exit(0);

let isNixOS = false;
try {
	isNixOS = readFileSync("/etc/os-release", "utf8").includes("nixos");
} catch {
	// No readable /etc/os-release: assume it is not NixOS.
}

if (!isNixOS) process.exit(0);

console.error(`
✖ This looks like NixOS, but the dev shell was not set up.

  The Electron binary npm downloads is not patched for NixOS: launching it
  routes through nix-ld and dies with a "[nix-ld] FATAL ... Posix(2)" panic.

  Run the app inside the flake's dev shell, which points Electron at the
  nixpkgs build instead:

      nix develop
      npm run dev

  The shell sets ELECTRON_OVERRIDE_DIST_PATH to the patched Electron, so the
  binary download (and nix-ld) are never involved.
`);

process.exit(1);
