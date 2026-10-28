import { writable } from 'svelte/store';
import { getEventBanners } from '../api/convoy.js';

export const DEFAULT_EVENT_BANNERS = {
  crackdown: {
    eventKey: 'crackdown',
    imageUrl: '../images/event_announcement_banner_images/crackdown.jpg',
    posX: 50,
    posY: 50,
    zoom: 1.0,
    fit: 'cover',
  },
  containerwars: {
    eventKey: 'containerwars',
    imageUrl: '../images/event_announcement_banner_images/container_wars.jpg',
    posX: 50,
    posY: 50,
    zoom: 1.0,
    fit: 'cover',
  },
  hotcargo: {
    eventKey: 'hotcargo',
    imageUrl: '../images/event_announcement_banner_images/hot_cargo.jpg',
    posX: 50,
    posY: 50,
    zoom: 1.0,
    fit: 'cover',
  },
  airdrop: {
    eventKey: 'airdrop',
    imageUrl: '../images/event_announcement_banner_images/gang_airdrop.jpg',
    posX: 50,
    posY: 50,
    zoom: 1.0,
    fit: 'cover',
  },
  convoy: {
    eventKey: 'convoy',
    imageUrl: '../images/event_announcement_banner_images/convoy.jpg',
    posX: 50,
    posY: 50,
    zoom: 1.0,
    fit: 'cover',
  },
  rally: {
    eventKey: 'rally',
    imageUrl: '../images/event_announcement_banner_images/gang_race.jpg',
    posX: 50,
    posY: 50,
    zoom: 1.0,
    fit: 'cover',
  },
  territory: {
    eventKey: 'territory',
    imageUrl: '../images/event_announcement_banner_images/territory.jpg',
    posX: 50,
    posY: 10,
    zoom: 1.0,
    fit: 'cover',
  },
  rivals: {
    eventKey: 'rivals',
    imageUrl: '../images/event_announcement_banner_images/rivals.jpg',
    posX: 50,
    posY: 50,
    zoom: 1.0,
    fit: 'cover',
  },
  tdm: {
    eventKey: 'tdm',
    imageUrl: '../images/event_announcement_banner_images/tdm.jpg',
    posX: 50,
    posY: 50,
    zoom: 1.0,
    fit: 'cover',
  },
};

// Every event banner image lives in images/event_announcement_banner_images/ (declared in fxmanifest files), served
// straight from that folder by file name - so replacing a file there with a new image of the SAME name and restarting
// the resource changes the banner everywhere (the server adds a ?v=<start time> so the browser re-fetches it).
// Older saves point at the retired banners/ folder - they are mapped to the new one.
export const BANNER_DIR = '../images/event_announcement_banner_images/';
export function stripBannerVersion(url) {
  return typeof url === 'string' ? url.replace(/[?&]v=\d+/, '') : url;
}
export function normalizeBannerUrl(url) {
  return typeof url === 'string' && url.startsWith('banners/') ? BANNER_DIR + url.slice('banners/'.length) : url;
}
function normalizeBanners(map) {
  const out = {};
  for (const [k, v] of Object.entries(map || {})) out[k] = v && typeof v === 'object' ? { ...v, imageUrl: normalizeBannerUrl(v.imageUrl) } : v;
  return out;
}

export const eventBanners = writable({ ...DEFAULT_EVENT_BANNERS });

export async function fetchEventBanners() {
  try {
    const res = await getEventBanners();
    if (res && res.ok && res.banners) {
      eventBanners.update((cur) => ({ ...cur, ...normalizeBanners(res.banners) }));
    }
  } catch (err) {
    // browser preview / dev fallback
  }
}

export function setEventBanners(banners) {
  if (banners && typeof banners === 'object') {
    eventBanners.update((cur) => ({ ...cur, ...normalizeBanners(banners) }));
  }
}

