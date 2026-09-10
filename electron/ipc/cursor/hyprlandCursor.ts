import net from "node:net";
import { statSync } from "node:fs";
import { CURSOR_SAMPLE_INTERVAL_MS } from "../constants";
import { setLinuxCursorScreenPoint } from "../state";
import { getScreen } from "../utils";

/**
 * Cursor polling via the Hyprland compositor IPC socket.
 *
 * On Wayland sessions Electron's `screen.getCursorScreenPoint()` returns
 * (0,0) (Chromium does not implement it on Wayland), and uiohook-napi's X11
 * RECORD hook stays silent whenever the pointer is over native Wayland
 * surfaces — including on Hyprland+Xwayland, because the compositor owns the
 * pointer and never forwards motion through Xwayland.
 *
 * Hyprland exposes the live cursor position through its control socket
 * (`$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket.sock`), where
 * the request `j/cursorpos` replies with `{"x": <logical>, "y": <logical>}`.
 * The coordinates are global and logical (compositor space), matching what
 * normalizeCursorScreenPoint expects after scaling to physical pixels — the
 * same convention the uiohook cache uses.
 */

const HYPR_POLL_FAILURE_LIMIT = 150; // ~5s at 33ms before giving up
const HYPR_POLL_TIMEOUT_MS = 250;
const HYPR_SOCKET_DETECT_TTL_MS = 10_000;

let hyprPollInterval: NodeJS.Timeout | null = null;
let hyprPollInFlight = false;
let hyprPollConsecutiveFailures = 0;
let hyprSocketDetectedAtMs = 0;
let hyprSocketPath: string | null = null;
let hyprLoggedFirstSample = false;

/**
 * Resolves (and caches for {@link HYPR_SOCKET_DETECT_TTL_MS}) the Hyprland
 * control socket path, or null when the session is not Hyprland.
 */
export function detectHyprlandSocketPath(nowMs = Date.now()): string | null {
	if (process.platform !== "linux") {
		return null;
	}

	if (hyprSocketPath && nowMs - hyprSocketDetectedAtMs <= HYPR_SOCKET_DETECT_TTL_MS) {
		return hyprSocketPath;
	}

	hyprSocketPath = null;
	hyprSocketDetectedAtMs = nowMs;

	const signature = process.env.HYPRLAND_INSTANCE_SIGNATURE;
	const runtimeDir = process.env.XDG_RUNTIME_DIR;
	if (!signature || !runtimeDir) {
		return null;
	}

	const candidate = `${runtimeDir}/hypr/${signature}/.socket.sock`;
	try {
		statSync(candidate);
		hyprSocketPath = candidate;
	} catch {
		// Socket does not exist (stale signature, non-Hyprland compositor).
	}

	return hyprSocketPath;
}

/** Test-only: reset all module state between cases. */
export function resetHyprlandCursorStateForTest() {
	stopHyprlandCursorPolling();
	hyprPollInFlight = false;
	hyprPollConsecutiveFailures = 0;
	hyprSocketDetectedAtMs = 0;
	hyprSocketPath = null;
	hyprLoggedFirstSample = false;
}

function pollHyprlandCursor(socketPath: string) {
	if (hyprPollInFlight) {
		return;
	}
	hyprPollInFlight = true;

	let response = "";
	let settled = false;
	const socket = net.connect(socketPath);
	socket.setTimeout(HYPR_POLL_TIMEOUT_MS);

	const finish = (ok: boolean) => {
		if (settled) {
			return;
		}
		settled = true;
		socket.destroy();

		if (ok) {
			hyprPollConsecutiveFailures = 0;
			if (!hyprLoggedFirstSample) {
				hyprLoggedFirstSample = true;
				console.log("[CursorDebug] Hyprland cursor poller: first successful sample");
			}
		} else {
			hyprPollConsecutiveFailures += 1;
			if (hyprPollConsecutiveFailures === HYPR_POLL_FAILURE_LIMIT) {
				console.warn(
					"[CursorTelemetry] Hyprland cursor poller: socket stopped responding, giving up.",
				);
				stopHyprlandCursorPolling();
			}
		}

		hyprPollInFlight = false;
	};

	socket.on("connect", () => {
		// Hyprland matches the request string exactly — no trailing newline.
		socket.write("j/cursorpos");
	});

	socket.on("data", (chunk: Buffer) => {
		response += chunk.toString();
	});

	socket.on("end", () => {
		try {
			const point = JSON.parse(response) as { x?: unknown; y?: unknown };
			const x = Number(point.x);
			const y = Number(point.y);
			if (!Number.isFinite(x) || !Number.isFinite(y)) {
				throw new Error(`malformed cursorpos response: ${response.slice(0, 120)}`);
			}

			// Hyprland reports logical (compositor) coordinates. The
			// linuxCursorScreenPoint cache is consumed as physical pixels
			// (divided by the primary scale factor downstream), matching the
			// X11/uiohook convention — so scale up here to keep one mapping.
			const sf = getPrimaryScaleFactor();
			setLinuxCursorScreenPoint({ x: x * sf, y: y * sf, updatedAt: Date.now() });
			finish(true);
		} catch {
			finish(false);
		}
	});

	const fail = () => finish(false);
	socket.on("timeout", fail);
	socket.on("error", fail);
}

function getPrimaryScaleFactor(): number {
	try {
		return getScreen().getPrimaryDisplay().scaleFactor || 1;
	} catch {
		return 1;
	}
}

/**
 * Starts the Hyprland cursor poller when the session provides a control
 * socket. Returns true when polling was started.
 */
export function startHyprlandCursorPolling(): boolean {
	if (hyprPollInterval) {
		return true;
	}

	const socketPath = detectHyprlandSocketPath();
	if (!socketPath) {
		return false;
	}

	console.log("[CursorDebug] Hyprland cursor poller: started", { socketPath });
	// First sample right away so the cache is warm before the sampler ticks.
	pollHyprlandCursor(socketPath);
	hyprPollInterval = setInterval(() => pollHyprlandCursor(socketPath), CURSOR_SAMPLE_INTERVAL_MS);

	return true;
}

export function stopHyprlandCursorPolling() {
	if (hyprPollInterval) {
		clearInterval(hyprPollInterval);
		hyprPollInterval = null;
	}
}
