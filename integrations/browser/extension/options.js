"use strict";

// Keep in sync with settingDefaults in youtube.js, which validates what it reads.
const defaults = { youtubeShowOriginal: true, youtubeFontScale: 100 };
const original = document.getElementById("original");
const scale = document.getElementById("scale");
const scaleValue = document.getElementById("scale-value");

function show(settings) {
  original.checked = settings.youtubeShowOriginal !== false;
  scale.value = String(settings.youtubeFontScale);
  scaleValue.value = `${scale.value}%`;
}

chrome.storage.sync.get(defaults).then(show);
original.addEventListener("change", () => chrome.storage.sync.set({ youtubeShowOriginal: original.checked }));
scale.addEventListener("input", () => {
  scaleValue.value = `${scale.value}%`;
  chrome.storage.sync.set({ youtubeFontScale: Number(scale.value) });
});
document.getElementById("reset").addEventListener("click", () => {
  show(defaults);
  chrome.storage.sync.set(defaults);
});
