import { createReadStream } from "node:fs";
import type { ReadStream } from "node:fs";
import { readdir } from "node:fs/promises";
import os from "node:os";

/**
 * Linux evdev mouse-button monitor.
 *
 * uiohook-napi captures clicks through X11 RECORD, which stays silent over
 * native Wayland surfaces (Hyprland, GNOME/KDE Wayland, …) — the compositor
 * owns the pointer and never forwards button events through Xwayland. The
 * periodic cursor sampler keeps movement working there, but clicks never
 * arrive, so click animations and zoom suggestions silently do nothing.
 *
 * The kernel evdev interface reports button presses for every pointer
 * regardless of display protocol. Reading `/dev/input/event*` is passive
 * (no grab, no interference) and needs no new dependencies — but it does
 * need read access to the device nodes (usually the `input` group).
 * When no node is readable we warn once with an actionable hint and let
 * movement telemetry continue; uiohook remains the source on X11.
 */

export const EV_KEY = 0x01;
export const BTN_LEFT = 0x110;
export const BTN_RIGHT = 0x111;
export const BTN_MIDDLE = 0x112;
export const BTN_TOUCH = 0x14a;

const INPUT_EVENT_SIZE_64_BIT = 24;
const INPUT_EVENT_TYPE_OFFSET = 16;
const INPUT_EVENT_CODE_OFFSET = 18;
const INPUT_EVENT_VALUE_OFFSET = 20;

export interface EvdevClickCallbacks {
	onButtonDown: (button: 1 | 2 | 3) => void;
	onButtonUp: () => void;
}

interface OpenEvdevDevice {
	path: string;
	stream: ReadStream;
	leftover: Buffer;
}

let openDevices: OpenEvdevDevice[] = [];
let activeCallbacks: EvdevClickCallbacks | null = null;
let hasLoggedEvdevWarning = false;

export function mapEvdevButtonCode(code: number): 1 | 2 | 3 | null {
	switch (code) {
		case BTN_LEFT:
		case BTN_TOUCH:
			return 1;
		case BTN_RIGHT:
			return 2;
		case BTN_MIDDLE:
			return 3;
		default:
			return null;
	}
}

export function parseInputEvent(
	buffer: Buffer,
	offset = 0,
): { type: number; code: number; value: number } | null {
	if (buffer.length - offset < INPUT_EVENT_SIZE_64_BIT) {
		return null;
	}

	return {
		type: buffer.readUInt16LE(offset + INPUT_EVENT_TYPE_OFFSET),
		code: buffer.readUInt16LE(offset + INPUT_EVENT_CODE_OFFSET),
		value: buffer.readInt32LE(offset + INPUT_EVENT_VALUE_OFFSET),
	};
}

export function consumeInputEventBytes(
	chunk: Buffer,
	leftover: Buffer,
	callbacks: EvdevClickCallbacks,
): Buffer {
	const pending = leftover.length > 0 ? Buffer.concat([leftover, chunk]) : chunk;
	let offset = 0;

	while (pending.length - offset >= INPUT_EVENT_SIZE_64_BIT) {
		const event = parseInputEvent(pending, offset);
		offset += INPUT_EVENT_SIZE_64_BIT;
		if (!event || event.type !== EV_KEY) {
			continue;
		}

		if (event.value === 1) {
			const button = mapEvdevButtonCode(event.code);
			if (button !== null) {
				callbacks.onButtonDown(button);
			}
		} else if (event.value === 0) {
			if (mapEvdevButtonCode(event.code) !== null) {
				callbacks.onButtonUp();
			}
		}
	}

	return offset < pending.length ? pending.subarray(offset) : Buffer.alloc(0);
}

function warnEvdevUnavailable(reason: string) {
	if (hasLoggedEvdevWarning) {
		return;
	}
	hasLoggedEvdevWarning = true;

	let userHint = "";
	try {
		const username = os.userInfo().username;
		if (username) {
			userHint = ` NixOS: users.users."${username}".extraGroups = [ "input" ]; then re-login.`;
		}
	} catch {
		// username is best-effort only
	}

	console.warn(
		`[CursorTelemetry] Linux click capture unavailable (${reason}). ` +
			`Cursor movement still works. To enable click effects, give Recordly read access to /dev/input/event*.${userHint}`,
	);
}

export async function listEvdevDevicePaths(
	readDir: (path: string) => Promise<string[]> = readdir,
): Promise<string[]> {
	const entries = await readDir("/dev/input");
	return entries
		.filter((entry) => /^event\d+$/.test(entry))
		.sort((left, right) => Number(left.slice(5)) - Number(right.slice(5)))
		.map((entry) => `/dev/input/${entry}`);
}

export async function startLinuxEvdevClickMonitor(
	callbacks: EvdevClickCallbacks,
	deps?: {
		readDir?: (path: string) => Promise<string[]>;
		openStream?: (path: string) => ReadStream;
	},
): Promise<boolean> {
	if (process.platform !== "linux") {
		return false;
	}

	if (openDevices.length > 0) {
		activeCallbacks = callbacks;
		for (const device of openDevices) {
			device.stream.removeAllListeners("data");
			device.stream.on("data", (chunk: Buffer) => {
				device.leftover = consumeInputEventBytes(
					Buffer.from(chunk),
					device.leftover,
					callbacks,
				);
			});
		}
		return true;
	}

	const readDir = deps?.readDir ?? readdir;
	const openStream = deps?.openStream ?? ((path: string) => createReadStream(path));

	let devicePaths: string[];
	try {
		devicePaths = await listEvdevDevicePaths(readDir);
	} catch (error) {
		warnEvdevUnavailable(error instanceof Error ? error.message : String(error));
		return false;
	}

	if (devicePaths.length === 0) {
		warnEvdevUnavailable("no event devices found");
		return false;
	}

	activeCallbacks = callbacks;
	let permissionDenied = false;

	for (const devicePath of devicePaths) {
		let stream: ReadStream;
		try {
			stream = openStream(devicePath);
		} catch (error) {
			if ((error as NodeJS.ErrnoException)?.code === "EACCES") {
				permissionDenied = true;
			}
			continue;
		}

		const device: OpenEvdevDevice = { path: devicePath, stream, leftover: Buffer.alloc(0) };
		stream.on("data", (chunk: Buffer) => {
			if (!activeCallbacks) {
				return;
			}
			device.leftover = consumeInputEventBytes(
				Buffer.from(chunk),
				device.leftover,
				activeCallbacks,
			);
		});
		stream.on("error", (error: Error) => {
			if ((error as NodeJS.ErrnoException)?.code === "EACCES") {
				permissionDenied = true;
			}
			stream.destroy();
			openDevices = openDevices.filter((open) => open !== device);
		});
		openDevices.push(device);
	}

	// Streams report EACCES asynchronously via 'error'; give them a tick to
	// fail before deciding whether any device is usable.
	await new Promise((resolve) => setTimeout(resolve, 50));
	openDevices = openDevices.filter((device) => !device.stream.destroyed);

	if (openDevices.length === 0) {
		warnEvdevUnavailable(permissionDenied ? "permission denied" : "no readable event devices");
		return false;
	}

	return true;
}

export function stopLinuxEvdevClickMonitor() {
	activeCallbacks = null;
	for (const device of openDevices) {
		try {
			device.stream.removeAllListeners("data");
			device.stream.destroy();
		} catch {
			// ignore shutdown errors
		}
	}
	openDevices = [];
}

/** Test-only: reset module state between cases. */
export function resetLinuxEvdevClicksForTest() {
	stopLinuxEvdevClickMonitor();
	hasLoggedEvdevWarning = false;
}
