const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const href = 'https://www.youtube.com/watch?v=abc';
function load(location = new URL(href)) {
  const context = { URL, URLSearchParams, location, addEventListener() {} };
  context.globalThis = context; context.top = context;
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../extension/youtube.js'), 'utf8'), context);
  return context.__noTypeYouTubeSubtitles;
}
const plain = (value) => JSON.parse(JSON.stringify(value));
test('parses json3, srv3 and srv1 timed text', () => {
  const yt = load();
  const json3 = JSON.stringify({ events: [{ tStartMs: 0, dDurationMs: 1500, segs: [{ utf8: 'Hello ' }, { utf8: '​world' }] },
    { tStartMs: 1500, segs: [{ utf8: '\n' }] }, { tStartMs: 'x', segs: [{ utf8: 'bad' }] }] });
  assert.deepEqual(plain(yt.parseTimedText(json3)), [{ start: 0, duration: 1500, text: 'Hello world' }]);
  assert.deepEqual(plain(yt.parseTimedText('<timedtext><body><p t="1000" d="2000">Tom &amp; <s>Jerry</s></p></body></timedtext>')),
    [{ start: 1000, duration: 2000, text: 'Tom & Jerry' }]);
  assert.deepEqual(plain(yt.parseTimedText('<transcript><text start="1.5" dur="2">It&amp;#39;s &lt;b&gt;fine</text></transcript>')),
    [{ start: 1500, duration: 2000, text: "It's <b>fine" }]);
  assert.deepEqual(plain(yt.parseTimedText('{oops')), []);
});
test('collapses incremental lines, merges word streams and clips overlaps', () => {
  const yt = load();
  const cues = yt.buildCues([
    { start: 0, duration: 1000, text: 'So' }, { start: 50, duration: 1200, text: 'So today' },
    { start: 400, duration: 400, text: 'we' }, { start: 800, duration: 400, text: 'talk about' },
    { start: 1200, duration: 400, text: 'parsers.' }, { start: 1600, duration: 400, text: 'next' },
    { start: 5000, duration: 0, text: 'A full sentence that stands on its own here.' },
    { start: 6000, duration: 3000, text: '第二行' },
  ]);
  assert.deepEqual(plain(cues), [
    { start: 0, end: 1600, text: 'So today we talk about parsers.' },
    { start: 1600, end: 2000, text: 'next' },
    { start: 5000, end: 6000, text: 'A full sentence that stands on its own here.' },
    { start: 6000, end: 9000, text: '第二行' },
  ]);
  assert.equal(yt.findCue(cues, 0), 0);
  assert.equal(yt.findCue(cues, 1599), 0);
  assert.equal(yt.findCue(cues, 3000), -1);
  assert.equal(yt.findCue(cues, 8999), 3);
  assert.equal(yt.findCue(cues, 9000), -1);
  assert.equal(yt.findCue([], 10), -1);
});
test('does not merge separate lines that happen to be short', () => {
  const yt = load();
  const cues = yt.buildCues([{ start: 0, duration: 2000, text: 'Yes.' }, { start: 2000, duration: 2000, text: 'No way' },
    { start: 6000, duration: 2000, text: 'Maybe' }]);
  assert.deepEqual(plain(cues.map((cue) => cue.text)), ['Yes.', 'No way', 'Maybe']);
  const same = yt.buildCues([{ start: 0, duration: 1000, text: '中文' }, { start: 100, duration: 1000, text: '字幕' }]);
  assert.deepEqual(plain(same), [{ start: 0, end: 1100, text: '中文字幕' }]);
});
test('sentences cross caption lines, split inside a line and get interpolated times', () => {
  const yt = load();
  const sentences = yt.buildSentences([
    { start: 0, end: 2000, text: 'One of my favorite tools that' },
    { start: 2000, end: 4000, text: 'I use is Herder. It is great' },
    { start: 4000, end: 5000, text: 'and fast.' },
    { start: 8000, end: 9000, text: 'After a pause' },
    { start: 11000, end: 12000, text: '这是中文。第二句' },
  ]);
  assert.deepEqual(plain(sentences.map((s) => s.text)), [
    'One of my favorite tools that I use is Herder.', 'It is great and fast.', 'After a pause', '这是中文。', '第二句']);
  assert.equal(sentences[0].start, 0);
  // "I use is Herder." is 16 of the 27 non-space characters of its line.
  assert.equal(Math.round(sentences[0].end), Math.round(2000 + 2000 * 16 / 27));
  assert.equal(sentences[1].start, sentences[0].end);
  assert.equal(sentences[1].end, 5000);
  assert.equal(sentences[2].end, 9000);
  assert.equal(yt.findCue(sentences, 3500), 1);
  assert.equal(yt.findCue(sentences, 6000), -1);
});
test('a long translation is shown a line-sized clause group at a time, switching with the original line', () => {
  const yt = load();
  const text = '我们可以看到，就在这里，我有一个漂亮的窗格，里面列出了我所有的空间，下方则是我的所有代理，而且我还能获得一直以来从 tmux 之类的工具中享受的所有便利功能。';
  const first = '我们可以看到，就在这里，我有一个漂亮的窗格，';
  const second = '里面列出了我所有的空间，下方则是我的所有代理，';
  const third = '而且我还能获得一直以来从 tmux 之类的工具中享受的所有便利功能。';
  assert.equal(first + second + third, text);
  const sentence = { start: 0, end: 9000 };
  const at = (time, ...cues) => yt.translationAt(text, sentence, cues.find((cue) => cue.start <= time && time < cue.end), time);
  // One group per line: each switches exactly when its line appears.
  const lines = [{ start: 0, end: 3000 }, { start: 3000, end: 6000 }, { start: 6000, end: 9000 }];
  assert.deepEqual([0, 2900, 3000, 5900, 6000, 8900].map((time) => at(time, ...lines)), [first, first, second, second, third, third]);
  // A line holding two groups shares its time by width; a line holding none keeps the group around it.
  const uneven = [{ start: 0, end: 900 }, { start: 900, end: 2000 }, { start: 2000, end: 9000 }];
  assert.deepEqual([0, 1000, 2000, 4000, 6000, 8900].map((time) => at(time, ...uneven)), [first, first, second, second, third, third]);
  // Without a caption line (a gap), the sentence time decides.
  assert.equal(at(4500), second);
  // A 3 s sentence holds at most two groups: the narrowest adjacent pair merges.
  const short = { start: 0, end: 3000 }, whole = { start: 0, end: 3000 };
  assert.equal(yt.translationAt(text, short, whole, 0), first + second);
  assert.equal(yt.translationAt(text, short, whole, 2900), third);
  assert.equal(yt.translationAt('短句，不用切。', sentence, lines[0], 100), '短句，不用切。');
  assert.equal(yt.translationAt('译文：vid1 line 0 explains the topic.', sentence, lines[0], 100), '译文：vid1 line 0 explains the topic.');
  const plainLong = '没有标点的一整段很长很长的译文'.repeat(3);
  assert.equal(yt.translationAt(plainLong, sentence, lines[1], 4000), plainLong);
});
test('titles, initials and decimals do not end a sentence; quotes and ?! runs stay with it', () => {
  const yt = load();
  const texts = (text) => plain(yt.buildSentences([{ start: 0, end: 1000, text }]).map((s) => s.text));
  assert.deepEqual(texts('Mr. Smith moved to the U.S. in 2020. Growth was 3.5 percent. "Really?!" she asked'),
    ['Mr. Smith moved to the U.S. in 2020.', 'Growth was 3.5 percent.', '"Really?!"', 'she asked']);
  assert.deepEqual(plain(yt.buildSentences([{ start: 0, end: 1000, text: 'Talk to Dr.' }, { start: 1000, end: 2000, text: 'Lee today.' }])
    .map((s) => s.text)), ['Talk to Dr. Lee today.']);
  assert.deepEqual(texts("It isn't. Use plan B. Then go"), ["It isn't.", 'Use plan B.', 'Then go']);
  const started = Date.now();
  yt.buildSentences([{ start: 0, end: 1000, text: `a${'.'.repeat(50000)}${'"'.repeat(50000)}b` }]);
  assert.ok(Date.now() - started < 200);
});
test('unpunctuated speech is cut at a clause mark after 100 characters or before 200', () => {
  const yt = load();
  const line = (n, text) => ({ start: n * 1000, end: n * 1000 + 1000, text });
  const clauses = yt.buildSentences(Array.from({ length: 6 }, (_, n) => line(n, `part ${n} of a long run of words without a stop,`)));
  assert.ok(clauses.length > 1 && clauses.every((s) => s.text.length <= 200));
  assert.ok(clauses.slice(0, -1).every((s) => s.text.length >= 100 && s.text.endsWith(',')));
  const words = yt.buildSentences(Array.from({ length: 12 }, (_, n) => line(n, `word ${n} keeps going and going on`)));
  assert.ok(words.length > 1 && words.every((s) => s.text.length <= 200));
});
test('accepts only same-origin timed text bound to a video', () => {
  const yt = load();
  const text = JSON.stringify({ events: [{ tStartMs: 0, dDurationMs: 1000, segs: [{ utf8: 'Hi' }] }] });
  const message = (url, extra = {}) => ({ source: 'notype-youtube', type: 'timedtext', url, text, ...extra });
  const track = yt.capture(message('/api/timedtext?v=abc&lang=en&fmt=json3'), href);
  assert.equal(track.video, 'abc'); assert.equal(track.translated, false); assert.equal(track.cues.length, 1);
  assert.equal(track.sentences.length, 1);
  assert.equal(yt.capture(message('/api/timedtext?v=abc&tlang=zh-Hans'), href).translated, true);
  assert.equal(yt.capture(message('https://evil.example/api/timedtext?v=abc'), href), null);
  assert.equal(yt.capture(message('/api/other?v=abc'), href), null);
  assert.equal(yt.capture(message('/api/timedtext?lang=en'), href), null);
  assert.equal(yt.capture(message('/api/timedtext?v=abc', { source: 'page' }), href), null);
  assert.equal(yt.capture(message('/api/timedtext?v=abc', { text: '{"events":[]}' }), href), null);
  assert.equal(yt.capture(message('/api/timedtext?v=abc', { text: 'x'.repeat(4000001) }), href), null);
});
test('subtitle mode applies only to the top-level watch page', () => {
  assert.equal(load().applies(), true);
  assert.equal(load(new URL('https://www.youtube.com/')).applies(), false);
  assert.equal(load(new URL('https://www.youtube.com/shorts/abc')).applies(), false);
});
test('normalizes subtitle settings, scales the size and hides only a replaced original', () => {
  const yt = load();
  assert.deepEqual(plain(yt.subtitleSettings({})), { showOriginal: true, scale: 100 });
  assert.deepEqual(plain(yt.subtitleSettings({ youtubeShowOriginal: false, youtubeFontScale: 125 })), { showOriginal: false, scale: 125 });
  assert.deepEqual(plain(yt.subtitleSettings({ youtubeShowOriginal: 'no', youtubeFontScale: 'big' })), { showOriginal: true, scale: 100 });
  assert.equal(yt.subtitleSettings({ youtubeFontScale: 500 }).scale, 160);
  assert.equal(yt.subtitleSettings({ youtubeFontScale: 10 }).scale, 70);
  assert.equal(yt.subtitleSize(480, 100), 20);
  assert.equal(yt.subtitleSize(480, 150), 30);
  assert.equal(yt.subtitleSize(2000, 100), 38);
  assert.equal(yt.subtitleSize(100, 70), 10);
  assert.deepEqual(plain(yt.subtitleLines('Hello', '你好', true)), { original: 'Hello', translated: '你好' });
  assert.deepEqual(plain(yt.subtitleLines('Hello', '你好', false)), { original: '', translated: '你好' });
  assert.deepEqual(plain(yt.subtitleLines('[Music]', '', false)), { original: '[Music]', translated: '' });
});
test('drops sound tags and lines left without words', () => {
  const yt = load();
  const json3 = JSON.stringify({ events: [
    { tStartMs: 0, dDurationMs: 1000, segs: [{ utf8: '[Music]' }] },
    { tStartMs: 1000, dDurationMs: 1000, segs: [{ utf8: '[Applause] Thank you [laughs] all.' }] },
    { tStartMs: 2000, dDurationMs: 1000, segs: [{ utf8: '♪ ♪' }] },
    { tStartMs: 3000, dDurationMs: 1000, segs: [{ utf8: '- ［笑］' }] },
    { tStartMs: 4000, dDurationMs: 1000, segs: [{ utf8: '♪ la la ♪' }] }] });
  assert.deepEqual(plain(yt.parseTimedText(json3)).map((cue) => cue.text), ['Thank you all.', '♪ la la ♪']);
  assert.deepEqual(plain(yt.parseTimedText('<timedtext><body><p t="0" d="900">[MUSIC PLAYING]</p><p t="900" d="900">Hi [ unclear ] there</p></body></timedtext>')),
    [{ start: 900, duration: 900, text: 'Hi there' }]);
});
