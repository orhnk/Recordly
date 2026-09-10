import { describe, expect, it, vi } from "vitest";

vi.mock("electron", () => ({
	app: {
		getPath: vi.fn(() => "/tmp"),
		setPath: vi.fn(),
		isReady: vi.fn(() => true),
		getVersion: vi.fn(() => "0.0.0-test"),
	},
}));

import { isNixStoreInstall } from "./updater";

describe("isNixStoreInstall", () => {
	it("detects Nix store paths through symlinks and indirection", () => {
		expect(isNixStoreInstall("/nix/store/abc123-recordly-1.0.0/libexec/recordly/recordly")).toBe(
			true,
		);
	});

	it("treats non-Nix paths as regular installs", () => {
		expect(isNixStoreInstall("/usr/bin/recordly")).toBe(false);
		expect(isNixStoreInstall("/opt/Recordly/recordly")).toBe(false);
		expect(
			isNixStoreInstall(
				"/home/user/Projects/Recordly/node_modules/electron/dist/electron",
				"/home/user/Projects/Recordly/node_modules/electron/dist/electron",
			),
		).toBe(false);
	});

	it("does not false-positive on paths that merely mention nix", () => {
		expect(isNixStoreInstall("/home/nixuser/projects/recordly/electron")).toBe(false);
		expect(isNixStoreInstall("/usr/local/nixstuff/recordly")).toBe(false);
	});
});
