import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import net from "node:net";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const { getScreen } = vi.hoisted(() => ({
	getScreen: vi.fn(),
}));

vi.mock("../utils", () => ({
	getScreen,
	getTelemetryPathForVideo: vi.fn(),
}));

vi.mock("electron", () => ({
	app: {
		getPath: vi.fn(() => "/tmp"),
	},
}));

import { linuxCursorScreenPoint, setLinuxCursorScreenPoint } from "../state";
import {
	detectHyprlandSocketPath,
	resetHyprlandCursorStateForTest,
	startHyprlandCursorPolling,
	stopHyprlandCursorPolling,
} from "./hyprlandCursor";

async function waitFor(condition: () => boolean, timeoutMs = 2_000) {
	const startedAt = Date.now();
	while (!condition()) {
		if (Date.now() - startedAt > timeoutMs) {
			throw new Error("waitFor timed out");
		}
		await new Promise((resolve) => setTimeout(resolve, 10));
	}
}

describe("hyprland cursor poller", () => {
	let runtimeDir: string;
	let socketPath: string;
	let server: net.Server | null = null;
	let previousRuntimeDir: string | undefined;
	let previousSignature: string | undefined;

	beforeEach(() => {
		resetHyprlandCursorStateForTest();
		setLinuxCursorScreenPoint(null);
		getScreen.mockReturnValue({
			getPrimaryDisplay: () => ({ scaleFactor: 1 }),
		});

		previousRuntimeDir = process.env.XDG_RUNTIME_DIR;
		previousSignature = process.env.HYPRLAND_INSTANCE_SIGNATURE;

		runtimeDir = fs.mkdtempSync(path.join(os.tmpdir(), "recordly-hypr-test-"));
		const signature = "test-signature";
		fs.mkdirSync(path.join(runtimeDir, "hypr", signature), { recursive: true });
		socketPath = path.join(runtimeDir, "hypr", signature, ".socket.sock");
		process.env.XDG_RUNTIME_DIR = runtimeDir;
		process.env.HYPRLAND_INSTANCE_SIGNATURE = signature;
	});

	afterEach(() => {
		stopHyprlandCursorPolling();
		resetHyprlandCursorStateForTest();
		server?.close();
		server = null;
		if (previousRuntimeDir === undefined) {
			delete process.env.XDG_RUNTIME_DIR;
		} else {
			process.env.XDG_RUNTIME_DIR = previousRuntimeDir;
		}
		if (previousSignature === undefined) {
			delete process.env.HYPRLAND_INSTANCE_SIGNATURE;
		} else {
			process.env.HYPRLAND_INSTANCE_SIGNATURE = previousSignature;
		}
		fs.rmSync(runtimeDir, { recursive: true, force: true });
	});

	it("detects the socket when the session is Hyprland", () => {
		fs.closeSync(fs.openSync(socketPath, "w"));
		expect(detectHyprlandSocketPath()).toBe(socketPath);
	});

	it("returns null when the socket does not exist", () => {
		expect(detectHyprlandSocketPath()).toBeNull();
	});

	it("returns null without Hyprland env vars", () => {
		delete process.env.HYPRLAND_INSTANCE_SIGNATURE;
		expect(detectHyprlandSocketPath()).toBeNull();
	});

	it("does not start polling without a Hyprland socket", () => {
		expect(startHyprlandCursorPolling()).toBe(false);
	});

	it("feeds the Linux cursor cache from a fake Hyprland IPC socket", async () => {
		server = net.createServer((socket) => {
			socket.on("data", () => {
				socket.end('{"x": 100, "y": 50}');
			});
		});
		await new Promise<void>((resolve) => server?.listen(socketPath, resolve));

		expect(startHyprlandCursorPolling()).toBe(true);
		await waitFor(() => linuxCursorScreenPoint !== null);

		expect(linuxCursorScreenPoint?.x).toBe(100);
		expect(linuxCursorScreenPoint?.y).toBe(50);
	});

	it("scales logical compositor coordinates by the primary scale factor", async () => {
		getScreen.mockReturnValue({
			getPrimaryDisplay: () => ({ scaleFactor: 2 }),
		});

		server = net.createServer((socket) => {
			socket.on("data", () => {
				socket.end('{"x": 100, "y": 50}');
			});
		});
		await new Promise<void>((resolve) => server?.listen(socketPath, resolve));

		expect(startHyprlandCursorPolling()).toBe(true);
		await waitFor(() => linuxCursorScreenPoint !== null);

		expect(linuxCursorScreenPoint?.x).toBe(200);
		expect(linuxCursorScreenPoint?.y).toBe(100);
	});
});
