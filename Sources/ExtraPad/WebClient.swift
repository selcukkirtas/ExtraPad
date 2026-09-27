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
}
