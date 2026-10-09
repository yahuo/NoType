"""Install the local native host for one unpacked extension ID on macOS or Linux."""

import hashlib
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


def install_linux(extension_id, config_home, data_home, python, source, extension=None):
    """Without an ID, copies `extension` to a stable folder and allows the ID Chromium derives from it."""
    destination = data_home / "notype/browser"
    if extension_id is None:
        # Chromium resolves symlinks before hashing the folder.
        extension_id = extension_id_for(os.path.realpath(copy_extension(extension, destination / "extension")))
    install_to(extension_id, destination,
               [config_home / browser for browser in LINUX_BROWSERS], python, source)
    return extension_id


def copy_extension(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    staging = target.with_name(target.name + ".new")
    shutil.rmtree(staging, ignore_errors=True)
    shutil.copytree(source, staging, ignore=shutil.ignore_patterns(".*", "__pycache__"))
    shutil.rmtree(target, ignore_errors=True)
    staging.rename(target)
    return target


def extension_id_for(path):
    """Chromium's ID for an unpacked extension without a manifest key: SHA-256 of its absolute path, 0-f as a-p."""
    digest = hashlib.sha256(os.fsencode(path)).hexdigest()[:32]
    return digest.translate(str.maketrans("0123456789abcdef", "abcdefghijklmnop"))


def xdg_home(variable, default):
    value = os.environ.get(variable, "")
    return Path(value) if os.path.isabs(value) else Path.home() / default


if __name__ == "__main__":
    linux = sys.platform.startswith("linux")
    if not (sys.platform == "darwin" and len(sys.argv) == 2 or linux and len(sys.argv) <= 2):
        sys.exit("用法：python3 integrations/browser/install.py <扩展ID>（Linux 上可省略扩展 ID）")
    host_source = Path(__file__).with_name("native_host.py")
    if sys.platform == "darwin":
        install(sys.argv[1], Path.home() / "Library/Application Support", sys.executable, host_source)
    else:
        data = xdg_home("XDG_DATA_HOME", ".local/share")
        given = sys.argv[1] if len(sys.argv) == 2 else None
        installed = install_linux(given, xdg_home("XDG_CONFIG_HOME", ".config"), data, sys.executable,
                                  host_source, Path(__file__).with_name("extension"))
        if given is None:
            print(f"在 chrome://extensions 开启开发者模式，“加载已解压的扩展程序”选择：{data / 'notype/browser/extension'}")
            print(f"扩展 ID 应为：{installed}；更新后在该页点扩展的重新加载按钮。")
