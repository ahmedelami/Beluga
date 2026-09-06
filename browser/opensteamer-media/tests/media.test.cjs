"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const crypto = require("node:crypto");
const root = path.resolve(__dirname, "..");
const read = name => fs.readFileSync(path.join(root, name), "utf8");
const id = () => crypto.randomUUID();
const extensionID = "dhmdpbpcldmnkjfibepklolofapiceab";
const epochTime = 1788710000000;
function event() { const listeners = []; return { addListener: fn => listeners.push(fn), fire: (...args) => listeners.map(fn => fn(...args)) }; }
function timers() {
  let wall = epochTime, monotonic = epochTime, count = 0;
  const jobs = new Map();
  return {
    Date: class extends Date { static now() { return wall; } },
    performance: { timeOrigin: epochTime, now: () => monotonic - epochTime },
    setTimeout: (fn, delay) => { jobs.set(++count, { fn, at: monotonic + delay }); return count; },
    clearTimeout: key => jobs.delete(key),
    setInterval: () => ++count,
    advance: (milliseconds, wallDelta = milliseconds) => { monotonic += milliseconds; wall += wallDelta; for (const [key, job] of jobs) if (job.at <= monotonic) { jobs.delete(key); job.fn(); } },
    now: () => wall,
    mono: () => monotonic,
  };
}
function port(sender, name = "youtube-media-v1") {
  const result = { sender, name, sent: [], onMessage: event(), onDisconnect: event(), disconnected: false, postMessage(message) { this.sent.push(structuredClone(message)); }, disconnect() { if (!this.disconnected) { this.disconnected = true; this.onDisconnect.fire(); } } };
  return result;
}
function worker(source = read("worker.js"), browserAPIs = {}) {
  const time = timers();
  const natives = [];
  const runtime = { id: extensionID, onConnect: event(), onMessage: event(), onInstalled: event(), getURL: file => `chrome-extension://${extensionID}/${file}`, connectNative: name => { assert.equal(name, "org.example.opensteamer.media"); const native = port(); natives.push(native); return native; } };
  const context = vm.createContext({ chrome: { runtime, ...browserAPIs }, crypto, TextEncoder, ...time });
  vm.runInContext(source, context, { filename: "worker.js" });
  function connect(tab = 1, document = id(), modifications = {}) {
    const p = port({ id: extensionID, frameId: 0, tab: { id: tab }, documentId: document, origin: "https://www.youtube.com", url: "https://www.youtube.com/watch?v=test", ...modifications });
    runtime.onConnect.fire(p);
    return p;
  }
  function state(p, item) { const epoch = p.sent.findLast(m => m.type === "reset")?.epoch; p.onMessage.fire({ type: "state", epoch, item }); }
  return { time, runtime, natives, connect, state, native: () => natives.at(-1) };
}
function item(properties = {}) { return { contextID: id(), sourceName: "YouTube", title: "Track", playbackRate: 1, playbackState: "playing", canPlay: false, canPause: true, canSkipForward: true, canSkipBackward: false, ...properties }; }
function command(contextID, now = epochTime, properties = {}) { return { v: 1, type: "command", id: id(), contextID, command: "skipForward", issuedAtMilliseconds: now, ...properties }; }
function commands(p) { return p.sent.filter(m => m.type === "command"); }
function lastState(h) { return h.native().sent.findLast(m => m.type === "state"); }
function lastResult(h) { return h.native().sent.findLast(m => m.type === "result"); }

test("manifest limits native messaging and install scripting to exact YouTube host", () => {
  const manifest = JSON.parse(read("manifest.json"));
  const calculated = crypto.createHash("sha256").update(Buffer.from(manifest.key, "base64")).digest("hex").slice(0, 32).replace(/[0-9a-f]/g, digit => String.fromCharCode(97 + parseInt(digit, 16)));
  assert.equal(calculated, extensionID);
  assert.deepEqual(manifest.permissions, ["nativeMessaging", "scripting"]);
  assert.deepEqual(manifest.host_permissions, ["https://www.youtube.com/*"]);
  assert.equal(manifest.web_accessible_resources, undefined);
  assert.deepEqual(manifest.content_scripts.map(s => s.world), ["MAIN", "ISOLATED"]);
  for (const script of manifest.content_scripts) { assert.deepEqual(script.matches, ["https://www.youtube.com/*"]); assert.equal(script.all_frames, false); }
});

test("installation bootstraps existing exact YouTube documents with bundled files without reload", async () => {
  const url = "https://www.youtube.com/watch?v=existing", documentID = id(), calls = [];
  const h = worker(read("worker.js"), {
    tabs: { query: async query => { assert.equal(query.url, "https://www.youtube.com/*"); return [{ id: 7, url }, { id: 8, url: "https://evil.example/" }]; }, get: async tabID => { assert.equal(tabID, 7); return { id: tabID, url }; } },
    scripting: { executeScript: async options => {
      calls.push(structuredClone(options));
      if (options.files[0] === "document-identity.js") return [{ frameId: 0, documentId: documentID, result: vm.runInNewContext(read("document-identity.js"), { location: { origin: "https://www.youtube.com", href: url } }) }];
      return [{ frameId: 0, documentId: documentID }];
    } },
  });
  h.runtime.onInstalled.fire({ reason: "install" });
  await new Promise(setImmediate);
  assert.equal(calls.length, 3);
  assert.deepEqual(calls.map(c => [c.world, c.files[0]]), [["ISOLATED", "document-identity.js"], ["MAIN", "adapter.js"], ["ISOLATED", "bridge.js"]]);
  for (const injection of calls.slice(1)) { assert.deepEqual(injection.target, { tabId: 7, documentIds: [documentID] }); assert.equal(injection.injectImmediately, true); }
  h.runtime.onInstalled.fire({ reason: "chrome_update" }); await new Promise(setImmediate);
  assert.equal(calls.length, 3);
});

test("installation rejects URL replacement and never falls back from retired document ID", async () => {
  for (const phase of ["observation", "fresh-check", "main-injection"]) {
    const url = "https://www.youtube.com/watch?v=existing", changed = "https://www.youtube.com/watch?v=replaced", documentID = id(), calls = [];
    const h = worker(read("worker.js"), {
      tabs: { query: async () => [{ id: 7, url }], get: async () => ({ id: 7, url: phase === "fresh-check" ? changed : url }) },
      scripting: { executeScript: async options => {
        calls.push(structuredClone(options));
        if (options.files[0] === "document-identity.js") return [{ frameId: 0, documentId: documentID, result: phase === "observation" ? changed : url }];
        if (phase === "main-injection") throw new Error("document no longer exists");
        return [];
      } },
    });
    h.runtime.onInstalled.fire({ reason: "install" }); await new Promise(setImmediate);
    assert.equal(calls.length, phase === "main-injection" ? 2 : 1);
    assert.equal(calls.some(call => call.files.includes("bridge.js")), false);
  }
});

test("worker chooses newly playing, retains fresh selected paused, clears stale state", () => {
  const h = worker(), a = h.connect(1), b = h.connect(2);
  const first = item(), second = item();
  h.state(a, first); h.time.advance(10); h.state(b, second);
  assert.equal(lastState(h).item.contextID, second.contextID);
  h.state(a, { ...first, playbackState: "paused", playbackRate: 0 });
  h.state(b, { ...second, playbackState: "paused", playbackRate: 0 });
  h.time.advance(20); h.state(a, { ...first, playbackState: "paused", playbackRate: 0 });
  assert.equal(lastState(h).item.contextID, second.contextID);
  h.time.advance(3001); h.state(a, null);
  assert.equal(lastState(h).item, null);
  assert.ok(h.native().sent.filter(m => m.type === "state").every((m, i) => m.revision === i + 1));
});

test("two playing tabs retain selection across heartbeats until a new playing item or transition", () => {
  const h = worker(), a = h.connect(1), b = h.connect(2);
  const first = item(), second = item(), replacement = item();
  h.state(a, first); h.time.advance(10); h.state(b, { ...second, playbackState: "paused", playbackRate: 0 });
  assert.equal(lastState(h).item.contextID, first.contextID);
  h.time.advance(10); h.state(b, second);
  assert.equal(lastState(h).item.contextID, second.contextID);
  for (let i = 0; i < 3; i++) {
    h.time.advance(100); h.state(a, { ...first, elapsedTime: i });
    assert.equal(lastState(h).item.contextID, second.contextID);
    h.time.advance(100); h.state(b, { ...second, elapsedTime: i });
    assert.equal(lastState(h).item.contextID, second.contextID);
  }
  h.state(a, replacement);
  assert.equal(lastState(h).item.contextID, replacement.contextID);
  h.time.advance(100); h.state(b, second);
  assert.equal(lastState(h).item.contextID, replacement.contextID);
  h.state(b, { ...second, playbackState: "paused", playbackRate: 0 });
  h.state(b, second);
  assert.equal(lastState(h).item.contextID, second.contextID);
});

test("worker rejects malformed, oversized, foreign and subframe sources", () => {
  const h = worker();
  for (const modifications of [{ id: "other" }, { frameId: 1 }, { origin: "https://evil.example" }, { url: "https://www.youtube.com.evil.example/" }, { documentId: undefined }]) assert.equal(h.connect(1, id(), modifications).disconnected, true);
  const p = h.connect(), valid = item();
  for (const invalid of [item({ title: "é".repeat(257) }), item({ title: "bad\nmetadata" }), item({ title: "bad\u0085metadata" }), item({ title: " " }), item({ artist: " " }), item({ artist: "é".repeat(129) }), item({ playbackRate: 17 }), item({ playbackRate: 0 }), item({ duration: NaN }), item({ duration: 31536001 }), item({ elapsedTime: 31536001 }), item({ elapsedTime: -1 }), item({ sourceName: "Music" }), item({ contextID: "invalid" }), item({ contextID: [id()] }), item({ canPlay: 1 }), item({ secret: "extra" }), item({ title: "x".repeat(5000) })]) { h.state(p, invalid); assert.equal(lastState(h).item, null); }
  h.state(p, valid); assert.equal(lastState(h).item.title, "Track");
});

test("worker command TTL preserves remaining lifetime and rejects future, old, replay, wrong context", () => {
  const h = worker(), p = h.connect(), media = item(); h.state(p, media);
  for (const issued of [h.time.now() + 1, h.time.now() - 1000, h.time.now() - 1001]) { h.native().onMessage.fire(command(media.contextID, issued)); assert.equal(lastResult(h).result, "failed"); }
  h.native().onMessage.fire(command(id())); assert.equal(lastResult(h).result, "staleContext");
  const request = command(media.contextID, h.time.now() - 700);
  h.native().onMessage.fire(request); h.native().onMessage.fire(request);
  assert.equal(commands(p).length, 1);
  assert.equal(commands(p)[0].deadline, h.time.mono() + 300);
  h.time.advance(301);
  assert.equal(lastResult(h).result, "failed");
  p.onMessage.fire({ type: "result", epoch: commands(p)[0].epoch, id: request.id, contextID: media.contextID, result: "applied" });
  assert.equal(lastResult(h).result, "failed");
});

test("worker fences command results by exact port, document, epoch and context", () => {
  const h = worker(), a = h.connect(1), b = h.connect(2), media = item(); h.state(a, media);
  const request = command(media.contextID); h.native().onMessage.fire(request);
  const epoch = commands(a)[0].epoch;
  b.onMessage.fire({ type: "result", epoch, id: request.id, contextID: media.contextID, result: "applied" });
  a.onMessage.fire({ type: "result", epoch: id(), id: request.id, contextID: media.contextID, result: "applied" });
  a.onMessage.fire({ type: "result", epoch, id: request.id, contextID: id(), result: "applied" });
  assert.equal(lastResult(h), undefined);
  h.connect(1);
  assert.equal(a.disconnected, true);
  assert.equal(lastResult(h).result, "staleContext");
  assert.equal(lastState(h).item, null);
});

test("worker native disconnection rotates contexts and never retransmits command", () => {
  const h = worker(), p = h.connect(), media = item(); h.state(p, media);
  const request = command(media.contextID); h.native().onMessage.fire(request);
  const oldEpoch = commands(p)[0].epoch;
  h.native().disconnect();
  assert.notEqual(p.sent.at(-1).epoch, oldEpoch);
  h.time.advance(1000);
  assert.equal(lastState(h).item, null);
  p.onMessage.fire({ type: "state", epoch: oldEpoch, item: media });
  assert.equal(lastState(h).item, null);
  assert.equal(commands(p).length, 1);
});

test("only exact extension popup can authorize Music; timeout is bounded", () => {
  const h = worker();
  const authorization = { v: 1, type: "authorizeMusic", id: id() };
  const popup = { id: extensionID, url: h.runtime.getURL("popup.html") };
  const replies = [];
  for (const sender of [{ ...popup, tab: { id: 1 } }, { ...popup, id: "other" }, { ...popup, url: "https://www.youtube.com/" }, { ...popup, url: h.runtime.getURL("popup.html?forged") }]) assert.deepEqual(h.runtime.onMessage.fire(authorization, sender, response => replies.push(response)), [false]);
  assert.equal(h.native().sent.some(m => m.type === "authorizeMusic"), false);
  assert.deepEqual(h.runtime.onMessage.fire(authorization, popup, response => replies.push(response)), [true]);
  h.native().onMessage.fire({ v: 1, type: "permissionResult", id: authorization.id, result: "authorized" });
  assert.equal(replies.at(-1).result, "authorized");
  h.runtime.onMessage.fire({ ...authorization, id: id() }, popup, response => replies.push(response));
  h.time.advance(30000); assert.equal(replies.at(-1).result, "unavailable");
});

test("worker ignores malformed native input and bounds pending commands without replay", () => {
  const h = worker(), p = h.connect(), media = item(); h.state(p, media);
  for (const request of [command(media.contextID, epochTime, { v: 2 }), command(media.contextID, epochTime, { id: [id()] }), command(media.contextID, epochTime, { command: "seek" }), command(media.contextID, epochTime, { issuedAtMilliseconds: 1.5 }), command(media.contextID, epochTime, { extra: true }), command(media.contextID, epochTime, { extra: "x".repeat(4097) })]) h.native().onMessage.fire(request);
  assert.equal(commands(p).length, 0);
  for (let i = 0; i < 33; i++) h.native().onMessage.fire(command(media.contextID));
  assert.equal(commands(p).length, 32); assert.equal(lastResult(h).result, "failed");
  h.time.advance(1000);
  assert.equal(h.native().sent.filter(m => m.type === "result").length, 33);
});

function bridge() {
  const time = timers(), events = new Map(), sent = [], ports = [];
  const window = { addEventListener: (name, fn) => { const callbacks = events.get(name) || []; callbacks.push(fn); events.set(name, callbacks); }, postMessage: message => sent.push(structuredClone(message)) };
  const runtime = { connect: options => { assert.equal(options.name, "youtube-media-v1"); const p = port(); ports.push(p); return p; } };
  const context = vm.createContext({ window, location: { origin: "https://www.youtube.com" }, chrome: { runtime }, TextEncoder, ...time });
  vm.runInContext(read("bridge.js"), context, { filename: "bridge.js" });
  const emit = (name, value) => (events.get(name) || []).forEach(fn => fn(value));
  const page = (payload, origin = "https://www.youtube.com") => emit("message", { source: window, origin, data: { channel: "opensteamer-youtube-media-v1", direction: "adapter", ...payload } });
  return { time, sent, ports, page, emit, port: () => ports.at(-1), reinject: () => vm.runInContext(read("bridge.js"), context) };
}

test("isolated bridge never forwards page permission requests or unsolicited results", () => {
  const h = bridge(), epoch = id(), media = item();
  h.port().onMessage.fire({ type: "reset", epoch });
  h.page({ type: "state", epoch, item: media }); assert.equal(h.port().sent.length, 1);
  h.page({ type: "authorizeMusic", epoch, id: id() });
  h.page({ type: "result", epoch, id: id(), contextID: media.contextID, result: "applied" });
  h.page({ type: "state", epoch, item: media }, "https://evil.example");
  h.page({ type: "state", epoch: id(), item: media });
  assert.equal(h.port().sent.length, 1);
  const request = command(media.contextID);
  h.port().onMessage.fire({ type: "command", epoch, command: request, deadline: h.time.mono() + 400 });
  assert.equal(h.sent.at(-1).deadline, h.time.mono() + 400);
  h.page({ type: "result", epoch, id: request.id, contextID: id(), result: "applied" });
  assert.equal(h.port().sent.length, 1);
  h.page({ type: "result", epoch, id: request.id, contextID: media.contextID, result: "applied" });
  assert.equal(h.port().sent.at(-1).result, "applied");
  h.page({ type: "result", epoch, id: request.id, contextID: media.contextID, result: "applied" });
  assert.equal(h.port().sent.length, 2);
});

test("isolated bridge revokes on disconnect and pagehide and rejects expired dispatch", () => {
  const h = bridge(), epoch = id(), request = command(id());
  h.port().onMessage.fire({ type: "reset", epoch });
  h.port().onMessage.fire({ type: "command", epoch, command: request, deadline: h.time.mono() - 1 });
  assert.equal(h.sent.some(m => m.type === "command"), false);
  assert.equal(h.port().sent.at(-1).result, "failed");
  h.port().disconnect(); assert.equal(h.sent.at(-1).epoch, null);
  h.time.advance(1000); assert.equal(h.ports.length, 2);
  h.page({ type: "state", epoch, item: item() }); assert.equal(h.port().sent.length, 0);
  h.emit("pagehide"); assert.equal(h.port().disconnected, true);
  h.time.advance(1000); assert.equal(h.ports.length, 2);
  h.emit("pageshow"); assert.equal(h.ports.length, 3);
});

function adapter(source = read("adapter.js")) {
  const time = timers(), events = new Map(), documentEvents = new Map(), sent = [];
  class Element {
    constructor() { this.isConnected = true; this.disabled = false; this.attributes = {}; this.style = { display: "block", visibility: "visible" }; this.clicks = 0; }
    getAttribute(key) { return this.attributes[key]; }
    getClientRects() { return this.hidden ? [] : [{}]; }
    click() { this.clicks++; }
  }
  class Media extends Element { play() { this.paused = false; this.plays++; return Promise.resolve(); } pause() { this.paused = true; this.pauses++; } }
  class Video extends Media { constructor() { super(); Object.assign(this, { readyState: 4, currentSrc: "blob:source-1", currentTime: 10, duration: 120, paused: false, ended: false, playbackRate: 1, plays: 0, pauses: 0 }); } }
  let video = new Video();
  const next = new Element(), previous = new Element(); previous.hidden = true;
  let player = new Element();
  const populate = p => { p.querySelector = selector => selector === "video.html5-main-video" ? video : selector === ".ytp-next-button" ? next : previous; };
  populate(player);
  const window = { addEventListener: (name, fn) => { const callbacks = events.get(name) || []; callbacks.push(fn); events.set(name, callbacks); }, postMessage: message => sent.push(structuredClone(message)) };
  const document = { title: "Fallback - YouTube", querySelector: () => player, addEventListener: (name, fn) => { const callbacks = documentEvents.get(name) || []; callbacks.push(fn); documentEvents.set(name, callbacks); } };
  const location = { origin: "https://www.youtube.com", href: "https://www.youtube.com/watch?v=video1" };
  const navigator = { mediaSession: { metadata: { title: "Example", artist: "Artist" }, playbackState: "paused" } };
  const context = vm.createContext({ window, document, location, navigator, crypto, URL, TextEncoder, HTMLElement: Element, HTMLMediaElement: Media, HTMLVideoElement: Video, getComputedStyle: element => element.style, ...time });
  vm.runInContext(source, context, { filename: "adapter.js" });
  const emit = (name, value) => (events.get(name) || []).forEach(fn => fn(value));
  const doc = name => (documentEvents.get(name) || []).forEach(fn => fn());
  let epoch = id();
  const message = payload => emit("message", { source: window, origin: location.origin, data: { channel: "opensteamer-youtube-media-v1", direction: "bridge", epoch, ...payload } });
  message({ type: "reset" });
  const state = () => sent.findLast(m => m.type === "state")?.item;
  const run = (request = command(state().contextID, time.now()), deadline = time.mono() + 1000) => { message({ type: "command", command: request, deadline }); return request; };
  return { time, navigator, location, next, previous, sent, doc, message, state, run, video: () => video, replaceVideo: () => { video = new Video(); }, replacePlayer: () => { player = new Element(); populate(player); }, reset: () => { epoch = id(); message({ type: "reset" }); }, reinject: () => vm.runInContext(source, context) };
}

test("duplicate static/install injections do not create a second adapter or bridge", () => {
  const a = adapter(), originalContext = a.state().contextID;
  a.reinject(); assert.equal(a.state().contextID, originalContext);
  const count = a.sent.length; a.reset(); assert.equal(a.sent.length, count + 1);
  a.run(); assert.equal(a.next.clicks, 1);
  const b = bridge(); b.reinject(); assert.equal(b.ports.length, 1);
});

test("adapter strips control text, omits blank artist and invalid times, and uses safe valid-item fallback", () => {
  const h = adapter();
  h.navigator.mediaSession.metadata = { title: "One\nTwo\u0085Three", artist: " \n\t\u0085 " };
  h.video().duration = 31536001; h.video().currentTime = 31536001; h.doc("loadedmetadata");
  assert.equal(h.state().title, "One Two Three"); assert.equal(h.state().artist, undefined);
  assert.equal(h.state().duration, undefined); assert.equal(h.state().elapsedTime, undefined);
  h.navigator.mediaSession.metadata.title = "\n\t"; h.doc("loadedmetadata"); assert.equal(h.state().title, "YouTube");
  h.video().playbackRate = 0; h.doc("ratechange"); assert.equal(h.state().playbackState, "paused");
  h.video().readyState = 0; h.doc("emptied"); assert.equal(h.state(), null);
});

test("adapter derives real playback, clips UTF-8 metadata and exposes actual controls", () => {
  const h = adapter();
  assert.equal(h.state().playbackState, "playing");
  assert.equal(h.state().canSkipForward, true); assert.equal(h.state().canSkipBackward, false);
  h.navigator.mediaSession.metadata.title = "🎵".repeat(200);
  h.navigator.mediaSession.metadata.artist = "é".repeat(200);
  h.doc("loadedmetadata");
  assert.equal(Buffer.byteLength(h.state().title), 512); assert.equal(Buffer.byteLength(h.state().artist), 256);
  h.video().paused = true; h.doc("pause"); assert.equal(h.state().playbackState, "paused");
  h.run(command(h.state().contextID, h.time.now(), { command: "skipBackward" }));
  assert.equal(h.sent.at(-1).result, "unsupported"); assert.equal(h.previous.clicks, 0);
});

test("adapter actual next click executes once and pause uses same exact video", () => {
  const h = adapter(), request = h.run(); h.run(request);
  assert.equal(h.next.clicks, 1);
  h.run(command(h.state().contextID, h.time.now(), { command: "pause" }));
  assert.equal(h.video().pauses, 1); assert.equal(h.video().paused, true);
});

test("adapter rejects stale navigation, item, video, player and native epochs", () => {
  for (const change of [h => { h.location.href = "https://www.youtube.com/watch?v=video2"; }, h => { h.video().currentSrc = "blob:new-source"; }, h => h.replaceVideo(), h => h.replacePlayer(), h => { h.navigator.mediaSession.metadata.title = "Another"; }, h => h.reset()]) {
    const h = adapter(), request = command(h.state().contextID); change(h); h.run(request);
    assert.equal(h.next.clicks, 0); assert.equal(h.sent.findLast(m => m.type === "result").result, "staleContext");
  }
  const h = adapter(), request = command(h.state().contextID); h.doc("yt-navigate-start"); h.run(request);
  assert.equal(h.state(), null); assert.equal(h.next.clicks, 0);
  h.doc("yt-navigate-finish"); assert.notEqual(h.state().contextID, request.contextID);
});

test("adapter never renews TTL across queue hops or clock rollback", () => {
  for (const scenario of ["expired", "monotonic", "future"]) {
    const h = adapter(), request = command(h.state().contextID), deadline = h.time.mono() + 200;
    if (scenario === "expired") h.time.advance(1001);
    if (scenario === "monotonic") h.time.advance(201, 0);
    if (scenario === "future") request.issuedAtMilliseconds++;
    h.run(request, deadline);
    assert.equal(h.next.clicks, 0); assert.equal(h.sent.at(-1).result, "failed");
  }
});

test("adapter rejects DOM mutation caused by untrusted metadata before action", () => {
  const h = adapter(), request = command(h.state().contextID);
  let reads = 0;
  Object.defineProperty(h.navigator.mediaSession.metadata, "title", { get() { if (++reads === 2) h.replaceVideo(); return "Example"; } });
  h.run(request);
  assert.equal(h.next.clicks, 0);
});

test("actual production source mutations are rejected by behavioral oracles", () => {
  const original = read("adapter.js");
  const mutants = [
    ["dedupe", "if (seen.has(command.id) || seen.size >= 2048) return;", "if (seen.size >= 2048) return;", mutant => { const h = adapter(mutant), request = h.run(); h.run(request); assert.equal(h.next.clicks, 1); }],
    ["deadline", "monotonicNow() >= deadline", "false", mutant => { const h = adapter(mutant), request = command(h.state().contextID), deadline = h.time.mono() + 100; h.time.advance(101, 0); h.run(request, deadline); assert.equal(h.next.clicks, 0); }],
    ["identity", "if (contextID !== command.contextID)", "if (false)", mutant => { const h = adapter(mutant), request = command(h.state().contextID); h.replaceVideo(); h.run(request); assert.equal(h.next.clicks, 0); }],
  ];
  for (const [name, before, after, oracle] of mutants) {
    assert.ok(original.includes(before), `mutation target exists: ${name}`);
    const mutated = original.replace(before, after);
    if (name === "identity") {
      // Remove the second copy of the same authority check as one semantic mutant.
      assert.throws(() => oracle(mutated.replace(" || contextID !== command.contextID", "")), assert.AssertionError, name);
    } else assert.throws(() => oracle(mutated), assert.AssertionError, name);
  }
  assert.equal(read("adapter.js"), original, "production source restored/unmodified after VM mutants");
  const originalWorker = read("worker.js");
  const before = "const popup = sender?.id === chrome.runtime.id && sender.url === chrome.runtime.getURL(\"popup.html\") && !sender.tab;";
  assert.ok(originalWorker.includes(before));
  assert.throws(() => {
    const h = worker(originalWorker.replace(before, "const popup = true;"));
    h.runtime.onMessage.fire({ v: 1, type: "authorizeMusic", id: id() }, { id: extensionID, url: "https://www.youtube.com/", tab: { id: 1 } }, () => {});
    assert.equal(h.native().sent.some(m => m.type === "authorizeMusic"), false);
  }, assert.AssertionError, "popup-only permission mutation is rejected");
  assert.equal(read("worker.js"), originalWorker);
});
