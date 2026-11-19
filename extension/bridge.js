chrome.runtime.onConnect.addListener(frame => {
  if (!frame.sender.tab) return;
  if (frame.name === "protected-playback") {
    let guard;
    try { guard = chrome.runtime.connectNative("local.edgepip.protection"); }
    catch { frame.disconnect(); return; }
    guard.onDisconnect.addListener(() => { void chrome.runtime.lastError; frame.disconnect(); });
    frame.onDisconnect.addListener(() => { void chrome.runtime.lastError; guard.disconnect(); });
    return;
  }
  if (frame.name !== "pip-player") return;
  const {id:tabId, windowId} = frame.sender.tab;
  let native;
  try { native = chrome.runtime.connectNative("local.edgepip.controls"); }
  catch { frame.disconnect(); return; }
  frame.onMessage.addListener(data => { if (data?.type === "state") native.postMessage(data); });
  native.onMessage.addListener(async data => {
    if (data?.type !== "control") return;
    if (data.action === "return") {
      try {
        await chrome.tabs.update(tabId, {active:true});
        await chrome.windows.update(windowId, {focused:true});
        frame.postMessage({type:"control", action:"close"});
      } catch { /* The user may already have closed the tab. */ }
    } else frame.postMessage(data);
  });
  native.onDisconnect.addListener(() => { void chrome.runtime.lastError; frame.disconnect(); });
  frame.onDisconnect.addListener(() => { void chrome.runtime.lastError; native.disconnect(); });
});

chrome.runtime.onInstalled.addListener(async () => {
  const tabs = await chrome.tabs.query({discarded:false});
  // A frozen background tab can keep executeScript pending until it wakes.
  // Attach to each top-level document independently of every other tab or frame.
  await Promise.allSettled(tabs.filter(tab => tab.id && /^(https?|file):/.test(tab.url || "")).map(async tab => {
    const inject = async (target, files, world="ISOLATED") => {
      await chrome.scripting.executeScript({target, files, world, injectImmediately:true});
    };
    const top = {tabId:tab.id};
    const all = {tabId:tab.id, allFrames:true};
    await Promise.allSettled([
      inject(top, ["protection.js","player.js"]), inject(top, ["media-actions.js"], "MAIN"),
      inject(all, ["protection.js","player.js"]), inject(all, ["media-actions.js"], "MAIN")
    ]);
  }));
});
