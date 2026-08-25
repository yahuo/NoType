import { randomUUID } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createConnection } from "node:net";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const PROTOCOL_VERSION = 1;
const MAXIMUM_FRAME_BYTES = 1_048_576;
const TRIGGER_WINDOW_MS = 1_000;
const MINIMUM_SPACE_INTERVAL_MS = 45;
const STATUS_KEY = "notype-translation";

type BridgeResponse = {
	version: number;
	id: string;
	ok: boolean;
	text?: string;
	error?: {
		code: string;
		message: string;
	};
};

function socketPath(): string {
	return process.env.NOTYPE_BRIDGE_SOCKET ?? join(tmpdir(), "com.opensource.notype", "bridge.sock");
}

function translateThroughNoType(text: string): Promise<string> {
	const id = randomUUID();
	const payload = Buffer.from(
		JSON.stringify({
			version: PROTOCOL_VERSION,
			id,
			method: "translate",
			client: "pi",
			text,
		}),
		"utf8",
	);

	if (payload.length > MAXIMUM_FRAME_BYTES) {
		return Promise.reject(new Error("The Pi draft is too large for the NoType bridge."));
	}

	const frame = Buffer.allocUnsafe(4 + payload.length);
	frame.writeUInt32BE(payload.length, 0);
	payload.copy(frame, 4);

	return new Promise((resolve, reject) => {
		const socket = createConnection({ path: socketPath() });
		let buffered = Buffer.alloc(0);
		let expectedPayloadBytes: number | undefined;
		let settled = false;

		const finish = (error?: Error, translated?: string) => {
			if (settled) return;
			settled = true;
			socket.destroy();
			if (error) reject(error);
			else resolve(translated ?? "");
		};

		socket.setTimeout(15_000);
		socket.once("connect", () => socket.write(frame));
		socket.once("timeout", () => finish(new Error("NoType translation timed out.")));
		socket.once("error", (error) => finish(error));
		socket.once("close", () => {
			if (!settled) finish(new Error("NoType closed the bridge before returning a response."));
		});
		socket.on("data", (chunk) => {
			if (settled) return;
			buffered = Buffer.concat([buffered, chunk]);

			if (expectedPayloadBytes === undefined && buffered.length >= 4) {
				expectedPayloadBytes = buffered.readUInt32BE(0);
				if (expectedPayloadBytes === 0 || expectedPayloadBytes > MAXIMUM_FRAME_BYTES) {
					finish(new Error(`NoType returned an invalid frame length: ${expectedPayloadBytes}.`));
					return;
				}
			}

			if (expectedPayloadBytes === undefined || buffered.length < 4 + expectedPayloadBytes) return;

			try {
				const response = JSON.parse(buffered.subarray(4, 4 + expectedPayloadBytes).toString("utf8")) as BridgeResponse;
				if (response.version !== PROTOCOL_VERSION || response.id !== id) {
					finish(new Error("NoType returned a response for a different bridge request."));
					return;
				}
				if (!response.ok) {
					finish(new Error(response.error?.message ?? "NoType translation failed."));
					return;
				}
				if (!response.text?.trim()) {
					finish(new Error("NoType returned an empty translation."));
					return;
				}
				finish(undefined, response.text);
			} catch (error) {
				finish(error instanceof Error ? error : new Error(String(error)));
			}
		});
	});
}

export default function (pi: ExtensionAPI) {
	let unsubscribeTerminalInput: (() => void) | undefined;
	let firstSpaceTimestamp: number | undefined;
	let lastSpaceTimestamp: number | undefined;
	let spaceCount = 0;
	let translationGeneration = 0;
	let translationInFlight = false;

	const resetTrigger = () => {
		firstSpaceTimestamp = undefined;
		lastSpaceTimestamp = undefined;
		spaceCount = 0;
	};

	const translateCurrentDraft = async (ctx: ExtensionContext) => {
		const currentText = ctx.ui.getEditorText();
		if (!currentText.endsWith("   ")) return;

		const sourceText = currentText.slice(0, -3);
		if (!sourceText.trim()) return;

		// Remove the trigger immediately. If the request fails, the user's source remains intact.
		ctx.ui.setEditorText(sourceText);

		if (translationInFlight) {
			ctx.ui.notify("NoType is already translating another Pi draft.", "warning");
			return;
		}

		translationInFlight = true;
		const generation = ++translationGeneration;
		ctx.ui.setStatus(STATUS_KEY, ctx.ui.theme.fg("accent", "NoType: translating…"));

		try {
			const translated = await translateThroughNoType(sourceText);
			if (generation !== translationGeneration) return;

			if (ctx.ui.getEditorText() !== sourceText) {
				ctx.ui.notify("NoType finished, but the Pi draft changed, so it was not overwritten.", "warning");
				return;
			}

			ctx.ui.setEditorText(translated);
		} catch (error) {
			if (generation !== translationGeneration) return;
			ctx.ui.notify(error instanceof Error ? error.message : String(error), "error");
		} finally {
			if (generation === translationGeneration) {
				translationInFlight = false;
				ctx.ui.setStatus(STATUS_KEY, undefined);
			}
		}
	};

	pi.on("session_start", (_event, ctx) => {
		unsubscribeTerminalInput?.();
		resetTrigger();

		if (ctx.mode !== "tui") return;

		unsubscribeTerminalInput = ctx.ui.onTerminalInput((data) => {
			if (data !== " ") {
				resetTrigger();
				return;
			}

			const now = performance.now();
			if (
				lastSpaceTimestamp !== undefined &&
				now >= lastSpaceTimestamp &&
				now - lastSpaceTimestamp < MINIMUM_SPACE_INTERVAL_MS
			) {
				// Pi does not expose the terminal key-repeat flag. Reject intervals typical
				// of auto-repeat so holding Space cannot trigger a translation.
				resetTrigger();
				return;
			}

			if (
				firstSpaceTimestamp === undefined ||
				now < firstSpaceTimestamp ||
				now - firstSpaceTimestamp > TRIGGER_WINDOW_MS
			) {
				firstSpaceTimestamp = now;
				spaceCount = 1;
			} else {
				spaceCount += 1;
			}
			lastSpaceTimestamp = now;

			if (spaceCount === 3) {
				resetTrigger();
				// Terminal listeners run before the focused editor. Defer until Pi has inserted
				// the third space, then verify the complete draft before changing anything.
				queueMicrotask(() => void translateCurrentDraft(ctx));
			}
		});
	});

	pi.on("session_shutdown", (_event, ctx) => {
		translationGeneration += 1;
		translationInFlight = false;
		resetTrigger();
		unsubscribeTerminalInput?.();
		unsubscribeTerminalInput = undefined;
		ctx.ui.setStatus(STATUS_KEY, undefined);
	});
}
