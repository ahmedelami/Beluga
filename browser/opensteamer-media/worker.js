"use strict";

const HOST = "org.example.opensteamer.media";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const isUUID = value => typeof value === "string" && UUID.test(value);
const COMMANDS = new Set(["play", "pause", "skipForward", "skipBackward"]);
const RESULTS = new Set(["applied", "staleContext", "unsupported", "noActiveMedia", "failed"]);
const sources = new Map();
const pending = new Map();
const seen = new Map();
const permissions = new Map();
let nativePort = null;
let selected = null;
let revision = 0;
let activityOrder = 0;
let reconnectTimer = null;
let reconnectDelay = 1000;
const monotonicNow = () => performance.timeOrigin + performance.now();
const bounded = value => { try { return new TextEncoder().encode(JSON.stringify(value)).length <= 4096; } catch { return false; } };
const exact = (value, required, optional = []) => value && typeof value === "object" && !Array.isArray(value) && required.every(k => Object.hasOwn(value, k)) && Object.keys(value).every(k => required.includes(k) || optional.includes(k));
const validText = (value, limit) => typeof value === "string" && value.trim().length > 0 && !/[\u0000-\u001f\u007f-\u009f]/.test(value) && new TextEncoder().encode(value).length <= limit;
const nonnegative = value => typeof value === "number" && Number.isFinite(value) && value >= 0;
const validTime = value => nonnegative(value) && value <= 31536000;

function validItem(item) {
  return item === null || (exact(item, ["contextID", "sourceName", "title", "playbackRate", "playbackState", "canPlay", "canPause", "canSkipForward", "canSkipBackward"], ["artist", "duration", "elapsedTime"]) && isUUID(item.contextID) && item.sourceName === "YouTube" && validText(item.title, 512) && (!Object.hasOwn(item, "artist") || validText(item.artist, 256)) && (!Object.hasOwn(item, "duration") || validTime(item.duration)) && (!Object.hasOwn(item, "elapsedTime") || validTime(item.elapsedTime)) && nonnegative(item.playbackRate) && item.playbackRate <= 16 && ["playing", "paused"].includes(item.playbackState) && (item.playbackState !== "playing" || item.playbackRate > 0) && ["canPlay", "canPause", "canSkipForward", "canSkipBackward"].every(k => typeof item[k] === "boolean"));
}

function post(port, message) {
  try { if (bounded(message)) { port.postMessage(message); return true; } } catch { /* Disconnection revokes authority below. */ }
  return false;
}

function fresh(source, now = monotonicNow()) { return source.item !== null && now - source.receivedAt <= 3000; }

function publish() {
  const now = monotonicNow();
  const playing = [...sources.values()].filter(s => fresh(s, now) && s.item.playbackState === "playing").sort((a, b) => b.lastPlayedOrder - a.lastPlayedOrder);
  selected = playing[0] || (selected && sources.get(selected.port) === selected && fresh(selected, now) ? selected : [...sources.values()].filter(s => fresh(s, now)).sort((a, b) => b.receivedAt - a.receivedAt)[0]) || null;
  if (!nativePort) return;
  if (revision === Number.MAX_SAFE_INTEGER) { nativePort.disconnect(); return; }
  post(nativePort, { v: 1, type: "state", revision: ++revision, item: selected?.item || null });
}

function result(command, value) {
  if (nativePort) post(nativePort, { v: 1, type: "result", id: command.id, contextID: command.contextID, result: value });
}

function finish(id, value) {
  const entry = pending.get(id);
  if (!entry) return;
  pending.delete(id);
  clearTimeout(entry.timer);
  result(entry.command, value);
}

function remember(id) {
  const now = monotonicNow();
  for (const [key, expiry] of seen) if (expiry < now) seen.delete(key);
  if (seen.has(id)) return false;
  // Do not evict still-live IDs: an overflow must never allow a relative replay.
  if (seen.size >= 2048) return false;
  seen.set(id, now + 60000);
  return true;
}

function receiveNative(message, port) {
  if (port !== nativePort || !bounded(message)) return;
  if (exact(message, ["v", "type", "id", "result"]) && message.v === 1 && message.type === "permissionResult" && isUUID(message.id) && ["authorized", "denied", "unavailable"].includes(message.result)) {
    const entry = permissions.get(message.id);
    if (entry) { permissions.delete(message.id); clearTimeout(entry.timer); entry.reply(message); }
    return;
  }
  if (!exact(message, ["v", "type", "id", "contextID", "command", "issuedAtMilliseconds"]) || message.v !== 1 || message.type !== "command" || !isUUID(message.id) || !isUUID(message.contextID) || !COMMANDS.has(message.command) || !Number.isSafeInteger(message.issuedAtMilliseconds)) return;
  if (!remember(message.id)) return;
  const remaining = message.issuedAtMilliseconds + 1000 - Date.now();
  if (remaining <= 0 || remaining > 1000) { result(message, "failed"); return; }
  if (!selected || !fresh(selected)) { result(message, "noActiveMedia"); return; }
  if (selected.item.contextID !== message.contextID) { result(message, "staleContext"); return; }
  if (pending.size >= 32) { result(message, "failed"); return; }
  const source = selected;
  const entry = { command: message, source, epoch: source.epoch, deadline: monotonicNow() + remaining, timer: null };
  pending.set(message.id, entry);
  entry.timer = setTimeout(() => finish(message.id, "failed"), remaining);
  if (!post(source.port, { type: "command", epoch: source.epoch, command: message, deadline: entry.deadline })) finish(message.id, "failed");
}

function revoke() {
  selected = null;
  for (const entry of pending.values()) clearTimeout(entry.timer);
  pending.clear();
  for (const source of sources.values()) { source.item = null; source.epoch = crypto.randomUUID(); post(source.port, { type: "reset", epoch: source.epoch }); }
  for (const [id, entry] of permissions) { clearTimeout(entry.timer); entry.reply({ v: 1, type: "permissionResult", id, result: "unavailable" }); }
  permissions.clear();
}

function connectNative() {
  if (nativePort) return;
  clearTimeout(reconnectTimer);
  reconnectTimer = null;
  try {
    const port = chrome.runtime.connectNative(HOST);
    nativePort = port;
    revoke();
    port.onMessage.addListener(message => receiveNative(message, port));
    port.onDisconnect.addListener(() => {
      void chrome.runtime.lastError;
      if (nativePort !== port) return;
      nativePort = null;
      revoke();
      reconnectTimer = setTimeout(connectNative, reconnectDelay);
      reconnectDelay = Math.min(reconnectDelay * 2, 10000);
    });
    publish();
  } catch {
    nativePort = null;
    revoke();
    reconnectTimer = setTimeout(connectNative, reconnectDelay);
    reconnectDelay = Math.min(reconnectDelay * 2, 10000);
  }
}

async function bootstrapExistingYouTubeTabs() {
  // Installation alone does not inject static scripts into already-open documents.
  const tabs = await chrome.tabs.query({ url: "https://www.youtube.com/*" });
  await Promise.allSettled(tabs.slice(0, 32).map(async tab => {
    if (!Number.isInteger(tab.id) || typeof tab.url !== "string" || !/^https:\/\/www\.youtube\.com\//.test(tab.url)) return;
    const observations = await chrome.scripting.executeScript({ target: { tabId: tab.id, frameIds: [0] }, world: "ISOLATED", files: ["document-identity.js"], injectImmediately: true });
    if (observations.length !== 1) return;
    const observed = observations[0];
    if (observed.frameId !== 0 || !isUUID(observed.documentId) || observed.result !== tab.url) return;
    const fresh = await chrome.tabs.get(tab.id);
    if (fresh.url !== observed.result) return;
    const target = { tabId: tab.id, documentIds: [observed.documentId] };
    await chrome.scripting.executeScript({ target, world: "MAIN", files: ["adapter.js"], injectImmediately: true });
    await chrome.scripting.executeScript({ target, world: "ISOLATED", files: ["bridge.js"], injectImmediately: true });
  }));
}

chrome.runtime.onInstalled.addListener(details => {
  if (details.reason === "install" || details.reason === "update") {
    bootstrapExistingYouTubeTabs().catch(() => { /* Removed or replaced documents require their normal static injection. */ });
  }
});

chrome.runtime.onConnect.addListener(port => {
  const sender = port.sender;
  if (port.name !== "youtube-media-v1" || sender?.id !== chrome.runtime.id || sender.frameId !== 0 || !Number.isInteger(sender.tab?.id) || typeof sender.documentId !== "string" || sender.documentId.length === 0 || sender.documentId.length > 128 || sender.origin !== "https://www.youtube.com" || !/^https:\/\/www\.youtube\.com\//.test(sender.url || "") || sources.size >= 32) { port.disconnect(); return; }
  const source = { port, tabID: sender.tab.id, documentID: sender.documentId, epoch: crypto.randomUUID(), item: null, receivedAt: 0, lastPlayedOrder: 0 };
  // A replacement document in the same tab retires its predecessor immediately.
  for (const old of sources.values()) if (old.tabID === source.tabID) {
    sources.delete(old.port);
    for (const [id, entry] of pending) if (entry.source === old) finish(id, "staleContext");
    old.port.disconnect();
  }
  sources.set(port, source);
  port.onMessage.addListener(message => {
    if (sources.get(port) !== source || !bounded(message) || message.epoch !== source.epoch) return;
    if (exact(message, ["type", "epoch", "item"]) && message.type === "state" && validItem(message.item)) {
      const previous = source.item?.contextID;
      if (message.item?.playbackState === "playing" && (source.item?.playbackState !== "playing" || previous !== message.item.contextID)) source.lastPlayedOrder = ++activityOrder;
      source.item = message.item;
      source.receivedAt = monotonicNow();
      if (previous !== message.item?.contextID) for (const [id, entry] of pending) if (entry.source === source) finish(id, "staleContext");
      reconnectDelay = 1000;
      publish();
    } else if (exact(message, ["type", "epoch", "id", "contextID", "result"]) && message.type === "result" && RESULTS.has(message.result)) {
      const entry = pending.get(message.id);
      if (!entry || entry.source !== source || entry.epoch !== source.epoch || entry.command.contextID !== message.contextID) return;
      finish(message.id, monotonicNow() > entry.deadline ? "failed" : message.result);
    }
  });
  port.onDisconnect.addListener(() => {
    void chrome.runtime.lastError;
    if (sources.get(port) !== source) return;
    sources.delete(port);
    for (const [id, entry] of pending) if (entry.source === source) finish(id, "staleContext");
    publish();
  });
  post(port, { type: "reset", epoch: source.epoch });
  publish();
  connectNative();
});

chrome.runtime.onMessage.addListener((message, sender, reply) => {
  const popup = sender?.id === chrome.runtime.id && sender.url === chrome.runtime.getURL("popup.html") && !sender.tab;
  if (!popup || !bounded(message)) return false;
  if (exact(message, ["v", "type"]) && message.v === 1 && message.type === "status") {
    reply({ connected: nativePort !== null, source: selected?.item?.sourceName || null });
    return false;
  }
  if (!exact(message, ["v", "type", "id"]) || message.v !== 1 || message.type !== "authorizeMusic" || !isUUID(message.id) || permissions.size >= 1 || !remember(message.id)) return false;
  if (!nativePort) { reply({ v: 1, type: "permissionResult", id: message.id, result: "unavailable" }); return false; }
  const timer = setTimeout(() => { permissions.delete(message.id); reply({ v: 1, type: "permissionResult", id: message.id, result: "unavailable" }); }, 30000);
  permissions.set(message.id, { reply, timer });
  if (!post(nativePort, message)) { permissions.delete(message.id); clearTimeout(timer); reply({ v: 1, type: "permissionResult", id: message.id, result: "unavailable" }); return false; }
  return true;
});

setInterval(publish, 1000);
connectNative();
