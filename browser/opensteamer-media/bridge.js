(() => {
  "use strict";
  const installation = Symbol.for("opensteamer.media.youtube.bridge.v1");
  if (globalThis[installation] || location.origin !== "https://www.youtube.com") return;
  globalThis[installation] = true;
  const CHANNEL = "opensteamer-youtube-media-v1";
  const ORIGIN = "https://www.youtube.com";
  const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
  const isUUID = value => typeof value === "string" && UUID.test(value);
  const pending = new Map();
  let port = null;
  let epoch = null;
  let reconnect = null;
  let suspended = false;
  const monotonicNow = () => performance.timeOrigin + performance.now();
  const bounded = value => { try { return new TextEncoder().encode(JSON.stringify(value)).length <= 4096; } catch { return false; } };

  function send(message) { window.postMessage({ channel: CHANNEL, direction: "bridge", ...message }, ORIGIN); }
  function revoke() { epoch = null; pending.clear(); send({ type: "reset", epoch: null }); }
  function connect() {
    if (suspended || port) return;
    clearTimeout(reconnect);
    try {
      const connected = chrome.runtime.connect({ name: "youtube-media-v1" });
      port = connected;
      connected.onMessage.addListener(message => {
        if (port !== connected || !bounded(message)) return;
        if (message.type === "reset" && isUUID(message.epoch)) { pending.clear(); epoch = message.epoch; send({ type: "reset", epoch }); }
        else if (message.type === "command" && epoch && message.epoch === epoch && message.command && isUUID(message.command.id) && Number.isFinite(message.deadline)) {
          for (const [id, entry] of pending) if (entry.deadline <= monotonicNow()) pending.delete(id);
          if (pending.size >= 32 || pending.has(message.command.id)) return;
          if (monotonicNow() >= message.deadline) { connected.postMessage({ type: "result", epoch, id: message.command.id, contextID: message.command.contextID, result: "failed" }); return; }
          pending.set(message.command.id, { contextID: message.command.contextID, deadline: message.deadline });
          send({ type: "command", epoch, command: message.command, deadline: message.deadline });
        }
      });
      connected.onDisconnect.addListener(() => {
        void chrome.runtime.lastError;
        if (port !== connected) return;
        port = null;
        revoke();
        if (!suspended) reconnect = setTimeout(connect, 1000);
      });
    } catch { port = null; revoke(); if (!suspended) reconnect = setTimeout(connect, 1000); }
  }
  window.addEventListener("message", event => {
    const message = event.data;
    if (event.source !== window || event.origin !== ORIGIN || !bounded(message) || message?.channel !== CHANNEL || message.direction !== "adapter" || !port || !epoch || message.epoch !== epoch) return;
    try {
      if (message.type === "state" && Object.keys(message).length === 5) port.postMessage({ type: "state", epoch, item: message.item });
      else if (message.type === "result" && Object.keys(message).length === 7) {
        const entry = pending.get(message.id);
        if (!entry || entry.contextID !== message.contextID) return;
        pending.delete(message.id);
        port.postMessage({ type: "result", epoch, id: message.id, contextID: message.contextID, result: monotonicNow() > entry.deadline ? "failed" : message.result });
      }
    } catch { port?.disconnect(); }
  });
  window.addEventListener("pagehide", () => { suspended = true; clearTimeout(reconnect); const old = port; port = null; revoke(); old?.disconnect(); });
  window.addEventListener("pageshow", () => { suspended = false; connect(); });
  connect();
})();
