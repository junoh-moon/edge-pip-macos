(() => {
  // Media Session has a setter but no getter for a site's track actions.
  // Preserve the native registrations and use only the two queue actions here.
  const session = navigator.mediaSession;
  if (!session || window.__edgePipTrackActions) return;
  const handlers = new Map();
  const trackActions = ["previoustrack", "nexttrack"];
  const proto = Object.getPrototypeOf(session);
  const descriptor = Object.getOwnPropertyDescriptor(proto, "setActionHandler");
  if (!descriptor?.value || !descriptor.configurable) return;
  function setActionHandler(action, handler) {
    const result = Reflect.apply(descriptor.value, this, arguments);
    if (this === session && trackActions.includes(action)) {
      if (handler) handlers.set(action, handler);
      else handlers.delete(action);
    }
    return result;
  }
  Object.defineProperty(proto, "setActionHandler", {...descriptor, value:setActionHandler});
  window.__edgePipTrackActions = true;
  document.addEventListener("edgepip-queue-query", event => {
    if (document.pictureInPictureElement && handlers.has(event.detail)) event.preventDefault();
  });
  document.addEventListener("edgepip-queue-run", event => {
    if (!document.pictureInPictureElement) return;
    const handler = handlers.get(event.detail);
    if (!handler) return;
    event.preventDefault();
    handler.call(session, {action:event.detail});
  });
})();
