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
