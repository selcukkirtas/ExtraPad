import Foundation

/// The iPad-side client. Deliberately ES5 with no build step: Safari on iOS 9
/// has no arrow functions, no template literals and no fetch. The stream itself
/// is decoded by Safari's own JPEG path via <img>, so JS never touches pixels.
enum WebClient {
    static func page(width: Int, height: Int, fps: Int) -> String {
        let html = #"""
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, minimum-scale=1, user-scalable=no">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black">
<meta name="apple-mobile-web-app-title" content="ExtraPad">
<link rel="apple-touch-icon" href="/icon.png">
<title>ExtraPad</title>
<style>
  * { margin: 0; padding: 0; -webkit-user-select: none; user-select: none; }
  html, body { width: 100%; height: 100%; background: #000; overflow: hidden;
               -webkit-touch-callout: none; }
  #screen { position: absolute; top: 0; left: 0; width: 100%; height: 100%;
            object-fit: contain; -webkit-transform: translateZ(0); }
  #hud { position: absolute; top: 0; left: 0; right: 0;
         font: 13px -apple-system, "Helvetica Neue", Helvetica, sans-serif;
         color: #fff; background: rgba(0,0,0,0.72); padding: 10px 14px;
         -webkit-transition: opacity .25s ease; transition: opacity .25s ease; }
  #hud.hidden { opacity: 0; }
  #hud b { font-weight: 600; }
  #hud .dim { color: #9aa0a6; }
</style>
</head>
<body>
  <img id="screen" alt="">
  <div id="hud">
    <b>ExtraPad</b>
    <span class="dim" id="info">baglaniyor&hellip;</span>
  </div>
<script>
(function () {
  "use strict";
  var img = document.getElementById("screen");
  var hud = document.getElementById("hud");
  var info = document.getElementById("info");
  var retries = 0;
  var frames = 0;
  var windowFrames = 0;
  var windowStart = new Date().getTime();
  var fpsText = "";

  function setInfo(text) { info.innerHTML = text; }

  // The number that matters is how many frames this iPad actually finished
  // decoding - not how many the Mac sent. Measured here, on the device.
  function countFrame() {
    frames = frames + 1;
    windowFrames = windowFrames + 1;
    var now = new Date().getTime();
    var elapsed = now - windowStart;
    if (elapsed >= 2000) {
      var fps = (windowFrames * 1000 / elapsed).toFixed(1);
      fpsText = fps + " fps (toplam " + frames + ")";
      windowFrames = 0;
      windowStart = now;
      setInfo("__W__x__H__ &middot; " + fpsText);
      hud.className = "";   // keep the reading visible while measuring
    }
  }

  function connect() {
    // Cache-buster: Safari will otherwise reuse the dead multipart response.
    var sep = location.search ? location.search + "&" : "?";
    img.src = "/stream" + sep + "t=" + new Date().getTime();
  }

  img.onload = function () {
    retries = 0;
    countFrame();
  };

  // A dropped Wi-Fi frame ends the multipart response; reconnect with backoff.
  img.onerror = function () {
    retries = retries + 1;
    setInfo("baglanti kesildi, yeniden deneniyor (" + retries + ")");
    hud.className = "";
    setTimeout(connect, Math.min(1000 * retries, 5000));
  };

  // Tap toggles the readout instead of hiding it on a timer.
  function toggleHud() {
    hud.className = hud.className === "hidden" ? "" : "hidden";
  }
  document.addEventListener("touchstart", toggleHud, false);
  document.addEventListener("click", toggleHud, false);

  setInfo("__W__x__H__ &middot; olculuyor&hellip;");
  connect();
}());
</script>
</body>
</html>
"""#
        return html
            .replacingOccurrences(of: "__W__", with: String(width))
            .replacingOccurrences(of: "__H__", with: String(height))
            .replacingOccurrences(of: "__FPS__", with: String(fps))
    }

    /// Delta client: receives changed rectangles over a WebSocket and paints
    /// them onto a canvas. Still ES5 - and deliberately light on per-message
    /// JavaScript, because a home-screen web app on an iPad 2 may be running
    /// without a JIT. The decoding stays in Safari's native JPEG path.
    static func deltaPage(width: Int, height: Int) -> String {
        let html = #"""
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, minimum-scale=1, user-scalable=no">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black">
<meta name="apple-mobile-web-app-title" content="ExtraPad">
<link rel="apple-touch-icon" href="/icon.png">
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
</style>
</head>
<body>
  <canvas id="screen" width="__W__" height="__H__"></canvas>
  <div id="hud"><b>ExtraPad</b> <span class="dim" id="info">baglaniyor&hellip;</span>
    <span class="dim"> &middot; uc parmak: bilgi serisi</span></div>
<script>
(function () {
  "use strict";
  var canvas = document.getElementById("screen");
  var ctx = canvas.getContext("2d");
  var hud = document.getElementById("hud");
  var info = document.getElementById("info");
  var urlFactory = window.URL || window.webkitURL;

  var queue = [];
  var drawing = false;
  var frames = 0, regions = 0, bytes = 0, decodeMs = 0;
  var windowStart = new Date().getTime();
  var ws = null, retries = 0;

  // One decode per frame, then a synchronous blit per region. Regions must land
  // in the order they were produced, so exactly one decode is ever in flight.
  function pump() {
    if (drawing || queue.length === 0) { return; }
    drawing = true;
    var item = queue.shift();
    var url = urlFactory.createObjectURL(item.blob);
    var img = new Image();
    var t0 = new Date().getTime();
    img.onload = function () {
      var list = item.regions;
      for (var i = 0; i < list.length; i++) {
        var r = list[i];
        ctx.drawImage(img, 0, r.sy, r.w, r.h, r.dx, r.dy, r.w, r.h);
      }
      urlFactory.revokeObjectURL(url);
      decodeMs = decodeMs + (new Date().getTime() - t0);
      frames = frames + 1;
      regions = regions + list.length;
      drawing = false;
      pump();
    };
    img.onerror = function () {
      urlFactory.revokeObjectURL(url);
      drawing = false;
      pump();
    };
    img.src = url;
  }

  // A backlog is latency: what is queued is already stale. Throw it away and
  // ask the server for a fresh full frame.
  //
  // This used to reconnect instead, which was a loop: reconnecting asked for a
  // keyframe, the keyframe was big enough to overrun the queue again, and that
  // reconnected. Asking over the open socket breaks the cycle.
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
    info.innerHTML = fps + " fps &middot; " + mbit + " Mbit/s &middot; cizim " +
                     perFrame + " ms &middot; kuyruk " + queue.length;
    frames = 0; regions = 0; bytes = 0; decodeMs = 0; windowStart = now;
  }

  function connect() {
    var proto = (location.protocol === "https:") ? "wss://" : "ws://";
    // The cookie set when this page loaded is normally enough, but not every
    // old browser attaches cookies to a WebSocket upgrade - so pass the key
    // through from the page URL as well when it is there.
    ws = new WebSocket(proto + location.host + "/ws" + location.search);
    ws.binaryType = "arraybuffer";

    ws.onopen = function () {
      retries = 0;
      info.innerHTML = "bagli, ilk kare bekleniyor&hellip;";
    };

    ws.onmessage = function (event) {
      var buf = event.data;
      var view = new DataView(buf);
      var isKey = view.getUint8(0) & 1;
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

      if (isKey) { queue = []; }
      queue.push({ regions: list,
                   blob: new Blob([new Uint8Array(buf, off)], { type: "image/jpeg" }) });
      if (queue.length > 3) { overflow(); return; }
      pump();
      report();
    };

    ws.onclose = function () {
      retries = retries + 1;
      info.innerHTML = "baglanti kesildi, yeniden deneniyor (" + retries + ")";
      setTimeout(connect, Math.min(500 * retries, 5000));
    };

    ws.onerror = function () { if (ws) { ws.close(); } };
  }

  // --- touch input -------------------------------------------------------
  //
  // One finger drives the Mac's cursor. The HUD moved to a three-finger tap so
  // it does not steal the taps that are now input.
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
    if (e.touches.length >= 3) { toggleHud(); return; }
    if (e.touches.length !== 1) { return; }
    e.preventDefault();
    sendInput("D", e.touches[0]);
  }

  function onMove(e) {
    if (e.touches.length !== 1) { return; }
    e.preventDefault();
    // The Mac cannot use more than the capture rate, and each message is a
    // round trip the iPad pays for.
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

  function toggleHud() {
    hud.className = hud.className === "hidden" ? "" : "hidden";
  }

  canvas.addEventListener("touchstart", onStart, false);
  canvas.addEventListener("touchmove", onMove, false);
  canvas.addEventListener("touchend", onEnd, false);
  canvas.addEventListener("touchcancel", onEnd, false);
  // Desktop browsers, for testing from the Mac itself.
  canvas.addEventListener("mousedown", function (e) { sendInput("D", e); }, false);
  canvas.addEventListener("mousemove", function (e) {
    if (e.buttons === 1) { sendInput("M", e); }
  }, false);
  canvas.addEventListener("mouseup", function (e) { sendInput("U", e); }, false);
  hud.addEventListener("click", toggleHud, false);

  if (!window.WebSocket) {
    info.innerHTML = "bu Safari WebSocket desteklemiyor - / adresini kullanin";
    return;
  }
  connect();
}());
</script>
</body>
</html>
"""#
        return html
            .replacingOccurrences(of: "__W__", with: String(width))
            .replacingOccurrences(of: "__H__", with: String(height))
    }

    /// Shown when the key is missing or wrong. Deliberately says nothing about
    /// which - and nothing about the machine it is running on.
    static func unauthorisedPage() -> String {
        return #"""
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ExtraPad</title>
<style>
  body { margin: 0; background: #16181c; color: #e8eaed;
         font: 16px -apple-system, "Helvetica Neue", Helvetica, sans-serif;
         display: -webkit-box; -webkit-box-pack: center; -webkit-box-align: center;
         display: flex; align-items: center; justify-content: center;
         height: 100vh; text-align: center; }
  .card { max-width: 30em; padding: 2em; }
  h1 { font-size: 1.25em; margin: 0 0 .6em; }
  p { color: #9aa0a6; line-height: 1.5; margin: 0; }
  code { color: #8ec7fb; }
</style>
</head>
<body>
  <div class="card">
    <h1>Erisim anahtari gerekli</h1>
    <p>Mac'te menu cubugundaki ExtraPad simgesine tiklayin ve oradaki tam adresi
       kullanin. Adres <code>?k=...</code> ile biter.</p>
  </div>
</body>
</html>
"""#
    }

    /// Shown while the Mac's owner decides. Polls rather than asking the user
    /// to reload, so approving on the Mac is enough to get going.
    static func pendingApprovalPage() -> String {
        return #"""
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black">
<link rel="apple-touch-icon" href="/icon.png">
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
         background: #8ec7fb; margin: 0 .15em;
         -webkit-animation: pulse 1.2s infinite ease-in-out; }
  .dot:nth-child(2) { -webkit-animation-delay: .2s; }
  .dot:nth-child(3) { -webkit-animation-delay: .4s; }
  @-webkit-keyframes pulse { 0%, 80%, 100% { opacity: .25; } 40% { opacity: 1; } }
</style>
</head>
<body>
  <div class="card">
    <h1>Mac'te onay bekleniyor</h1>
    <p>Mac'inizde bu cihaz icin bir soru cikti. <b>Izin Ver</b> dediginizde ekran
       burada acilacak.</p>
    <div><span class="dot"></span><span class="dot"></span><span class="dot"></span></div>
  </div>
<script>
(function () {
  "use strict";
  // Reloading is enough: once approved, the same URL serves the screen.
  setTimeout(function () { location.reload(); }, 2000);
}());
</script>
</body>
</html>
"""#
    }

    /// Shown to a device the owner turned down.
    static func deniedPage() -> String {
        return #"""
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
    <h1>Bu cihaza izin verilmedi</h1>
    <p>Mac'te menu cubugundaki ExtraPad simgesinden cihaz listesini
       sifirlayarak yeniden deneyebilirsiniz.</p>
  </div>
</body>
</html>
"""#
    }
}
