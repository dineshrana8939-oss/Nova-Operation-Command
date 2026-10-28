// ─── Report PDF helpers (Event History list + the Report window) ───────────────────────────────────────
// The server builds the PDF (server/modules/pdf_generator.lua) and sends it as base64.
import { getReportPdf, getReportLink, sendReportToDiscord } from '../api/convoy.js';
import { fetchNui } from '../api/nui.js';

export function saveBase64Pdf(base64, fileName) {
  const bin = atob(base64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  const url = URL.createObjectURL(new Blob([bytes], { type: 'application/pdf' }));
  const a = document.createElement('a');
  a.href = url;
  a.download = fileName || 'report.pdf';
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 4000);
}

// The game's browser cannot save files, so the report goes through the server instead: it keeps the PDF for a few minutes
// behind a private link and the tablet opens that link in the player's normal web browser, which downloads it.
async function openReportLink(id) {
  if (typeof window === 'undefined' || typeof window.invokeNative !== 'function') return null; // not inside the game
  const res = await getReportLink(id);
  if (!res || !res.ok || !res.path) return { ok: false, message: (res && res.error) || 'The PDF could not be created.' };
  let base = res.baseUrl;
  if (!base) {
    const ep = await fetchNui('reports:baseUrl');
    if (ep && ep.endpoint) base = `http://${ep.endpoint}`;
  }
  if (!base) return null;
  window.invokeNative('openUrl', base.replace(/\/+$/, '') + res.path);
  return { ok: true, message: `Opening ${res.fileName || 'the report'} in your web browser, where it downloads. The link works for 10 minutes. If nothing opened, use "Send to Discord".` };
}

// Returns { ok, message } — never throws, so a button can just show the message.
export async function downloadReportPdf(id) {
  try {
    const viaLink = await openReportLink(id);
    if (viaLink) return viaLink;
  } catch (e) { /* fall through to the in-page download below */ }
  try {
    const res = await getReportPdf(id, true);
    if (!res || !res.ok || !res.base64) return { ok: false, message: (res && res.error) || 'The PDF could not be created.' };
    saveBase64Pdf(res.base64, res.fileName || `report_${id}.pdf`);
    return { ok: true, message: `Saved ${res.fileName || 'the PDF'} to your downloads. If nothing was saved (the game's browser can block downloads), use "Send to Discord".` };
  } catch (e) {
    return { ok: false, message: 'The download was blocked. Use "Send to Discord" to get the file.' };
  }
}

export async function resendReportToDiscord(id) {
  try {
    const res = await sendReportToDiscord(id);
    if (res && res.ok) return { ok: true, message: 'The PDF report was posted to the Discord channel.' };
    return { ok: false, message: (res && res.error) || 'The report could not be sent to Discord.' };
  } catch (e) {
    return { ok: false, message: 'The report could not be sent to Discord.' };
  }
}