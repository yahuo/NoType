-- NoType key bindings for Omarchy's Hyprland Lua config.
-- install.sh copies this file to ~/.config/notype/hyprland.lua. Load it from
-- ~/.config/hypr/bindings.lua with:
--
--   require("notype.hyprland")

o.bind("ALT + SPACE", "NoType dictation", "notype record toggle")
o.bind("ALT + SHIFT + SPACE", "NoType English translation", "notype translate")
o.bind("ALT + ESCAPE", "NoType cancel", "notype cancel")
o.bind("ALT + CTRL + SPACE", "NoType selection to Chinese", "notype selection-chinese")
o.bind("ALT + SHIFT + T", "NoType translate agent draft", "notype agent-translate")

-- The shell plugin's Settings and Setup windows float like their macOS counterparts.
o.window({ class = "^org.quickshell$", title = "^NoType (Settings|Setup)$" }, { float = true, center = true })
