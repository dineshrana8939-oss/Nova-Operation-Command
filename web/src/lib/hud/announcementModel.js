// Everything that turns an announcement ({ type, title, message }) into what the banner card shows. The in-game HUD
// (Announcement.svelte) and the tablet's broadcast preview both go through here, so they can never disagree.
import { inferEventKey, statusFor, containerWarsStatus } from './eventThemes.js';

// the event kind the server stamps on an "upcoming event" announcement (callbacks.lua announceUpcomingConvoy)
export const KIND_TO_ANNOUNCE_TYPE = {
  CONVOY: 'convoy', GANG_AIRDROP: 'airdrop', HOT_CARGO: 'hotcargo', TDM: 'tdm', CONTAINER_WARS: 'containerwars', GANG_RACE: 'rally', GANG_TERRITORY: 'territory', CRACKDOWN: 'crackdown',
};

export function announcementSubtitle(eventKey, type, title = '', message = '') {
  const titleLower = (title || '').toLowerCase();
  const messageLower = (message || '').toLowerCase();
    if (eventKey === 'containerwars') {
      if (titleLower.includes('upcoming')) return 'UPCOMING AUCTION // CONTAINER WARS';
      if (titleLower.includes('final round') && titleLower.includes('bidding')) return 'FINAL BIDDING // HARBOUR AUCTION';
      if (titleLower.includes('final')) return 'FINAL ROUND // HARBOUR AUCTION';
      if (titleLower.includes('bidding open')) return 'BIDDING OPEN // HARBOUR AUCTION';
      if (titleLower.includes('opening')) return 'DOORS OPENING // HARBOUR AUCTION';
      if (titleLower.includes('won')) return 'LOT SOLD // HARBOUR AUCTION';
      if (titleLower.includes('no bids') || titleLower.includes('payment failed')) return 'LOT UNSOLD // HARBOUR AUCTION';
      if (titleLower.includes('concluded') || titleLower.includes('cancelled')) return 'AUCTION CLOSED // CONTAINER WARS';
      return 'HARBOUR AUCTION // CONTAINER WARS';
    }
    if (eventKey === 'rivals') {
      if (titleLower.includes('rival challenge') || titleLower.includes('challenge')) return 'RIVAL CHALLENGE // TERRITORY DISPUTE';
      if (titleLower.includes('scheduled')) return 'WAR SCHEDULED // TERRITORY CONTROL';
      if (titleLower.includes('captured')) return 'WAR WON // ATTACKERS WIN';
      if (titleLower.includes('defended')) return 'WAR WON // HOME GANG HOLDS';
      if (titleLower.includes('no show')) return 'WAR VOID // NO ONE SHOWED UP';
      if (titleLower.includes('contested')) return 'CAPTURE CONTESTED // TERRITORY WAR';
      return 'GANG RIVALS // TERRITORY WAR';
    }
    if (eventKey === 'crackdown') {
      if (titleLower.includes('fight')) return 'THE FIGHT IS ON // GANG VS POLICE';
      if (titleLower.includes('win') || titleLower.includes('draw')) return 'OPERATION OVER // CRACKDOWN RESULT';
      if (titleLower.includes('cancel')) return 'OPERATION CALLED OFF // CRACKDOWN';
      return 'OPERATION CRACKDOWN // GANG VS POLICE';
    }
    if (eventKey === 'territory') {
      if (titleLower.includes('upcoming')) return 'UPCOMING AUCTION // GANG TERRITORY';
      if (titleLower.includes('sold') || titleLower.includes('no bids') || titleLower.includes('payment failed')) return 'TERRITORY AUCTION // LOT RESULT';
      return 'GANG TERRITORY AUCTION // TERRITORY CONTROL';
    }
    if (titleLower.includes('police pursuit') || titleLower.includes('suspects fleeing') || titleLower.includes('illegal race')) return 'POLICE DISPATCH // 10-99 HIGH SPEED PURSUIT';
    if (titleLower.includes('upcoming') && titleLower.includes('rally')) return 'UPCOMING GANG RALLY // STREET RACE';
    if (titleLower.includes('upcoming') && titleLower.includes('airdrop')) return 'UPCOMING AIRDROP // SUPPLY EVENT';
    if (titleLower.includes('upcoming') && (titleLower.includes('hot cargo') || titleLower.includes('hot_cargo'))) return 'UPCOMING RUN // HOT CARGO SHIPMENT';
    if (titleLower.includes('upcoming') && titleLower.includes('convoy')) return 'UPCOMING CONVOY // ARMORED OPERATION';
    if (titleLower.includes('champion') || titleLower.includes('winner')) return 'RACE CONCLUDED // PODIUM VICTORY';
    if (titleLower.includes('rally') || type === 'rally') return 'STREET RALLY // ILLEGAL CIRCUIT';
    if (titleLower.includes('airdrop') || type === 'airdrop') return 'SUPPLY DROP // TACTICAL AIRDROP';
    if (titleLower.includes('hot cargo') || titleLower.includes('hot_cargo') || type === 'hotcargo') {
      if (titleLower.includes('alert') || titleLower.includes('dispatch')) return 'POLICE DISPATCH // HOT CARGO ALERT';
      if (titleLower.includes('hijack') || messageLower.includes('has hijacked')) return 'HOT CARGO // TRUCK HIJACKED';
      if (titleLower.includes('disabled')) return 'HOT CARGO // TRUCK DISABLED';
      if (titleLower.includes('critical')) return 'HOT CARGO // TRUCK CRITICAL';
      if (titleLower.includes('started')) return 'HOT CARGO // RUN LIVE';
      if (titleLower.includes('completed') || titleLower.includes('concluded') || titleLower.includes('failed') || titleLower.includes('cancelled') || titleLower.includes('ended')) return 'HOT CARGO // RUN ENDED';
      return 'HOT CARGO // HIGH VALUE SHIPMENT';
    }
    if (eventKey === 'tdm') return 'COMBAT EVENT // TEAM DEATHMATCH';
    if (titleLower.includes('started') || titleLower.includes('departed')) return 'CONVOY DEPARTURE // SERVER EVENT';
    if (titleLower.includes('checkpoint')) return 'CHECKPOINT STATUS // CONVOY OPERATION';
    if (titleLower.includes('ambush')) return 'HOSTILE AMBUSH // THREAT ENGAGEMENT';
    if (titleLower.includes('captured') || titleLower.includes('hijacked')) return 'CONVOY HIJACKED // TACTICAL VICTORY';
    if (titleLower.includes('delivered') || titleLower.includes('secured')) return 'SHIPMENT SECURED // MISSION COMPLETE';
    if (titleLower.includes('failed') || titleLower.includes('destroyed')) return 'MISSION FAILED // CONVOY LOST';
    if (titleLower.includes('cancelled')) return 'OPERATION TERMINATED // STAND DOWN';
    if (type === 'warn') return 'TACTICAL WARNING // ATTENTION';
    if (type === 'danger') return 'CRITICAL ALERT // HIGH THREAT';
    if (type === 'success') return 'OBJECTIVE COMPLETE // STATUS UPDATE';
    if (type === 'convoy') return 'TACTICAL DISPATCH // CONVOY OPERATION';
    return 'SERVER ANNOUNCEMENT // ADMIN BROADCAST';
}

// Right-hand badge: the server's own wins, otherwise derived from the wording.
export function announcementStatus(eventKey, type, title, given) {
  return given || (eventKey === 'containerwars' ? containerWarsStatus(title) : statusFor(type, title));
}

// The banner image configured for the event (Event Banner Images tab), as the card wants it.
export function announcementImage(bannerCfg, ann = {}) {
  const posX = ann.posX != null ? ann.posX : (bannerCfg ? bannerCfg.posX : 50);
  const posY = ann.posY != null ? ann.posY : (bannerCfg ? bannerCfg.posY : 50);
  return {
    img: ann.imageUrl || (bannerCfg && bannerCfg.imageUrl) || null,
    pos: ann.imagePosition || `${posX}% ${posY}%`,
    fit: ann.imageFit || (bannerCfg ? bannerCfg.fit : 'cover'),
    zoom: ann.zoom != null ? ann.zoom : (bannerCfg ? bannerCfg.zoom : 1.0),
  };
}

export { inferEventKey };