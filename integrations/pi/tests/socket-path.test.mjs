import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { join } from "node:path";
import { test } from "node:test";
import notype, { socketPath } from "../notype.ts";

function environment(t, values) {
	for (const [key, value] of Object.entries(values)) {
		const previous = process.env[key];
		if (value === undefined) delete process.env[key];
		else process.env[key] = value;
		t.after(() => {
			if (previous === undefined) delete process.env[key];
			else process.env[key] = previous;
		});
	}
}

test("an explicit socket override takes priority over temporary directories", async (t) => {
	environment(t, { NOTYPE_BRIDGE_SOCKET: "/tmp/forwarded-notype.sock", TMPDIR: "/tmp/stale" });
	assert.equal(await socketPath(), "/tmp/forwarded-notype.sock");
});

for (const temporaryDirectory of ["/tmp/notype-stale-user", undefined]) {
	test(`macOS resolves its user directory with TMPDIR=${temporaryDirectory}`, {
		skip: process.platform !== "darwin",
	}, async (t) => {
		const expected = join(execFileSync("/usr/bin/getconf", ["DARWIN_USER_TEMP_DIR"], { encoding: "utf8" }).trim(),
			"com.opensource.notype", "bridge.sock");
		environment(t, { NOTYPE_BRIDGE_SOCKET: undefined, TMPDIR: temporaryDirectory });
		assert.equal(await socketPath(), expected);
	});
}

test("a missing bridge preserves the source and explains how to reconnect", { timeout: 5_000 }, async (t) => {
	environment(t, { NOTYPE_BRIDGE_SOCKET: `/tmp/notype-missing-${randomUUID()}.sock` });
	let text = "请检查这段代码";
	let input;
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
			onTerminalInput: (handler) => { input = handler; return () => {}; },
		},
	};
	notype({ on: (event, handler) => { handlers[event] = handler; } });
	handlers.session_start({}, ctx);
	input("   ");
	text += "   ";
	await completed;
	assert.equal(text, "请检查这段代码");
	assert.equal(notifications.length, 1);
	assert.equal(notifications[0].level, "error");
	assert.match(notifications[0].message, /Open NoType.*ENOENT/);
	handlers.session_shutdown({}, ctx);
});
