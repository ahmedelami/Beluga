"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const crypto = require("node:crypto");
const swift = fs.readFileSync(path.resolve(__dirname,"../../../macOS/Sources/CaptureServer/MacChromeMediaScript.swift"),"utf8");
const source = swift.match(/static let source = #"""\n([\s\S]*?)\n    """#/)[1];
const A = "AAAAAAAAAAA", B = "BBBBBBBBBBB", C = "CCCCCCCCCCC";
const base = 1788800000000;
function fixture(code = source) {
  const h = {time:100,wall:base,clicks:0,pauses:0,plays:0,styles:0,styleHook:null,playHook:null,pending:null};
  class Events {
    constructor() { this.listeners = new Map(); }
    addEventListener(name,callback,options = {}) {
      const entry = {callback,signal:options.signal};
      if (!this.listeners.has(name)) this.listeners.set(name,[]);
      this.listeners.get(name).push(entry);
    }
    fire(name) { for (const entry of this.listeners.get(name) || []) if (!entry.signal?.aborted) entry.callback({type:name}); }
  }
  class Element extends Events {
    constructor() { super(); this.isConnected = true; this.disabled = false; this.attrs = {}; this.display = "block"; this.visibility = "visible"; }
    getAttribute(key) { return this.attrs[key] ?? null; }
    getClientRects() { return this.display === "none" ? [] : [{}]; }
    click() { h.clicks++; if (h.clickHook) h.clickHook(this); }
  }
  class Media extends Element {
    constructor() { super(); this.paused = true; this.ended = false; this.readyState = 4; this.currentSrc = "blob:source-A"; this.currentTime = 10; this.duration = 120; this.playbackRate = 1; }
    play() { h.plays++; this.paused = false; if (h.playHook) return h.playHook(this); return Promise.resolve(); }
    pause() { h.pauses++; this.paused = true; }
  }
  class Video extends Media {}
  h.video = new Video(); h.videos = [h.video]; h.player = new Element(); h.players = [h.player];
  h.next = new Element(); h.next.attrs.href = `https://www.youtube.com/watch?v=${B}`;
  h.previous = new Element(); h.previous.attrs.href = `https://www.youtube.com/watch?v=${C}`;
  h.player.querySelector = selector => selector === "video.html5-main-video" ? h.video : null;
  h.player.querySelectorAll = selector => selector === ".ytp-next-button" ? (h.next ? [h.next] : []) : (h.previous ? [h.previous] : []);
  h.rendered = A; h.watch = new Element(); h.watch.getAttribute = key => key === "video-id" ? h.rendered : null;
  h.document = new Events();
  h.document.querySelectorAll = selector => selector === "#movie_player" ? h.players : selector === "video" ? h.videos : [];
  h.document.querySelector = selector => selector === "#movie_player" ? h.players[0] : selector === "ytd-watch-flexy" ? h.watch : null;
  h.window = new Events(); h.location = {href:`https://www.youtube.com/watch?v=${A}`};
  h.metadata = {title:"Test title",artist:"Artist"};
  h.context = vm.createContext({URL,crypto,TextEncoder,AbortController,Promise,
    HTMLMediaElement:Media,HTMLVideoElement:Video,HTMLElement:Element,
    location:h.location,document:h.document,navigator:{mediaSession:{metadata:h.metadata}},
    addEventListener:h.window.addEventListener.bind(h.window),
    performance:{now:()=>h.time},Date:class extends Date { static now() { return h.wall; } },
    getComputedStyle:node=>{ h.styles++; h.styleHook?.(h.styles,node); return {display:node.display,visibility:node.visibility}; }});
  h.run = vm.runInContext(`(${code})`,h.context,{timeout:1000});
  h.call = request => JSON.parse(h.run(request));
  h.read = () => h.call({schemaVersion:1,operation:"read"});
  h.advance = ms => { h.time += ms; h.wall += ms; };
  h.request = (command = "pause", snapshot = h.read().snapshot) => ({schemaVersion:1,operation:"command",commandID:crypto.randomUUID(),
    expected:{documentID:snapshot.documentID,itemID:snapshot.itemID,itemGeneration:snapshot.itemGeneration},command,
    expiresAtPageMilliseconds:h.time+1000,expiresAtUnixMilliseconds:h.wall+1000});
  h.result = request => h.call({schemaVersion:1,operation:"result",commandID:request.commandID,expected:request.expected});
  h.navigate = (id, sameSource = false) => {
    h.document.fire("yt-navigate-start"); h.location.href=`https://www.youtube.com/watch?v=${id}`;
    h.video.fire("emptied"); if (!sameSource) h.video.currentSrc=`blob:${id}`;
    h.rendered=id; h.document.fire("yt-navigate-finish");
  };
  h.replaceVideo = () => { const old = h.video; old.isConnected=false; h.video=new Video(); h.videos=[h.video]; return old; };
  return h;
}
const flush = () => new Promise(setImmediate);

test("executes the exact production Swift raw function and emits bounded sanitized metadata", () => {
  const h=fixture(); h.metadata.title="é".repeat(1000)+"\nsecret"; h.metadata.artist="\u0001a";
  const value=h.read(); assert.equal(value.status,"ok");
  assert.equal(Buffer.byteLength(value.snapshot.title),512); assert.equal(value.snapshot.artist,"a");
  assert.equal(value.snapshot.duration,120); assert.equal(value.snapshot.elapsedTime,10);
  assert.equal(value.snapshot.paused,true); assert.equal(value.snapshot.playbackRate,0);
  assert.ok(Buffer.byteLength(JSON.stringify(value))<=4096);
  assert.equal(h.read().snapshot.itemID,value.snapshot.itemID);
});
test("rejects malformed request and expected fields without native operations", () => {
  const h=fixture(), q=h.request("play");
  for (const bad of [null,{}, {...q,extra:1},{...q,commandID:"not-uuid"},{...q,command:"toggle"},
    {...q,expiresAtPageMilliseconds:NaN},{...q,expiresAtUnixMilliseconds:Infinity},
    ...[null,{}, {...q.expected,itemGeneration:0},{...q.expected,itemGeneration:1.5},
      {...q.expected,documentID:"bad"},{...q.expected,itemID:123},{...q.expected,extra:true}].map(expected=>({...q,expected}))]) {
    assert.equal(h.call(bad).status,"failed");
  }
  assert.equal(h.plays+h.pauses+h.clicks,0);
});
test("no authority before read, wrong document, or wrong generation", () => {
  const a=fixture(), q=a.request("play"), b=fixture();
  assert.equal(b.call(q).status,"staleContext");
  assert.equal(a.call({...q,expected:{...q.expected,itemGeneration:q.expected.itemGeneration+1}}).status,"staleContext");
  assert.equal(a.call({...q,expected:{...q.expected,documentID:crypto.randomUUID()}}).status,"staleContext");
  assert.equal(a.plays+b.plays,0);
});
test("actual delayed dispatch and independently expired clocks cannot cause playback", () => {
  for (const clock of ["both","wall","page"]) {
    const h=fixture(), q=h.request("play");
    if(clock!=="wall")h.time+=1001; if(clock!=="page")h.wall+=1001;
    assert.equal(h.call(q).status,"failed"); assert.equal(h.plays,0);
  }
});
test("absolute pause is idempotent and async play requires fulfillment and readback", async () => {
  const h=fixture(); assert.equal(h.call(h.request("pause")).status,"ok");
  assert.equal(h.call(h.request("pause")).status,"ok"); assert.equal(h.video.paused,true);
  const q=h.request("play"); assert.equal(h.call(q).status,"pending"); await flush();
  assert.equal(h.result(q).status,"ok"); assert.equal(h.video.paused,false); assert.equal(h.plays,1);
  assert.equal(h.call(q).status,"ok"); assert.equal(h.plays,1);
});
test("relative intent executes once in same generation and duplicate result never clicks", () => {
  const h=fixture(), q=h.request("next");
  assert.equal(h.call(q).status,"pending"); assert.equal(h.call(q).status,"pending");
  assert.equal(h.result(q).status,"pending"); assert.equal(h.clicks,1);
  assert.equal(h.call({...q,command:"previous"}).status,"staleContext"); assert.equal(h.clicks,1);
  h.navigate(B); assert.equal(h.result(q).status,"ok");
  assert.equal(h.call(q).status,"ok"); assert.equal(h.clicks,1);
});
test("relative success requires the advertised successor rather than any navigation", () => {
  const h=fixture(),q=h.request("next"); h.call(q);h.navigate(C);
  assert.equal(h.result(q).status,"staleContext");assert.equal(h.clicks,1);
});
test("next and previous require exact supported controls and confirm their distinct targets", () => {
  for(const key of ["disabled","foreign","hidden","missingHref","duplicates"]) {
    const h=fixture();
    if(key==="disabled")h.next.disabled=true;
    if(key==="foreign")h.next.attrs.href=`https://evil.example/watch?v=${B}`;
    if(key==="hidden")h.next.display="none";
    if(key==="missingHref")delete h.next.attrs.href;
    if(key==="duplicates")h.player.querySelectorAll=()=>[h.next,h.next];
    assert.equal(h.read().snapshot.canNext,false);assert.equal(h.call(h.request("next")).status,"unsupported");assert.equal(h.clicks,0);
  }
  const h=fixture(),q=h.request("previous");h.call(q);h.navigate(C);assert.equal(h.result(q).status,"ok");
});
test("navigation transition and unready/render-mismatched media are unavailable", () => {
  const h=fixture(),q=h.request("play");h.document.fire("yt-navigate-start");
  assert.equal(h.read().status,"noMedia");assert.equal(h.call(q).status,"staleContext");
  h.document.fire("yt-navigate-finish");h.rendered=B;assert.equal(h.read().status,"noMedia");
  h.rendered=A;h.video.readyState=0;assert.equal(h.read().status,"noMedia");
  h.video.readyState=4;assert.equal(h.read().status,"ok");assert.equal(h.call(q).status,"staleContext");assert.equal(h.plays,0);
});
test("unsupported, ambiguous, missing IDs and temporary source absence retire old identity", () => {
  for(const mutation of ["unsupported","ambiguous","missingID","emptySource"]) {
    const h=fixture(),q=h.request("play"),url=h.location.href,src=h.video.currentSrc;
    if(mutation==="unsupported")h.location.href="https://www.youtube.com/results";
    if(mutation==="ambiguous")h.videos.push(h.video);
    if(mutation==="missingID"){h.location.href="https://www.youtube.com/watch";h.rendered=null;}
    if(mutation==="emptySource")h.video.currentSrc="";
    assert.equal(h.read().status,"noMedia");h.location.href=url;h.rendered=A;h.videos=[h.video];h.video.currentSrc=src;
    assert.equal(h.read().status,"ok");assert.equal(h.call(q).status,"staleContext");assert.equal(h.plays,0);
  }
});
test("exact URL/source ABA and real document reload cannot resurrect prior intent", () => {
  const h=fixture(),q=h.request("play"),old=h.read().snapshot;
  h.navigate(B,true);h.navigate(A,true);assert.equal(h.location.href,`https://www.youtube.com/watch?v=${A}`);
  assert.notEqual(h.read().snapshot.itemID,old.itemID);assert.equal(h.call(q).status,"staleContext");
  const reloaded=fixture();assert.notEqual(reloaded.read().snapshot.documentID,old.documentID);
  assert.equal(reloaded.call(q).status,"staleContext");assert.equal(h.plays+reloaded.plays,0);
});
test("BFCache pagehide/pageshow rotates document nonce", () => {
  const h=fixture(),q=h.request("play");h.window.fire("pagehide");assert.equal(h.read().status,"noMedia");
  h.window.fire("pageshow");assert.notEqual(h.read().snapshot.documentID,q.expected.documentID);
  assert.equal(h.call(q).status,"staleContext");assert.equal(h.plays,0);
});
test("replacement video binds new listeners and detaches old element callbacks", () => {
  const h=fixture();h.read();const old=h.replaceVideo();let s=h.read().snapshot;
  old.fire("emptied");assert.equal(h.read().snapshot.itemID,s.itemID);
  const q=h.request("play");h.video.fire("emptied");s=h.read().snapshot;
  assert.notEqual(s.itemID,q.expected.itemID);assert.equal(h.call(q).status,"staleContext");
});
test("late async play fulfillment cannot acquire successor identity", async () => {
  const h=fixture();let resolve;h.playHook=()=>new Promise(r=>{resolve=r;});
  const q=h.request("play");assert.equal(h.call(q).status,"pending");h.navigate(B);resolve();await flush();
  assert.equal(h.result(q).status,"staleContext");assert.equal(h.plays,1);
});
test("rejected play promise and command expiry never become successful", async () => {
  const h=fixture();h.playHook=()=>Promise.reject(new Error("NotAllowedError"));
  const q=h.request("play");h.call(q);await flush();assert.equal(h.result(q).status,"failed");
  const g=fixture();g.playHook=()=>new Promise(()=>{});const r=g.request("play");g.call(r);g.advance(1001);
  assert.equal(g.result(r).status,"failed");assert.equal(g.plays,1);
});
test("ledger is bounded, survives source transitions, and never admits oversized output", () => {
  const h=fixture();for(let i=0;i<128;i++)assert.equal(h.call(h.request("pause")).status,"ok");
  assert.equal(h.call(h.request("pause")).status,"failed");assert.equal(h.pauses,128);
  h.advance(60001);assert.equal(h.call(h.request("pause")).status,"ok");
});
function finalIdentityOracle(code) {
  const h=fixture(code),q=h.request("play");h.styles=0;
  h.styleHook=count=>{if(count===3)h.video.currentSrc="blob:replacement";};
  h.call(q);assert.equal(h.plays,0,"identity changed at final admission but native play ran");
}
function finalDeadlineOracle(code) {
  const h=fixture(code),q=h.request("play");h.styles=0;
  h.styleHook=count=>{if(count===3)h.advance(1001);};
  h.call(q);assert.equal(h.plays,0,"expired at final admission but native play ran");
}
test("behavioral mutant removing the final identity fence is rejected", () => {
  finalIdentityOracle(source);
  const mutant=source.replace(/if \(!fence \|\| !sameExpected\(fence.snapshot,request.expected\)[\s\S]*?return output\(record.status,fence\?\.snapshot\);\n        }/,"if (false) {}");
  assert.notEqual(mutant,source);assert.throws(()=>finalIdentityOracle(mutant),/native play ran/);
});
test("behavioral mutant removing the final deadline check is rejected", () => {
  finalDeadlineOracle(source);
  const mutant=source.replace('if (expired(request)) { record.status = "failed"; return output(record.status,fence.snapshot); }','if (false) {}');
  assert.notEqual(mutant,source);assert.throws(()=>finalDeadlineOracle(mutant),/native play ran/);
});
test("behavioral mutant removing duplicate interception is rejected", () => {
  const oracle=code=>{const h=fixture(code),q=h.request("next");h.call(q);h.call(q);assert.equal(h.clicks,1,"relative duplicate executed");};
  oracle(source);const mutant=source.replace("if (existing) {","if (false && existing) {");
  assert.notEqual(mutant,source);assert.throws(()=>oracle(mutant),/relative duplicate executed/);
});
test("behavioral mutant removing final relative-target fencing is rejected", () => {
  const oracle=code=>{
    const h=fixture(code),q=h.request("next");h.styles=0;
    h.styleHook=count=>{if(count===3)h.next.attrs.href=`https://www.youtube.com/watch?v=${C}`;};
    h.call(q);assert.equal(h.clicks,0,"changed relative target was clicked");
  };
  oracle(source);
  const mutant=source.replace('(relative && (!controlFence || controlFence.node !== chosen.node || controlFence.href !== chosen.href))','false');
  assert.notEqual(mutant,source);assert.throws(()=>oracle(mutant),/changed relative target was clicked/);
});
