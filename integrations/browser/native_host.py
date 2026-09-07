"""Chrome native messaging (native endian) -> NoType Unix socket (big endian)."""

import json
import logging
from logging.handlers import RotatingFileHandler
import os
import re
import select
import socket
import struct
import subprocess
import sys
import time
from pathlib import Path

MAX_FRAME = 1_048_576


class ClientDisconnected(Exception):
    pass


def read_exact(read, length):
    data = bytearray()
    while len(data) < length:
        chunk = read(length - len(data))
        if not chunk:
            raise EOFError("连接在完整消息到达前关闭。")
        data.extend(chunk)
    return bytes(data)


def read_frame(read, endian):
    header = read_exact(read, 4)
    length = struct.unpack(endian + "I", header)[0]
    if not 0 < length <= MAX_FRAME:
        raise ValueError("消息长度无效。")
    return json.loads(read_exact(read, length).decode("utf-8"))


def encode_frame(value, endian):
    payload = json.dumps(value, ensure_ascii=False).encode("utf-8")
    if not 0 < len(payload) <= MAX_FRAME:
        raise ValueError("消息过长。")
    return struct.pack(endian + "I", len(payload)) + payload


def bridge_socket():
    # Match Foundation's per-user temporary directory, independently of Chrome's TMPDIR.
    directory = subprocess.check_output(
        ["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"], text=True,
    ).strip()
    return Path(directory) / "com.opensource.notype/bridge.sock"


def request_body(request):
    request_id = request.get("id", "") if isinstance(request, dict) else ""
    if not isinstance(request_id, str) or not 0 < len(request_id.encode("utf-8")) <= 128:
        raise ValueError("请求 ID 无效。")
    method = request.get("method")
    if request.get("version") != 1 or method not in ("translate_chinese", "translate_chinese_batch"):
        raise ValueError("只支持中文段落翻译。")
    body = {"version": 1, "id": request_id, "method": method, "client": "browser"}
    if method == "translate_chinese_batch":
        items = request.get("items")
        if not isinstance(items, list) or not 1 <= len(items) <= 4:
            raise ValueError("批次必须包含 1 至 4 段。")
        ids = set()
        total = 0
        for item in items:
            if not isinstance(item, dict) or not isinstance(item.get("id"), str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", item["id"]):
                raise ValueError("段落 ID 无效。")
            text = item.get("text")
            length = len(text.encode("utf-16-le")) // 2 if isinstance(text, str) else 0
            if not isinstance(text, str) or not text.strip() or not 0 < length <= 12000 or item["id"] in ids:
                raise ValueError("段落为空、重复或过长。")
            ids.add(item["id"])
            total += length
        if len(items) > 1 and total > 6000:
            raise ValueError("批次文本超过 6000 字符。")
        body["items"] = [{"id": item["id"], "text": item["text"]} for item in items]
    else:
        text = request.get("text")
        if not isinstance(text, str) or not text.strip() or len(text) > 12000:
            raise ValueError("段落为空或超过 12000 字符。")
        body["text"] = text
    return body


class BridgeSession:
    """One sequential socket per browser translation session; never replay a request."""
    def __init__(self, socket_path=None, cancel_fd=None):
        self.socket_path = socket_path
        self.cancel_fd = cancel_fd
        self.connection = None

    def close(self):
        if self.connection is not None:
            self.connection.close()
            self.connection = None
            logging.getLogger("notype.browser").info("connection_close")

    def responses(self, request):
        body = request_body(request)
        body["keepAlive"] = True
        if self.connection is None:
            self.connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.connection.settimeout(5)
            self.connection.connect(str(self.socket_path or bridge_socket()))
            self.connection.settimeout(190)
            logging.getLogger("notype.browser").info("connection_open")
        connection = self.connection
        connection.sendall(encode_frame(body, ">"))

        def receive(count):
            if self.cancel_fd is not None:
                ready, _, _ = select.select([connection, self.cancel_fd], [], [], 190)
                if self.cancel_fd in ready:
                    if not os.read(self.cancel_fd, 1):
                        raise ClientDisconnected()
                    raise ValueError("上一个批次完成前不能发送新请求。")
                if not ready:
                    raise TimeoutError("等待 NoType 响应超时。")
            return connection.recv(count)

        while True:
            response = read_frame(receive, ">")
            if (not isinstance(response, dict) or response.get("id") != body["id"]
                    or response.get("version") != 1 or type(response.get("ok")) is not bool):
                raise ValueError("NoType 响应格式不正确。")
            if response.get("partial") is True and (body["method"] != "translate_chinese_batch"
                    or not response["ok"] or not isinstance(response.get("text"), str)):
                raise ValueError("NoType 流式响应格式不正确。")
            yield response
            if response.get("partial") is not True:
                return


def responses(request, socket_path=None, cancel_fd=None, session=None):
    request_id = request.get("id", "") if isinstance(request, dict) else ""
    bridge = session or BridgeSession(socket_path, cancel_fd)
    logger = logging.getLogger("notype.browser")
    started = time.monotonic()
    first = True
    try:
        # Counts and IDs only: never record source text, translations, or credentials.
        body = request_body(request)
        items = body.get("items", [{"text": body.get("text", "")}])
        logger.info("request_start %s", json.dumps({"id": request_id, "paragraphs": len(items),
                    "characters": sum(len(item["text"].encode("utf-16-le")) // 2 for item in items)}))
        for response in bridge.responses(request):
            if first:
                logger.info("first_frame id=%s elapsed_ms=%d", json.dumps(request_id), (time.monotonic() - started) * 1000)
                first = False
            if response.get("partial") is not True:
                logger.info("request_end id=%s ok=%s elapsed_ms=%d", json.dumps(request_id), response["ok"], (time.monotonic() - started) * 1000)
            yield response
    except ClientDisconnected:
        logger.info("request_cancelled id=%s", json.dumps(request_id))
        bridge.close()
    except (OSError, ValueError, EOFError, subprocess.SubprocessError) as error:
        logger.warning("request_failed id=%s stage=bridge error_type=%s elapsed_ms=%d", json.dumps(request_id), type(error).__name__, (time.monotonic() - started) * 1000)
        bridge.close()
        yield {
            "version": 1, "id": request_id if isinstance(request_id, str) else "", "ok": False,
            "error": {"code": "bridge_unavailable", "message": f"请确认新版 NoType 正在运行：{error}"},
        }
    finally:
        if session is None:
            bridge.close()


def translate(request, socket_path=None):
    return list(responses(request, socket_path))[-1]


def configure_logging():
    directory = Path.home() / "Library/Logs/NoType"
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    handler = RotatingFileHandler(directory / "browser-bridge.log", maxBytes=1_048_576, backupCount=2)
    os.chmod(handler.baseFilename, 0o600)
    handler.setFormatter(logging.Formatter("%(asctime)s pid=%(process)d %(message)s"))
    logger = logging.getLogger("notype.browser")
    logger.setLevel(logging.INFO)
    logger.addHandler(handler)


def main():
    configure_logging()
    session = BridgeSession(cancel_fd=sys.stdin.fileno())
    try:
        while True:
            # Observe app shutdown even while the page is idle waiting for scrolling.
            readers = [sys.stdin.fileno()]
            if session.connection is not None:
                readers.append(session.connection)
            ready, _, _ = select.select(readers, [], [])
            if session.connection is not None and session.connection in ready:
                logging.getLogger("notype.browser").warning("idle_connection_closed_or_unexpected_data")
                return
            try:
                # Unbuffered reads: select must not miss input prefetched by BufferedReader.
                request = read_frame(lambda n: os.read(sys.stdin.fileno(), n), "=")
            except (EOFError, ValueError, OSError):
                return
            for response in responses(request, session=session):
                sys.stdout.buffer.write(encode_frame(response, "="))
                sys.stdout.buffer.flush()
                if not response["ok"]:
                    return
    except (BrokenPipeError, ConnectionResetError):
        pass
    finally:
        session.close()


if __name__ == "__main__":
    main()
