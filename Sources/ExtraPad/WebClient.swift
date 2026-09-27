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
    img.src = "/stream?t=" + new Date().getTime();
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
  <div id="hud"><b>ExtraPad delta</b> <span class="dim" id="info">baglaniyor&hellip;</span></div>
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
  var patches = 0, bytes = 0, windowStart = new Date().getTime();
  var ws = null, retries = 0;

  // Patches must land in the order they were produced, or a later rectangle can
  // be overwritten by an earlier one. So exactly one decode is in flight.
  function pump() {
    if (drawing || queue.length === 0) { return; }
    drawing = true;
    var item = queue.shift();
    var url = urlFactory.createObjectURL(item.blob);
    var img = new Image();
    img.onload = function () {
      ctx.drawImage(img, item.x, item.y);
      urlFactory.revokeObjectURL(url);
      drawing = false;
      patches = patches + 1;
      pump();
    };
    img.onerror = function () {
      urlFactory.revokeObjectURL(url);
      drawing = false;
      pump();
    };
    img.src = url;
  }

  // If decoding cannot keep up the backlog is thrown away and the connection is
  // restarted: reconnecting makes the server send a fresh full frame, which is
  // the only safe way back to a correct canvas.
  function overflow() {
    queue = [];
    if (ws) { ws.close(); }
  }

  function report() {
    var now = new Date().getTime();
    var elapsed = now - windowStart;
    if (elapsed < 2000) { return; }
    var fps = (patches * 1000 / elapsed).toFixed(1);
    var mbit = (bytes * 8 / (elapsed / 1000) / 1000000).toFixed(1);
    info.innerHTML = fps + " bolge/sn &middot; " + mbit + " Mbit/s";
    patches = 0; bytes = 0; windowStart = now;
  }

  function connect() {
    var proto = (location.protocol === "https:") ? "wss://" : "ws://";
    ws = new WebSocket(proto + location.host + "/ws");
    ws.binaryType = "arraybuffer";

    ws.onopen = function () {
      retries = 0;
      info.innerHTML = "bagli, ilk kare bekleniyor&hellip;";
    };

    ws.onmessage = function (event) {
      var buf = event.data;
      var view = new DataView(buf);
      var x = view.getUint16(0), y = view.getUint16(2);
      var w = view.getUint16(4), h = view.getUint16(6);
      var isKey = view.getUint8(8) & 1;
      bytes = bytes + buf.byteLength;

      if (isKey) { queue = []; }
      queue.push({ x: x, y: y, w: w, h: h,
                   blob: new Blob([new Uint8Array(buf, 9)], { type: "image/jpeg" }) });
      if (queue.length > 24) { overflow(); return; }
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

  function toggleHud() {
    hud.className = hud.className === "hidden" ? "" : "hidden";
  }
  document.addEventListener("touchstart", toggleHud, false);
  document.addEventListener("click", toggleHud, false);

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
}
