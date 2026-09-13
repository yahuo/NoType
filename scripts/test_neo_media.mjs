// Exercise the shipped page's audio playback and microphone ownership without a device or network.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../Sources/NoType/Services/CodexRealtimeService.swift', import.meta.url), 'utf8');
const page = source.match(/static let page = #"""([\s\S]*?)"""#/)[1];
const script = page.match(/<script>([\s\S]*?)<\/script>/)[1];
const shutdown = source.match(/web\.evaluateJavaScript\("([^"]*neo\.stop\(\)[^"]*)"\)/)[1];

function harness(pendingPermission = false) {
  const state = {stops: 0, peerCloses: 0, audioCloses: 0, messages: [], sent: [], now: 1000, input: 0, output: 0, timeouts: new Map()};
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
      return {fftSize: 256, getFloatTimeDomainData(values) { values.fill(output ? state.output : state.input); }};
    }
    createMediaStreamSource() { return {connect() {}}; }
    close() { state.audioCloses++; }
  }
  class Audio { muted = false; constructor() { state.audio = this; } async play() {} pause() {} }
  const context = vm.createContext({
    window: {webkit: {messageHandlers: {neo: {postMessage: message => state.messages.push(message)}}}},
    navigator: {mediaDevices: {getUserMedia: () => permission}},
    RTCPeerConnection: Peer, AudioContext, Audio,
    performance: {now: () => state.now},
    setInterval: callback => { state.tick = callback; return 1; },
    clearInterval() { state.tick = null; },
    setTimeout(callback, delay) { const token = {}; state.timeouts.set(token, {callback, at: state.now + delay}); return token; },
    clearTimeout(token) { state.timeouts.delete(token); },
  });
  vm.runInContext(script, context);
  return {
    state, context, grant, track,
    offer: () => vm.runInContext('neo.offer()', context),
    stop: () => vm.runInContext(shutdown, context),
    finish: () => vm.runInContext('neo.finishAfterReply()', context),
    greet: () => vm.runInContext('neo.greet()', context),
    event(value) { state.channel.onmessage({data: JSON.stringify(value)}); },
    receive(role, end_ms) { state.channel.onmessage({data: JSON.stringify({type: 'turn.done', turn: {role, end_ms}})}); },
    advance(ms, output = 0, input = 0) {
      state.now += ms; state.output = output; state.input = input; state.tick?.();
      for (const [token, timeout] of state.timeouts) {
        if (timeout.at <= state.now) { state.timeouts.delete(token); timeout.callback(); }
      }
    },
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
  assert.equal(test.state.audio.muted, false, 'A late audio track must still play grounded progress during delegation');
  test.advance(100, 0.1);
  assert.equal(test.state.messages.at(-1).speaking, true, 'Progress audio must remain audible and visible while the backend is working');
  assert.equal(test.track.enabled, true, 'The user must be able to keep talking and interrupt during delegation');
  test.stop();
}
{
  const test = harness();
  await test.offer();
  await test.state.peer.ontrack({streams: [{}]});
  test.state.channel.onmessage({data: JSON.stringify({type: 'delegation.created'})});
  test.receive('user', 2000);
  test.finish();
  test.state.channel.onmessage({data: JSON.stringify({type: 'delegation.created'})});
  test.advance(100, 0.1);
  assert.equal(test.state.audio.muted, false, 'An in-flight delegation must not silence the farewell');
  assert.equal(test.ended(), 0);
  test.receive('assistant', 4000);
  test.advance(800);
  assert.equal(test.ended(), 1);
  test.stop();
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
{
  const test = harness();
  await test.offer();
  await test.state.peer.ontrack({streams: [{}]});
  for (let i = 0; i < 150; i++) {
    test.advance(100, 0.1, i % 50 < 5 ? 0.02 : 0.005);
    assert.equal(test.state.audio.muted, false, 'Recurring background noise must not punch holes in remote audio');
    assert.equal(test.state.messages.at(-1).speaking, true, 'The HUD must reflect the audio being received');
  }
  for (let i = 0; i < 70; i++) {
    test.advance(100, 0.1, 0.05);
    assert.equal(test.state.audio.muted, false, 'Sustained microphone input must leave turn-taking to the model');
  }
  assert.equal(test.track.enabled, true, 'The model must keep receiving microphone input while speaking');
  assert.equal(test.state.sent.length, 0, 'Microphone levels must not inject interruption instructions');
  test.stop();
}
{
  const test = harness();
  await test.offer();
  await test.state.peer.ontrack({streams: [{}]});
  test.advance(100, 0.1);
  const events = [
    {type: 'turn.created', turn: {id: 'old', role: 'assistant', end_ms: 1200}},
    {type: 'turn.created', turn: {id: 'user', role: 'user', end_ms: 2000}},
    {type: 'turn.done', turn: {id: 'old', role: 'assistant', end_ms: 2000}},
    {type: 'turn.created', turn: {id: 'new', role: 'assistant', end_ms: 3000}},
    {type: 'turn.done', turn: {id: 'user', role: 'user', end_ms: 3000, transcript: '停一下，只说收到。'}},
    {type: 'turn.created', turn: {id: 'old', role: 'assistant', end_ms: 1200}},
  ];
  for (const event of events) {
    test.event(event);
    assert.equal(test.state.audio.muted, false, 'Transcript events must not gate remote audio playback');
    assert.equal(test.state.sent.length, 0, 'Transcript events must not tell the model when to stop or answer');
  }
  assert.equal(test.state.messages.at(-1).text, '停一下，只说收到。', 'User transcripts must still reach the native command handler');
  assert.equal(test.track.enabled, true);
  test.stop();
}
{
  const test = harness();
  await test.offer();
  await test.state.peer.ontrack({streams: [{}]});
  for (const output of [0.1, 0, 0, 0.1, 0.1, 0, 0.1]) {
    test.advance(100, output, 0.05);
    assert.equal(test.state.audio.muted, false, 'Model-selected pauses and speech must pass through without a local hold');
    assert.equal(test.state.messages.at(-1).speaking, output > 0, 'Speaking state must follow remote audio even while the microphone is active');
  }
  assert.equal(test.state.sent.length, 0, 'Playback must not require a local resume command');
  test.stop();
}
{
  const test = harness();
  await test.offer();
  await test.state.peer.ontrack({streams: [{}]});
  test.event({type: 'turn.created', turn: {id: 'old', role: 'assistant', end_ms: 1200}});
  for (let i = 0; i < 3; i++) test.advance(100, 0.1, 0.05);
  test.event({type: 'turn.created', turn: {id: 'user', role: 'user', end_ms: 1800}});
  test.receive('user', 2000);
  test.finish();
  test.event({type: 'turn.created', turn: {id: 'farewell', role: 'assistant', end_ms: 2200}});
  test.advance(300, 0.1);
  assert.equal(test.state.audio.muted, false, 'Ending during playback must still make the farewell audible');
  test.receive('assistant', 4000);
  test.advance(799);
  assert.equal(test.ended(), 0, 'The farewell must finish even after barge-in');
  test.advance(1);
  assert.equal(test.ended(), 1);
  test.stop();
}
{
  const test = harness();
  await test.offer();
  test.state.peer.connectionState = 'failed';
  test.state.peer.iceConnectionState = 'failed';
  test.state.peer.onconnectionstatechange();
  assert.equal(test.state.messages.at(-1).reason, 'peer_failed', 'Connection errors must identify the failing media stage');
  test.state.channel.onerror();
  assert.equal(test.state.messages.at(-1).reason, 'data_channel_error');
  test.state.channel.onclose();
  assert.equal(test.state.messages.at(-1).reason, 'data_channel_closed');
  test.stop();
}
{
  const test = harness();
  await test.offer();
  test.state.peer.connectionState = 'disconnected';
  test.state.peer.onconnectionstatechange();
  test.advance(4900);
  assert.equal(test.state.messages.some(message => message.type === 'error'), false, 'A transient disconnection must be allowed to recover');
  test.state.peer.connectionState = 'connected';
  test.state.peer.onconnectionstatechange();
  test.advance(5000);
  assert.equal(test.state.messages.some(message => message.type === 'error'), false, 'Recovery must cancel the pending disconnect error');
  test.stop();
}
{
  const test = harness();
  await test.offer();
  test.state.peer.connectionState = 'disconnected';
  test.state.peer.onconnectionstatechange();
  test.advance(5000);
  assert.equal(test.state.messages.at(-1).reason, 'peer_disconnected_timeout', 'A persistent disconnect must still release the failed call');
  test.state.peer.onconnectionstatechange();
  test.stop();
  assert.equal(test.state.timeouts.size, 0, 'Closing a call must cancel its disconnect timer');
}
console.log('Neo media lifecycle: 20 scenarios passed');
