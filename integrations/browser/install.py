"""Install the local native host for one unpacked extension ID on macOS."""

import json
import re
import shlex
import shutil
import sys
from pathlib import Path


def install(extension_id, support, python, source):
    if not re.fullmatch(r"[a-p]{32}", extension_id):
        raise ValueError("扩展 ID 必须是 chrome://extensions 或 edge://extensions 中的 32 位 ID。")
    destination = support / "NoType/Browser"
    destination.mkdir(parents=True, exist_ok=True)
    host = destination / "native_host.py"
    shutil.copyfile(source, host)
    host.chmod(0o600)
    launcher = destination / "notype-browser-host"
    launcher.write_text(f"#!/bin/sh\nexec {shlex.quote(python)} {shlex.quote(str(host))}\n")
    launcher.chmod(0o700)
    for browser in ("Google/Chrome", "Microsoft Edge"):
        path = support / browser / "NativeMessagingHosts/com.opensource.notype.browser.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        origins = [f"chrome-extension://{extension_id}/"]
        if path.exists():
            previous = json.loads(path.read_text())
            origins = list(dict.fromkeys(previous.get("allowed_origins", []) + origins))
        path.write_text(json.dumps({
            "name": "com.opensource.notype.browser",
            "description": "NoType 网页中文翻译连接程序",
            "path": str(launcher), "type": "stdio", "allowed_origins": origins,
        }, ensure_ascii=False, indent=2) + "\n")
        path.chmod(0o600)
        print(f"已安装：{path}")


if __name__ == "__main__":
    if sys.platform != "darwin" or len(sys.argv) != 2:
        sys.exit("用法（macOS）：python3 integrations/browser/install.py <扩展ID>")
    install(sys.argv[1], Path.home() / "Library/Application Support",
            sys.executable, Path(__file__).with_name("native_host.py"))
