(() => {
  if (typeof globalThis.__edgePipControlsInstalled === "function" && globalThis.__edgePipControlsInstalled()) return;
  globalThis.__edgePipControlsInstalled = () => { try { return Boolean(chrome.runtime.id); } catch { return false; } };
  let video, port, retry = 0, lastSent = 0;
  const timers = ["play", "pause", "timeupdate", "volumechange", "durationchange", "seeking", "seeked", "ratechange", "progress", "ended"];
  const current = () => {
    let v = document.pictureInPictureElement;
    while (v?.shadowRoot?.pictureInPictureElement) v = v.shadowRoot.pictureInPictureElement;
    return v instanceof HTMLVideoElement ? v : null;
  };

  function sitePlayer() {
    return video?.closest(".html5-video-player");
  }
  function siteButton(selector) {
    const button = sitePlayer()?.querySelector(selector);
    if (!button || button.disabled || button.getAttribute("aria-disabled") === "true" ||
        !button.getClientRects().length || getComputedStyle(button).visibility === "hidden") return null;
    return button;
  }
  function queue(action, run = false) {
    const name = run ? "edgepip-queue-run" : "edgepip-queue-query";
    if (!document.dispatchEvent(new CustomEvent(name, {detail:action, cancelable:true}))) return true;
    const button = siteButton(action === "nexttrack" ? ".ytp-next-button" : ".ytp-prev-button");
    if (run) button?.click();
    return Boolean(button);
  }
  const tracks = () => Array.from(video.textTracks).filter(t => ["subtitles", "captions"].includes(t.kind));
  const captionButton = () => siteButton(".ytp-subtitles-button");
  function captions() {
    const button = captionButton();
    const list = tracks();
    const active = list.find(t => t.mode === "showing");
    const showing = button ? button.getAttribute("aria-pressed") === "true" : Boolean(active);
    let text = "";
    if (showing) {
      const lines = active ? Array.from(active.activeCues || [], c => c.getCueAsHTML?.().textContent || "") : [];
      if (!lines.length && button) {
        sitePlayer().querySelectorAll(".ytp-caption-segment").forEach(el => lines.push(el.textContent));
      }
      text = lines.join(" ").trim().slice(0, 1000);
    }
    return {hasCaptions:Boolean(button || list.length), captions:showing, captionText:text};
  }
  function toggleCaptions() {
    const button = captionButton();
    if (button) { button.click(); return; }
    const list = tracks();
    const active = list.find(t => t.mode === "showing");
    if (active) list.forEach(t => { if (t.mode === "showing") t.mode = "disabled"; });
    else if (list.length) (list.find(t => t.language === navigator.language) || list[0]).mode = "showing";
  }
  function seekTo(target) {
    if (!Number.isFinite(target) || !video.seekable.length) return;
    let nearest = video.seekable.start(0);
    for (let i = 0; i < video.seekable.length; i++) {
      const value = Math.max(video.seekable.start(i), Math.min(video.seekable.end(i), target));
      if (Math.abs(target - value) < Math.abs(target - nearest)) nearest = value;
    }
    video.currentTime = nearest;
  }
  function state(event) {
    if (!video || !port) return;
    if (event?.type === "timeupdate" && performance.now() - lastSent < 240) return;
    lastSent = performance.now();
    const ranges = video.seekable;
    const spans = Array.from({length:ranges.length}, (_, i) => [ranges.start(i), ranges.end(i)]);
    const protection = globalThis.__edgePipProtection;
    const ordinaryPiP = Boolean(protection?.isProtected && !protection.isProtected(video));
    port.postMessage({type:"state", ordinaryPiP, time:video.currentTime, duration:Number.isFinite(video.duration) ? video.duration : null,
      spans, paused:video.paused || video.ended, muted:video.muted, volume:video.volume, rate:video.playbackRate,
      previous:queue("previoustrack"), next:queue("nexttrack"), live:video.duration === Infinity, ...captions()});
  }
  function connect() {
    if (!video || port) return;
    try {
      const channel = chrome.runtime.connect({name:"pip-player"});
      port = channel;
      channel.onDisconnect.addListener(() => {
        void chrome.runtime.lastError;
        if (port !== channel) return;
        port = null;
        if (video) retry = setTimeout(connect, 1300);
      });
      channel.onMessage.addListener(async msg => {
        if (!video || current() !== video || !msg || msg.type !== "control") return;
        const n = msg.value;
        try {
          switch (msg.action) {
            case "play": await video.play(); break;
            case "pause": video.pause(); break;
            case "close": await document.exitPictureInPicture(); return;
            case "mute": video.muted = !video.muted; break;
            case "volume":
              if (Number.isFinite(n)) { video.volume = Math.min(1, Math.max(0, n)); video.muted = false; }
              break;
            case "seek": seekTo(n); break;
            case "skip": if (Number.isFinite(n)) seekTo(video.currentTime + n); break;
            case "live": if (video.seekable.length) seekTo(video.seekable.end(video.seekable.length-1)); break;
            case "rate": if ([0.25,0.5,0.75,1,1.25,1.5,1.75,2].includes(n)) video.playbackRate = n; break;
            case "captions": toggleCaptions(); break;
            case "previous": queue("previoustrack", true); break;
            case "next": queue("nexttrack", true); break;
          }
        } finally { state(); }
      });
      state();
    } catch { if (video && chrome.runtime?.id) retry = setTimeout(connect, 1300); }
  }
  function stop() {
    clearTimeout(retry);
    if (video) {
      timers.forEach(name => video.removeEventListener(name, state));
      video.removeEventListener("leavepictureinpicture", stop);
      video.textTracks.removeEventListener("change", state);
    }
    video = null;
    const old = port; port = null;
    old?.disconnect();
  }
  function start(v) {
    if (!v || video === v) return;
    stop(); video = v;
    timers.forEach(name => v.addEventListener(name, state));
    v.addEventListener("leavepictureinpicture", stop);
    v.textTracks.addEventListener("change", state);
    connect();
  }
  document.addEventListener("enterpictureinpicture", e => start(current() || (e.target instanceof HTMLVideoElement ? e.target : null)), true);
  window.addEventListener("pagehide", stop);
  function sync() {
    const v = current();
    if (v) start(v); else if (video) stop();
  }
  document.addEventListener("visibilitychange", sync);
  window.addEventListener("pageshow", sync);
  sync();
})();
