/// Executed only through Chrome's permissioned page-context AppleEvent API.
enum MacChromeMediaScript {
    static let source = #"""
    function(request) {
      "use strict";
      const KEY = Symbol.for("opensteamer.native.youtube.v1");
      const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
      const VIDEO = /^[A-Za-z0-9_-]{11}$/;
      const encoder = new TextEncoder();
      const exact = (o, keys) => o && typeof o === "object" && !Array.isArray(o) &&
        Object.keys(o).length === keys.length && keys.every(k => Object.hasOwn(o, k));
      const uuid = value => typeof value === "string" && UUID.test(value);
      const expectedValid = e => exact(e, ["documentID", "itemID", "itemGeneration"]) &&
        uuid(e.documentID) && uuid(e.itemID) && Number.isSafeInteger(e.itemGeneration) && e.itemGeneration > 0;
      const sameExpected = (a,b) => a && b && a.documentID === b.documentID &&
        a.itemID === b.itemID && a.itemGeneration === b.itemGeneration;
      const bounded = o => { try { return encoder.encode(JSON.stringify(o)).length <= 4096; } catch { return false; } };
      const output = (status, snapshot) => {
        const result = {schemaVersion:1,status};
        if (snapshot) result.snapshot = snapshot;
        return JSON.stringify(bounded(result) ? result : {schemaVersion:1,status:"failed"});
      };
      const text = (value, max) => {
        if (typeof value !== "string") return "";
        let result = "", count = 0;
        for (const c of value.slice(0,max * 2).replace(/[\u0000-\u001f\u007f-\u009f]/g," ").trim()) {
          const size = encoder.encode(c).length;
          if (count + size > max) break;
          result += c; count += size;
        }
        return result;
      };
      const identity = () => {
        try {
          const url = new URL(location.href), videoID = url.searchParams.get("v");
          return url.origin === "https://www.youtube.com" && url.pathname === "/watch" &&
            VIDEO.test(videoID || "") ? {href:location.href,videoID} : null;
        } catch { return null; }
      };
      try {
        if (!bounded(request) || request?.schemaVersion !== 1) return output("failed");
        const operation = request.operation;
        if (operation === "read") {
          if (!exact(request,["schemaVersion","operation"])) return output("failed");
        } else if (operation === "result") {
          if (!exact(request,["schemaVersion","operation","commandID","expected"]) ||
              !uuid(request.commandID) || !expectedValid(request.expected)) return output("failed");
        } else if (operation === "command") {
          if (!exact(request,["schemaVersion","operation","commandID","expected","command",
                "expiresAtUnixMilliseconds","expiresAtPageMilliseconds"]) ||
              !uuid(request.commandID) || !expectedValid(request.expected) ||
              !["play","pause","next","previous"].includes(request.command) ||
              !Number.isFinite(request.expiresAtUnixMilliseconds) ||
              !Number.isFinite(request.expiresAtPageMilliseconds)) return output("failed");
        } else return output("failed");

        let s = globalThis[KEY];
        if (!s) {
          if (operation !== "read") return output("staleContext");
          if (!identity()) return output("noMedia");
          s = {documentID:crypto.randomUUID(),itemID:null,itemGeneration:1,video:null,player:null,
            href:null,src:null,videoID:null,retired:false,navigating:false,unavailable:true,
            commands:new Map(),videoEvents:null,documentEvents:new AbortController(),
            play:HTMLMediaElement.prototype.play,pause:HTMLMediaElement.prototype.pause,
            click:HTMLElement.prototype.click};
          Object.defineProperty(globalThis,KEY,{value:s});
          s.invalidate = () => {
            s.itemGeneration++; s.itemID = null; s.unavailable = true;
          };
          const options = {signal:s.documentEvents.signal};
          addEventListener("pagehide",() => { s.retired = true; s.invalidate(); },options);
          addEventListener("pageshow",() => {
            s.documentID = crypto.randomUUID(); s.retired = false; s.navigating = false; s.invalidate();
          },options);
          document.addEventListener("yt-navigate-start",() => { s.navigating = true; s.invalidate(); },options);
          document.addEventListener("yt-navigate-finish",() => { s.navigating = false; s.invalidate(); },options);
        }
        const unavailable = () => {
          if (!s.unavailable || s.itemID) s.invalidate();
          return null;
        };
        const control = (player, selector) => {
          const nodes = player.querySelectorAll(selector);
          if (nodes.length !== 1) return null;
          const node = nodes[0];
          if (!(node instanceof HTMLElement) || !node.isConnected || node.disabled ||
              node.getAttribute("aria-disabled") === "true" || node.getAttribute("aria-hidden") === "true") return null;
          // YouTube can hide an enabled next/previous link in compact player layouts.
          // Command authority comes from its destination and state, not its pixels.
          try {
            const href = node.getAttribute("href");
            if (!href) return null;
            const url = new URL(href,location.href), videoID = url.searchParams.get("v");
            if (url.origin !== "https://www.youtube.com" || url.pathname !== "/watch" || !VIDEO.test(videoID || "")) return null;
            return {node,href,videoID};
          } catch { return null; }
        };
        const observe = () => {
          const page = identity();
          if (!page || s.retired || s.navigating) return unavailable();
          const players = document.querySelectorAll("#movie_player"), videos = document.querySelectorAll("video");
          if (players.length !== 1 || videos.length !== 1) return unavailable();
          const player = players[0], video = videos[0];
          if (!(player instanceof HTMLElement) || !(video instanceof HTMLVideoElement) ||
              !player.isConnected || !video.isConnected || player.querySelector("video.html5-main-video") !== video)
            return unavailable();
          if (s.video !== video) {
            s.videoEvents?.abort(); s.videoEvents = new AbortController();
            s.video = video; s.invalidate();
            video.addEventListener("emptied",s.invalidate,{signal:s.videoEvents.signal});
          }
          if (s.player !== player || s.href !== page.href || s.src !== video.currentSrc || s.videoID !== page.videoID) {
            s.player = player; s.href = page.href; s.src = video.currentSrc; s.videoID = page.videoID; s.invalidate();
          }
          const rendered = document.querySelector("ytd-watch-flexy")?.getAttribute("video-id");
          if (rendered !== page.videoID || !VIDEO.test(rendered || "") || video.readyState < 1 || !video.currentSrc)
            return unavailable();
          if (!s.itemID) s.itemID = crypto.randomUUID();
          s.unavailable = false;
          const next = control(player,".ytp-next-button"), previous = control(player,".ytp-prev-button");
          const metadata = navigator.mediaSession?.metadata;
          const title = text(metadata?.title,512) || "YouTube", artist = text(metadata?.artist,256);
          const duration = video.duration, elapsed = video.currentTime, rate = video.playbackRate;
          if (!Number.isFinite(elapsed) || elapsed < 0 || elapsed > 31536000 ||
              !Number.isFinite(rate) || rate <= 0 || rate > 16) return unavailable();
          const paused = video.paused || video.ended;
          const snapshot = {documentID:s.documentID,itemID:s.itemID,itemGeneration:s.itemGeneration,
            videoID:page.videoID,title,paused,playbackRate:paused ? 0 : rate,
            elapsedTime:elapsed,observedAtUnixMilliseconds:Date.now(),observedAtPageMilliseconds:performance.now(),
            canPlay:paused,canPause:!paused,canNext:!!next,canPrevious:!!previous};
          if (artist) snapshot.artist = artist;
          if (Number.isFinite(duration) && duration >= 0 && duration <= 31536000) snapshot.duration = duration;
          // Recheck after all metadata/control getters; a read cannot create mixed authority.
          if (s.retired || s.navigating || s.video !== video || s.player !== player ||
              location.href !== page.href || video.currentSrc !== s.src || !video.isConnected || !player.isConnected ||
              document.querySelector("#movie_player") !== player || player.querySelector("video.html5-main-video") !== video ||
              document.querySelector("ytd-watch-flexy")?.getAttribute("video-id") !== page.videoID)
            return unavailable();
          return {snapshot,video,player,next,previous,href:page.href,src:s.src};
        };
        const expired = r => performance.now() >= r.expiresAtPageMilliseconds || Date.now() >= r.expiresAtUnixMilliseconds;
        const recordResult = (record, view) => {
          if (record.expected.documentID !== s.documentID || s.retired) return output("staleContext",view?.snapshot);
          if (record.status === "pending") {
            if (expired(record)) record.status = "failed";
            else if (record.targetVideoID && view && view.snapshot.itemID !== record.expected.itemID) {
              record.status = view.snapshot.videoID === record.targetVideoID ? "ok" : "staleContext";
            }
          }
          return output(record.status,view?.snapshot);
        };
        const view = observe();
        const now = performance.now();
        for (const [id,record] of s.commands) if (now >= record.retainUntil) s.commands.delete(id);
        if (operation === "read") return output(view ? "ok" : "noMedia",view?.snapshot);
        const existing = s.commands.get(request.commandID);
        if (existing) {
          if (!sameExpected(existing.expected,request.expected) ||
              (operation === "command" && (existing.command !== request.command ||
                existing.expiresAtUnixMilliseconds !== request.expiresAtUnixMilliseconds ||
                existing.expiresAtPageMilliseconds !== request.expiresAtPageMilliseconds))) return output("staleContext");
          return recordResult(existing,view);
        }
        if (operation === "result") return output("staleContext",view?.snapshot);
        if (!view || !sameExpected(view.snapshot,request.expected)) return output("staleContext",view?.snapshot);
        if (expired(request) || request.expiresAtPageMilliseconds - now > 5000 ||
            request.expiresAtUnixMilliseconds - Date.now() > 5000) return output("failed",view.snapshot);
        if (s.commands.size >= 128) return output("failed",view.snapshot);
        const relative = request.command === "next" || request.command === "previous";
        const chosen = relative ? view[request.command] : null;
        if (relative && !chosen) return output("unsupported",view.snapshot);
        const record = {expected:{...request.expected},command:request.command,status:"pending",
          expiresAtUnixMilliseconds:request.expiresAtUnixMilliseconds,expiresAtPageMilliseconds:request.expiresAtPageMilliseconds,
          retainUntil:now + 60000,targetVideoID:chosen?.videoID};
        s.commands.set(request.commandID,record);
        const fence = observe();
        const controlFence = relative ? fence?.[request.command] : null;
        // Final identity/deadline admission is adjacent to the native operation.
        if (!fence || !sameExpected(fence.snapshot,request.expected) || fence.video !== view.video ||
            fence.player !== view.player || fence.href !== view.href || fence.src !== view.src ||
            (relative && (!controlFence || controlFence.node !== chosen.node || controlFence.href !== chosen.href))) {
          record.status = "staleContext"; return output(record.status,fence?.snapshot);
        }
        if (expired(request)) { record.status = "failed"; return output(record.status,fence.snapshot); }
        try {
          if (relative) {
            s.click.call(chosen.node);
          } else if (request.command === "pause") {
            s.pause.call(view.video);
            const after = observe();
            record.status = after && sameExpected(after.snapshot,record.expected) && after.snapshot.paused ? "ok" : "staleContext";
          } else {
            const pending = s.play.call(view.video);
            Promise.resolve(pending).then(() => {
              const after = observe();
              if (record.status !== "pending") return;
              record.status = !after || !sameExpected(after.snapshot,record.expected) ? "staleContext" :
                expired(record) || after.snapshot.paused ? "failed" : "ok";
            },() => { if (record.status === "pending") record.status = "failed"; });
          }
        } catch { record.status = "failed"; }
        return recordResult(record,observe());
      } catch { return output("failed"); }
    }
    """#
}
