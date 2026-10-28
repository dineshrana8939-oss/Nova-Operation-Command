import { invoke } from './nui.js';

export const getBootstrap = () => invoke('nova_convoytruck:getBootstrap');
export const getConvoys = () => invoke('nova_convoytruck:getConvoys');
export const getConvoy = (id) => invoke('nova_convoytruck:getConvoy', id);
export const createConvoy = (payload) => invoke('nova_convoytruck:createConvoy', payload);
export const updateConvoy = (id, payload) => invoke('nova_convoytruck:updateConvoy', id, payload);
export const deleteConvoy = (id) => invoke('nova_convoytruck:deleteConvoy', id);
export const reuseConvoy = (id) => invoke('nova_convoytruck:reuseConvoy', id);
export const cloneConvoy = (id, newName) => invoke('nova_convoytruck:cloneConvoy', id, newName);
// dateTimeLocal: the raw value of an <input type="datetime-local"> ("YYYY-MM-DDTHH:MM"),
// interpreted server-side as wall-clock time in Config.ScheduleUtcOffsetHours' zone.
export const scheduleConvoy = (id, dateTimeLocal) => invoke('nova_convoytruck:scheduleConvoy', id, dateTimeLocal);
export const scheduleRecurringConvoy = (id) => invoke('nova_convoytruck:scheduleRecurringConvoy', id);
export const unscheduleConvoy = (id) => invoke('nova_convoytruck:unscheduleConvoy', id);
export const forceEndConvoy = (id) => invoke('nova_convoytruck:forceEndConvoy', id);
export const getDashboard = () => invoke('nova_convoytruck:getDashboard');
export const getConvoyHistory = (limit) => invoke('nova_convoytruck:getConvoyHistory', limit);
export const deleteConvoyHistory = (id) => invoke('nova_convoytruck:deleteConvoyHistory', id);
export const clearConvoyHistory = () => invoke('nova_convoytruck:clearConvoyHistory');
export const getConvoyEvents = (convoyDefinitionId) => invoke('nova_convoytruck:getConvoyEvents', convoyDefinitionId);
// Admin-only (see callbacks.lua) — governs how EVERY admin-entered schedule
// date/time on this server is interpreted, not just the caller's own convoys.
export const getScheduleSettings = () => invoke('nova_convoytruck:getScheduleSettings');
export const setScheduleSettings = (utcOffsetHours, pollIntervalSeconds) => invoke('nova_convoytruck:setScheduleSettings', utcOffsetHours, pollIntervalSeconds);
// Returns { ok, utc } — the true server UTC unix timestamp (Scheduler.nowUtc()),
// not the caller's own PC clock. See CreateConvoy.svelte's clockSkewMs.
export const getServerTime = () => invoke('nova_convoytruck:getServerTime');
// Admin-only — broadcasts a banner to connected players. Supports optional custom title, message, and targetAudience ('EVERYONE' | 'GANG_ONLY').
export const announceUpcomingConvoy = (id, customTitle, customMessage, targetAudience) => invoke('nova_convoytruck:announceUpcomingConvoy', id, customTitle, customMessage, targetAudience);
export const sendServerAnnouncement = (title, body, bannerColor, imageUrl, imagePosition, imageFit, posX, posY, zoom) => invoke('nova_convoytruck:sendServerAnnouncement', title, body, bannerColor, imageUrl, imagePosition, imageFit, posX, posY, zoom);
export const previewServerAnnouncement = (title, body, bannerColor, imageUrl, imagePosition, imageFit, posX, posY, zoom) => invoke('nova_convoytruck:previewServerAnnouncement', title, body, bannerColor, imageUrl, imagePosition, imageFit, posX, posY, zoom);
// withPdf=false returns only the report data (no PDF is generated); true also returns the PDF as base64
export const getReportPdf = (id, withPdf = true) => invoke('nova_convoytruck:getReportPdf', id, withPdf);
export const getReportLink = (id) => invoke('nova_convoytruck:getReportLink', id);
export const sendReportToDiscord = (id) => invoke('nova_convoytruck:sendReportToDiscord', id);
export const getCivilianLeaderboard = (eventType) => invoke('nova_convoytruck:getCivilianLeaderboard', eventType);
export const getCivilianAvailableEvents = () => invoke('nova_convoytruck:civilian:getAvailableEvents');
export const joinCivilianEvent = (eventId) => invoke('nova_convoytruck:civilian:joinEvent', eventId);
export const getEventBanners = () => invoke('nova_convoytruck:getEventBanners');
export const saveEventBanner = (eventKey, imageUrl, posX, posY, zoom, fit) => invoke('nova_convoytruck:saveEventBanner', eventKey, imageUrl, posX, posY, zoom, fit);
