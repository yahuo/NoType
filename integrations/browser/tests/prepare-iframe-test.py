"""Build an isolated extension with a fake native host; no credentials or model calls."""
import json
import shutil
from pathlib import Path

root = Path(__file__).resolve().parents[3]
extension = root / "dist/iframe-tests/extension"
extension.mkdir(parents=True, exist_ok=True)
for source in (root / "integrations/browser/extension").iterdir():
    if source.is_file():
        shutil.copy2(source, extension / source.name)
background = extension / "background.js"
background.write_text((Path(__file__).with_name("mock-native.js")).read_text() + "\n" + background.read_text())
config = {
    "browser": {
        "browserName": "chromium",
        "launchOptions": {
            "channel": "chromium",
            "args": [f"--disable-extensions-except={extension}", f"--load-extension={extension}"],
            "ignoreDefaultArgs": ["--disable-extensions"],
        },
        "contextOptions": {"viewport": {"width": 1200, "height": 1800}},
    },
    "outputDir": str(root / "dist/iframe-tests/browser-output"),
}
(root / "dist/iframe-tests/config.json").write_text(json.dumps(config, indent=2))
print(root / "dist/iframe-tests/config.json")
