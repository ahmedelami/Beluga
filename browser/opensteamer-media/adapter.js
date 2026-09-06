(() => {
  "use strict";
  const installation = Symbol.for("opensteamer.media.youtube.adapter.v1");
  if (globalThis[installation] || location.origin !== "https://www.youtube.com") return;
  globalThis[installation] = true;
  const CHANNEL = "opensteamer-youtube-media-v1";
  const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
  const isUUID = value => typeof value === "string" && UUID.test(value);
  const origin = "https://www.youtube.com";
  const encoder = new TextEncoder();
  const nativePlay = HTMLMediaElement.prototype.play;
  const nativePause = HTMLMediaElement.prototype.pause;
  const nativeClick = HTMLElement.prototype.click;
  const seen = new Map();
  let epoch = null;
  let current = null;
  let contextID = null;
  let navigating = false;
  let lastJSON = "";
  let lastSentAt = 0;
  const monotonicNow = () => performance.timeOrigin + performance.now();
  const bounded = value => { try { return encoder.encode(JSON.stringify(value)).length <= 4096; } catch { return false; } };
  const exact = (value, keys) => value && typeof value === "object" && !Array.isArray(value) && keys.every(k => Object.hasOwn(value, k)) && Object.keys(value).length === keys.length;

  function truncate(value, max) {
    if (typeof value !== "string") return "";
    let output = "";
    let size = 0;
    for (const character of value.slice(0, max * 2).replace(/[\u0000-\u001f\u007f-\u009f]/g, " ").trim()) {
      const bytes = encoder.encode(character).length;
      if (size + bytes > max) break;
      output += character;
      size += bytes;
    }
    return output;
  }

  function control(player, selector) {
    const node = player.querySelector(selector);
    if (!(node instanceof HTMLElement) || !node.isConnected || node.disabled || node.getAttribute("aria-disabled") === "true" || node.getAttribute("aria-hidden") === "true" || node.getClientRects().length === 0) return null;
    const style = getComputedStyle(node);
    return style.display !== "none" && style.visibility !== "hidden" ? node : null;
  }

  function snapshot() {
    if (navigating || location.origin !== origin) return null;
    const url = new URL(location.href);
    const videoID = url.pathname === "/watch" ? url.searchParams.get("v") : (url.pathname.match(/^\/shorts\/([A-Za-z0-9_-]+)$/)?.[1]);
    if (!videoID || !/^[A-Za-z0-9_-]{1,128}$/.test(videoID)) return null;
    const player = document.querySelector("#movie_player");
    const video = player?.querySelector("video.html5-main-video");
    if (!(player instanceof HTMLElement) || !(video instanceof HTMLVideoElement) || !player.isConnected || !video.isConnected || video.readyState < 1 || !video.currentSrc) return null;
    const pageURL = location.href;
    const mediaURL = video.currentSrc;
    const untrustedMediaSession = navigator.mediaSession;
    let title = "", artist = "";
    try { title = truncate(untrustedMediaSession?.metadata?.title, 512); artist = truncate(untrustedMediaSession?.metadata?.artist, 256); } catch { /* Page metadata is optional and untrusted. */ }
    title ||= "YouTube";
    const next = control(player, ".ytp-next-button");
    const previous = control(player, ".ytp-prev-button");
    return { player, video, pageURL, mediaURL, key: `${videoID}\n${mediaURL}\n${title}\n${artist}`, title, artist, next, previous };
  }

  function same(a, b) { return a && b && a.player === b.player && a.video === b.video && a.key === b.key; }

  function refresh() {
    const next = snapshot();
    if (!same(current, next)) { current = next; contextID = next ? crypto.randomUUID() : null; }
    else current = next;
    return current;
  }

  function send(message) {
    const envelope = { channel: CHANNEL, direction: "adapter", epoch, ...message };
    if (bounded(envelope)) window.postMessage(envelope, origin);
  }

  function publish(force = false) {
    if (!epoch) return;
    let item = null;
    const source = refresh();
    if (source) {
      const video = source.video;
      const playing = !video.paused && !video.ended && video.playbackRate > 0;
      item = { contextID, sourceName: "YouTube", title: source.title, playbackRate: playing ? Math.min(16, Math.max(0, video.playbackRate)) : 0, playbackState: playing ? "playing" : "paused", canPlay: !playing, canPause: playing, canSkipForward: source.next !== null, canSkipBackward: source.previous !== null };
      if (source.artist) item.artist = source.artist;
      if (Number.isFinite(video.duration) && video.duration >= 0 && video.duration <= 31536000) item.duration = video.duration;
      if (Number.isFinite(video.currentTime) && video.currentTime >= 0 && video.currentTime <= 31536000) item.elapsedTime = video.currentTime;
    }
    const json = JSON.stringify(item);
    const now = monotonicNow();
    if (force || json !== lastJSON || now - lastSentAt >= 1000) { lastJSON = json; lastSentAt = now; send({ type: "state", item }); }
  }

  function respond(command, result, commandEpoch) {
    if (commandEpoch === epoch) send({ type: "result", id: command.id, contextID: command.contextID, result });
  }

  function execute(command, deadline) {
    if (!exact(command, ["v", "type", "id", "contextID", "command", "issuedAtMilliseconds"]) || command.v !== 1 || command.type !== "command" || !isUUID(command.id) || !isUUID(command.contextID) || !["play", "pause", "skipForward", "skipBackward"].includes(command.command) || !Number.isSafeInteger(command.issuedAtMilliseconds) || !Number.isFinite(deadline)) return;
    const commandEpoch = epoch;
    const now = monotonicNow();
    for (const [id, expiry] of seen) if (expiry < now) seen.delete(id);
    if (seen.has(command.id) || seen.size >= 2048) return;
    seen.set(command.id, now + 60000);
    const source = refresh();
    if (!source) { respond(command, "noActiveMedia", commandEpoch); return; }
    if (contextID !== command.contextID) { respond(command, "staleContext", commandEpoch); publish(true); return; }
    const target = command.command === "skipForward" ? source.next : command.command === "skipBackward" ? source.previous : source.video;
    if (!target) { respond(command, "unsupported", commandEpoch); return; }
    // Re-read all identity-bearing state after untrusted page metadata getters.
    const fence = snapshot();
    if (!same(source, fence) || (command.command === "skipForward" && fence.next !== target) || (command.command === "skipBackward" && fence.previous !== target) || epoch !== commandEpoch || contextID !== command.contextID || document.querySelector("#movie_player") !== source.player || source.player.querySelector("video.html5-main-video") !== source.video || !source.player.isConnected || !source.video.isConnected || location.href !== fence.pageURL || source.video.currentSrc !== fence.mediaURL) { refresh(); respond(command, "staleContext", commandEpoch); publish(true); return; }
    const wall = Date.now();
    if (wall < command.issuedAtMilliseconds || wall >= command.issuedAtMilliseconds + 1000 || monotonicNow() >= deadline) { respond(command, "failed", commandEpoch); return; }
    try {
      let outcome;
      if (command.command === "play") outcome = nativePlay.call(target);
      else if (command.command === "pause") nativePause.call(target);
      else nativeClick.call(target);
      if (outcome && typeof outcome.then === "function") {
        outcome.then(() => { respond(command, "applied", commandEpoch); publish(true); }, () => respond(command, "failed", commandEpoch));
      } else { respond(command, "applied", commandEpoch); publish(true); }
    } catch { respond(command, "failed", commandEpoch); }
  }

  window.addEventListener("message", event => {
    const message = event.data;
    if (event.source !== window || event.origin !== origin || !bounded(message) || message?.channel !== CHANNEL || message.direction !== "bridge") return;
    if (exact(message, ["channel", "direction", "type", "epoch"]) && message.type === "reset" && (message.epoch === null || isUUID(message.epoch))) { epoch = message.epoch; current = null; contextID = null; lastJSON = ""; publish(true); }
    else if (epoch && message.epoch === epoch && exact(message, ["channel", "direction", "type", "epoch", "command", "deadline"]) && message.type === "command") execute(message.command, message.deadline);
  });
  document.addEventListener("yt-navigate-start", () => { navigating = true; current = null; contextID = null; publish(true); });
  document.addEventListener("yt-navigate-finish", () => { navigating = false; publish(true); });
  window.addEventListener("pagehide", () => { epoch = null; current = null; contextID = null; });
  for (const name of ["play", "pause", "ended", "emptied", "loadedmetadata", "durationchange", "ratechange", "seeked"]) document.addEventListener(name, () => publish(true), true);
  setInterval(() => publish(), 250);
})();
