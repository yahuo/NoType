// YouTube bilingual subtitles for the top frame of www.youtube.com.
// Passive part (from document_start): keep the caption tracks that
// youtube-bridge.js copies from the player. Nothing is translated or sent
// before the toolbar button starts subtitle mode on a /watch page.
(() => {
  if (globalThis.__noTypeYouTubeSubtitles) return;
  const source = "notype-youtube";
  const maxText = 4000000;
  const maxCues = 20000;
  const maxVideos = 8;
  const tracks = new Map();
  const cjk = /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]/u;
  const terminal = /[.!?。！？…]["'’”)\]]*$/u;

  function clean(text) {
    return text.replace(/[​﻿]/g, "").replace(/\s+/g, " ").trim();
  }
  function decodeEntities(text) {
    const named = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " " };
    return text.replace(/&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot|apos|nbsp);/gi, (match, name) => {
      const lower = name.toLowerCase();
      if (lower[0] !== "#") return named[lower];
      const code = lower[1] === "x" ? parseInt(lower.slice(2), 16) : parseInt(lower.slice(1), 10);
      return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : match;
    });
  }
  function number(value) {
    const result = typeof value === "number" ? value : typeof value === "string" && value.trim() ? Number(value) : NaN;
    return Number.isFinite(result) && result >= 0 ? result : null;
  }

  // json3 (what the web player requests), srv3 (<p t d> in ms) or srv1 (<text start dur> in s).
  function parseTimedText(text) {
    const raw = [];
    const trimmed = text.trim();
    if (trimmed.startsWith("{")) {
      let data;
      try { data = JSON.parse(trimmed); } catch { return raw; }
      for (const event of Array.isArray(data?.events) ? data.events : []) {
        const start = number(event?.tStartMs);
        if (start === null || !Array.isArray(event.segs)) continue;
        const line = clean(event.segs.map((segment) => typeof segment?.utf8 === "string" ? segment.utf8 : "").join(""));
        if (line) raw.push({ start, duration: number(event.dDurationMs) ?? 0, text: line });
      }
      return raw;
    }
    for (const match of trimmed.matchAll(/<(p|text)\b([^>]*)>([\s\S]*?)<\/\1>/gi)) {
      const attribute = (name) => match[2].match(new RegExp(`\\b${name}\\s*=\\s*["']([^"']*)["']`, "i"))?.[1];
      const ms = match[1].toLowerCase() === "p";
      const start = number(attribute(ms ? "t" : "start"));
      const duration = number(attribute(ms ? "d" : "dur")) ?? 0;
      if (start === null) continue;
      // Strip tags before decoding; srv1 escapes entities twice (&amp;#39;).
      const line = clean(decodeEntities(decodeEntities(match[3].replace(/<br\s*\/?>/gi, " ").replace(/<[^>]*>/g, ""))));
      if (line) raw.push({ start: ms ? start : start * 1000, duration: ms ? duration : duration * 1000, text: line });
    }
    return raw;
  }

  function joinText(left, right) {
    if ((cjk.test(left.slice(-1)) && cjk.test(right[0])) || /^[,.!?;:%)\]}'’…]/u.test(right)) return left + right;
    return `${left} ${right}`;
  }
  const words = (text) => text.split(" ").length;
  const fragment = (cue) => cue.text.length <= 32 && words(cue.text) <= 2;

  // Normalize to sorted, non-overlapping cues: one cue on screen at a time.
  function buildCues(raw) {
    const ordered = raw.filter((cue) => cue.text).sort((a, b) => a.start - b.start);
    const collapsed = [];
    for (const cue of ordered) {
      const last = collapsed.at(-1);
      if (last && cue.start - last.start <= 120) {
        // Same moment: an incremental update keeps the longest text; a different line joins it.
        const end = Math.max(last.start + last.duration, cue.start + cue.duration);
        const prefix = last.text.startsWith(cue.text) || cue.text.startsWith(last.text);
        last.text = prefix ? (cue.text.length >= last.text.length ? cue.text : last.text) : joinText(last.text, cue.text);
        last.duration = end - last.start;
      } else collapsed.push({ ...cue });
    }
    collapsed.forEach((cue, index) => {
      if (cue.duration > 0) return;
      const next = collapsed[index + 1];
      cue.duration = next ? Math.max(500, Math.min(8000, next.start - cue.start)) : 2000;
    });
    // Word-by-word streams (three or more short fragments in quick succession)
    // become phrases of up to 14 words / 8 seconds, ending at sentence punctuation.
    const end = (cue) => cue.start + Math.max(cue.duration, 500);
    const joinable = (a, b) => b.start - end(a) <= 700 && b.start - a.start <= 1800;
    const merged = [];
    for (let i = 0; i < collapsed.length;) {
      const [a, b, c] = collapsed.slice(i, i + 3);
      if (!c || ![a, b, c].every(fragment) || terminal.test(a.text) || terminal.test(b.text) ||
          !joinable(a, b) || !joinable(b, c)) {
        merged.push(a); i++; continue;
      }
      let text = a.text, count = words(a.text), finish = end(a), j = i + 1;
      while (j < collapsed.length && !terminal.test(text)) {
        const next = collapsed[j];
        if (!fragment(next) || !joinable(collapsed[j - 1], next) || count + words(next.text) > 14 ||
            end(next) - a.start > 8000) break;
        text = joinText(text, next.text); count += words(next.text); finish = Math.max(finish, end(next)); j++;
      }
      merged.push({ start: a.start, duration: finish - a.start, text });
      i = j;
    }
    return merged.map((cue, index) => {
      const next = merged[index + 1];
      return { start: cue.start, end: next ? Math.min(cue.start + cue.duration, next.start) : cue.start + cue.duration, text: cue.text };
    });
  }

  // Translation units. Captions (ASR especially) break lines mid-sentence, and a model asked to
  // translate those fragments one by one reorders words across them and drifts. So sentences are
  // cut at their own punctuation, wherever it falls inside a cue, and timed by interpolating
  // character offsets over that cue. Long or unpunctuated runs end at a clause mark after 100
  // characters, before 200 characters, or at a pause of more than 1.5 s.
  const clause = /[,;:，；：、]["'’”)\]]*$/u;
  // Initials (U.S., e.g.) and common titles end in a period without ending the sentence. A lone
  // letter (plan B., leader C., isn't.) does.
  const titles = new Set(["mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc"]);
  function abbreviation(text, dot) {
    let from = dot;
    while (from > 0 && /[A-Za-z.]/.test(text[from - 1])) from--;
    if (from > 0 && /[\p{L}\p{N}'’]/u.test(text[from - 1])) return false;
    const word = text.slice(from, dot).toLowerCase();
    return titles.has(word) || /^(?:[a-z]\.)+[a-z]$/.test(word);
  }
  // One linear pass: a run of end marks plus closing quotes ends a sentence; Latin marks also need
  // a following space (3.5, example.com) or the end of the line.
  function splitSentences(text) {
    const pieces = [];
    let from = 0;
    for (let i = 0; i < text.length; i++) {
      if (!".!?…。！？".includes(text[i])) continue;
      let run = i + 1;
      while (run < text.length && ".!?…。！？".includes(text[run])) run++;
      let stop = run;
      while (stop < text.length && `"'’”)]`.includes(text[stop])) stop++;
      const wide = "。！？".includes(text[run - 1]);
      const open = !wide && stop < text.length && !/\s/.test(text[stop]);
      if (!open && !(run === i + 1 && text[i] === "." && abbreviation(text, i))) {
        const piece = text.slice(from, stop).trim();
        if (piece) pieces.push({ text: piece, ended: true });
        from = stop;
      }
      i = stop - 1;
    }
    const rest = text.slice(from).trim();
    if (rest) pieces.push({ text: rest, ended: false });
    return pieces;
  }
  function buildSentences(cues) {
    const sentences = [];
    let current = null, previousEnd = -Infinity;
    const close = (end) => { if (current) { current.end = end; sentences.push(current); current = null; } };
    for (const cue of cues) {
      if (cue.start - previousEnd > 1500) close(previousEnd);
      const pieces = splitSentences(cue.text);
      const total = pieces.reduce((sum, piece) => sum + piece.text.length, 0);
      const at = (offset) => cue.start + (cue.end - cue.start) * offset / total;
      let offset = 0;
      for (const { text, ended } of pieces) {
        const start = at(offset);
        offset += text.length;
        if (current && (current.text.length + text.length > 200 || (current.text.length >= 100 && clause.test(current.text)))) close(start);
        if (current) current.text = joinText(current.text, text); else current = { start, text };
        if (ended) close(at(offset));
      }
      previousEnd = cue.end;
    }
    close(previousEnd);
    return sentences;
  }

  // A long sentence's translation is shown about one line at a time. Above 36 full-width characters
  // (Latin counts half), clauses cut after Chinese punctuation are grouped up to 28, with at most one
  // group per 1.5 s of the sentence so each stays long enough to read.
  const width = (text) => Array.from(text).reduce((sum, char) => sum + (char.codePointAt(0) >= 0x2e80 ? 1 : 0.5), 0);
  function translationGroups(text, duration) {
    if (width(text) <= 36) return [{ text, width: width(text) }];
    const groups = [];
    for (const clause of text.match(/[^，。！？；：]+(?:[，。！？；：]+[”’」』）)]*|$)/gu) || []) {
      const piece = clause.trim();
      if (!piece) continue;
      const last = groups.at(-1);
      if (last && last.width + width(piece) <= 28) { last.text += piece; last.width += width(piece); }
      else groups.push({ text: piece, width: width(piece) });
    }
    const most = Math.max(1, Math.floor(duration / 1500));
    while (groups.length > most) {
      let pair = 0;
      for (let i = 1; i < groups.length - 1; i++) {
        if (groups[i].width + groups[i + 1].width < groups[pair].width + groups[pair + 1].width) pair = i;
      }
      groups.splice(pair, 2, { text: groups[pair].text + groups[pair + 1].text, width: groups[pair].width + groups[pair + 1].width });
    }
    return groups.length ? groups : [{ text, width: width(text) }];
  }
  // Groups switch together with the original line: each group belongs to the caption line playing
  // at its midpoint (sentence time maps to width), and shows while that line does. A line holding
  // several groups shares its time among them by width; a line holding none keeps the group around it.
  function translationAt(text, sentence, cue, time) {
    const duration = sentence.end - sentence.start;
    const groups = translationGroups(text, duration);
    if (groups.length === 1) return groups[0].text;
    const total = groups.reduce((sum, group) => sum + group.width, 0);
    const at = (moment) => duration > 0 ? Math.min(1, Math.max(0, (moment - sentence.start) / duration)) * total : 0;
    let edge = 0;
    const spans = groups.map((group) => ({ ...group, middle: (edge += group.width) - group.width / 2, end: edge }));
    const now = at(time);
    const from = cue ? at(Math.max(cue.start, sentence.start)) : now;
    const to = cue ? at(Math.min(cue.end, sentence.end)) : now;
    const owned = spans.filter((span) => span.middle >= from && span.middle < to);
    if (!owned.length) return (spans.find((span) => (from + to) / 2 < span.end) ?? spans.at(-1)).text;
    const share = (now - from) / (to - from) * owned.reduce((sum, span) => sum + span.width, 0);
    let covered = 0;
    for (const span of owned) {
      covered += span.width;
      if (share < covered) return span.text;
    }
    return owned.at(-1).text;
  }

  function findCue(cues, time) {
    let low = 0, high = cues.length;
    while (low < high) {
      const middle = (low + high) >>> 1;
      if (cues[middle].start <= time) low = middle + 1; else high = middle;
    }
    return low > 0 && time < cues[low - 1].end ? low - 1 : -1;
  }
  function firstFrom(cues, time) {
    let low = 0, high = cues.length;
    while (low < high) {
      const middle = (low + high) >>> 1;
      if (cues[middle].end <= time) low = middle + 1; else high = middle;
    }
    return low;
  }

  // The page can post the same message, so treat it as untrusted caption data:
  // same-origin timedtext URL bound to a video ID, bounded size and cue count.
  function capture(data, href) {
    if (!data || data.source !== source || data.type !== "timedtext" || typeof data.url !== "string" ||
        data.url.length > 32768 || typeof data.text !== "string" || !data.text || data.text.length > maxText) return null;
    let url;
    try { url = new URL(data.url, href); } catch { return null; }
    if (url.origin !== new URL(href).origin || url.pathname !== "/api/timedtext") return null;
    const video = url.searchParams.get("v");
    if (!video) return null;
    const cues = buildCues(parseTimedText(data.text));
    if (!cues.length || cues.length > maxCues) return null;
    return { video, url: url.href, translated: url.searchParams.has("tlang"), cues, sentences: buildSentences(cues) };
  }
  function remember(track) {
    const current = tracks.get(track.video);
    // Prefer the original-language track over YouTube's own auto-translation.
    if (current && !current.translated && track.translated) return;
    tracks.delete(track.video);
    tracks.set(track.video, track);
    while (tracks.size > maxVideos) tracks.delete(tracks.keys().next().value);
  }
  addEventListener("message", (event) => {
    if (event.source !== window || event.origin !== location.origin) return;
    const track = capture(event.data, location.href);
    if (track) remember(track);
  });

  function needsTranslation(text) {
    return text.length <= 1000 && /\p{L}/u.test(text) && !/^[\p{Script=Han}\p{P}\p{N}\p{Z}\p{S}\s]+$/u.test(text);
  }
  function applies() {
    return globalThis.top === globalThis && location.hostname === "www.youtube.com" && location.pathname === "/watch";
  }

  // Stored in chrome.storage.sync by options.html; missing or invalid values fall back to these.
  const settingDefaults = { youtubeShowOriginal: true, youtubeFontScale: 100 };
  function subtitleSettings(stored) {
    const scale = Number(stored?.youtubeFontScale);
    return {
      showOriginal: stored?.youtubeShowOriginal !== false,
      scale: Number.isFinite(scale) ? Math.min(160, Math.max(70, Math.round(scale))) : settingDefaults.youtubeFontScale,
    };
  }
  // Follows the player height like native captions, then applies the user's scale.
  function subtitleSize(height, scale) {
    return Math.round(Math.min(38, Math.max(14, height * 0.042)) * scale / 100);
  }
  // With the original hidden, it still stands in while a sentence has no translation to show.
  function subtitleLines(cue, translation, showOriginal) {
    return { original: showOriginal || !translation ? cue : "", translated: translation };
  }

  const viewStyle = ":host{all:initial!important;position:absolute!important;inset:0!important;z-index:41!important;display:block!important;pointer-events:none!important}" +
    ".box{position:absolute;left:4%;right:4%;bottom:var(--notype-bottom,60px);display:flex;flex-direction:column;align-items:center;gap:.12em;" +
    "font:500 var(--notype-size,20px)/1.35 'YouTube Noto',Roboto,'PingFang SC','Hiragino Sans GB','Microsoft YaHei',sans-serif;text-align:center;transition:bottom .2s}" +
    ".box[hidden],.line:empty{display:none}.line{max-width:100%;overflow-wrap:anywhere}" +
    ".line>span{background:#080808b8;padding:.06em .4em;border-radius:.2em;-webkit-box-decoration-break:clone;box-decoration-break:clone}" +
    ".src{font-size:.82em;color:#e6e6e6}.dst{color:#fff}.line>span{animation:notype-in .15s ease-out}@keyframes notype-in{from{opacity:0}}" +
    ".pill{all:unset;position:absolute;top:12px;left:12px;max-width:min(70%,420px);padding:6px 10px;border-radius:8px;background:#20272fe6;color:#fff;" +
    "font:13px/1.5 system-ui,sans-serif;box-shadow:0 4px 16px #0004;pointer-events:auto;cursor:default}" +
    ".pill[hidden]{display:none}.pill:not(:disabled){cursor:pointer;background:#8a5a00e6}.pill:focus-visible{outline:2px solid #ffb340}" +
    "@media (prefers-reduced-motion:reduce){.box{transition:none}.line>span{animation:none}}";
  const nativeStyle = "#movie_player[data-notype-subtitles] .ytp-caption-window-container{opacity:0!important}";

  function start() {
    if (globalThis.__noTypeBilingual) return;
    const state = { stop, fail, retry, setFailures() {} };
    globalThis.__noTypeBilingual = state;
    const translations = new Map();
    const requests = new Map();
    let port = null, nextId = 0, frame = 0, stopped = false, errorMessage = "";
    let videoId = null, track = null, videoSince = 0, refetched = false, clickedFor = "";
    let lastPressed = null, captionsWanted = true, scheduledAt = -Infinity, scheduledTime = NaN;
    let host, box, original, translated, pill, sheet, layoutKey = "", player = null;
    let results = 0, failuresKey = "", failures = 0, failureReason = "";
    let settings = subtitleSettings(settingDefaults);
    function loadSettings() {
      chrome.storage.sync.get(settingDefaults).then((stored) => {
        if (stopped) return;
        settings = subtitleSettings(stored);
        layoutKey = "";
      }, () => {});
    }
    function settingsChanged(changes, area) {
      if (area === "sync" && Object.keys(changes).some((key) => key in settingDefaults)) loadSettings();
    }
    chrome.storage.onChanged.addListener(settingsChanged);
    loadSettings();

    function stop() {
      stopped = true;
      chrome.storage.onChanged.removeListener(settingsChanged);
      cancelAnimationFrame(frame);
      const old = port;
      port = null;
      old?.disconnect();
      requests.clear();
      detach();
      sheet?.remove();
      if (globalThis.__noTypeBilingual === state) delete globalThis.__noTypeBilingual;
    }
    function fail(message) {
      if (stopped) return;
      stopped = true;
      errorMessage = message || "NoType 返回了错误。";
      requests.forEach((group) => group.forEach((entry) => { if (entry.status === "waiting") entry.status = "pending"; }));
      requests.clear();
      const old = port;
      port = null;
      old?.disconnect();
    }
    function retry() {
      if (stopped) return;
      for (const entry of translations.values()) if (entry.status === "failed") entry.status = "pending";
      results++;
      scheduledTime = NaN;
    }

    function connect() {
      if (port) return port;
      const connected = chrome.runtime.connect({ name: "notype.translate" });
      port = connected;
      connected.onMessage.addListener(handleResponse);
      connected.onDisconnect.addListener(() => {
        if (port !== connected) return;
        const detail = chrome.runtime.lastError?.message;
        port = null;
        if (requests.size) fail(detail || "本地连接已断开。");
      });
      return connected;
    }
    function handleResponse(response) {
      if (stopped) return;
      if (!response?.ok) { fail(response?.error?.message || "NoType 返回了错误。"); return; }
      // Cues are prefetched ahead of playback, so streamed partial text is not shown.
      if (response.partial === true) return;
      const group = requests.get(response.id);
      if (!group || !Array.isArray(response.items)) { fail("翻译响应的批次 ID 不匹配。"); return; }
      requests.delete(response.id);
      results++;
      const items = new Map(response.items.map((item) => [item?.id, item]));
      for (const entry of group) {
        const item = items.get(entry.id);
        if (typeof item?.text === "string" && item.text.trim()) { entry.status = "done"; entry.result = item.text.trim(); }
        else { entry.status = "failed"; entry.error = typeof item?.error === "string" ? item.error : "译文缺失。"; }
      }
      // Release the native connections between prefetch windows, as paragraph mode does when done.
      if (!requests.size && port) { const old = port; port = null; old.disconnect(); }
    }
    function submit(group) {
      const id = `y${nextId++}`;
      for (const entry of group) { entry.status = "waiting"; entry.id = `s${nextId++}`; }
      requests.set(id, group);
      connect().postMessage({ id, items: group.map(({ id, text, priority }) => ({ id, text, priority })) });
    }

    // Translate the current sentence and the next 90 s (scaled by playback rate);
    // the next 20 s go first. During playback sentences enter the window one by one, so
    // later ones wait until 12 can share a batch or less than 45 s of lead is left.
    // The background pool shares slots with other tabs.
    function schedule(time, rate) {
      const now = performance.now();
      if (stopped || (now - scheduledAt < 500 && Math.abs(time - scheduledTime) <= 3000)) return;
      scheduledAt = now; scheduledTime = time;
      const speed = Math.max(1, rate || 1);
      const pending = [], changed = [], inWindow = new Set();
      for (let i = firstFrom(track.sentences, time - 1000); i < track.sentences.length; i++) {
        const sentence = track.sentences[i];
        if (sentence.start > time + 90000 * speed) break;
        if (!needsTranslation(sentence.text) || inWindow.has(sentence.text)) continue;
        inWindow.add(sentence.text);
        const priority = sentence.start <= time + 20000 * speed ? 0 : 1;
        let entry = translations.get(sentence.text);
        if (!entry) { entry = { text: sentence.text, status: "pending" }; translations.set(sentence.text, entry); }
        if (entry.status === "pending") { entry.priority = priority; entry.at = sentence.start; pending.push(entry); }
        else if (entry.status === "waiting" && entry.priority !== priority) { entry.priority = priority; changed.push(entry); }
      }
      // After a seek, cues left behind wait behind everything else.
      for (const entry of translations.values()) {
        if (entry.status === "waiting" && !inWindow.has(entry.text) && entry.priority !== 2) { entry.priority = 2; changed.push(entry); }
      }
      pending.sort((a, b) => a.priority - b.priority || a.at - b.at);
      const urgent = pending.some((entry) => entry.priority === 0 || entry.at <= time + 45000 * speed);
      let group = [], length = 0, allShort = true;
      for (const entry of urgent || pending.length >= 12 ? pending : []) {
        const short = entry.text.length <= 100;
        if (group.length && ((group.length >= 4 && (!allShort || !short)) || length + entry.text.length > 6000)) {
          submit(group); group = []; length = 0; allShort = true;
        }
        group.push(entry); length += entry.text.length; allShort = allShort && short;
        if (group.length === 12 || (!allShort && group.length === 4)) { submit(group); group = []; length = 0; allShort = true; }
      }
      if (group.length) submit(group);
      for (let i = 0; port && i < changed.length; i += 512) {
        port.postMessage({ type: "priority", items: changed.slice(i, i + 512).map(({ id, priority }) => ({ id, priority })) });
      }
    }

    function switchVideo(id) {
      videoId = id; track = null; videoSince = performance.now(); refetched = false;
      lastPressed = null; scheduledTime = NaN;
      if (!requests.size) return;
      // Cancel the previous video's queue; the background drops batches nobody waits for.
      requests.forEach((group) => group.forEach((entry) => { if (entry.status === "waiting") entry.status = "pending"; }));
      requests.clear();
      const old = port;
      port = null;
      old?.disconnect();
    }
    // Fallback when the response arrived before this script listened, for example
    // after the extension was reloaded: re-read the player's own URL once.
    async function refetch(id) {
      const url = performance.getEntriesByType("resource").map((entry) => entry.name).filter((name) => {
        try {
          const parsed = new URL(name);
          return parsed.origin === location.origin && parsed.pathname === "/api/timedtext" &&
            parsed.searchParams.get("v") === id && !parsed.searchParams.has("tlang");
        } catch { return false; }
      }).at(-1);
      if (!url) return;
      try {
        const response = await fetch(url, { credentials: "include" });
        const text = response.ok ? await response.text() : "";
        const captured = text && capture({ source, type: "timedtext", url, text }, location.href);
        if (captured) remember(captured);
      } catch {}
    }

    function attach(target) {
      if (!host) {
        host = document.createElement("notype-subtitle");
        host.setAttribute("translate", "no");
        host.className = "notranslate";
        const root = host.attachShadow({ mode: "open" });
        const style = document.createElement("style");
        style.textContent = viewStyle;
        box = document.createElement("div");
        box.className = "box";
        original = document.createElement("div");
        original.className = "line src";
        translated = document.createElement("div");
        translated.className = "line dst";
        translated.lang = "zh-CN";
        box.append(original, translated);
        pill = document.createElement("button");
        pill.className = "pill";
        pill.type = "button";
        pill.hidden = true;
        pill.setAttribute("role", "status");
        // Keep the click away from the player, which would toggle playback.
        pill.addEventListener("click", (event) => { event.stopPropagation(); retry(); });
        root.append(style, box, pill);
      }
      if (!sheet) {
        sheet = document.createElement("style");
        sheet.textContent = nativeStyle;
      }
      if (!sheet.isConnected) (document.head || document.documentElement).append(sheet);
      if (player !== target) { player?.removeAttribute("data-notype-subtitles"); player = target; }
      if (host.parentElement !== target) target.append(host);
    }
    function detach() {
      host?.remove();
      player?.removeAttribute("data-notype-subtitles");
      player = null;
    }
    function setLine(line, text) {
      if (line.textContent === text) return;
      line.textContent = "";
      if (text) { const span = document.createElement("span"); span.textContent = text; line.append(span); }
    }
    function setStatus(text, actionable = false, reason = "") {
      if (pill.textContent !== text) pill.textContent = text;
      if (pill.title !== reason) pill.title = reason;
      pill.hidden = !text;
      pill.disabled = !actionable;
    }
    function layout(target) {
      const height = target.clientHeight;
      const controls = !target.classList.contains("ytp-autohide");
      const bottom = controls ? (target.querySelector(".ytp-chrome-bottom")?.offsetHeight || 48) + 14 : Math.round(height * 0.05);
      const size = subtitleSize(height, settings.scale);
      const key = `${bottom}:${size}`;
      if (key === layoutKey) return;
      layoutKey = key;
      host.style.setProperty("--notype-bottom", `${bottom}px`);
      host.style.setProperty("--notype-size", `${size}px`);
    }

    function update() {
      const id = location.pathname === "/watch" ? new URLSearchParams(location.search).get("v") || "" : "";
      if (id !== videoId) switchVideo(id);
      const target = document.querySelector("#movie_player");
      const video = target?.querySelector("video");
      if (!id || !target || !video) { detach(); return; }
      attach(target);
      const captured = tracks.get(id);
      if (captured && captured !== track) { track = captured; track.texts ??= new Set(track.sentences.map((sentence) => sentence.text)); scheduledTime = NaN; }
      const button = target.querySelector(".ytp-subtitles-button");
      const usable = !!button && button.getClientRects().length > 0 && button.getAttribute("aria-disabled") !== "true";
      const pressed = button?.getAttribute("aria-pressed") === "true";
      // Respect the user turning CC off: hide everything and stop re-enabling it.
      if (lastPressed === true && !pressed && track) captionsWanted = false;
      if (pressed) captionsWanted = true;
      lastPressed = pressed;
      const ad = target.classList.contains("ad-showing");
      // Turn CC on once per video, also when an earlier track is cached but CC is off now.
      if (usable && !pressed && !ad && captionsWanted && clickedFor !== id) { clickedFor = id; button.click(); }
      if (!track && pressed && !refetched && performance.now() - videoSince > 1500) { refetched = true; void refetch(id); }

      const showing = pressed && !!track && !ad;
      target.toggleAttribute("data-notype-subtitles", showing);
      box.hidden = !showing;
      let waiting = false;
      if (showing) {
        layout(target);
        const time = video.currentTime * 1000;
        // The original follows the caption line; the translation follows its whole sentence.
        const cue = track.cues[findCue(track.cues, time)];
        const sentence = track.sentences[findCue(track.sentences, time)];
        const entry = sentence && needsTranslation(sentence.text) ? translations.get(sentence.text) : null;
        const lines = subtitleLines(cue?.text || "", entry?.status === "done" ? translationAt(entry.result, sentence, cue, time) : "", settings.showOriginal);
        setLine(original, lines.original);
        setLine(translated, lines.translated);
        waiting = !!entry && ["pending", "waiting"].includes(entry.status) && !stopped;
        schedule(time, video.playbackRate);
      }

      // Count only this video's failures; earlier videos keep theirs for a later retry.
      const key = showing ? `${results}:${track.url}` : "";
      if (key !== failuresKey) {
        failuresKey = key; failures = 0; failureReason = "";
        if (showing) for (const entry of translations.values()) {
          if (entry.status === "failed" && track.texts.has(entry.text)) { failures++; failureReason = entry.error || failureReason; }
        }
      }
      if (errorMessage) setStatus(`NoType 字幕翻译已停止：${errorMessage} 再次点击插件按钮可关闭。`);
      else if (showing && failures) setStatus(`NoType：${failures} 条字幕翻译失败，点击重试。`, !requests.size, failureReason);
      else if (!track && !ad) {
        const settled = performance.now() - videoSince > 1500;
        setStatus(pressed ? (settled ? "NoType：正在读取字幕…（若一直无字幕，请刷新页面）" : "") :
          // Also covers a player that ignored the automatic CC click.
          usable ? (!captionsWanted || (clickedFor === id && settled) ? "NoType：打开字幕（CC）后显示双语字幕。" : "") :
          settled ? "NoType：此视频没有可用字幕。" : "");
      } else setStatus(waiting ? "NoType：正在翻译字幕…" : "");
    }
    function tick() {
      if (globalThis.__noTypeBilingual !== state) return;
      frame = requestAnimationFrame(tick);
      try { update(); }
      catch (error) { if (!stopped) fail(error?.message || String(error)); }
    }
    tick();
  }

  globalThis.__noTypeYouTubeSubtitles = {
    applies, start, parseTimedText, buildCues, buildSentences, translationAt, findCue, capture,
    subtitleSettings, subtitleSize, subtitleLines,
  };
})();
