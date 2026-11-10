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
test('accepts only same-origin timed text bound to a video', () => {
  const yt = load();
  const text = JSON.stringify({ events: [{ tStartMs: 0, dDurationMs: 1000, segs: [{ utf8: 'Hi' }] }] });
  const message = (url, extra = {}) => ({ source: 'notype-youtube', type: 'timedtext', url, text, ...extra });
  const track = yt.capture(message('/api/timedtext?v=abc&lang=en&fmt=json3'), href);
  assert.equal(track.video, 'abc'); assert.equal(track.translated, false); assert.equal(track.cues.length, 1);
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
