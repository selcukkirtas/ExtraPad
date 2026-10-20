namespace ExtraPadWindows.Networking;

/// Mirrors Sources/ExtraPad/WebClient.swift almost verbatim - the page itself
/// is plain ES5 JavaScript and talks only the wire protocol, so the exact
/// same markup works unmodified against this host. Only /stream (mjpeg) is
/// skipped for now; /delta (the WebSocket client) is what the iPad actually
/// uses.
public static class WebClientPages
{
    /// Four seconds of silent 16x16 black H.264, looped to hold the iPad's
    /// screen awake. See the matching comment in WebClient.swift for why this
    /// exists at all.
    private const string KeepAwakeVideoBase64 =
        "AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAMybW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAD6AAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAl10cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAD6AAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAABAAAAAQAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAA+gAAAAAAABAAAAAAHVbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAABAAAABAABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABgG1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAUBzdGJsAAAAuHN0c2QAAAAAAAAAAQAAAKhhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAABAAEABIAAAASAAAAAAAAAABFExhdmM2My4xLjEwMiBsaWJ4MjY0AAAAAAAAAAAAAAAAGP//AAAALmF2Y0MBQsAe/+EAFmdCwB7ZHsBEAAADAAQAAAMACDxYuSABAAVoy4PLIAAAABBwYXNwAAAAAQAAAAEAAAAUYnRydAAAAAAAAAVGAAAAAAAAABhzdHRzAAAAAAAAAAEAAAAEAABAAAAAABRzdHNzAAAAAAAAAAEAAAABAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAAEAAAAAQAAACRzdHN6AAAAAAAAAAAAAAAEAAAChgAAAAoAAAAKAAAACQAAABRzdGNvAAAAAAAAAAEAAANiAAAAYXVkdGEAAABZbWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAsaWxzdAAAACSpdG9vAAAAHGRhdGEAAAABAAAAAExhdmY2My4xLjEwMgAAAAhmcmVlAAACq21kYXQAAAJwBgX//2zcRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY1IHIzMjIyIGIzNTYwNWEgLSBILjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDovL3d3dy52aWRlb2xhbi5vcmcveDI2NC5odG1sIC0gb3B0aW9uczogY2FiYWM9MCByZWY9MyBkZWJsb2NrPTE6MDowIGFuYWx5c2U9MHgxOjB4MTExIG1lPWhleCBzdWJtZT03IHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTEgbWVfcmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0xIDh4OGRjdD0wIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0PS0yIHRocmVhZHM9MSBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTAgd2VpZ2h0cD0wIGtleWludD0yNTAga2V5aW50X21pbj0xIHNjZW5lY3V0PTQwIGludHJhX3JlZnJlc2g9MCByY19sb29rYWhlYWQ9NDAgcmM9Y3JmIG1idHJlZT0xIGNyZj0yMy4wIHFjb21wPTAuNjAgcXBtaW49MCBxcG1heD02OSBxcHN0ZXA9NCBpcF9yYXRpbz0xLjQwIGFxPTE6MS4wMACAAAAADmWIhAX///8PRQABV5+AAAAABkGaOAv6gAAAAAZBmlQC3qAAAAAFQZpgFfU=";

    public static string DeltaPage(int width, int height, int protocolVersion)
    {
        var html = """
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, minimum-scale=1, user-scalable=no">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black">
<meta name="apple-mobile-web-app-title" content="ExtraPad">
<title>ExtraPad</title>
<style>
  * { margin: 0; padding: 0; -webkit-user-select: none; user-select: none; }
  html, body { width: 100%; height: 100%; background: #000; overflow: hidden;
               -webkit-touch-callout: none; }
  #screen { position: absolute; top: 0; left: 0; width: 100%; height: 100%; }
  #hud { position: absolute; top: 0; left: 0; right: 0;
         font: 13px -apple-system, "Helvetica Neue", Helvetica, sans-serif;
         color: #fff; background: rgba(0,0,0,0.72); padding: 10px 14px; }
  #hud.hidden { opacity: 0; }
  #hud b { font-weight: 600; }
  #hud .dim { color: #9aa0a6; }
  #locked { position: absolute; top: 0; left: 0; width: 100%; height: 100%;
            display: none; background: #000; color: #fff; text-align: center;
            font: 15px -apple-system, "Helvetica Neue", Helvetica, sans-serif; }
  #locked.shown { display: block; }
  #locked p { position: absolute; top: 45%; left: 0; right: 0; }
  #locked .dim { display: block; margin-top: 8px; font-size: 13px; color: #9aa0a6; }
  #awake { position: absolute; bottom: 0; left: 0; width: 1px; height: 1px;
           opacity: 0.01; pointer-events: none; }
  #tap { position: absolute; bottom: 24px; left: 0; right: 0; text-align: center;
         pointer-events: none; transition: opacity .4s; }
  #tap span { background: rgba(0,0,0,0.72); color: #fff; border-radius: 16px;
              padding: 8px 14px;
              font: 13px -apple-system, "Helvetica Neue", Helvetica, sans-serif; }
  #tap.gone { opacity: 0; }
</style>
</head>
<body>
  <canvas id="screen" width="__W__" height="__H__"></canvas>
  <div id="locked"><p>This PC is locked<span class="dim">The screen comes back
    when you unlock it.</span></p></div>
  <video id="awake" loop muted playsinline webkit-playsinline preload="auto"
         src="data:video/mp4;base64,__WAKEVIDEO__"></video>
  <div id="tap"><span>Tap once to keep this screen awake</span></div>
  <div id="hud" class="hidden"><b>ExtraPad</b> <span class="dim" id="info">connecting&hellip;</span></div>
<script>
(function () {
  "use strict";
  var canvas = document.getElementById("screen");
  var ctx = canvas.getContext("2d");
  var hud = document.getElementById("hud");
  var info = document.getElementById("info");
  var locked = document.getElementById("locked");
  var awake = document.getElementById("awake");
  var tapHint = document.getElementById("tap");
  var urlFactory = window.URL || window.webkitURL;

  var queue = [];
  var drawing = false;
  var frames = 0, regions = 0, bytes = 0, decodeMs = 0;
  var windowStart = new Date().getTime();
  var ws = null, retries = 0;
  var hudVisible = false;
  var MY_PROTOCOL = __PROTO__;

  function reloadIfStale() {
    try {
      var req = new XMLHttpRequest();
      req.open("GET", "/version?t=" + new Date().getTime(), true);
      req.onreadystatechange = function () {
        if (req.readyState !== 4 || req.status !== 200) { return; }
        var hostProtocol = Number(req.responseText.replace(/.*"protocol":([0-9]+).*/, "$1"));
        if (hostProtocol && hostProtocol !== MY_PROTOCOL) {
          info.innerHTML = "updating&hellip;";
          location.replace(location.pathname + "?r=" + new Date().getTime());
        }
      };
      req.send(null);
    } catch (e) { /* offline; the reconnect loop will keep trying */ }
  }

  var pumpImg = new Image();
  var pumpItem = null;
  var pumpUrl = null;
  var pumpStart = 0;
  pumpImg.onload = function () {
    var list = pumpItem.regions;
    for (var i = 0; i < list.length; i++) {
      var r = list[i];
      ctx.drawImage(pumpImg, 0, r.sy, r.w, r.h, r.dx, r.dy, r.w, r.h);
    }
    urlFactory.revokeObjectURL(pumpUrl);
    decodeMs = decodeMs + (new Date().getTime() - pumpStart);
    frames = frames + 1;
    regions = regions + list.length;
    drawing = false;
    pump();
  };
  pumpImg.onerror = function () {
    urlFactory.revokeObjectURL(pumpUrl);
    drawing = false;
    pump();
  };

  function pump() {
    if (drawing || queue.length === 0) { return; }
    drawing = true;
    pumpItem = queue.shift();
    pumpUrl = urlFactory.createObjectURL(pumpItem.blob);
    pumpStart = new Date().getTime();
    pumpImg.src = pumpUrl;
  }

  var wantAwake = false;
  var awakeUnlocked = false;

  function applyWake() {
    if (!awakeUnlocked) { return; }
    try {
      if (wantAwake) {
        if (awake.paused) { awake.play(); }
      } else if (!awake.paused) {
        awake.pause();
      }
    } catch (e) { /* no-op */ }
  }

  function keepAwake(on) {
    if (on === wantAwake) { return; }
    wantAwake = on;
    applyWake();
  }

  function unlockWake() {
    if (awakeUnlocked) { return; }
    awakeUnlocked = true;
    tapHint.className = "gone";
    applyWake();
  }
  document.addEventListener("touchstart", unlockWake, false);
  document.addEventListener("mousedown", unlockWake, false);

  function hostSaid(text) {
    if (text !== "S locked" && text !== "S awake") { return; }
    var isLocked = (text === "S locked");
    locked.className = isLocked ? "shown" : "";
    tapHint.className = (isLocked || awakeUnlocked) ? "gone" : "";
    if (isLocked) {
      keepAwake(false);
      queue = [];
      ctx.fillStyle = "#000";
      ctx.fillRect(0, 0, canvas.width, canvas.height);
      info.innerHTML = "the PC is locked";
    }
  }

  function overflow() {
    queue = [];
    if (ws && ws.readyState === 1) { ws.send("R"); }
  }

  function report() {
    var now = new Date().getTime();
    var elapsed = now - windowStart;
    if (elapsed < 2000) { return; }
    var fps = (frames * 1000 / elapsed).toFixed(1);
    var mbit = (bytes * 8 / (elapsed / 1000) / 1000000).toFixed(2);
    var perFrame = frames > 0 ? (decodeMs / frames).toFixed(0) : "0";
    info.innerHTML = fps + " fps &middot; " + mbit + " Mbit/s &middot; draw " +
                     perFrame + " ms &middot; queue " + queue.length;
    frames = 0; regions = 0; bytes = 0; decodeMs = 0; windowStart = now;
  }

  function connect() {
    var proto = (location.protocol === "https:") ? "wss://" : "ws://";
    var sep = location.search ? location.search + "&" : "?";
    ws = new WebSocket(proto + location.host + "/ws" + sep + "v=" + MY_PROTOCOL);
    ws.binaryType = "arraybuffer";

    ws.onopen = function () {
      retries = 0;
      info.innerHTML = "connected, waiting for the first frame&hellip;";
    };

    ws.onmessage = function (event) {
      var buf = event.data;
      if (typeof buf === "string") { hostSaid(buf); return; }
      var view = new DataView(buf);
      var flags = view.getUint8(0);
      var isKey = flags & 1;
      var wantHud = (flags & 2) !== 0;
      if (wantHud !== hudVisible) {
        hudVisible = wantHud;
        hud.className = wantHud ? "" : "hidden";
      }
      var count = view.getUint8(1);
      var list = [];
      var off = 2;
      for (var i = 0; i < count; i++) {
        list.push({ sy: view.getUint16(off),     dx: view.getUint16(off + 2),
                    dy: view.getUint16(off + 4), w:  view.getUint16(off + 6),
                    h:  view.getUint16(off + 8) });
        off = off + 10;
      }
      bytes = bytes + buf.byteLength;
      keepAwake(true);

      if (isKey) { queue = []; }
      queue.push({ regions: list,
                   blob: new Blob([new Uint8Array(buf, off)], { type: "image/jpeg" }) });
      if (queue.length > 3) { overflow(); return; }
      pump();
      report();
    };

    ws.onclose = function () {
      retries = retries + 1;
      hostSaid("S awake");
      keepAwake(false);
      info.innerHTML = "disconnected, retrying (" + retries + ")";
      if (retries === 2) { reloadIfStale(); }
      setTimeout(connect, Math.min(500 * retries, 5000));
    };

    ws.onerror = function () { if (ws) { ws.close(); } };
  }

  var lastMove = 0;

  function toDisplay(touch) {
    var rect = canvas.getBoundingClientRect();
    return {
      x: Math.round((touch.clientX - rect.left) / rect.width * canvas.width),
      y: Math.round((touch.clientY - rect.top) / rect.height * canvas.height)
    };
  }

  function sendInput(phase, touch) {
    if (!ws || ws.readyState !== 1) { return; }
    var p = toDisplay(touch);
    ws.send(phase + " " + p.x + " " + p.y);
  }

  function onStart(e) {
    if (e.touches.length !== 1) { return; }
    e.preventDefault();
    sendInput("D", e.touches[0]);
  }

  function onMove(e) {
    if (e.touches.length !== 1) { return; }
    e.preventDefault();
    var now = new Date().getTime();
    if (now - lastMove < 16) { return; }
    lastMove = now;
    sendInput("M", e.touches[0]);
  }

  function onEnd(e) {
    e.preventDefault();
    var touch = e.changedTouches && e.changedTouches[0];
    if (touch) { sendInput("U", touch); }
  }

  canvas.addEventListener("touchstart", onStart, false);
  canvas.addEventListener("touchmove", onMove, false);
  canvas.addEventListener("touchend", onEnd, false);
  canvas.addEventListener("touchcancel", onEnd, false);
  canvas.addEventListener("mousedown", function (e) { sendInput("D", e); }, false);
  canvas.addEventListener("mousemove", function (e) {
    if (e.buttons === 1) { sendInput("M", e); }
  }, false);
  canvas.addEventListener("mouseup", function (e) { sendInput("U", e); }, false);

  if (!window.WebSocket) {
    info.innerHTML = "this browser has no WebSocket";
    return;
  }
  connect();
}());
</script>
</body>
</html>
""";
        return html
            .Replace("__W__", width.ToString())
            .Replace("__H__", height.ToString())
            .Replace("__PROTO__", protocolVersion.ToString())
            .Replace("__WAKEVIDEO__", KeepAwakeVideoBase64);
    }

    public static string UnauthorisedPage() => """
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ExtraPad</title>
<style>
  body { margin: 0; background: #16181c; color: #e8eaed;
         font: 16px -apple-system, "Helvetica Neue", Helvetica, sans-serif;
         display: flex; align-items: center; justify-content: center;
         height: 100vh; text-align: center; }
  .card { max-width: 30em; padding: 2em; }
  h1 { font-size: 1.25em; margin: 0 0 .6em; }
  p { color: #9aa0a6; line-height: 1.5; margin: 0; }
</style>
</head>
<body>
  <div class="card">
    <h1>You need to connect first</h1>
    <p>Open this address' home page and enter the six-digit code shown in the
       ExtraPad tray icon on your PC.</p>
    <p style="margin-top:1em"><a href="/" style="color:#8ec7fb">Go to the home page</a></p>
  </div>
</body>
</html>
""";

    public static string PendingApprovalPage() => """
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black">
<title>ExtraPad</title>
<style>
  body { margin: 0; background: #16181c; color: #e8eaed;
         font: 16px -apple-system, "Helvetica Neue", Helvetica, sans-serif;
         display: flex; align-items: center; justify-content: center;
         height: 100vh; text-align: center; }
  .card { max-width: 30em; padding: 2em; }
  h1 { font-size: 1.25em; margin: 0 0 .6em; }
  p { color: #9aa0a6; line-height: 1.5; margin: 0 0 1em; }
  .dot { display: inline-block; width: .5em; height: .5em; border-radius: 50%;
         background: #8ec7fb; margin: 0 .15em; }
</style>
</head>
<body>
  <div class="card">
    <h1>Waiting for approval on the PC</h1>
    <p>Your PC is asking about this device. Choose <b>Allow</b> there and the
       screen will appear here.</p>
    <div><span class="dot"></span><span class="dot"></span><span class="dot"></span></div>
  </div>
<script>
(function () {
  "use strict";
  setTimeout(function () { location.reload(); }, 2000);
}());
</script>
</body>
</html>
""";

    public static string DeniedPage() => """
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ExtraPad</title>
<style>
  body { margin: 0; background: #16181c; color: #e8eaed;
         font: 16px -apple-system, "Helvetica Neue", Helvetica, sans-serif;
         display: flex; align-items: center; justify-content: center;
         height: 100vh; text-align: center; }
  .card { max-width: 28em; padding: 2em; }
  h1 { font-size: 1.25em; margin: 0 0 .6em; }
  p { color: #9aa0a6; line-height: 1.5; margin: 0; }
</style>
</head>
<body>
  <div class="card">
    <h1>This device was not allowed</h1>
    <p>You can try again after clearing the device list from the ExtraPad
       tray icon on your PC.</p>
  </div>
</body>
</html>
""";

    public static string PairingPage(bool wrong)
    {
        var message = wrong
            ? "<p class=\"bad\">That code is not right. Check the ExtraPad tray icon on your PC again.</p>"
            : "<p>Click the ExtraPad icon in your PC's system tray and enter the six-digit code shown there.</p>";
        return """
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black">
<title>ExtraPad</title>
<style>
  * { -webkit-box-sizing: border-box; box-sizing: border-box; }
  body { margin: 0; background: #16181c; color: #e8eaed;
         font: 17px -apple-system, "Helvetica Neue", Helvetica, sans-serif;
         display: flex; align-items: center; justify-content: center;
         min-height: 100vh; text-align: center; }
  .card { width: 22em; max-width: 90%; padding: 2em; }
  h1 { font-size: 1.3em; margin: 0 0 .5em; }
  p { color: #9aa0a6; line-height: 1.5; margin: 0 0 1.5em; }
  p.bad { color: #ff9a8a; }
  input { width: 100%; padding: .7em; font-size: 2em; text-align: center;
          letter-spacing: .35em; border-radius: 12px; border: 2px solid #3a3f47;
          background: #1e2126; color: #fff; -webkit-appearance: none; }
  input:focus { outline: none; border-color: #8ec7fb; }
  button { margin-top: 1em; width: 100%; padding: .8em; font-size: 1.1em;
           border: none; border-radius: 12px; background: #3b82f6; color: #fff;
           -webkit-appearance: none; }
</style>
</head>
<body>
  <div class="card">
    <h1>ExtraPad</h1>
    __MESSAGE__
    <form method="GET" action="/pair">
      <input name="code" type="tel" maxlength="6" pattern="[0-9]*"
             placeholder="000000" autofocus>
      <button type="submit">Connect</button>
    </form>
  </div>
</body>
</html>
""".Replace("__MESSAGE__", message);
    }

    public static string NotFoundPage() => """
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ExtraPad</title>
<style>
  body { margin: 0; background: #16181c; color: #e8eaed;
         font: 16px -apple-system, "Helvetica Neue", Helvetica, sans-serif;
         display: flex; align-items: center; justify-content: center;
         height: 100vh; text-align: center; }
  .card { max-width: 28em; padding: 2em; }
  h1 { font-size: 1.25em; margin: 0 0 .6em; }
  p { color: #9aa0a6; line-height: 1.5; margin: 0 0 1em; }
  a { color: #8ec7fb; }
</style>
</head>
<body>
  <div class="card">
    <h1>No such page</h1>
    <p>ExtraPad is running, but the page you asked for is not here.</p>
    <p><a href="/">Go to the home page</a></p>
  </div>
</body>
</html>
""";
}
