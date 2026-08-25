// OSC 52 clipboard shim for ttyd.
//
// xterm.js (and therefore ttyd 1.7.7) has no OSC 52 handler: it registers
// handlers for 0,1,2,4,8,10,11,12,104,110,111,112,1337 and silently drops 52.
// Claude Code's fullscreen renderer copies the selection by emitting
// ESC ] 52 ; c ; <base64> BEL, so without this shim "selected text auto-copies
// to your clipboard" is a no-op in the browser terminal.
//
// This hooks the WebSocket rather than xterm.js internals on purpose: ttyd's
// frontend is a minified bundle with no exported terminal handle, but its wire
// protocol is stable (binary frames, first byte '0' = OUTPUT, rest is raw pty
// output). That keeps the patch independent of the bundle hash.
(function () {
  var ESC = 0x1b, BEL = 0x07, BACKSLASH = 0x5c;
  var MARKER = [0x1b, 0x5d, 0x35, 0x32, 0x3b]; // ESC ] 5 2 ;
  var MAX_PENDING = 4 * 1024 * 1024;           // drop absurd payloads
  var carry = new Uint8Array(0);

  function concat(a, b) {
    var out = new Uint8Array(a.length + b.length);
    out.set(a, 0); out.set(b, a.length);
    return out;
  }

  function indexOfMarker(buf, from) {
    outer: for (var i = from; i + MARKER.length <= buf.length; i++) {
      for (var k = 0; k < MARKER.length; k++) if (buf[i + k] !== MARKER[k]) continue outer;
      return i;
    }
    return -1;
  }

  // Returns [payloadEnd, resumeAt] or null if the terminator hasn't arrived yet.
  function findTerminator(buf, from) {
    for (var i = from; i < buf.length; i++) {
      if (buf[i] === BEL) return [i, i + 1];
      if (buf[i] === ESC && i + 1 < buf.length && buf[i + 1] === BACKSLASH) return [i, i + 2];
    }
    return null;
  }

  function copy(text) {
    window.__osc52_last = text; // observable hook for diagnostics
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).catch(fallback.bind(null, text));
    } else {
      fallback(text);
    }
  }

  function fallback(text) {
    try {
      var ta = document.createElement('textarea');
      ta.value = text;
      ta.setAttribute('readonly', '');
      ta.style.cssText = 'position:fixed;left:-9999px;top:0;opacity:0';
      document.body.appendChild(ta);
      ta.select();
      document.execCommand('copy');
      document.body.removeChild(ta);
    } catch (e) { /* nothing else we can do */ }
  }

  function emit(bytes) {
    var s = '';
    for (var i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
    var semi = s.indexOf(';');            // skip the Pc (selection) parameter
    if (semi < 0) return;
    var b64 = s.slice(semi + 1);
    if (b64 === '?' || b64 === '') return; // clipboard *read* request — never answer it
    try {
      var bin = atob(b64);
      var arr = new Uint8Array(bin.length);
      for (var j = 0; j < bin.length; j++) arr[j] = bin.charCodeAt(j);
      copy(new TextDecoder('utf-8').decode(arr));
    } catch (e) { /* malformed base64 */ }
  }

  function scan(chunk) {
    var buf = carry.length ? concat(carry, chunk) : chunk;
    var pos = 0;
    for (;;) {
      var start = indexOfMarker(buf, pos);
      if (start < 0) {
        // keep just enough tail to match a marker split across frames
        var keep = Math.min(MARKER.length - 1, buf.length);
        carry = buf.slice(buf.length - keep);
        return;
      }
      var term = findTerminator(buf, start + MARKER.length);
      if (!term) {
        carry = (buf.length - start > MAX_PENDING) ? new Uint8Array(0) : buf.slice(start);
        return;
      }
      emit(buf.subarray(start + MARKER.length, term[0]));
      pos = term[1];
    }
  }

  var Native = window.WebSocket;
  function Patched(url, protocols) {
    var ws = protocols === undefined ? new Native(url) : new Native(url, protocols);
    ws.addEventListener('message', function (ev) {
      var d = ev.data;
      if (!(d instanceof ArrayBuffer)) return;      // ttyd output frames are binary
      var u8 = new Uint8Array(d);
      if (u8.length < 1 || u8[0] !== 0x30) return;  // '0' == OUTPUT
      try { scan(u8.subarray(1)); } catch (e) { carry = new Uint8Array(0); }
    });
    return ws;
  }
  Patched.prototype = Native.prototype;
  ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED'].forEach(function (k) { Patched[k] = Native[k]; });
  window.WebSocket = Patched;
})();
