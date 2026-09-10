import { EventEmitter } from "node:events";
import { afterEach, describe, expect, it, vi } from "vitest";

vi.mock("electron", () => ({
	app: {
		getPath: vi.fn(() => "/tmp"),
	},
}));

import {
	BTN_LEFT,
	BTN_MIDDLE,
	BTN_RIGHT,
	BTN_TOUCH,
	consumeInputEventBytes,
	EV_KEY,
	listEvdevDevicePaths,
	mapEvdevButtonCode,
	parseInputEvent,
	resetLinuxEvdevClicksForTest,
	startLinuxEvdevClickMonitor,
	stopLinuxEvdevClickMonitor,
} from "./linuxEvdevClicks";
import type { EvdevClickCallbacks } from "./linuxEvdevClicks";

function makeEventBuffer(type: number, code: number, value: number) {
	const buffer = Buffer.alloc(24);
	buffer.writeBigUInt64LE(0n, 0);
	buffer.writeBigUInt64LE(0n, 8);
	buffer.writeUInt16LE(type, 16);
	buffer.writeUInt16LE(code, 18);
	buffer.writeInt32LE(value, 20);
	return buffer;
}

function makeCallbacks(): EvdevClickCallbacks & { downs: Array<1 | 2 | 3>; ups: number } {
	const callbacks = {
		downs: [] as Array<1 | 2 | 3>,
		ups: 0,
		onButtonDown: (button: 1 | 2 | 3) => {
			callbacks.downs.push(button);
		},
		onButtonUp: () => {
			callbacks.ups += 1;
		},
	};
	return callbacks;
}

class FakeEventStream extends EventEmitter {
	destroyed = false;

	destroy() {
		this.destroyed = true;
		this.removeAllListeners("data");
		return this;
	}
}

afterEach(() => {
	resetLinuxEvdevClicksForTest();
	vi.restoreAllMocks();
});

describe("mapEvdevButtonCode", () => {
	it("maps left, right, middle, and touch codes", () => {
		expect(mapEvdevButtonCode(BTN_LEFT)).toBe(1);
		expect(mapEvdevButtonCode(BTN_TOUCH)).toBe(1);
		expect(mapEvdevButtonCode(BTN_RIGHT)).toBe(2);
		expect(mapEvdevButtonCode(BTN_MIDDLE)).toBe(3);
	});

	it("ignores keyboard and unrelated button codes", () => {
		expect(mapEvdevButtonCode(30)).toBeNull();
		expect(mapEvdevButtonCode(0x113)).toBeNull();
		expect(mapEvdevButtonCode(0x100)).toBeNull();
	});
});

describe("parseInputEvent", () => {
	it("reads type, code, and value from a 24-byte event", () => {
		const event = parseInputEvent(makeEventBuffer(EV_KEY, BTN_LEFT, 1));
		expect(event).toEqual({ type: EV_KEY, code: BTN_LEFT, value: 1 });
	});

	it("returns null for truncated buffers", () => {
		expect(parseInputEvent(Buffer.alloc(10))).toBeNull();
	});
});

describe("consumeInputEventBytes", () => {
	it("routes button presses and releases to callbacks", () => {
		const callbacks = makeCallbacks();
		const leftover = consumeInputEventBytes(
			Buffer.concat([
				makeEventBuffer(EV_KEY, BTN_LEFT, 1),
				makeEventBuffer(EV_KEY, BTN_LEFT, 0),
				makeEventBuffer(EV_KEY, BTN_RIGHT, 1),
				makeEventBuffer(EV_KEY, BTN_MIDDLE, 1),
			]),
			Buffer.alloc(0),
			callbacks,
		);

		expect(callbacks.downs).toEqual([1, 2, 3]);
		expect(callbacks.ups).toBe(1);
		expect(leftover.length).toBe(0);
	});

	it("ignores keyboard codes, repeats, and non-key events", () => {
		const callbacks = makeCallbacks();
		consumeInputEventBytes(
			Buffer.concat([
				makeEventBuffer(EV_KEY, 30, 1),
				makeEventBuffer(EV_KEY, BTN_LEFT, 2),
				makeEventBuffer(0x02, 0, 5),
			]),
			Buffer.alloc(0),
			callbacks,
		);

		expect(callbacks.downs).toEqual([]);
		expect(callbacks.ups).toBe(0);
	});

	it("buffers partial events across chunks", () => {
		const callbacks = makeCallbacks();
		const full = makeEventBuffer(EV_KEY, BTN_LEFT, 1);
		const first = consumeInputEventBytes(full.subarray(0, 10), Buffer.alloc(0), callbacks);
		expect(callbacks.downs).toEqual([]);
		expect(first.length).toBe(10);

		const second = consumeInputEventBytes(full.subarray(10), first, callbacks);
		expect(callbacks.downs).toEqual([1]);
		expect(second.length).toBe(0);
	});
});

describe("listEvdevDevicePaths", () => {
	it("keeps only event nodes in numeric order", async () => {
		const paths = await listEvdevDevicePaths(async () => ["mice", "event10", "event2", "js0"]);
		expect(paths).toEqual(["/dev/input/event2", "/dev/input/event10"]);
	});
});

describe("startLinuxEvdevClickMonitor", () => {
	it("opens event nodes and forwards button traffic", async () => {
		const streams = [new FakeEventStream(), new FakeEventStream()];
		const callbacks = makeCallbacks();
		const opened = await startLinuxEvdevClickMonitor(callbacks, {
			readDir: async () => ["event0", "event1"],
			openStream: ((path: string) => {
				return path.endsWith("event0") ? streams[0] : streams[1];
			}) as () => never,
		});

		expect(opened).toBe(true);
		streams[0].emit("data", makeEventBuffer(EV_KEY, BTN_LEFT, 1));
		streams[1].emit("data", makeEventBuffer(EV_KEY, BTN_RIGHT, 0));
		expect(callbacks.downs).toEqual([1]);
		expect(callbacks.ups).toBe(1);

		stopLinuxEvdevClickMonitor();
		expect(streams[0].destroyed).toBe(true);
		expect(streams[1].destroyed).toBe(true);
	});

	it("returns false and warns once when nothing is readable", async () => {
		const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
		const failing = () =>
			startLinuxEvdevClickMonitor(makeCallbacks(), {
				readDir: async () => ["event0"],
				openStream: () => {
					throw Object.assign(new Error("denied"), { code: "EACCES" });
				},
			});

		expect(await failing()).toBe(false);
		expect(await failing()).toBe(false);
		expect(warn).toHaveBeenCalledTimes(1);
	});
});
