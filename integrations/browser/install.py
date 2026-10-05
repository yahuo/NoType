"""Install the local native host for one unpacked extension ID on macOS or Linux."""

import json
import os
import re
import shlex
import shutil
import sys
from pathlib import Path

MANIFEST = "NativeMessagingHosts/com.opensource.notype.browser.json"
MACOS_BROWSERS = ("Google/Chrome", "Microsoft Edge")
# Per-user Chromium-family directories under $XDG_CONFIG_HOME.
LINUX_BROWSERS = ("google-chrome", "chromium", "microsoft-edge", "BraveSoftware/Brave-Browser")


def install_to(extension_id, destination, browser_directories, python, source):
    if not re.fullmatch(r"[a-p]{32}", extension_id):
        raise ValueError("扩展 ID 必须是 chrome://extensions 或 edge://extensions 中的 32 位 ID。")
    destination.mkdir(parents=True, exist_ok=True)
    host = destination / "native_host.py"
    shutil.copyfile(source, host)
    host.chmod(0o600)
    launcher = destination / "notype-browser-host"
    launcher.write_text(f"#!/bin/sh\nexec {shlex.quote(python)} {shlex.quote(str(host))}\n")
    launcher.chmod(0o700)
    for browser in browser_directories:
        path = browser / MANIFEST
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


def install(extension_id, support, python, source):
    install_to(extension_id, support / "NoType/Browser",
               [support / browser for browser in MACOS_BROWSERS], python, source)


def install_linux(extension_id, config_home, data_home, python, source):
    install_to(extension_id, data_home / "notype/browser",
               [config_home / browser for browser in LINUX_BROWSERS], python, source)


def xdg_home(variable, default):
    value = os.environ.get(variable, "")
    return Path(value) if os.path.isabs(value) else Path.home() / default


if __name__ == "__main__":
    if len(sys.argv) != 2 or not (sys.platform == "darwin" or sys.platform.startswith("linux")):
        sys.exit("用法（macOS 或 Linux）：python3 integrations/browser/install.py <扩展ID>")
    host_source = Path(__file__).with_name("native_host.py")
    if sys.platform == "darwin":
        install(sys.argv[1], Path.home() / "Library/Application Support", sys.executable, host_source)
    else:
        install_linux(sys.argv[1], xdg_home("XDG_CONFIG_HOME", ".config"),
                      xdg_home("XDG_DATA_HOME", ".local/share"), sys.executable, host_source)
