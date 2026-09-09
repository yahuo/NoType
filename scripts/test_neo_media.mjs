// Exercise the shipped page's microphone ownership without a device or network.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../Sources/NoType/Services/CodexRealtimeService.swift', import.meta.url), 'utf8');
const page = source.match(/static let page = #"""([\s\S]*?)"""#/)[1];
const script = page.match(/<script>([\s\S]*?)<\/script>/)[1];
const shutdown = source.match(/web\.evaluateJavaScript\("([^"]*neo\.stop\(\)[^"]*)"\)/)[1];

function harness(pendingPermission = false) {
  const state = {stops: 0, peerCloses: 0, audioCloses: 0, messages: [], sent: [], now: 1000, output: 0};
  const track = {enabled: true, stop: () => state.stops++};
  const microphone = {getTracks: () => [track]};
  let grant;
  const permission = pendingPermission ? new Promise(resolve => { grant = () => resolve(microphone); }) : Promise.resolve(microphone);
  class Peer {
    constructor() { state.peer = this; }
    iceGatheringState = 'complete';
    addTrack() {}
    createDataChannel() { state.channel = {readyState: 'open', close() {}, send(value) { state.sent.push(JSON.parse(value)); }}; return state.channel; }
    async createOffer() { return {type: 'offer', sdp: 'v=0\r\n'}; }
    async setLocalDescription(value) { this.localDescription = value; }
    close() { state.peerCloses++; }
  }
  class AudioContext {
    analysers = 0;
    async resume() {}
    createAnalyser() {
      const output = this.analysers++ > 0;
      return {fftSize: 256, getFloatTimeDomainData(values) { values.fill(output ? state.output : 0); }};
    }
    createMediaStreamSource() { return {connect() {}}; }
    close() { state.audioCloses++; }
  }
  class Audio { constructor() { state.audio = this; } async play() {} pause() {} }
  const context = vm.createContext({
    window: {webkit: {messageHandlers: {neo: {postMessage: message => state.messages.push(message)}}}},
    navigator: {mediaDevices: {getUserMedia: () => permission}},
    RTCPeerConnection: Peer, AudioContext, Audio,
    performance: {now: () => state.now},
    setInterval: callback => { state.tick = callback; return 1; },
    clearInterval() { state.tick = null; },
  });
  vm.runInContext(script, context);
  return {
    state, context, grant, track,
    offer: () => vm.runInContext('neo.offer()', context),
    stop: () => vm.runInContext(shutdown, context),
    finish: () => vm.runInContext('neo.finishAfterReply()', context),
    greet: () => vm.runInContext('neo.greet()', context),
    block: () => vm.runInContext('neo.blockReply()', context),
    reply: () => vm.runInContext('neo.prepareReply()', context),
    receive(role, end_ms) { state.channel.onmessage({data: JSON.stringify({type: 'turn.done', turn: {role, end_ms}})}); },
    advance(ms, output = 0) { state.now += ms; state.output = output; state.tick?.(); },
    ended: () => state.messages.filter(message => message.type === 'playbackEnded').length,
  };
}

{
  const test = harness();
  assert.equal(await test.offer(), 'v=0\r\n');
  test.stop();
  assert.equal(test.state.stops, 1, 'Ending must stop the microphone before page navigation');
  assert.equal(test.state.peerCloses, 1, 'Ending must close the peer');
  assert.equal(test.state.audioCloses, 1, 'Ending must close the audio context');
  test.state.channel.onopen();
  test.state.channel.onerror();
  assert.equal(test.state.messages.length, 0, 'Late transport events must not revive a closed call');
}
{
  const test = harness(true);
  const offered = test.offer();
  test.stop();
  test.grant();
  await assert.rejects(offered, /closed/);
  assert.equal(test.state.stops, 1, 'A late microphone permission result must release its tracks');
  assert.equal(test.state.peerCloses, 0, 'Cancellation before permission must not create a peer');
}
{
  const test = harness();
  await test.offer();
  const received = (role, transcript) => test.state.channel.onmessage({
    data: JSON.stringify({type: 'turn.done', turn: {role, transcript}}),
  });
  received('assistant', '结束会话。');
  assert.equal(test.state.messages.length, 0, 'Assistant speech must not trigger a user end command');
  received('user', '结束会话。');
  assert.equal(test.state.messages.length, 1);
  assert.equal(test.state.messages[0].type, 'userTurn');
  assert.equal(test.state.messages[0].text, '结束会话。', 'The final user transcript must reach the native command handler');
  test.stop();
  received('user', '结束会话。');
  assert.equal(test.state.messages.length, 1, 'Late transcripts must be ignored after ending');
}
{
  const test = harness();
  await test.offer();
  await test.state.peer.ontrack({streams: [{}]});
  test.receive('user', 2000);
  test.finish();
  assert.equal(test.track.enabled, true, 'The audio stream must stay live until the farewell has finished');
  test.advance(100, 0.1);
  test.advance(900);
  assert.equal(test.ended(), 0, 'A pause within an unfinished reply must not end the call');
  test.receive('assistant', 4000);
  test.advance(600);
  assert.equal(test.ended(), 0, 'A turn completion event is not playback completion');
  test.advance(100, 0.1);
  test.advance(799);
  assert.equal(test.ended(), 0, 'Buffered audio must finish before closing');
  test.advance(1);
  assert.equal(test.ended(), 1);
  test.advance(1000);
  assert.equal(test.ended(), 1, 'Completion must be emitted only once');
  test.stop();
}
{
  const test = harness();
  await test.offer();
  test.receive('assistant', 2000);
  test.receive('user', 2000);
  test.finish();
  test.advance(900);
  assert.equal(test.ended(), 0, 'A previous or interrupted reply must not close before the farewell');
  test.receive('assistant', 3000);
  test.advance(800);
  assert.equal(test.ended(), 1);
  test.stop();
}
{
  const test = harness();
  await test.offer();
  test.receive('assistant', 3000);
  test.receive('user', 2000);
  test.finish();
  test.advance(800);
  assert.equal(test.ended(), 1, 'A late user transcript must still recognize the completed farewell');
  test.stop();
}
{
  const test = harness();
  await test.offer();
  test.receive('user', 2000);
  test.finish();
  test.advance(9999);
  assert.equal(test.ended(), 0);
  test.advance(1);
  assert.equal(test.ended(), 1, 'A missing reply must not leave the HUD open forever');
  test.stop();
}
{
  const test = harness();
  await test.offer();
  await test.state.peer.ontrack({streams: [{}]});
  test.receive('user', 2000);
  test.finish();
  for (let i = 0; i < 3; i++) test.advance(9000, 0.1);
  assert.equal(test.ended(), 0, 'The fallback must not cut off an audible reply even if turn.done is missing');
  test.advance(10000);
  assert.equal(test.ended(), 1);
  test.stop();
}
{
  const test = harness();
  await test.offer();
  test.receive('user', 2000);
  test.finish();
  test.stop();
  test.advance(12000);
  assert.equal(test.ended(), 0, 'Manual close must cancel the pending graceful completion');
  assert.equal(test.state.stops, 1);
}
{
  const test = harness();
  await test.offer();
  test.state.channel.onmessage({data: JSON.stringify({type: 'delegation.created', item: {id: 'delegation-1'}})});
  assert.equal(test.state.sent.length, 0, 'The media page must leave tool delegation to Codex instead of returning a fake denial');
  test.stop();
}
{
  const test = harness();
  await test.offer();
  test.state.channel.onmessage({data: JSON.stringify({type: 'delegation.created'})});
  await test.state.peer.ontrack({streams: [{}]});
  assert.equal(test.state.audio.muted, true, 'Delegation must silence speculative speech even when the audio track arrives later');
  test.advance(100, 0.1);
  assert.equal(test.state.messages.at(-1).speaking, false, 'Muted speculation must not be shown as an audible answer');
  const reply = test.reply();
  let ready = false; reply.then(value => { ready = value; });
  test.advance(900);
  await Promise.resolve();
  assert.equal(ready, false, 'An unfinished speculative turn must not overlap the actual result');
  test.receive('assistant', 4000);
  test.advance(100, 0.1);
  test.advance(799);
  assert.equal(test.state.audio.muted, true, 'Buffered speculation must drain before speaking the actual result');
  test.advance(1);
  assert.equal(await reply, true);
  assert.equal(test.state.audio.muted, false);
  assert.equal(test.track.enabled, true, 'The user must still be able to interrupt while work is pending');
  test.stop();
}
{
  const test = harness();
  await test.offer();
  await test.state.peer.ontrack({streams: [{}]});
  test.block();
  const stale = test.reply();
  test.block();
  assert.equal(await stale, false, 'A new task must cancel pending speech from the previous task');
  const farewell = test.reply();
  test.finish();
  assert.equal(await farewell, false, 'Ending must cancel the queued tool result');
  assert.equal(test.state.audio.muted, false, 'Ending must allow the farewell to play');
  test.stop();
}
{
  const test = harness();
  await test.offer();
  test.block();
  const reply = test.reply();
  test.stop();
  assert.equal(await reply, false, 'Closing must release the pending playback callback');
}

{
  const test = harness();
  await test.offer();
  test.state.channel.readyState = 'connecting';
  test.greet();
  assert.equal(test.state.sent.length, 0, 'The greeting must wait for the voice channel');
  test.state.channel.readyState = 'open';
  test.greet();
  test.greet();
  assert.equal(test.state.sent.length, 1, 'Each call must greet only once');
  assert.equal(test.state.sent[0].type, 'session.context.append');
  assert.equal(test.state.sent[0].channel, 'speakable');
  assert.equal(test.state.sent[0].content[0].text, '我在，请说。');
  test.stop();
  test.greet();
  assert.equal(test.state.sent.length, 1, 'A closed call must never speak a delayed greeting');
}
console.log('Neo media lifecycle: 14 scenarios passed');
