import io
import json
import os
import socket
import subprocess
import select
from unittest.mock import patch
import struct
import sys
import tempfile
import threading
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import native_host
import install


class NativeHostTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "darwin", "macOS runtime directory")
    def test_default_socket_uses_existing_macos_user_temp_directory(self):
        path = native_host.bridge_socket()
        self.assertTrue(path.is_absolute())
        self.assertTrue(path.parent.parent.is_dir())
        self.assertEqual(path.parts[-2:], ("com.opensource.notype", "bridge.sock"))

    def request(self):
        return {"version": 1, "id": "paragraph-1", "method": "translate_chinese", "text": "Hello 世界"}

    def test_fragmented_native_frame_and_unicode(self):
        payload = native_host.encode_frame(self.request(), "=")
        self.assertEqual(struct.unpack("=I", payload[:4])[0], len(payload) - 4)
        stream = io.BytesIO(payload)
        self.assertEqual(native_host.read_frame(lambda n: stream.read(min(n, 2)), "="), self.request())

    def test_invalid_and_truncated_frames(self):
        for length in (0, native_host.MAX_FRAME + 1):
            with self.assertRaises(ValueError):
                native_host.read_frame(io.BytesIO(struct.pack("=I", length)).read, "=")
        with self.assertRaises(EOFError):
            native_host.read_frame(io.BytesIO(b"\x04\x00\x00\x00{}").read, "=")

    def test_socket_round_trip_and_method_restriction(self):
        with tempfile.TemporaryDirectory(prefix="nt-", dir="/tmp") as directory:
            path = Path(directory) / "b.sock"
            received = []
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(str(path))
                server.listen(1)
                server.settimeout(3)

                def reply():
                    connection, _ = server.accept()
                    with connection:
                        request = native_host.read_frame(connection.recv, ">")
                        received.append(request)
                        response = native_host.encode_frame({
                            "version": 1, "id": request["id"], "ok": True, "text": "你好，世界",
                        }, ">")
                        for byte in response:
                            connection.sendall(bytes([byte]))

                thread = threading.Thread(target=reply)
                thread.start()
                result = native_host.translate(self.request(), path)
                thread.join(4)
                self.assertFalse(thread.is_alive())
            self.assertEqual(result["text"], "你好，世界")
            self.assertEqual(received[0], {**self.request(), "client": "browser", "keepAlive": True})
            self.assertFalse(native_host.translate({**self.request(), "method": "translate_editor"}, path)["ok"])

    def test_process_reuses_socket_for_100_batches_then_cancels(self):
        with tempfile.TemporaryDirectory(prefix="nt-reuse-", dir="/tmp") as directory:
            path = Path(directory) / "b.sock"
            received = []
            cancelled = threading.Event()
            errors = []
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(str(path))
                server.listen(1)
                server.settimeout(3)
                def reply():
                    try:
                        connection, _ = server.accept()
                        with connection:
                            connection.settimeout(3)
                            for index in range(101):
                                request = native_host.read_frame(connection.recv, ">")
                                received.append(request)
                                partial = native_host.encode_frame({"version": 1, "id": request["id"], "ok": True,
                                    "partial": True, "text": "译文"}, ">")
                                if index == 100:
                                    connection.sendall(partial)
                                    if connection.recv(1) == b"": cancelled.set()
                                    return
                                final = native_host.encode_frame({"version": 1, "id": request["id"], "ok": True,
                                    "items": [{"id": "p0", "text": "你好"}]}, ">")
                                # Deliberately coalesce responses, with a split header.
                                connection.sendall(partial[:2])
                                connection.sendall(partial[2:] + final)
                    except Exception as error:
                        errors.append(error)
                thread = threading.Thread(target=reply)
                thread.start()
                script = ("import native_host; from pathlib import Path; "
                          "native_host.bridge_socket=lambda:Path(" + repr(str(path)) + "); "
                          "native_host.configure_logging=lambda:None; native_host.main()")
                process = subprocess.Popen([sys.executable, "-c", script], cwd=Path(native_host.__file__).parent,
                                           stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                def read(count):
                    if not select.select([process.stdout], [], [], 3)[0]:
                        raise TimeoutError("native process stalled")
                    return os.read(process.stdout.fileno(), count)
                try:
                    for index in range(101):
                        request = {"version": 1, "id": str(index), "method": "translate_chinese_batch",
                                   "items": [{"id": "p0", "text": "Hello"}]}
                        process.stdin.write(native_host.encode_frame(request, "="))
                        process.stdin.flush()
                        partial = native_host.read_frame(read, "=")
                        self.assertTrue(partial["partial"])
                        self.assertEqual(partial["id"], str(index))
                        if index < 100:
                            final = native_host.read_frame(read, "=")
                            self.assertEqual(final["id"], str(index))
                    process.stdin.close()
                    self.assertEqual(process.wait(3), 0)
                    self.assertTrue(cancelled.wait(2))
                    self.assertEqual(len(received), 101)
                    self.assertTrue(all(request["keepAlive"] for request in received))
                    self.assertEqual(errors, [])
                finally:
                    if process.poll() is None: process.kill(); process.wait()
                    process.stdout.close()
                    process.stderr.close()
                    thread.join(4)

    def test_process_exits_when_app_closes_an_idle_connection(self):
        with tempfile.TemporaryDirectory(prefix="nt-idle-", dir="/tmp") as directory:
            path = Path(directory) / "b.sock"
            release = threading.Event()
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(str(path))
                server.listen(1)
                server.settimeout(3)
                def reply_then_close():
                    connection, _ = server.accept()
                    with connection:
                        connection.settimeout(3)
                        request = native_host.read_frame(connection.recv, ">")
                        connection.sendall(native_host.encode_frame({"version": 1, "id": request["id"], "ok": True, "text": "你好"}, ">"))
                        release.wait(3)
                thread = threading.Thread(target=reply_then_close)
                thread.start()
                script = ("import native_host; from pathlib import Path; "
                          "native_host.bridge_socket=lambda:Path(" + repr(str(path)) + "); "
                          "native_host.configure_logging=lambda:None; native_host.main()")
                process = subprocess.Popen([sys.executable, "-c", script], cwd=Path(native_host.__file__).parent,
                                           stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                def read(count):
                    if not select.select([process.stdout], [], [], 3)[0]: raise TimeoutError("native process stalled")
                    return os.read(process.stdout.fileno(), count)
                try:
                    process.stdin.write(native_host.encode_frame(self.request(), "="))
                    process.stdin.flush()
                    self.assertTrue(native_host.read_frame(read, "=")["ok"])
                    release.set()
                    # Keep stdin open: app shutdown alone must disconnect the browser.
                    self.assertEqual(process.wait(3), 0)
                finally:
                    release.set()
                    if process.poll() is None: process.kill(); process.wait()
                    process.stdin.close(); process.stdout.close(); process.stderr.close()
                    thread.join(4)

    def test_broken_connection_is_not_replayed(self):
        with tempfile.TemporaryDirectory(prefix="nt-broken-", dir="/tmp") as directory:
            path = Path(directory) / "b.sock"
            received = []
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(str(path))
                server.listen(2)
                server.settimeout(2)
                def drop():
                    connection, _ = server.accept()
                    with connection:
                        received.append(native_host.read_frame(connection.recv, ">"))
                thread = threading.Thread(target=drop)
                thread.start()
                bridge = native_host.BridgeSession(path)
                result = list(native_host.responses(self.request(), session=bridge))
                thread.join(2)
                self.assertFalse(result[-1]["ok"])
                self.assertIsNone(bridge.connection)
                self.assertEqual(len(received), 1)
                self.assertFalse(select.select([server], [], [], 0.05)[0])

    def test_bridge_timeout_closes_socket_and_reports_failure(self):
        bridge = native_host.BridgeSession()
        with patch.object(bridge, "responses", side_effect=TimeoutError("wait expired")):
            result = list(native_host.responses(self.request(), session=bridge))
        self.assertFalse(result[-1]["ok"])
        self.assertIn("wait expired", result[-1]["error"]["message"])

    def test_stream_frames_are_yielded_before_final_and_validate_ids(self):
        with tempfile.TemporaryDirectory(prefix="nt-stream-", dir="/tmp") as directory:
            path = Path(directory) / "b.sock"
            release = threading.Event()
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(str(path))
                server.listen(1)
                server.settimeout(3)
                def reply():
                    connection, _ = server.accept()
                    with connection:
                        request = native_host.read_frame(connection.recv, ">")
                        connection.sendall(native_host.encode_frame({"version": 1, "id": request["id"], "ok": True,
                            "partial": True, "text": '{"id":"p0","text":"你好'}, ">"))
                        release.wait(2)
                        connection.sendall(native_host.encode_frame({"version": 1, "id": request["id"], "ok": True,
                            "items": [{"id": "p0", "text": "你好，世界"}]}, ">"))
                thread = threading.Thread(target=reply)
                thread.start()
                stream = native_host.responses({"version": 1, "id": "stream", "method": "translate_chinese_batch",
                    "items": [{"id": "p0", "text": "Hello world"}]}, path)
                first = next(stream)
                self.assertTrue(first["partial"])
                release.set()
                self.assertEqual(next(stream)["items"][0]["text"], "你好，世界")
                self.assertEqual(list(stream), [])
                thread.join(3)
                self.assertFalse(thread.is_alive())

    def test_browser_pipe_eof_cancels_active_socket(self):
        with tempfile.TemporaryDirectory(prefix="nt-cancel-", dir="/tmp") as directory:
            path = Path(directory) / "b.sock"
            accepted = threading.Event()
            disconnected = threading.Event()
            reader, writer = os.pipe()
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(str(path))
                server.listen(1)
                server.settimeout(3)
                def wait_for_disconnect():
                    connection, _ = server.accept()
                    with connection:
                        connection.settimeout(3)
                        native_host.read_frame(connection.recv, ">")
                        accepted.set()
                        if connection.recv(1) == b"": disconnected.set()
                server_thread = threading.Thread(target=wait_for_disconnect)
                server_thread.start()
                result = []
                def consume():
                    result.extend(native_host.responses(self.request(), path, cancel_fd=reader))
                client_thread = threading.Thread(target=consume)
                client_thread.start()
                self.assertTrue(accepted.wait(2))
                os.close(writer)
                client_thread.join(3)
                server_thread.join(3)
                os.close(reader)
                self.assertFalse(client_thread.is_alive())
                self.assertTrue(disconnected.is_set())
                self.assertEqual(result, [])

    def test_missing_app_and_invalid_input(self):
        self.assertFalse(native_host.translate(self.request(), "/tmp/no-such-notype/socket")["ok"])
        for request in (None, [], {}, {**self.request(), "text": "x" * 12001}):
            self.assertFalse(native_host.translate(request)["ok"])

    def test_installer_quotes_paths_and_preserves_existing_extension(self):
        with tempfile.TemporaryDirectory(prefix="notype install '") as directory:
            support = Path(directory)
            source = Path(__file__).resolve().parents[1] / "native_host.py"
            install.install("a" * 32, support, sys.executable, source)
            install.install("b" * 32, support, sys.executable, source)
            manifest = json.loads((support / "Google/Chrome/NativeMessagingHosts/com.opensource.notype.browser.json").read_text())
            self.assertEqual(manifest["allowed_origins"], [f"chrome-extension://{'a' * 32}/", f"chrome-extension://{'b' * 32}/"])
            self.assertTrue(Path(manifest["path"]).stat().st_mode & 0o100)
            self.assertEqual((support / "NoType/Browser/native_host.py").read_bytes(), source.read_bytes())
        with self.assertRaises(ValueError):
            install.install("../bad", Path("/tmp"), sys.executable, source)


if __name__ == "__main__":
    unittest.main()
