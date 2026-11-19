(() => {
  if (globalThis.__edgePipProtection?.connected()) return;
  const protectedHosts = ["tving.com", "netflix.com", "disneyplus.com", "coupangplay.com", "wavve.com", "watcha.com"];
  const serviceHost = host => protectedHosts.some(domain => host === domain || host.endsWith("." + domain));
  const knownSite = serviceHost(location.hostname) || [...location.ancestorOrigins].some(origin => {
    try { return serviceHost(new URL(origin).hostname); } catch { return false; }
  });

  const encrypted = new WeakSet();
  const media = new Set();
  let port, retry, sweep, leaving = false, preparing = true;
  const context = chrome.runtime;
  function connected() { try { return Boolean(context.id); } catch { return false; } }
  globalThis.__edgePipProtection = {connected};

  function eligible(el) {
    return knownSite || encrypted.has(el) || Boolean(el.mediaKeys);
  }
  function active(el) {
    return !el.ended && (!el.paused || el.matches(":picture-in-picture"));
  }
  function inspect(el) {
    if (!(el instanceof HTMLMediaElement)) return;
    if (eligible(el) && active(el)) media.add(el);
    else media.delete(el);
  }
  function refresh() {
    clearTimeout(retry);
    if (leaving || !connected()) { release(); return; }
    for (const el of media) if (!el.isConnected || !active(el) || !eligible(el)) media.delete(el);
    // On a protected player page, stop before its first media element or key is ready.
    const enteringPlayer = knownSite && window === top && preparing && !document.hidden &&
      /(?:^|\/)(?:player|watch|play|live|contents)(?:[\/?#]|$)/i.test(location.pathname);
    if (!media.size && !enteringPlayer) { release(); return; }
    if (!sweep) sweep = setInterval(refresh, 1000);
    if (port) return;
    try {
      const channel = context.connect({name:"protected-playback"});
      port = channel;
      channel.onDisconnect.addListener(() => {
        void context.lastError;
        if (port !== channel) return;
        port = null;
        if (!leaving && connected()) retry = setTimeout(refresh, 350);
      });
    } catch { if (connected()) retry = setTimeout(refresh, 350); }
  }
  function release() {
    clearInterval(sweep); sweep = 0;
    const old = port; port = null;
    old?.disconnect();
  }
  function handle(event) {
    const el = event.target;
    if (!(el instanceof HTMLMediaElement)) return;
    if (event.type === "emptied") encrypted.delete(el);
    if (event.type === "encrypted" || event.type === "waitingforkey") encrypted.add(el);
    if (!eligible(el) && !media.has(el)) return;
    if (event.type === "play" || event.type === "playing" || event.type === "pause" || event.type === "ended")
      preparing = false;
    inspect(el);
    refresh();
  }
  for (const type of ["play","playing","pause","ended","emptied","encrypted","waitingforkey","loadedmetadata",
                      "timeupdate","enterpictureinpicture","leavepictureinpicture"])
    document.addEventListener(type, handle, true);

  function scan() {
    for (const el of document.querySelectorAll("video,audio")) {
      if (eligible(el) && !el.paused) preparing = false;
      inspect(el);
    }
    refresh();
  }
  document.addEventListener("visibilitychange", scan);
  window.navigation?.addEventListener("currententrychange", () => { preparing = true; scan(); });
  window.addEventListener("pageshow", () => { leaving = false; scan(); });
  window.addEventListener("pagehide", () => { leaving = true; clearTimeout(retry); release(); });
  scan();
})();
