import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("electron", () => ({
	app: {
		getPath: vi.fn(() => "/tmp"),
		setPath: vi.fn(),
		isReady: vi.fn(() => true),
	},
}));

import {
	activeCursorSamples,
	setActiveCursorSamples,
	setCursorCaptureStartTimeMs,
	setIsCursorCaptureActive,
	setLastLeftClick,
} from "../state";
import {
	recordCursorMouseDown,
	recordCursorMouseUp,
	repairBundledUiohookBinaryForCurrentArch,
	shouldStartGlobalInteractionHook,
} from "./interaction";

vi.mock("../utils", () => ({
	getScreen: vi.fn(() => ({
		getCursorScreenPoint: () => ({ x: 0, y: 0 }),
		getPrimaryDisplay: () => ({ scaleFactor: 1 }),
		getDisplayNearestPoint: () => ({ bounds: { x: 0, y: 0, width: 100, height: 100 } }),
		getAllDisplays: () => [],
	})),
	getTelemetryPathForVideo: vi.fn(),
}));

describe("shouldStartGlobalInteractionHook", () => {
	it("does not start the synchronous uiohook event tap on macOS", () => {
		expect(shouldStartGlobalInteractionHook("darwin")).toBe(false);
	});

	it("keeps global interaction capture enabled on Windows and Linux", () => {
		expect(shouldStartGlobalInteractionHook("win32")).toBe(true);
		expect(shouldStartGlobalInteractionHook("linux")).toBe(true);
	});
});

describe("recordCursorMouseDown / recordCursorMouseUp", () => {
	beforeEach(() => {
		setIsCursorCaptureActive(true);
		setCursorCaptureStartTimeMs(Date.now() - 1_000);
		setActiveCursorSamples([]);
		setLastLeftClick(null);
	});

	afterEach(() => {
		setIsCursorCaptureActive(false);
		setActiveCursorSamples([]);
		setLastLeftClick(null);
	});

	it("merges duplicate reports of one physical click from two sources", () => {
		recordCursorMouseDown(1);
		recordCursorMouseDown(1);

		expect(activeCursorSamples.filter((sample) => sample.interactionType === "click")).toHaveLength(1);
	});

	it("merges duplicate mouseup reports", () => {
		recordCursorMouseUp();
		recordCursorMouseUp();

		expect(activeCursorSamples.filter((sample) => sample.interactionType === "mouseup")).toHaveLength(1);
	});

	it("keeps the click and its release as separate samples", () => {
		recordCursorMouseDown(1);
		recordCursorMouseUp();

		expect(activeCursorSamples.map((sample) => sample.interactionType)).toEqual([
			"click",
			"mouseup",
		]);
	});
});

describe("repairBundledUiohookBinaryForCurrentArch", () => {
	const tempRoots: string[] = [];

	afterEach(async () => {
		await Promise.all(
			tempRoots
				.splice(0)
				.map((tempRoot) => fs.rm(tempRoot, { recursive: true, force: true })),
		);
	});

	it("promotes the bundled darwin-arm64 prebuild over a stale incompatible build", async () => {
		const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), "recordly-uiohook-"));
		tempRoots.push(tempRoot);

		const packageRoot = path.join(tempRoot, "uiohook-napi");
		const prebuildPath = path.join(packageRoot, "prebuilds", "darwin-arm64", "node.napi.node");
		const buildPath = path.join(packageRoot, "build", "Release", "uiohook_napi.node");
		await fs.mkdir(path.dirname(prebuildPath), { recursive: true });
		await fs.mkdir(path.dirname(buildPath), { recursive: true });
		await fs.writeFile(prebuildPath, "arm64-prebuild");
		await fs.writeFile(buildPath, "x64-build");

		const log = vi.fn();
		const repaired = repairBundledUiohookBinaryForCurrentArch(
			Object.assign(
				new Error(
					"mach-o file, but is an incompatible architecture (have 'x86_64', need 'arm64')",
				),
				{
					code: "ERR_DLOPEN_FAILED",
				},
			),
			{ packageRoot, platform: "darwin", arch: "arm64", log },
		);

		expect(repaired).toBe(true);
		expect(await fs.readFile(buildPath, "utf8")).toBe("arm64-prebuild");
		expect(log).toHaveBeenCalledWith(
			"[CursorTelemetry] Repaired stale uiohook-napi binary using bundled darwin-arm64 prebuild.",
		);
	});

	it("does not rewrite binaries for unrelated load failures", async () => {
		const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), "recordly-uiohook-"));
		tempRoots.push(tempRoot);

		const packageRoot = path.join(tempRoot, "uiohook-napi");
		const buildPath = path.join(packageRoot, "build", "Release", "uiohook_napi.node");
		await fs.mkdir(path.dirname(buildPath), { recursive: true });
		await fs.writeFile(buildPath, "existing-build");

		const repaired = repairBundledUiohookBinaryForCurrentArch(
			Object.assign(new Error("some other dlopen failure"), {
				code: "ERR_DLOPEN_FAILED",
			}),
			{ packageRoot, platform: "darwin", arch: "arm64" },
		);

		expect(repaired).toBe(false);
		expect(await fs.readFile(buildPath, "utf8")).toBe("existing-build");
	});
});
