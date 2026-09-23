import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { createServer } from "node:net";
import { test } from "node:test";
import notype from "../notype.ts";

async function harness(t, source = "请检查这段代码") {
	const socketPath = `/tmp/notype-pi-test-${randomUUID().slice(0, 8)}.sock`;
	const previousSocket = process.env.NOTYPE_BRIDGE_SOCKET;
	process.env.NOTYPE_BRIDGE_SOCKET = socketPath;
	const sockets = new Set();
	let receiveRequest;
	const requestReceived = new Promise((resolve) => { receiveRequest = resolve; });
	const server = createServer((socket) => {
		sockets.add(socket);
		socket.on("close", () => sockets.delete(socket));
		let buffered = Buffer.alloc(0);
		socket.on("data", (chunk) => {
			buffered = Buffer.concat([buffered, chunk]);
			if (buffered.length < 4 || buffered.length < 4 + buffered.readUInt32BE(0)) return;
			receiveRequest({ socket, request: JSON.parse(buffered.subarray(4).toString()) });
		});
	});
	await new Promise((resolve) => server.listen(socketPath, resolve));
	t.after(async () => {
		for (const socket of sockets) socket.destroy();
		await new Promise((resolve) => server.close(resolve));
		if (previousSocket === undefined) delete process.env.NOTYPE_BRIDGE_SOCKET;
		else process.env.NOTYPE_BRIDGE_SOCKET = previousSocket;
	});

	let text = source;
	let terminalInput;
	let finish;
	const completed = new Promise((resolve) => { finish = resolve; });
	const notifications = [];
	const handlers = {};
	const ctx = {
		mode: "tui",
		ui: {
			getEditorText: () => text,
			setEditorText: (value) => { text = value; },
			setStatus: (_key, value) => { if (value === undefined) finish(); },
			theme: { fg: (_color, value) => value },
			notify: (message, level) => notifications.push({ message, level }),
			onTerminalInput: (handler) => { terminalInput = handler; return () => {}; },
		},
	};
	notype({ on: (event, handler) => { handlers[event] = handler; } });
	handlers.session_start({}, ctx);
	// Pi dispatches terminal listeners before inserting the same chunk in its editor.
	terminalInput("   ");
	text += "   ";
	const { socket, request } = await requestReceived;
	assert.equal(request.text, source);
	assert.equal(text, source);

	return {
		get text() { return text; },
		set text(value) { text = value; },
		notifications,
		input(data) {
			terminalInput(data);
			text += data;
		},
		async respond() {
			const payload = Buffer.from(JSON.stringify({ version: 1, id: request.id, ok: true, text: "Please review this code." }));
			const header = Buffer.alloc(4);
			header.writeUInt32BE(payload.length);
			socket.end(Buffer.concat([header, payload]));
			await completed;
		},
	};
}

test("three spaces replace an unchanged Pi draft", async (t) => {
	const h = await harness(t);
	await h.respond();
	assert.equal(h.text, "Please review this code.");
	assert.deepEqual(h.notifications, []);
});

for (const spaces of [" ", "  ", "   "]) {
	test(`extra ${spaces.length} trailing spaces preserve the translation and spacing`, async (t) => {
		const h = await harness(t);
		h.input(spaces);
		await h.respond();
		assert.equal(h.text, "Please review this code." + spaces);
		assert.deepEqual(h.notifications, []);
	});
}

for (const changedDraft of ["请检查这段代码，还要补测试", "请检查其他代码", "请检查这段代码\n", ""]) {
	test(`a changed or submitted Pi draft is not overwritten: ${JSON.stringify(changedDraft)}`, async (t) => {
		const h = await harness(t);
		h.text = changedDraft;
		await h.respond();
		assert.equal(h.text, changedDraft);
		assert.equal(h.notifications[0]?.level, "warning");
	});
}
