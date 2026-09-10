import fs from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import {
	activeCursorSamples,
	hasLoggedInteractionHookFailure,
	interactionCaptureCleanup,
	isCursorCaptureActive,
	lastLeftClick,
	setHasLoggedInteractionHookFailure,
	setInteractionCaptureCleanup,
	setLastLeftClick,
	setLinuxCursorScreenPoint,
} from "../state";
import type {
	CursorInteractionType,
	HookMouseEvent,
	UiohookLike,
	UiohookModuleNamespace,
} from "../types";
import {
	getCursorCaptureElapsedMs,
	getHookCursorScreenPoint,
	getNormalizedCursorPoint,
	isCursorCapturePaused,
	normalizeHookCursorPoint,
	pushCursorSample,
} from "./telemetry";
import {
	startLinuxEvdevClickMonitor,
	stopLinuxEvdevClickMonitor,
} from "./linuxEvdevClicks";

const nodeRequire = createRequire(import.meta.url);

export function normalizeHookMouseButton(rawButton: unknown): 1 | 2 | 3 {
	if (typeof rawButton !== "number" || !Number.isFinite(rawButton)) {
		return 1;
	}

	if (rawButton === 2 || rawButton === 39) {
		return 2;
	}

	if (rawButton === 3 || rawButton === 38) {
		return 3;
	}

	return 1;
}

export function getHookMouseButton(event: HookMouseEvent | null | undefined): 1 | 2 | 3 {
	return normalizeHookMouseButton(
		event?.button ?? event?.mouseButton ?? event?.data?.button ?? event?.data?.mouseButton,
	);
}

export function stopInteractionCapture() {
	if (process.platform === "linux") {
		try {
			stopLinuxEvdevClickMonitor();
		} catch {
			// ignore evdev shutdown errors
		}
	}

	if (interactionCaptureCleanup) {
		interactionCaptureCleanup();
		setInteractionCaptureCleanup(null);
	}
}

function isUiohookLike(value: unknown): value is UiohookLike {
	const candidate = value as Partial<UiohookLike> | null;
	return typeof candidate?.on === "function" && typeof candidate?.start === "function";
}

function resolveUiohookModule(moduleExports: UiohookModuleNamespace) {
	const defaultExport = moduleExports.default;

	if (moduleExports.uIOhook) {
		return moduleExports.uIOhook;
	}

	if (moduleExports.uiohook) {
		return moduleExports.uiohook;
	}

	if (moduleExports.Uiohook) {
		return moduleExports.Uiohook;
	}

	if (isUiohookLike(defaultExport)) {
		return defaultExport;
	}

	if (defaultExport?.uIOhook) {
		return defaultExport.uIOhook;
	}

	if (defaultExport?.uiohook) {
		return defaultExport.uiohook;
	}

	if (defaultExport?.Uiohook) {
		return defaultExport.Uiohook;
	}

	return null;
}

function shouldRepairBundledUiohookBinary(error: unknown): error is NodeJS.ErrnoException {
	if (process.platform !== "darwin") {
		return false;
	}

	if (process.arch !== "arm64") {
		return false;
	}

	const candidate = error as NodeJS.ErrnoException | null;
	return (
		candidate?.code === "ERR_DLOPEN_FAILED" &&
		typeof candidate.message === "string" &&
		candidate.message.includes("incompatible architecture")
	);
}

export function repairBundledUiohookBinaryForCurrentArch(
	error: unknown,
	options?: {
		packageRoot?: string;
		platform?: NodeJS.Platform;
		arch?: string;
		log?: (message: string) => void;
	},
) {
	const platform = options?.platform ?? process.platform;
	const arch = options?.arch ?? process.arch;

	if (platform !== "darwin" || arch !== "arm64") {
		return false;
	}

	const candidate = error as NodeJS.ErrnoException | null;
	if (
		candidate?.code !== "ERR_DLOPEN_FAILED" ||
		typeof candidate.message !== "string" ||
		!candidate.message.includes("incompatible architecture")
	) {
		return false;
	}

	const packageRoot =
		options?.packageRoot ?? path.dirname(nodeRequire.resolve("uiohook-napi/package.json"));
	const prebuildPath = path.join(packageRoot, "prebuilds", `darwin-${arch}`, "node.napi.node");
	const buildPath = path.join(packageRoot, "build", "Release", "uiohook_napi.node");

	if (!fs.existsSync(prebuildPath)) {
		return false;
	}

	try {
		fs.mkdirSync(path.dirname(buildPath), { recursive: true });
		fs.copyFileSync(prebuildPath, buildPath);
		(options?.log ?? console.warn)(
			"[CursorTelemetry] Repaired stale uiohook-napi binary using bundled darwin-arm64 prebuild.",
		);
		return true;
	} catch {
		return false;
	}
}

function loadUiohookModule() {
	try {
		const moduleExports = nodeRequire("uiohook-napi") as UiohookModuleNamespace;
		return resolveUiohookModule(moduleExports);
	} catch (error) {
		if (!shouldRepairBundledUiohookBinary(error)) {
			throw error;
		}

		if (!repairBundledUiohookBinaryForCurrentArch(error)) {
			throw error;
		}

		delete nodeRequire.cache[nodeRequire.resolve("uiohook-napi")];
		const moduleExports = nodeRequire("uiohook-napi") as UiohookModuleNamespace;
		return resolveUiohookModule(moduleExports);
	}
}

export function shouldStartGlobalInteractionHook(platform: NodeJS.Platform = process.platform) {
	// On macOS, uiohook can block forever while its native event tap starts
	// (notably when Accessibility permission is unavailable or stale). Because
	// start() executes synchronously, that freezes Electron's main thread and
	// makes every window, including the recording HUD, unresponsive. Cursor
	// position and visual-state telemetry still come from the existing native
	// macOS monitor and Electron sampler.
	//
	// On Linux, uiohook-napi wraps the blocking X11 RECORD call in a
	// background thread (uv_thread_create) so start() itself returns quickly.
	// On X11 this gives us accurate cursor coordinates that the Electron
	// screen API no longer provides reliably (Chromium 123+ regression). On
	// pure Wayland sessions XOpenDisplay fails and the hook silently produces
	// no events, but that is harmless — the periodic sampler fills in whatever
	// it can and the evdev monitor in linuxEvdevClicks.ts covers clicks.
	return platform !== "darwin";
}

const DUPLICATE_CLICK_WINDOW_MS = 60;
const DUPLICATE_CLICK_MAX_DISTANCE = 0.01;

function isDuplicateInteractionSample(
	cx: number,
	cy: number,
	timeMs: number,
	kind: "click" | "mouseup",
) {
	const last = activeCursorSamples[activeCursorSamples.length - 1];
	if (!last || typeof last.timeMs !== "number" || timeMs - last.timeMs > DUPLICATE_CLICK_WINDOW_MS) {
		return false;
	}

	if (Math.hypot(cx - last.cx, cy - last.cy) > DUPLICATE_CLICK_MAX_DISTANCE) {
		return false;
	}

	if (kind === "mouseup") {
		return last.interactionType === "mouseup";
	}

	return (
		last.interactionType === "click" ||
		last.interactionType === "double-click" ||
		last.interactionType === "right-click" ||
		last.interactionType === "middle-click"
	);
}

export function recordCursorMouseDown(button: 1 | 2 | 3) {
	console.log("[CursorDebug] recordCursorMouseDown: button =", button, "isActive =", isCursorCaptureActive, "isPaused =", isCursorCapturePaused());
	if (!isCursorCaptureActive || isCursorCapturePaused()) {
		return;
	}

	const point = getNormalizedCursorPoint();
	if (!point) {
		return;
	}

	const timeMs = getCursorCaptureElapsedMs();
	if (isDuplicateInteractionSample(point.cx, point.cy, timeMs, "click")) {
		return;
	}
	let interactionType: CursorInteractionType = "click";

	if (button === 2) {
		interactionType = "right-click";
	} else if (button === 3) {
		interactionType = "middle-click";
	} else {
		const thresholdMs = 350;
		const distance = lastLeftClick
			? Math.hypot(point.cx - lastLeftClick.cx, point.cy - lastLeftClick.cy)
			: Number.POSITIVE_INFINITY;

		if (lastLeftClick && timeMs - lastLeftClick.timeMs <= thresholdMs && distance <= 0.04) {
			interactionType = "double-click";
		}

		setLastLeftClick({ timeMs, cx: point.cx, cy: point.cy });
	}

	pushCursorSample(point.cx, point.cy, timeMs, interactionType);
}

export function recordCursorMouseUp() {
	console.log("[CursorDebug] recordCursorMouseUp: isActive =", isCursorCaptureActive, "isPaused =", isCursorCapturePaused());
	if (!isCursorCaptureActive || isCursorCapturePaused()) {
		return;
	}

	const point = getNormalizedCursorPoint();
	if (!point) {
		return;
	}

	const timeMs = getCursorCaptureElapsedMs();
	if (isDuplicateInteractionSample(point.cx, point.cy, timeMs, "mouseup")) {
		return;
	}

	pushCursorSample(point.cx, point.cy, timeMs, "mouseup");
}

export async function startInteractionCapture() {
	console.log("[CursorDebug] startInteractionCapture called:", {
		platform: process.platform,
		isActive: isCursorCaptureActive,
		shouldStart: shouldStartGlobalInteractionHook(),
	});

	if (!isCursorCaptureActive) {
		console.log("[CursorDebug] startInteractionCapture: skipped (not active)");
		return;
	}

	if (!["darwin", "win32", "linux"].includes(process.platform)) {
		console.log("[CursorDebug] startInteractionCapture: skipped (unsupported platform)");
		return;
	}

	if (!shouldStartGlobalInteractionHook()) {
		console.warn("[CursorTelemetry] Skipping the blocking global interaction hook on macOS.");
		return;
	}

	stopInteractionCapture();

	try {
		const hook = loadUiohookModule();
		console.log(
			"[CursorTelemetry] hook loaded:",
			!!hook,
			"has.on:",
			typeof hook?.on,
			"has.start:",
			typeof hook?.start,
		);
		if (!isCursorCaptureActive) {
			return;
		}

		if (!hook || typeof hook.on !== "function" || typeof hook.start !== "function") {
			console.log("[CursorTelemetry] hook unusable — aborting interaction capture");
			return;
		}

		const onMouseDown = (event: HookMouseEvent) => {
			recordCursorMouseDown(getHookMouseButton(event));
		};

		const onMouseUp = () => {
			recordCursorMouseUp();
		};

		let mouseMoveCount = 0;

		const onMouseMove = (event: HookMouseEvent) => {
			if (!isCursorCaptureActive || isCursorCapturePaused()) {
				return;
			}

			const rawPoint = getHookCursorScreenPoint(event);
			if (!rawPoint) {
				return;
			}

			// Normalize directly from the uiohook event coordinates instead of
			// calling getNormalizedCursorPoint(), which relies on Electron's
			// screen.getCursorScreenPoint() — broken on Wayland (returns 0,0)
			// and unreliable on X11 since Chromium 123.
			const point = normalizeHookCursorPoint(rawPoint.x, rawPoint.y);
			pushCursorSample(point.cx, point.cy, getCursorCaptureElapsedMs(), "move");

			mouseMoveCount++;
			if (mouseMoveCount <= 3 || mouseMoveCount % 200 === 0) {
				console.log(`[CursorDebug] onMouseMove #${mouseMoveCount}: raw=(${rawPoint.x}, ${rawPoint.y}) normalized=(${point.cx.toFixed(4)}, ${point.cy.toFixed(4)})`);
			}

			// Also keep the Linux cache fresh so the periodic sampler
			// (getNormalizedCursorPoint) benefits between mousemove events.
			if (process.platform === "linux") {
				setLinuxCursorScreenPoint({ x: rawPoint.x, y: rawPoint.y, updatedAt: Date.now() });
			}
		};

		hook.on("mousedown", onMouseDown);
		hook.on("mouseup", onMouseUp);
		hook.on("mousemove", onMouseMove);

		console.log("[CursorDebug] startInteractionCapture: hook listeners registered, calling hook.start()");

		setInteractionCaptureCleanup(() => {
			try {
				if (typeof hook.off === "function") {
					hook.off("mousedown", onMouseDown);
					hook.off("mouseup", onMouseUp);
					hook.off("mousemove", onMouseMove);
				} else if (typeof hook.removeListener === "function") {
					hook.removeListener("mousedown", onMouseDown);
					hook.removeListener("mouseup", onMouseUp);
					hook.removeListener("mousemove", onMouseMove);
				}
			} catch {
				// ignore listener cleanup errors
			}

			try {
				if (typeof hook.stop === "function") {
					hook.stop();
				}
			} catch {
				// ignore hook shutdown errors
			}
		});

		hook.start();
		console.log("[CursorDebug] startInteractionCapture: hook.start() returned successfully");
	} catch (error) {
		console.error("[CursorDebug] startInteractionCapture: hook.start() threw error:", error);
		if (!hasLoggedInteractionHookFailure) {
			setHasLoggedInteractionHookFailure(true);
			console.warn("[CursorTelemetry] Global interaction capture unavailable:", error);
		}
	}

	// On Linux the X11 hook stays silent over native Wayland surfaces, so
	// complement it with kernel evdev button events. Both sources feed the
	// same record functions; cross-source duplicates for one physical click
	// are merged by the duplicate-sample guard above.
	if (process.platform === "linux" && isCursorCaptureActive) {
		try {
			await startLinuxEvdevClickMonitor({
				onButtonDown: recordCursorMouseDown,
				onButtonUp: recordCursorMouseUp,
			});
		} catch (error) {
			console.warn("[CursorTelemetry] Linux evdev click capture unavailable:", error);
		}
	}
}
