// ─── NUI bridge helpers ────────────────────────────────────────────────────────
// GetParentResourceName is injected automatically by the FiveM CEF runtime.
// Falls back to a literal name so `npm run dev` works in a normal browser.

export function isEnvBrowser() {
  return !window.invokeNative;
}

function resourceName() {
  return typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'nova_convoytruck';
}

export async function fetchNui(eventName, data = {}) {
  if (isEnvBrowser()) {
    console.warn(`[nui:mock] ${eventName}`, data);
    return { ok: true };
  }

  const resp = await fetch(`https://${resourceName()}/${eventName}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json; charset=UTF-8' },
    body: JSON.stringify(data),
  });
  return resp.json();
}

// Routes through the single 'invoke' NUI callback registered in
// client/modules/tablet.lua, which forwards to an ox_lib server callback of
// the same name. Every server-validated action goes through here so the Lua
// side only needs one RegisterNUICallback for the whole tablet.
export async function invoke(name, ...args) {
  return fetchNui('invoke', { name, args });
}
