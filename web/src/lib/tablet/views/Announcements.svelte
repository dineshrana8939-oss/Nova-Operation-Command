<script>
  import { onMount } from 'svelte';
  import {
    getConvoys,
    announceUpcomingConvoy,
    sendServerAnnouncement,
    previewServerAnnouncement,
    saveEventBanner,
  } from '../../api/convoy.js';
  import { tabletPreviewHide, tabletPreviewRestore } from '../../api/route.js';
  import { handleHudMessage } from '../../hud/hudStore.js';
  import { eventBanners, DEFAULT_EVENT_BANNERS, fetchEventBanners, stripBannerVersion } from '../../hud/eventBannerStore.js';
  import AnnouncementCard from '../../hud/AnnouncementCard.svelte';
  import { KIND_TO_ANNOUNCE_TYPE, inferEventKey, announcementSubtitle, announcementStatus, announcementImage } from '../../hud/announcementModel.js';
  import { THEMES } from '../../hud/eventThemes.js';
  import { confirmAction } from '../ui/confirm.js';
  import Icon from '../ui/Icon.svelte';
  import { kindTag, statusTag } from '../ui/badges.js';
  import { STATUS_LABELS } from '../../constants.js';
  import { viewSub, announceEventId } from '../../stores.js';
  import BannerImageEditor from '../ui/BannerImageEditor.svelte';
  import '../tablet-theme.css';

  let convoys = [];
  let loading = true;
  let error = '';

  // Custom announcement section
  let customTitle = '';
  let customBody = '';
  let sendingCustom = false;
  let customSentFlash = false;
  let customSentFlashTimer;

  // Banner customization state
  let bannerColor = '#368FE9';
  let hueValue = 211;
  let hexInput = '#368FE9';
  let imageUrlInput = '';
  let loadedImageUrl = '';
  let imageLoading = false;
  let imageError = '';
  let customFit = 'cover'; // 'cover' | 'contain'
  let customPosX = 50;     // 0 to 100
  let customPosY = 50;     // 0 to 100
  let customZoom = 1.0;    // 0.5 to 3.0
  $: imageFit = customFit;
  $: imageOffsetY = customPosY;
  $: activeImageUrl = loadedImageUrl || (imageUrlInput.trim().startsWith('http') ? imageUrlInput.trim() : '');
  $: imagePosition = `${customPosX}% ${customPosY}%`;
  let previewMyselfActive = false;
  let previewRestoreTimer;
  let previewFlashTimer;

  // Event Banner Images Management state
  let editingBanner = null;
  let savingBanner = false;
  let bannerSavedFlash = '';
  let bannerSavedFlashTimer;

  // Inline Frame Setting & Size state
  let activeEditKey = null;
  let editDraft = null;
  let isBannerDragging = false;
  let dragStartX = 0;
  let dragStartY = 0;
  let startPosX = 50;
  let startPosY = 50;

  const EVENT_BANNER_TYPES = [
    {
      key: 'territory',
      name: 'Gang Territory Auction',
      kind: 'GANG_TERRITORY',
      badgeClass: 'kind-badge-territory',
      badgeText: 'Gang Territory',
      kicker: 'UPCOMING AUCTION // GANG TERRITORY',
      sampleTitle: 'Gang Territory Auction Starting Soon',
      sampleDesc: 'Grove Street, Davis and Strawberry go to the highest bidding gang. Bring your money to the auction house.',
      icon: 'pin',
      accent: '#c45ee0',
      accentRgb: '196, 94, 224',
      defaultImage: '../images/event_announcement_banner_images/territory.jpg',
    },
    {
      key: 'rivals',
      name: 'Gang Rivals',
      kind: 'GANG_TERRITORY',
      badgeClass: 'kind-badge-rivals',
      badgeText: 'Gang Rivals',
      kicker: 'RIVAL CHALLENGE // TERRITORY DISPUTE',
      sampleTitle: 'Rival War: Ballas vs Vagos',
      sampleDesc: 'The challenge for Davis has been accepted. Both gangs: get ready for the war.',
      icon: 'crosshair',
      accent: '#5b7bff',
      accentRgb: '91, 123, 255',
      defaultImage: '../images/event_announcement_banner_images/rivals.jpg',
    },
    {
      key: 'containerwars',
      name: 'Container Wars',
      kind: 'CONTAINER_WARS',
      badgeClass: 'kind-badge-cw',
      badgeText: 'Container Wars',
      kicker: 'UPCOMING AUCTION // CONTAINER WARS',
      sampleTitle: 'Harbour Container Wars Starting Soon',
      sampleDesc: 'High-stakes bidding auction will commence at Terminal 4. Secure rare cargo containers.',
      icon: 'box',
      accent: '#52d24a',
      accentRgb: '82, 210, 74',
      defaultImage: '../images/event_announcement_banner_images/container_wars.jpg',
    },
    {
      key: 'hotcargo',
      name: 'Hot Cargo',
      kind: 'HOT_CARGO',
      badgeClass: 'kind-badge-hot',
      badgeText: 'Hot Cargo',
      kicker: 'UPCOMING RUN // HOT CARGO SHIPMENT',
      sampleTitle: 'Armored Tanker High-Value Transport',
      sampleDesc: 'Contract payload en route across Los Santos. Intercept or escort the shipment.',
      icon: 'flame',
      accent: '#e0489f',
      accentRgb: '224, 72, 159',
      defaultImage: '../images/event_announcement_banner_images/hot_cargo.jpg',
    },
    {
      key: 'airdrop',
      name: 'Gang Airdrop',
      kind: 'GANG_AIRDROP',
      badgeClass: 'kind-badge-airdrop',
      badgeText: 'Gang Airdrop',
      kicker: 'UPCOMING AIRDROP // SUPPLY EVENT',
      sampleTitle: 'Military Supply Crate Airborne',
      sampleDesc: 'Tactical cargo dropping in Sandy Shores. Contested drop zone with heavy combat.',
      icon: 'parachute',
      accent: '#9b7bff',
      accentRgb: '155, 123, 255',
      defaultImage: '../images/event_announcement_banner_images/gang_airdrop.jpg',
    },
    {
      key: 'convoy',
      name: 'Convoy',
      kind: 'CONVOY',
      badgeClass: 'kind-badge-convoy',
      badgeText: 'Convoy',
      kicker: 'UPCOMING CONVOY // ARMORED OPERATION',
      sampleTitle: 'Armed Federal Convoy in Transit',
      sampleDesc: 'Heavy security escort carrying high tier black market loot across Highway 1.',
      icon: 'truck',
      accent: '#ee8a2b',
      accentRgb: '238, 138, 43',
      defaultImage: '../images/event_announcement_banner_images/convoy.jpg',
    },
    {
      key: 'rally',
      name: 'Gang Rally',
      kind: 'GANG_RACE',
      badgeClass: 'kind-badge-race',
      badgeText: 'Gang Rally',
      kicker: 'UPCOMING GANG RALLY // STREET RACE',
      sampleTitle: 'Underground Street Rally Grand Prix',
      sampleDesc: 'Illegal sprint tournament open for registration. Checkpoint circuit through downtown.',
      icon: 'flag',
      accent: '#22c7d6',
      accentRgb: '34, 199, 214',
      defaultImage: '../images/event_announcement_banner_images/gang_race.jpg',
    },
    {
      key: 'tdm',
      name: 'TDM Match',
      kind: 'TDM',
      badgeClass: 'kind-badge-tdm',
      badgeText: 'TDM Match',
      kicker: 'COMBAT EVENT // TEAM DEATHMATCH',
      sampleTitle: 'Gang Arena Warfare 5v5',
      sampleDesc: 'Tactical industrial firefight scheduled. Ready your squad and weapons for battle.',
      icon: 'shield',
      accent: '#e5484d',
      accentRgb: '229, 72, 77',
      defaultImage: '../images/event_announcement_banner_images/tdm.jpg',
    },
    {
      key: 'crackdown',
      name: 'Operation Crackdown',
      kind: 'CRACKDOWN',
      badgeClass: 'kind-badge-tdm',
      badgeText: 'Operation Crackdown',
      kicker: 'GANG VS POLICE // OPERATION CRACKDOWN',
      sampleTitle: 'Operation Crackdown: Harbour Sweep',
      sampleDesc: 'One gang against the police on duty inside a combat zone. Last side standing wins.',
      icon: 'shield',
      accent: '#d6336c',
      accentRgb: '214, 51, 108',
      defaultImage: '../images/event_announcement_banner_images/crackdown.jpg',
    },
  ];

  const COLOR_PRESETS = [
    { label: 'Blue', color: '#368FE9' },
    { label: 'Green', color: '#3BC47B' },
    { label: 'Gold', color: '#E7A72F' },
    { label: 'Red', color: '#E85C62' },
    { label: 'Purple', color: '#9B6CFF' },
    { label: 'Pink', color: '#E66AA8' },
    { label: 'Cyan', color: '#00C9C8' },
    { label: 'Steel', color: '#8F9CAE' },
  ];

  function hueHex(H) {
    let s = 0.72, v = 0.91;
    let f = n => v - v * s * Math.max(Math.min((n + H / 60) % 6, 4 - (n + H / 60) % 6, 1), 0);
    return '#' + [f(5), f(3), f(1)].map(x => Math.round(x * 255).toString(16).padStart(2, '0')).join('').toUpperCase();
  }

  function onHueInput(e) {
    hueValue = +e.target.value;
    const c = hueHex(hueValue);
    bannerColor = c;
    hexInput = c;
  }

  function onHexInput(e) {
    const val = e.target.value.trim().toUpperCase();
    hexInput = val;
    if (/^#[0-9A-F]{6}$/i.test(val)) {
      bannerColor = val;
    }
  }

  function selectPreset(c) {
    bannerColor = c.toUpperCase();
    hexInput = bannerColor;
  }

  function loadImage() {
    imageError = '';
    const url = imageUrlInput.trim();
    if (!url) {
      loadedImageUrl = '';
      return;
    }
    if (!/^https?:\/\//i.test(url)) {
      imageError = 'URL must start with http:// or https://';
      return;
    }
    imageLoading = true;
    const img = new Image();
    img.onload = () => {
      imageLoading = false;
      loadedImageUrl = url;
      imageError = '';
    };
    img.onerror = () => {
      imageLoading = false;
      // In CEF / NUI, JS Image() preloads can trigger CORS on CDNs while CSS backgrounds still display fine
      loadedImageUrl = url;
      imageError = '';
    };
    img.src = url;
  }

  function clearImage() {
    imageUrlInput = '';
    loadedImageUrl = '';
    imageError = '';
    customPosX = 50;
    customPosY = 50;
    customZoom = 1.0;
    customFit = 'cover';
  }

  // Event Announcement Modal state
  let selectedEvent = null;
  let modalTitle = '';
  let modalBody = '';
  let modalAudience = 'EVERYONE'; // 'EVERYONE' | 'GANG_ONLY'
  let broadcasting = false;
  let modalError = '';

  $: upcoming = convoys.filter((c) => c.status === 'DRAFT' || c.status === 'SCHEDULED');

  // Three sub-tabs: Event Announcements, Custom Announcement, and Event Banner Images
  // The three sub pages (events / custom / banners) are chosen from the floating row under the main menu (navGroups.js).
  $: sub = ['events', 'custom', 'banners'].includes($viewSub) ? $viewSub : 'events';

  // Event list: name search + type/status picklists + paging.
  const KIND_FILTER_OPTIONS = [
    { value: 'ALL', label: 'All types' },
    { value: 'CONVOY', label: 'Convoy' },
    { value: 'GANG_AIRDROP', label: 'Gang Airdrop' },
    { value: 'HOT_CARGO', label: 'Hot Cargo' },
    { value: 'GANG_RACE', label: 'Gang Rally' },
    { value: 'TDM', label: 'TDM Match' },
    { value: 'CONTAINER_WARS', label: 'Container Wars' },
    { value: 'GANG_TERRITORY', label: 'Gang Territory Auction' },
    { value: 'CRACKDOWN', label: 'Operation Crackdown' },
  ];
  const STATUS_FILTER_OPTIONS = [
    { value: 'ALL', label: 'All statuses' },
    { value: 'DRAFT', label: 'Draft' },
    { value: 'SCHEDULED', label: 'Scheduled' },
  ];
  let searchQuery = '';
  let kindFilter = 'ALL';
  let statusFilter = 'ALL';
  let page = 1;
  let pageSize = 20;

  $: filteredUpcoming = upcoming.filter((c) => {
    const q = searchQuery.toLowerCase().trim();
    if (q && !(c.name || '').toLowerCase().includes(q)) return false;
    if (kindFilter !== 'ALL' && (c.kind || 'CONVOY') !== kindFilter) return false;
    if (statusFilter !== 'ALL' && c.status !== statusFilter) return false;
    return true;
  });
  $: filtersActive = searchQuery.trim() !== '' || kindFilter !== 'ALL' || statusFilter !== 'ALL';
  $: totalPages = Math.max(1, Math.ceil(filteredUpcoming.length / pageSize));
  $: if (page > totalPages) page = totalPages;
  $: if (page < 1) page = 1;
  $: from = filteredUpcoming.length === 0 ? 0 : (page - 1) * pageSize + 1;
  $: to = Math.min(page * pageSize, filteredUpcoming.length);
  $: pagedEvents = filteredUpcoming.slice((page - 1) * pageSize, page * pageSize);

  const resetPage = () => { page = 1; };
  $: resetPage(searchQuery, kindFilter, statusFilter, pageSize);
  function clearFilters() { searchQuery = ''; kindFilter = 'ALL'; statusFilter = 'ALL'; page = 1; }

  // Single source of truth for how each event kind is labelled/badged/iconed
  // on this screen — every kind branch used to be repeated inline in five
  // separate places (table badge, modal badge, modal title default, preview
  // icon, preview subtitle), and GANG_RACE was missing from every one of
  // them, so a Rally Race always fell through to the generic Convoy text.
  // The broadcast preview is the REAL in-game banner card, fed through the same logic as the HUD, with the event's
  // banner image straight from the shared store - so saving a new image in the Event Banner Images tab shows here
  // at once, and what is previewed is what players get.
  $: pvType = selectedEvent ? (KIND_TO_ANNOUNCE_TYPE[selectedEvent.kind] || 'convoy') : 'convoy';
  $: pvTitle = modalTitle || 'Announcement Title';
  $: pvKey = inferEventKey(pvType, pvTitle, modalBody);
  $: pvImage = announcementImage($eventBanners[pvKey]);

  // Custom server announcement: exactly what the server broadcasts (type 'info') and the HUD then derives from it.
  $: cuTitle = customTitle || 'Server Restart in 10 Minutes';
  $: cuKey = inferEventKey('info', cuTitle, customBody);
  $: cuImage = announcementImage($eventBanners[cuKey], {
    imageUrl: activeImageUrl || null, imagePosition, imageFit: customFit, posX: customPosX, posY: customPosY, zoom: customZoom,
  });
  function kindMeta(kind) {
    if (kind === 'GANG_AIRDROP') return { label: 'Gang Airdrop', badgeClass: 'kind-badge-airdrop', icon: 'parachute', previewClass: 'preview-airdrop', subtitle: 'UPCOMING AIRDROP // SUPPLY EVENT', titlePrefix: 'Upcoming Gang Airdrop' };
    if (kind === 'HOT_CARGO') return { label: 'Hot Cargo', badgeClass: 'kind-badge-hot', icon: 'flame', previewClass: 'preview-hot', subtitle: 'UPCOMING RUN // HOT CARGO SHIPMENT', titlePrefix: 'Upcoming Hot Cargo Run' };
    if (kind === 'GANG_RACE') return { label: 'Gang Rally', badgeClass: 'kind-badge-race', icon: 'flag', previewClass: 'preview-rally', subtitle: 'UPCOMING GANG RALLY // STREET RACE', titlePrefix: 'Upcoming Gang Rally' };
    if (kind === 'TDM') return { label: 'TDM Match', badgeClass: 'kind-badge-tdm', icon: 'shield', previewClass: 'preview-convoy', subtitle: 'UPCOMING TDM // GANG VS GANG', titlePrefix: 'Upcoming TDM Match' };
    if (kind === 'CONTAINER_WARS') return { label: 'Container Wars', badgeClass: 'kind-badge-cw', icon: 'box', previewClass: 'preview-cw', subtitle: 'UPCOMING AUCTION // HARBOUR DOCK WARS', titlePrefix: 'Upcoming Container Wars' };
    if (kind === 'CRACKDOWN') return { label: 'Operation Crackdown', badgeClass: 'kind-badge-tdm', icon: 'shield', previewClass: 'preview-convoy', subtitle: 'OPERATION CRACKDOWN // GANG VS POLICE', titlePrefix: 'Operation Crackdown' };
    if (kind === 'GANG_TERRITORY') return { label: 'Gang Territory', badgeClass: 'kind-badge-territory', icon: 'pin', previewClass: 'preview-territory', subtitle: 'UPCOMING AUCTION // GANG TERRITORY', titlePrefix: 'Upcoming Gang Territory Auction' };
    return { label: 'Convoy', badgeClass: 'kind-badge-convoy', icon: 'truck', previewClass: 'preview-convoy', subtitle: 'UPCOMING CONVOY // ARMORED OPERATION', titlePrefix: 'Upcoming Convoy Event' };
  }

  async function refresh() {
    loading = true;
    const res = await getConvoys();
    convoys = res && res.ok ? res.convoys : [];
    loading = false;
    openRequestedEvent();
  }

  // Manage Events → Announce lands here: open the announcement window of the event it named (only Draft / Scheduled ones can be announced)
  function openRequestedEvent() {
    const id = $announceEventId;
    if (id == null) return;
    announceEventId.set(null);
    const ev = convoys.find((c) => c.id === id);
    if (ev && (ev.status === 'DRAFT' || ev.status === 'SCHEDULED')) openAnnounceModal(ev);
  }

  function formatScheduled(ts) {
    if (!ts) return null;
    return new Date(ts * 1000).toLocaleString();
  }

  function openAnnounceModal(c) {
    selectedEvent = c;
    modalError = '';
    modalTitle = `${kindMeta(c.kind).titlePrefix}: ${c.name}`;
    const settings = c.settings || {};
    modalAudience = settings.eventAccess === 'GANG_ONLY' ? 'GANG_ONLY' : 'EVERYONE';

    let parts = [];
    if (c.shortDescription && c.shortDescription.trim()) {
      parts.push(c.shortDescription.trim());
    }
    if (settings.announceStartTime && settings.announceStartTime.trim()) {
      parts.push(`Starts ${settings.announceStartTime.trim()}.`);
    } else if (c.status === 'SCHEDULED' && c.scheduledAt) {
      parts.push(`Starts ${formatScheduled(c.scheduledAt)}.`);
    } else {
      parts.push('No fixed start time yet — keep an eye out.');
    }
    if (settings.announceEndTime && settings.announceEndTime.trim()) {
      parts.push(`Ends ${settings.announceEndTime.trim()}.`);
    }
    if (settings.announceMessage && settings.announceMessage.trim()) {
      parts.push(settings.announceMessage.trim());
    }
    modalBody = parts.join('\n');
  }

  function closeAnnounceModal() {
    selectedEvent = null;
    modalTitle = '';
    modalBody = '';
    modalAudience = 'EVERYONE';
    modalError = '';
  }

  async function submitEventAnnouncement() {
    if (!selectedEvent) return;
    if (!modalTitle.trim()) {
      modalError = 'Announcement title cannot be empty.';
      return;
    }
    broadcasting = true;
    modalError = '';
    const res = await announceUpcomingConvoy(selectedEvent.id, modalTitle.trim(), modalBody.trim(), modalAudience);
    broadcasting = false;
    if (!res || !res.ok) {
      modalError = (res && res.error) || 'Failed to broadcast announcement.';
      return;
    }
    closeAnnounceModal();
    customSentFlash = true;
    clearTimeout(customSentFlashTimer);
    customSentFlashTimer = setTimeout(() => (customSentFlash = false), 3000);
  }

  // "Test HUD": shows this event's banner on your own screen right now, with the image currently saved for it
  // (no explicit image is passed, so the HUD falls back to the saved event banner - exactly what players get).
  function testEventBanner(ev) {
    // through the HUD's own 'announce' handler, which also owns the hide timer — writing the store directly left the banner up for good
    handleHudMessage({
      action: 'announce',
      title: `${ev.name} banner test`,
      message: 'Admin preview of this event banner.',
      type: ev.key,
      status: 'ADMIN PREVIEW',
      duration: 9000,
    });
  }
  async function previewMyself() {
    error = '';
    if (!customTitle.trim()) {
      error = 'Title is required before previewing.';
      return;
    }

    const activeImg = activeImageUrl || null;

    // The banner is shown by the REAL pipeline (the server sends it to this player only, exactly like a broadcast),
    // at the top of the screen - which the open tablet would cover, so the tablet steps aside while it plays.
    let shown = false;
    try {
      const res = await previewServerAnnouncement(
        customTitle.trim(),
        customBody.trim(),
        bannerColor,
        activeImg,
        imagePosition,
        customFit,
        customPosX,
        customPosY,
        customZoom
      );
      shown = !(res && res.ok === false);
    } catch (e) {
      shown = false;
    }

    // browser / dev fallback: no game behind the page, draw it locally
    if (!shown) {
      handleHudMessage({
        action: 'announce',
        title: customTitle.trim(),
        message: customBody.trim(),
        type: 'info',
        status: 'ADMIN PREVIEW',
        duration: 9000,
        bannerColor,
        imageUrl: activeImg,
        imagePosition,
        imageFit: customFit,
        posX: customPosX,
        posY: customPosY,
        zoom: customZoom,
      });
    }
    tabletPreviewHide();
    clearTimeout(previewRestoreTimer);
    previewRestoreTimer = setTimeout(() => tabletPreviewRestore(), 11500);
    previewMyselfActive = true;
    clearTimeout(previewFlashTimer);
    previewFlashTimer = setTimeout(() => (previewMyselfActive = false), 3500);
  }

  async function sendCustom() {
    error = '';
    if (!customTitle.trim()) { error = 'Title is required.'; return; }
    const ok = await confirmAction(`Broadcast to EVERY connected player right now:\n\n"${customTitle}"\n${customBody}`, { title: 'Send Server Announcement' });
    if (!ok) return;
    sendingCustom = true;
    const activeImg = activeImageUrl || null;
    const res = await sendServerAnnouncement(
      customTitle.trim(),
      customBody.trim(),
      bannerColor,
      activeImg,
      imagePosition,
      customFit,
      customPosX,
      customPosY,
      customZoom
    );
    sendingCustom = false;
    if (!res || !res.ok) { error = (res && res.error) || 'Failed to send announcement.'; return; }
    customSentFlash = true;
    clearTimeout(customSentFlashTimer);
    customSentFlashTimer = setTimeout(() => (customSentFlash = false), 3500);
  }

  function openEditBanner(ev) {
    const cfg = $eventBanners[ev.key] || DEFAULT_EVENT_BANNERS[ev.key] || {};
    editingBanner = {
      isCustom: false,
      key: ev.key,
      name: ev.name,
      title: `Edit Banner — ${ev.name}`,
      eventKey: ev.key,
      bannerColor: ev.accent || (THEMES[ev.key] && THEMES[ev.key].accent) || '#368fe9',
      imageUrl: cfg.imageUrl || ev.defaultImage || '',
      defaultImageUrl: ev.defaultImage || cfg.imageUrl || '',
      posX: cfg.posX != null ? cfg.posX : 50,
      posY: cfg.posY != null ? cfg.posY : 50,
      zoom: cfg.zoom != null ? cfg.zoom : 1.0,
      fit: cfg.fit || 'cover',
    };
  }

  function openCustomBannerEditor() {
    editingBanner = {
      isCustom: true,
      key: 'custom',
      name: 'Custom Announcement',
      title: 'Edit Custom Announcement Banner',
      eventKey: 'server',
      bannerColor: bannerColor,
      imageUrl: activeImageUrl || '',
      defaultImageUrl: '',
      posX: customPosX,
      posY: customPosY,
      zoom: customZoom,
      fit: customFit,
    };
  }

  async function handleBannerSave(e) {
    const detail = e.detail;
    if (editingBanner && editingBanner.isCustom) {
      if (detail.imageUrl !== undefined) {
        imageUrlInput = detail.imageUrl || '';
        loadedImageUrl = detail.imageUrl || '';
      }
      customPosX = detail.posX;
      customPosY = detail.posY;
      customZoom = detail.zoom;
      customFit = detail.fit;
      editingBanner = null;
      return;
    }

    if (!editingBanner) return;

    savingBanner = true;
    try {
      const res = await saveEventBanner(
        editingBanner.key,
        detail.imageUrl,
        detail.posX,
        detail.posY,
        detail.zoom,
        detail.fit
      );
      if (res && res.ok && res.banners) {
        eventBanners.update((cur) => ({ ...cur, ...res.banners }));
      } else {
        eventBanners.update((cur) => ({
          ...cur,
          [editingBanner.key]: {
            ...(cur[editingBanner.key] || {}),
            imageUrl: detail.imageUrl,
            posX: detail.posX,
            posY: detail.posY,
            zoom: detail.zoom,
            fit: detail.fit,
          },
        }));
      }
      bannerSavedFlash = `Banner framing for ${editingBanner.name} saved!`;
      clearTimeout(bannerSavedFlashTimer);
      bannerSavedFlashTimer = setTimeout(() => (bannerSavedFlash = ''), 3500);
    } catch (err) {
      console.error('Error saving banner:', err);
    } finally {
      savingBanner = false;
      editingBanner = null;
    }
  }

  function startEditEvent(ev) {
    if (activeEditKey === ev.key) {
      activeEditKey = null;
      editDraft = null;
      return;
    }
    const cfg = $eventBanners[ev.key] || DEFAULT_EVENT_BANNERS[ev.key] || {};
    activeEditKey = ev.key;
    editDraft = {
      key: ev.key,
      name: ev.name,
      accent: ev.accent || (THEMES[ev.key] && THEMES[ev.key].accent) || '#368fe9',
      imageUrl: cfg.imageUrl || ev.defaultImage || '',
      defaultImageUrl: ev.defaultImage || cfg.imageUrl || '',
      inputUrl: cfg.imageUrl || ev.defaultImage || '',
      posX: cfg.posX != null ? cfg.posX : 50,
      posY: cfg.posY != null ? cfg.posY : 50,
      zoom: cfg.zoom != null ? cfg.zoom : 1.0,
      fit: cfg.fit || 'cover',
      imageLoading: false,
      imageError: '',
    };
  }

  function cancelEditEvent() {
    activeEditKey = null;
    editDraft = null;
  }

  async function saveEditEvent() {
    if (!editDraft) return;
    savingBanner = true;
    const keyToSave = editDraft.key;
    const savedName = editDraft.name;
    const imgToSave = editDraft.imageUrl ? editDraft.imageUrl.trim() : null;
    const px = Math.round(editDraft.posX);
    const py = Math.round(editDraft.posY);
    const zm = +(+editDraft.zoom).toFixed(2);
    const ft = editDraft.fit || 'cover';

    try {
      const res = await saveEventBanner(keyToSave, imgToSave, px, py, zm, ft);
      if (res && res.ok && res.banners) {
        eventBanners.update((cur) => ({ ...cur, ...res.banners }));
      } else {
        eventBanners.update((cur) => ({
          ...cur,
          [keyToSave]: {
            ...(cur[keyToSave] || {}),
            imageUrl: imgToSave,
            posX: px,
            posY: py,
            zoom: zm,
            fit: ft,
          },
        }));
      }
      bannerSavedFlash = `Banner framing for ${savedName} saved successfully!`;
      clearTimeout(bannerSavedFlashTimer);
      bannerSavedFlashTimer = setTimeout(() => (bannerSavedFlash = ''), 3500);
      activeEditKey = null;
      editDraft = null;
    } catch (err) {
      console.error('Error saving banner:', err);
    } finally {
      savingBanner = false;
    }
  }

  function loadDraftImage() {
    if (!editDraft) return;
    editDraft.imageError = '';
    const trimmed = (editDraft.inputUrl || '').trim();
    if (!trimmed) {
      editDraft.imageUrl = '';
      return;
    }
    editDraft.imageLoading = true;
    const img = new Image();
    img.onload = () => {
      if (!editDraft) return;
      editDraft.imageLoading = false;
      editDraft.imageUrl = trimmed;
      editDraft.imageError = '';
    };
    img.onerror = () => {
      if (!editDraft) return;
      editDraft.imageLoading = false;
      // In CEF / NUI, JS Image() preloads can trigger CORS for some CDNs while CSS backgrounds display fine.
      editDraft.imageUrl = trimmed;
      editDraft.imageError = '';
    };
    img.src = trimmed;
  }

  function resetDraftComposition() {
    if (!editDraft) return;
    editDraft.posX = 50;
    editDraft.posY = 50;
    editDraft.zoom = 1.0;
    editDraft.fit = 'cover';
    if (!editDraft.imageUrl && editDraft.defaultImageUrl) {
      editDraft.imageUrl = editDraft.defaultImageUrl;
      editDraft.inputUrl = editDraft.defaultImageUrl;
    }
  }

  function onBannerMouseDown(e, key) {
    if (e.button !== 0 || activeEditKey !== key || !editDraft || !editDraft.imageUrl) return;
    isBannerDragging = true;
    dragStartX = e.clientX;
    dragStartY = e.clientY;
    startPosX = editDraft.posX;
    startPosY = editDraft.posY;

    window.addEventListener('mousemove', onBannerMouseMove);
    window.addEventListener('mouseup', onBannerMouseUp);
  }

  function onBannerMouseMove(e) {
    if (!isBannerDragging || !editDraft) return;
    const dx = e.clientX - dragStartX;
    const dy = e.clientY - dragStartY;
    const sensitivity = 0.35 / Math.max(0.5, editDraft.zoom);
    editDraft.posX = Math.max(0, Math.min(100, Math.round(startPosX - dx * sensitivity)));
    editDraft.posY = Math.max(0, Math.min(100, Math.round(startPosY - dy * sensitivity)));
  }

  function onBannerMouseUp() {
    isBannerDragging = false;
    window.removeEventListener('mousemove', onBannerMouseMove);
    window.removeEventListener('mouseup', onBannerMouseUp);
  }

  function onBannerWheel(e, key) {
    if (activeEditKey !== key || !editDraft || !editDraft.imageUrl) return;
    e.preventDefault();
    const delta = e.deltaY < 0 ? 0.05 : -0.05;
    editDraft.zoom = Math.max(0.5, Math.min(3.0, +(editDraft.zoom + delta).toFixed(2)));
  }

  onMount(() => {
    refresh();
    fetchEventBanners();
  });
</script>

<div class="panel view-enter">
  <div class="panel-header">
    <span class="panel-title"><Icon name="activity" size={14} /> Announcements</span>
    <button class="btn btn-refresh" on:click={refresh}><Icon name="refresh" size={13} /> Refresh</button>
  </div>
  <div class="panel-body">
    {#if error}<div class="error">{error}</div>{/if}
    {#if customSentFlash}<div class="saved-flash" style="margin-bottom:12px"><Icon name="check" size={14} /> Announcement successfully broadcast server-wide!</div>{/if}

    {#if sub === 'events'}
    <p class="note">Broadcasts a banner to EVERY connected player server-wide — not gated by event join, gang, or police status. Admin-only.</p>
    <div class="ann-control-bar">
      <div class="ctrl-filters-group">
        <div class="ctrl-search">
          <Icon name="search" size={13} />
          <input type="text" placeholder="Search event name..." bind:value={searchQuery} />
          {#if searchQuery}
            <button type="button" class="ctrl-clear-btn" on:click={() => (searchQuery = '')} aria-label="Clear search">
              <Icon name="close" size={12} />
            </button>
          {/if}
        </div>

        <div class="ctrl-select-wrap">
          <span class="ctrl-select-lbl">Type</span>
          <select bind:value={kindFilter}>
            {#each KIND_FILTER_OPTIONS as o}
              <option value={o.value}>{o.label}</option>
            {/each}
          </select>
        </div>

        <div class="ctrl-select-wrap">
          <span class="ctrl-select-lbl">Status</span>
          <select bind:value={statusFilter}>
            {#each STATUS_FILTER_OPTIONS as o}
              <option value={o.value}>{o.label}</option>
            {/each}
          </select>
        </div>
      </div>

      <div class="ctrl-paging-group">
        <div class="ctrl-rows-select">
          <span class="ctrl-rows-lbl">Rows</span>
          <select bind:value={pageSize}>
            <option value={10}>10</option>
            <option value={20}>20</option>
            <option value={50}>50</option>
            <option value={100}>100</option>
          </select>
        </div>

        <div class="ctrl-pager-actions">
          <button type="button" class="ann-pg-btn" disabled={page <= 1} on:click={() => (page = 1)} title="First page" aria-label="First page">«</button>
          <button type="button" class="ann-pg-btn" disabled={page <= 1} on:click={() => (page -= 1)} title="Previous page" aria-label="Previous page">‹</button>
          <span class="ann-pg-info">{page} / {totalPages}</span>
          <button type="button" class="ann-pg-btn" disabled={page >= totalPages} on:click={() => (page += 1)} title="Next page" aria-label="Next page">›</button>
          <button type="button" class="ann-pg-btn" disabled={page >= totalPages} on:click={() => (page = totalPages)} title="Last page" aria-label="Last page">»</button>
        </div>

        <div class="ctrl-meta-info">
          <span><strong>{from}–{to}</strong> of <strong>{filteredUpcoming.length}</strong></span>
          {#if filtersActive}
            <button type="button" class="ann-reset" on:click={clearFilters}>Clear</button>
          {/if}
        </div>
      </div>
    </div>
    {#if loading}
      <div class="empty-state">Loading events...</div>
    {:else if upcoming.length === 0}
      <div class="empty-state">No draft or scheduled events right now — create one first.</div>
    {:else}
      <table class="data-table ann-table-structured">
        <thead>
          <tr>
            <th class="col-name">Event Name</th>
            <th class="col-kind">Kind</th>
            <th class="col-status">Status</th>
            <th class="col-starts">Starts</th>
            <th class="col-actions">Actions</th>
          </tr>
        </thead>
        <tbody>
          {#each pagedEvents as c (c.id)}
            <tr>
              <td class="col-name">
                <span class="event-name-text" title={c.name}>{c.name}</span>
              </td>
              <td class="col-kind">
                <span class="tag" style={kindTag(c.kind)}>{kindMeta(c.kind).label}</span>
              </td>
              <td class="col-status">
                <span class="tag" style={statusTag(c.status)}>{STATUS_LABELS[c.status] || c.status}</span>
              </td>
              <td class="col-starts">
                <span class="starts-text">{c.status === 'SCHEDULED' && c.scheduledAt ? formatScheduled(c.scheduledAt) : '—'}</span>
              </td>
              <td class="col-actions">
                <button class="btn btn-primary btn-announce-compact" on:click={() => openAnnounceModal(c)}>
                  <Icon name="megaphone" size={11} /><span>Announce</span>
                </button>
              </td>
            </tr>
          {:else}
            <tr><td colspan="5" class="ann-empty">No events match the current filters.</td></tr>
          {/each}
        </tbody>
      </table>
    {/if}
    {:else if sub === 'custom'}
    <div class="cs-head">
      <div class="section-title">Custom Server Announcement</div>
      <p class="field-hint">Create and preview a server-wide announcement.</p>
    </div>

    <!-- MESSAGE -->
    <div class="cs-label">Message</div>
    <div class="cs-card cs-message">
      <div class="field">
        <label for="cs-title">Title</label>
        <input id="cs-title" type="text" maxlength="100" placeholder="e.g. Server Restart in 10 Minutes" bind:value={customTitle} />
      </div>
      <div class="field">
        <label for="cs-body">Body <span class="optional">optional</span></label>
        <textarea id="cs-body" maxlength="500" placeholder="Extra detail shown under the title" bind:value={customBody}></textarea>
      </div>
    </div>

    <!-- APPEARANCE -->
    <div class="cs-label">Appearance</div>
    <div class="cs-grid">
      <div class="cs-card">
        <div class="cs-card-title"><Icon name="edit" size={13} /> Banner Color</div>
        <div class="color-layout">
          <div
            class="color-box-preview"
            style="background-color: {bannerColor}; box-shadow: inset 0 0 0 4px rgba(255, 255, 255, 0.08), 0 4px 16px {bannerColor}33;"
          ></div>
          <div class="color-controls-right">
            <div class="hue-wrapper">
              <input type="range" min="0" max="360" value={hueValue} on:input={onHueInput} class="hue-slider" title="Adjust Hue" />
              <div class="hue-labels">
                <span>Red</span><span>Yellow</span><span>Green</span><span>Cyan</span><span>Blue</span><span>Pink</span><span>Red</span>
              </div>
            </div>
            <div class="hex-presets-row">
              <div class="hex-input-wrap">
                <span class="hex-lbl">Hex</span>
                <input type="text" maxlength="7" value={hexInput} on:input={onHexInput} class="hex-field" placeholder="#368FE9" />
              </div>
              <div class="presets-container">
                {#each COLOR_PRESETS as p}
                  <button
                    type="button"
                    class="swatch-btn"
                    class:active={bannerColor.toUpperCase() === p.color.toUpperCase()}
                    style="background-color: {p.color};"
                    title={p.label}
                    on:click={() => selectPreset(p.color)}
                  ></button>
                {/each}
              </div>
            </div>
          </div>
        </div>
      </div>

      <div class="cs-card">
        <div class="cs-card-title"><Icon name="image" size={13} /> Banner Image <span class="cs-opt">optional</span></div>
        <div class="cs-url-row">
          <input
            type="text"
            class="cs-url"
            placeholder="Paste image URL (PNG, JPG, WebP)…"
            bind:value={imageUrlInput}
            on:keydown={(e) => { if (e.key === 'Enter') loadImage(); }}
          />
          <button type="button" class="btn btn-primary cs-load" on:click={loadImage} disabled={imageLoading}>
            {imageLoading ? 'Loading…' : 'Load'}
          </button>
          {#if activeImageUrl || imageUrlInput}
            <button type="button" class="btn cs-clear" on:click={clearImage} title="Clear image" aria-label="Clear image"><Icon name="close" size={14} /></button>
          {/if}
        </div>
        {#if imageError}
          <div class="image-err-alert"><Icon name="alertCircle" size={13} /><span>{imageError}</span></div>
        {/if}
        <button type="button" class="btn btn-edit cs-edit-btn" on:click={openCustomBannerEditor} disabled={!activeImageUrl} title={activeImageUrl ? '' : 'Load an image first'}>
          <Icon name="edit" size={14} /> Edit Image / Framing
        </button>
      </div>
    </div>

    <!-- LIVE PREVIEW: the actual in-game banner at its real size -->
    <div class="cs-label">Live Preview</div>
    <div class="banner-stage">
      <AnnouncementCard
        preview
        eventKey={cuKey}
        subtitle={announcementSubtitle(cuKey, 'info', cuTitle, customBody)}
        title={cuTitle}
        message={customBody}
        status={announcementStatus(cuKey, 'info', cuTitle, null)}
        bannerImg={cuImage.img}
        bannerPos={cuImage.pos}
        bannerFit={cuImage.fit}
        bannerZoom={cuImage.zoom}
        bannerColor={bannerColor}
      />
    </div>

    <!-- ACTIONS -->
    <div class="cs-actions">
      {#if previewMyselfActive}
        <span class="saved-flash"><Icon name="eye" size={13} /> Showing in HUD</span>
      {/if}
      {#if customSentFlash}
        <span class="saved-flash"><Icon name="check" size={13} /> Sent to Everyone</span>
      {/if}
      <button type="button" class="btn btn-secondary btn-preview-myself" on:click={previewMyself}>
        <Icon name="eye" size={14} /> Preview Myself
      </button>
      <button type="button" class="btn btn-primary" on:click={sendCustom} disabled={sendingCustom}>
        <Icon name="megaphone" size={14} /> {sendingCustom ? 'Sending...' : 'Send to Everyone'}
      </button>
    </div>
    {:else if sub === 'banners'}
    <!-- 3. EVENT BANNER IMAGES SUB-TAB -->
    <div class="banner-tab-head">
      <div>
        <div class="banner-main-title"><Icon name="image" size={15} /> Event Banner Images</div>
        <p class="banner-sub-desc">
          Configure official artwork, camera framing, and zoom for each server event announcement.
          Click <strong>Edit Banner</strong> on any event to customize and preview live changes below.
        </p>
      </div>
      {#if bannerSavedFlash}
        <div class="saved-flash banner-saved-badge">
          <Icon name="check" size={14} />
          <span>{bannerSavedFlash}</span>
        </div>
      {/if}
    </div>

    <div class="event-banners-grid">
      {#each EVENT_BANNER_TYPES as ev (ev.key)}
        {@const cfg = $eventBanners[ev.key] || DEFAULT_EVENT_BANNERS[ev.key] || {}}
        {@const isEditing = activeEditKey === ev.key}
        {@const currentImg = isEditing && editDraft ? editDraft.imageUrl : (cfg.imageUrl || ev.defaultImage)}
        {@const posX = isEditing && editDraft ? editDraft.posX : (cfg.posX != null ? cfg.posX : 50)}
        {@const posY = isEditing && editDraft ? editDraft.posY : (cfg.posY != null ? cfg.posY : 50)}
        {@const zoom = isEditing && editDraft ? editDraft.zoom : (cfg.zoom != null ? cfg.zoom : 1.0)}
        {@const fit = isEditing && editDraft ? editDraft.fit : (cfg.fit || 'cover')}
        
        <div
          class="event-banner-card"
          class:is-editing={isEditing}
          style="--card-accent: {ev.accent}; --card-accent-rgb: {ev.accentRgb};"
        >
          <div class="eb-card-header">
            <div class="eb-title-block">
              <span class="eb-icon-badge" style="background: {ev.accent}1a; border-color: {ev.accent}55; color: {ev.accent};">
                <Icon name={ev.icon} size={16} />
              </span>
              <div class="eb-title-meta">
                <div class="eb-name-row">
                  <h4 class="eb-name">{ev.name}</h4>
                  <span class="eb-badge {ev.badgeClass}">{ev.badgeText}</span>
                </div>
                <span class="eb-desc-kicker">{ev.kicker}</span>
              </div>
            </div>

            <div class="eb-header-right">
              {#if cfg.imageUrl && stripBannerVersion(cfg.imageUrl) !== ev.defaultImage}
                <span class="status-pill status-custom"><Icon name="edit" size={11} /> Custom Artwork</span>
              {:else}
                <span class="status-pill status-bundled"><Icon name="check" size={11} /> Default Artwork</span>
              {/if}
            </div>
          </div>

          <!-- Banner Preview inside the card -->
          <div
            class="eb-preview-container"
            class:is-interactive={isEditing}
            class:is-dragging={isEditing && isBannerDragging}
            style="border-color: {ev.accent}{isEditing ? 'aa' : '3b'}; box-shadow: 0 8px 24px rgba(0, 0, 0, 0.55), 0 0 {isEditing ? '24px' : '12px'} {ev.accent}{isEditing ? '33' : '14'};"
            on:mousedown={(e) => onBannerMouseDown(e, ev.key)}
            on:wheel={(e) => onBannerWheel(e, ev.key)}
          >
            <div class="eb-preview-rail-top" style="background: {ev.accent};"></div>

            {#if isEditing}
              <div class="eb-viewport-hint" style="background: {ev.accent}25; border-color: {ev.accent}66; color: {ev.accent};">
                <span class="pulse-dot" style="background: {ev.accent}; box-shadow: 0 0 8px {ev.accent};"></span>
                <span>Interactive Viewport • Drag to Pan • Wheel to Zoom</span>
              </div>
            {/if}

            {#if currentImg}
              <div
                class="eb-preview-photo"
                style="background-image: url('{currentImg}'); background-position: {posX}% {posY}%; background-size: {fit}; transform: scale({zoom}); transform-origin: {posX}% {posY}%;"
              ></div>
              <div class="eb-preview-overlay"></div>
            {:else}
              <div class="eb-preview-empty">No banner image assigned</div>
            {/if}

            <div class="eb-preview-content">
              <div class="eb-preview-kicker" style="color: {ev.accent};">
                <span class="eb-live-pulse" style="background: {ev.accent}; box-shadow: 0 0 8px {ev.accent};"></span>
                {ev.kicker}
              </div>
              <div class="eb-preview-title">{ev.sampleTitle}</div>
              <div class="eb-preview-desc">{ev.sampleDesc}</div>
            </div>

            <div class="eb-preview-status-tag" style="border-color: {ev.accent}88; color: {ev.accent}; background: {ev.accent}18;">
              <span>UPCOMING</span>
            </div>

            <div class="eb-preview-rail-bottom" style="background: {ev.accent};"></div>
          </div>

          <!-- IF NOT EDITING: Compact Clean Action Bar -->
          {#if !isEditing}
            <div class="eb-card-footer">
              <div class="eb-framing-tags">
                <span class="framing-tag">Pos: <strong>{posX}% X, {posY}% Y</strong></span>
                <span class="framing-tag">Zoom: <strong>{zoom}x</strong></span>
                <span class="framing-tag">Fit: <strong>{fit.toUpperCase()}</strong></span>
              </div>

              <div class="eb-actions-row">
                <button
                  type="button"
                  class="btn btn-secondary btn-test-hud"
                  on:click={() => testEventBanner(ev)}
                  title="Preview this event banner live on your HUD right now"
                >
                  <Icon name="eye" size={13} />
                  <span>Test HUD</span>
                </button>

                <button
                  type="button"
                  class="btn btn-primary btn-edit-banner"
                  on:click={() => startEditEvent(ev)}
                  title="Open inline image positioning, pan, zoom and crop editor"
                >
                  <Icon name="edit" size={13} />
                  <span>Edit Banner</span>
                </button>
              </div>
            </div>
          {:else}
            <!-- IF EDITING: Expanded Framing & Size Controls Directly Below It! -->
            <div class="eb-inline-editor">
              <!-- 1. IMAGE SOURCE -->
              <div class="ie-block ie-source-block">
                <div class="ie-block-header">
                  <span class="ie-block-title"><Icon name="image" size={13} /> Image Source</span>
                  <div class="ie-header-actions">
                    {#if editDraft.defaultImageUrl}
                      <button
                        type="button"
                        class="ie-mini-action"
                        on:click={() => { editDraft.inputUrl = editDraft.defaultImageUrl; editDraft.imageUrl = editDraft.defaultImageUrl; editDraft.imageError = ''; }}
                      >
                        <Icon name="refresh" size={12} /> Use Default Artwork
                      </button>
                    {/if}
                    {#if editDraft.imageUrl}
                      <button
                        type="button"
                        class="ie-mini-action ie-action-danger"
                        on:click={() => { editDraft.inputUrl = ''; editDraft.imageUrl = ''; editDraft.imageError = ''; }}
                      >
                        <Icon name="close" size={12} /> Remove Image
                      </button>
                    {/if}
                  </div>
                </div>

                <div class="ie-input-row">
                  <input
                    type="text"
                    placeholder="Enter image URL or local path (e.g. ../images/event_announcement_banner_images/convoy.jpg)..."
                    bind:value={editDraft.inputUrl}
                    on:keydown={(e) => { if (e.key === 'Enter') loadDraftImage(); }}
                  />
                  <button type="button" class="btn btn-secondary btn-load-img" on:click={loadDraftImage} disabled={editDraft.imageLoading}>
                    {editDraft.imageLoading ? 'Loading...' : 'Load'}
                  </button>
                </div>

                {#if editDraft.imageError}
                  <div class="ie-error-banner">
                    <Icon name="alertCircle" size={13} />
                    <span>{editDraft.imageError}</span>
                  </div>
                {/if}
              </div>

              <!-- 2. FRAMING & COMPOSITION (SIZE + POS X + POS Y) -->
              <div class="ie-block ie-framing-block">
                <div class="ie-block-header">
                  <span class="ie-block-title"><Icon name="edit" size={13} /> Framing &amp; Composition</span>
                  <div class="ie-fit-toggle">
                    <button
                      type="button"
                      class="ie-fit-pill"
                      class:active={editDraft.fit === 'cover'}
                      on:click={() => (editDraft.fit = 'cover')}
                    >Cover</button>
                    <button
                      type="button"
                      class="ie-fit-pill"
                      class:active={editDraft.fit === 'contain'}
                      on:click={() => (editDraft.fit = 'contain')}
                    >Contain</button>
                  </div>
                </div>

                <div class="ie-sliders-grid">
                  <!-- ZOOM / SCALE -->
                  <div class="ie-slider-card">
                    <div class="ie-slider-head">
                      <span class="ie-slider-label">Zoom / Scale</span>
                      <span class="ie-slider-val" style="color: {ev.accent};">{editDraft.zoom.toFixed(2)}x</span>
                    </div>
                    <div class="ie-range-wrap">
                      <input
                        type="range"
                        min="0.5"
                        max="3.0"
                        step="0.05"
                        bind:value={editDraft.zoom}
                        class="ie-slider"
                      />
                    </div>
                    <div class="ie-preset-chips">
                      <button type="button" class="ie-chip" class:active={editDraft.zoom === 1.0} on:click={() => (editDraft.zoom = 1.0)}>1.0x</button>
                      <button type="button" class="ie-chip" class:active={editDraft.zoom === 1.25} on:click={() => (editDraft.zoom = 1.25)}>1.25x</button>
                      <button type="button" class="ie-chip" class:active={editDraft.zoom === 1.5} on:click={() => (editDraft.zoom = 1.5)}>1.5x</button>
                      <button type="button" class="ie-chip" class:active={editDraft.zoom === 2.0} on:click={() => (editDraft.zoom = 2.0)}>2.0x</button>
                    </div>
                  </div>

                  <!-- POSITION X -->
                  <div class="ie-slider-card">
                    <div class="ie-slider-head">
                      <span class="ie-slider-label">Position X (Horizontal)</span>
                      <span class="ie-slider-val" style="color: {ev.accent};">{Math.round(editDraft.posX)}%</span>
                    </div>
                    <div class="ie-range-wrap">
                      <input
                        type="range"
                        min="0"
                        max="100"
                        step="1"
                        bind:value={editDraft.posX}
                        class="ie-slider"
                      />
                    </div>
                    <div class="ie-preset-chips">
                      <button type="button" class="ie-chip" class:active={Math.round(editDraft.posX) === 0} on:click={() => (editDraft.posX = 0)}>Left</button>
                      <button type="button" class="ie-chip" class:active={Math.round(editDraft.posX) === 50} on:click={() => (editDraft.posX = 50)}>Center</button>
                      <button type="button" class="ie-chip" class:active={Math.round(editDraft.posX) === 100} on:click={() => (editDraft.posX = 100)}>Right</button>
                    </div>
                  </div>

                  <!-- POSITION Y -->
                  <div class="ie-slider-card">
                    <div class="ie-slider-head">
                      <span class="ie-slider-label">Position Y (Vertical)</span>
                      <span class="ie-slider-val" style="color: {ev.accent};">{Math.round(editDraft.posY)}%</span>
                    </div>
                    <div class="ie-range-wrap">
                      <input
                        type="range"
                        min="0"
                        max="100"
                        step="1"
                        bind:value={editDraft.posY}
                        class="ie-slider"
                      />
                    </div>
                    <div class="ie-preset-chips">
                      <button type="button" class="ie-chip" class:active={Math.round(editDraft.posY) === 0} on:click={() => (editDraft.posY = 0)}>Top</button>
                      <button type="button" class="ie-chip" class:active={Math.round(editDraft.posY) === 50} on:click={() => (editDraft.posY = 50)}>Center</button>
                      <button type="button" class="ie-chip" class:active={Math.round(editDraft.posY) === 100} on:click={() => (editDraft.posY = 100)}>Bottom</button>
                    </div>
                  </div>
                </div>
              </div>

              <!-- 3. ACTIONS FOOTER -->
              <div class="ie-footer-actions">
                <button
                  type="button"
                  class="btn btn-secondary btn-reset-draft"
                  on:click={resetDraftComposition}
                >
                  <Icon name="refresh" size={13} />
                  <span>Reset Composition</span>
                </button>

                <div class="ie-save-group">
                  <button
                    type="button"
                    class="btn btn-secondary btn-cancel-draft"
                    on:click={cancelEditEvent}
                    disabled={savingBanner}
                  >
                    Cancel
                  </button>

                  <button
                    type="button"
                    class="btn btn-primary btn-save-draft"
                    on:click={saveEditEvent}
                    disabled={savingBanner}
                  >
                    <Icon name="check" size={14} />
                    <span>{savingBanner ? 'Saving...' : 'Save Changes'}</span>
                  </button>
                </div>
              </div>
            </div>
          {/if}
        </div>
      {/each}
    </div>
    {/if}
  </div>
</div>

<!-- Event Announcement Customization Modal -->
{#if selectedEvent}
  <div class="overlay" on:click|self={closeAnnounceModal}>
    <div class="announce-modal">
      <div class="modal-header">
        <div class="modal-header-title">
          <Icon name="megaphone" size={16} /> Broadcast Event Announcement
        </div>
        <button class="icon-btn-close" on:click={closeAnnounceModal}><Icon name="close" size={14} /></button>
      </div>

      <div class="modal-body">
        <div class="event-target-banner">
          <span class="target-name">{selectedEvent.name}</span>
          <span class="kind-badge {kindMeta(selectedEvent.kind).badgeClass}">{kindMeta(selectedEvent.kind).label}</span>
          <span class="badge {selectedEvent.status === 'SCHEDULED' ? 'badge-scheduled' : 'badge-draft'}">{selectedEvent.status}</span>
        </div>

        {#if modalError}<div class="error" style="margin-bottom:12px">{modalError}</div>{/if}

        <div class="field">
          <div class="field-label-row">
            <label for="ann-title">Announcement Title</label>
            <span class="char-count">{modalTitle.length}/100</span>
          </div>
          <input id="ann-title" type="text" maxlength="100" bind:value={modalTitle} placeholder="Title displayed at top of banner" />
        </div>

        <div class="field">
          <div class="field-label-row">
            <label for="ann-body">Custom Message / Details <span class="optional">shown under title</span></label>
            <span class="char-count">{modalBody.length}/500</span>
          </div>
          <textarea id="ann-body" rows="4" maxlength="500" bind:value={modalBody} placeholder="Extra detail or schedule shown under the title"></textarea>
        </div>

        <div class="field">
          <label>Target Audience</label>
          <div class="audience-toggle-group">
            <button
              type="button"
              class="audience-btn"
              class:active={modalAudience === 'EVERYONE'}
              on:click={() => (modalAudience = 'EVERYONE')}
            >
              <Icon name="users" size={13} />
              <span>Everyone (Gangs &amp; Civilians)</span>
            </button>
            <button
              type="button"
              class="audience-btn"
              class:active={modalAudience === 'GANG_ONLY'}
              on:click={() => (modalAudience = 'GANG_ONLY')}
            >
              <Icon name="shield" size={13} />
              <span>Gang Members Only</span>
            </button>
          </div>
        </div>

        <!-- Live In-Game Banner Preview: the real HUD banner card, at its real size -->
        <div class="preview-heading">In-Game Banner Preview</div>
        <div class="banner-stage">
          <AnnouncementCard
            preview
            eventKey={pvKey}
            subtitle={announcementSubtitle(pvKey, pvType, pvTitle, modalBody)}
            title={pvTitle}
            message={modalBody}
            status={announcementStatus(pvKey, pvType, pvTitle, null)}
            bannerImg={pvImage.img}
            bannerPos={pvImage.pos}
            bannerFit={pvImage.fit}
            bannerZoom={pvImage.zoom}
          />
        </div>
      </div>
      <div class="modal-actions">
        <button class="btn" on:click={closeAnnounceModal} disabled={broadcasting}>Cancel</button>
        <button class="btn btn-primary" on:click={submitEventAnnouncement} disabled={broadcasting}>
          <Icon name="megaphone" size={13} /> {broadcasting ? 'Broadcasting...' : (modalAudience === 'EVERYONE' ? 'Broadcast to Everyone' : 'Broadcast to Gangs')}
        </button>
      </div>
    </div>
  </div>
{/if}

<!-- Reusable Banner Framing Editor Modal for Event Banners & Custom Announcements -->
{#if editingBanner}
  <BannerImageEditor
    title={editingBanner.title}
    eventKey={editingBanner.eventKey}
    eventName={editingBanner.name}
    bannerColor={editingBanner.bannerColor}
    initialImageUrl={editingBanner.imageUrl}
    defaultImageUrl={editingBanner.defaultImageUrl}
    initialPosX={editingBanner.posX}
    initialPosY={editingBanner.posY}
    initialZoom={editingBanner.zoom}
    initialFit={editingBanner.fit}
    saving={savingBanner}
    on:save={handleBannerSave}
    on:cancel={() => (editingBanner = null)}
  />
{/if}

<style>
  /* ── Event Banner Images Sub-Tab ── */
  .banner-tab-head {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    margin-bottom: 24px;
    gap: 20px;
    padding-bottom: 4px;
  }
  .banner-main-title {
    margin: 0 0 6px;
    font-size: var(--fs-emph);
    font-weight: 700;
    letter-spacing: 0.02em;
    color: var(--lt-ffffff, #ffffff);
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .banner-sub-desc {
    margin: 0;
    font-size: var(--fs-small);
    color: var(--lt-959ca5, #959ca5);
    line-height: 1.55;
    max-width: 820px;
  }
  .banner-sub-desc strong {
    color: var(--lt-e3e6e9, #e3e6e9);
    font-weight: 600;
  }
  .banner-saved-badge {
    margin: 0;
    padding: 8px 16px;
    font-size: var(--fs-meta);
    display: inline-flex;
    align-items: center;
    gap: 8px;
    white-space: nowrap;
    border-radius: var(--r-tag);
  }

  /* Spacious, balanced grid to avoid congestion */
  .event-banners-grid {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 24px;
    margin-bottom: 36px;
  }
  @media (max-width: 1120px) {
    .event-banners-grid {
      grid-template-columns: 1fr;
    }
  }

  /* Event Banner Tile / Card */
  .event-banner-card {
    background: var(--lt-111316, #111316);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.08);
    border-radius: var(--r-panel);
    padding: 22px;
    display: flex;
    flex-direction: column;
    gap: 16px;
    transition: all 0.22s cubic-bezier(0.16, 1, 0.3, 1);
    box-shadow: none;
    position: relative;
  }
  .event-banner-card:hover {
    border-color: rgba(var(--ink-rgb, 255, 255, 255), 0.16);
    background: var(--bg-surface, #15171b);
  }
  .event-banner-card.is-editing {
    grid-column: 1 / -1;
    border-color: var(--card-accent, #4f94e6);
    box-shadow: none;
    background: var(--c-base, #131518);
  }

  /* Card Header */
  .eb-card-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 14px;
  }
  .eb-title-block {
    display: flex;
    align-items: center;
    gap: 12px;
  }
  .eb-icon-badge {
    width: 38px;
    height: 38px;
    border-radius: var(--r-tag);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.12);
    display: inline-flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
  }
  .eb-title-meta {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }
  .eb-name-row {
    display: flex;
    align-items: center;
    gap: 9px;
  }
  .eb-name {
    margin: 0;
    font-size: var(--fs-emph);
    font-weight: 700;
    color: var(--lt-eceef0, #eceef0);
    letter-spacing: 0.02em;
  }
  .eb-badge {
    display: inline-block;
    padding: 2px 8px;
    border-radius: 999px;
    font-size: var(--fs-meta);
    font-weight: 600;
    letter-spacing: 0.01em;
  }
  .eb-desc-kicker {
    font-size: var(--fs-meta);
    font-weight: 600;
    letter-spacing: 0.01em;
    color: #7c848d;
  }
  .eb-header-right {
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .status-pill {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-size: var(--fs-meta);
    font-weight: 600;
    padding: 4px 10px;
    border-radius: var(--r-tag);
    letter-spacing: 0.02em;
  }
  .status-bundled {
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.04);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.08);
    color: var(--lt-aeb5bd, #aeb5bd);
  }
  .status-custom {
    background: var(--c-hover);
    border: 1px solid var(--accent-primary);
    color: var(--lt-7ab7f5, #7ab7f5);
  }

  /* High-Fidelity Banner Preview inside Card */
  .eb-preview-container {
    position: relative;
    height: 140px;
    border-radius: var(--r-panel);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.1);
    background: var(--lt-0f1113, #0f1113);
    overflow: hidden;
    display: flex;
    flex-direction: column;
    justify-content: center;
    padding: 0 22px;
    transition: height 0.2s ease, border-color 0.2s ease;
    user-select: none;
  }
  .event-banner-card.is-editing .eb-preview-container {
    height: 154px;
  }
  .eb-preview-container.is-interactive {
    cursor: grab;
  }
  .eb-preview-container.is-interactive:active,
  .eb-preview-container.is-dragging {
    cursor: grabbing !important;
  }
  .eb-viewport-hint {
    position: absolute;
    top: 10px;
    left: 14px;
    z-index: 5;
    display: inline-flex;
    align-items: center;
    gap: 7px;
    font-size: var(--fs-meta);
    font-weight: 700;
    letter-spacing: 0.01em;
    padding: 3px 9px;
    border-radius: var(--r-ctl);
    border: 1px solid;
    pointer-events: none;
  }
  .pulse-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
  }
  .eb-preview-rail-top {
    position: absolute;
    top: 0;
    left: 0;
    right: 0;
    height: 2px;
    z-index: 4;
  }
  .eb-preview-rail-bottom {
    position: absolute;
    bottom: 0;
    left: 0;
    right: 0;
    height: 2px;
    z-index: 4;
  }
  .eb-preview-photo {
    position: absolute;
    inset: 0;
    background-repeat: no-repeat;
    z-index: 1;
    pointer-events: none;
  }
  .eb-preview-overlay {
    position: absolute;
    inset: 0;
    background: linear-gradient(90deg, rgba(var(--ltc-8-9-15, 8, 9, 15), 0.94) 0%, rgba(var(--ltc-8-9-15, 8, 9, 15), 0.78) 55%, rgba(var(--ltc-8-9-15, 8, 9, 15), 0.35) 100%);
    z-index: 2;
    pointer-events: none;
  }
  .eb-preview-empty {
    position: absolute;
    inset: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: var(--fs-small);
    color: #7c848d;
    z-index: 1;
  }
  .eb-preview-content {
    position: relative;
    z-index: 3;
    max-width: calc(100% - 130px);
    pointer-events: none;
  }
  .eb-preview-kicker {
    display: flex;
    align-items: center;
    gap: 7px;
    font-size: var(--fs-meta);
    font-weight: 700;
    letter-spacing: 0.01em;
    margin-bottom: 3px;
  }
  .eb-live-pulse {
    width: 6px;
    height: 6px;
    border-radius: 50%;
  }
  .eb-preview-title {
    font-size: var(--fs-body);
    font-weight: 700;
    color: var(--lt-ffffff, #ffffff);
    line-height: 1.25;
    margin-bottom: 3px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .eb-preview-desc {
    font-size: var(--fs-meta);
    color: var(--lt-c4ca9d, #c4ca9d);
    line-height: 1.35;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .eb-preview-status-tag {
    position: absolute;
    right: 18px;
    top: 50%;
    transform: translateY(-50%);
    z-index: 3;
    padding: 5px 12px;
    border-radius: var(--r-tag);
    border: 1px solid;
    font-size: var(--fs-meta);
    font-weight: 600;
    letter-spacing: 0.01em;
    pointer-events: none;
  }

  /* Normal Footer (when not editing) */
  .eb-card-footer {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 12px;
    padding-top: 4px;
  }
  .eb-framing-tags {
    display: flex;
    gap: 8px;
    flex-wrap: wrap;
  }
  .framing-tag {
    font-size: var(--fs-meta);
    color: var(--lt-959ca5, #959ca5);
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.035);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.07);
    border-radius: var(--r-tag);
    padding: 3px 8px;
  }
  .framing-tag strong {
    color: var(--lt-e3e6e9, #e3e6e9);
    font-weight: 600;
  }
  .eb-actions-row {
    display: flex;
    gap: 10px;
    align-items: center;
  }
  .btn-test-hud {
    padding: 7px 14px;
    font-size: var(--fs-meta);
    font-weight: 600;
    display: inline-flex;
    align-items: center;
    gap: 7px;
  }
  .btn-edit-banner {
    padding: 7px 16px;
    font-size: var(--fs-meta);
    font-weight: 600;
    display: inline-flex;
    align-items: center;
    gap: 7px;
  }

  /* ── Inline Framing & Size Editor Drawer (Below the Banner) ── */
  .eb-inline-editor {
    display: flex;
    flex-direction: column;
    gap: 18px;
    padding-top: 8px;
    border-top: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.07);
    animation: fadeInDrawer 0.22s ease-out;
  }
  @keyframes fadeInDrawer {
    from { opacity: 0; transform: translateY(-6px); }
    to { opacity: 1; transform: translateY(0); }
  }
  .ie-block {
    background: var(--lt-0f1113, #0f1113);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.06);
    border-radius: var(--r-panel);
    padding: 16px;
  }
  .ie-block-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 12px;
  }
  .ie-block-title {
    font-size: var(--fs-meta);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--lt-e3e6e9, #e3e6e9);
    display: flex;
    align-items: center;
    gap: 7px;
  }
  .ie-header-actions {
    display: flex;
    gap: 10px;
    align-items: center;
  }
  .ie-mini-action {
    background: transparent;
    border: none;
    color: #8d949c;
    font-size: var(--fs-meta);
    font-weight: 600;
    cursor: pointer;
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 2px 6px;
    border-radius: var(--r-panel);
    transition: all 0.15s ease;
  }
  .ie-mini-action:hover {
    color: var(--lt-ffffff, #ffffff);
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.06);
  }
  .ie-mini-action.ie-action-danger:hover {
    color: #ff6b72;
    background: rgba(255, 75, 85, 0.1);
  }
  .ie-input-row {
    display: flex;
    gap: 10px;
    align-items: center;
  }
  .ie-input-row input {
    flex: 1;
    height: 38px;
    background: var(--bg-surface, #15171b);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.1);
    border-radius: var(--r-ctl);
    padding: 0 12px;
    color: var(--lt-ffffff, #ffffff);
    font-size: var(--fs-small);
    transition: border-color 0.15s ease;
  }
  .ie-input-row input:focus {
    border-color: var(--accent-primary);
    outline: none;
  }
  .btn-load-img {
    height: 38px;
    padding: 0 16px;
    font-size: var(--fs-meta);
    font-weight: 600;
  }
  .ie-error-banner {
    margin-top: 10px;
    padding: 8px 12px;
    background: var(--c-raised);
    border: 1px solid var(--c-line);
    border-radius: var(--r-ctl);
    color: var(--lt-ff858a, #ff858a);
    font-size: var(--fs-meta);
    display: flex;
    align-items: center;
    gap: 8px;
    border-left: 3px solid rgb(240, 68, 82);}

  /* Fit Mode Toggle */
  .ie-fit-toggle {
    display: flex;
    gap: 4px;
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.04);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.08);
    border-radius: var(--r-ctl);
    padding: 2px;
  }
  .ie-fit-pill {
    padding: 4px 12px;
    font-size: var(--fs-meta);
    font-weight: 600;
    color: #8d949c;
    background: transparent;
    border: none;
    border-radius: var(--r-tag);
    cursor: pointer;
    transition: all 0.16s ease;
  }
  .ie-fit-pill.active {
    background: var(--accent-primary);
    color: var(--on-accent, #ffffff);
    text-shadow: none;
    box-shadow: none;
  }

  /* 3-Column Sliders Grid */
  .ie-sliders-grid {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 16px;
  }
  @media (max-width: 900px) {
    .ie-sliders-grid {
      grid-template-columns: 1fr;
    }
  }
  .ie-slider-card {
    background: var(--bg-surface, #15171b);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.06);
    border-radius: var(--r-ctl);
    padding: 14px;
    display: flex;
    flex-direction: column;
    gap: 10px;
  }
  .ie-slider-head {
    display: flex;
    justify-content: space-between;
    align-items: center;
  }
  .ie-slider-label {
    font-size: var(--fs-meta);
    font-weight: 600;
    color: var(--lt-aeb5bd, #aeb5bd);
    letter-spacing: 0.02em;
  }
  .ie-slider-val {
    font-size: var(--fs-small);
    font-weight: 700;
    font-family: var(--font-mono);
  }
  .ie-range-wrap {
    display: flex;
    align-items: center;
  }
  .ie-slider {
    width: 100%;
    accent-color: var(--accent-primary);
    cursor: pointer;
    height: 5px;
  }
  .ie-preset-chips {
    display: flex;
    gap: 6px;
    flex-wrap: wrap;
  }
  .ie-chip {
    flex: 1;
    min-width: 36px;
    padding: 4px 6px;
    font-size: var(--fs-meta);
    font-weight: 600;
    color: var(--lt-959ca5, #959ca5);
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.035);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.07);
    border-radius: var(--r-tag);
    cursor: pointer;
    text-align: center;
    transition: all 0.15s ease;
  }
  .ie-chip:hover {
    color: var(--lt-ffffff, #ffffff);
    border-color: rgba(var(--ink-rgb, 255, 255, 255), 0.15);
  }
  .ie-chip.active {
    background: var(--c-action);
    border-color: var(--accent-primary);
    color: var(--on-accent);
  }

  /* Inline Drawer Footer Actions */
  .ie-footer-actions {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 14px;
    padding-top: 4px;
  }
  .btn-reset-draft {
    padding: 8px 16px;
    font-size: var(--fs-meta);
    font-weight: 600;
    display: inline-flex;
    align-items: center;
    gap: 7px;
  }
  .ie-save-group {
    display: flex;
    gap: 10px;
    align-items: center;
  }
  .btn-cancel-draft {
    padding: 8px 18px;
    font-size: var(--fs-meta);
    font-weight: 600;
  }
  .btn-save-draft {
    padding: 8px 22px;
    font-size: var(--fs-meta);
    font-weight: 700;
    display: inline-flex;
    align-items: center;
    gap: 8px;
    background: var(--accent-primary);
    box-shadow: none;
    color: var(--on-accent, inherit);
}

  /* Custom Announcement Framing Bar */
  .image-framing-bar {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 10px;
    padding: 6px 10px;
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.025);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.06);
    border-radius: var(--r-ctl);
  }
  .btn-framing-tool {
    padding: 5px 11px;
    font-size: var(--fs-meta);
    display: inline-flex;
    align-items: center;
    gap: 6px;
  }
  .framing-quick-info {
    display: flex;
    gap: 8px;
    font-size: var(--fs-meta);
    color: var(--lt-959ca5, #959ca5);
  }
  .img-editor-overlay-hint {
    position: absolute;
    inset: 0;
    background: rgba(var(--ltc-10-12-18, 10, 12, 18), 0.72);
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 7px;
    font-size: var(--fs-meta);
    font-weight: 600;
    color: var(--lt-ffffff, #ffffff);
    opacity: 0;
    cursor: pointer;
    transition: opacity 0.16s ease;
  }
  .image-preview-panel.has-photo:hover .img-editor-overlay-hint {
    opacity: 1;
  }
  .note {
    font-size: var(--fs-body);
    color: var(--text-dim);
    line-height: 1.6;
    margin-bottom: 16px;
  }
  .section-title {
    margin: 0 0 10px;
    font-size: var(--fs-small);
    font-weight: var(--fw-nav);
    letter-spacing: 0.01em;
    color: var(--text-main);
  }
  .event-name-text {
    font-weight: 600;
    color: var(--text-main);
  }
  .row-actions {
    display: flex;
    justify-content: flex-end;
  }
  .kind-badge {
    display: inline-block;
    padding: 2px 8px;
    border-radius: 999px;
    font-size: var(--fs-meta);
    font-weight: 600;
    letter-spacing: 0.01em;
  }
  .kind-badge-airdrop {
    background: rgb(155, 123, 255);
    border: 1px solid rgb(155, 123, 255);
    color: #111111;
  }
  .kind-badge-hot {
    background: rgb(224, 72, 159);
    border: 1px solid rgb(224, 72, 159);
    color: #111111;
  }
  .kind-badge-tdm {
    background: rgb(229, 72, 77);
    border-color: rgb(229, 72, 77);
    color: #111111;
  }
  .kind-badge-convoy {
    background: rgb(238, 138, 43);
    border: 1px solid rgb(238, 138, 43);
    color: #111111;
  }
  .kind-badge-race {
    background: rgb(34, 199, 214);
    border: 1px solid rgb(34, 199, 214);
    color: #111111;
  }
  .kind-badge-cw {
    background: rgb(82, 210, 74);
    border: 1px solid rgb(82, 210, 74);
    color: #111111;
  }
  .kind-badge-territory {
    background: rgb(196, 94, 224);
    border: 1px solid rgb(196, 94, 224);
    color: #111111;
  }
  .kind-badge-rivals {
    background: rgb(91, 123, 255);
    border: 1px solid rgb(91, 123, 255);
    color: #111111;
  }
  .field-hint {
    font-size: var(--fs-small);
    color: var(--text-dim);
    line-height: 1.5;
    margin: -3px 0 10px;
  }
  .field label .optional {
    text-transform: none;
    font-weight: 400;
    font-size: var(--fs-small);
    color: var(--text-dim);
    margin-left: 4px;
  }
  .field-label-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 5px;
  }
  .char-count {
    font-size: var(--fs-small);
    color: var(--tablet-text-faint);
    font-family: var(--font-mono);
  }
  /* Custom Announcement Section Styling */
  .customization-section {
    margin-top: 14px;
    margin-bottom: 20px;
  }
  .customization-header {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-bottom: 12px;
  }
  .custom-sec-title {
    font-size: var(--fs-small);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--text-main, #e3e6e9);
  }
  /* ── Custom Server Announcement: Message / Appearance / Live Preview ── */
  .cs-head { margin-bottom: 18px; }
  .cs-head .section-title { margin-bottom: 4px; }
  .cs-head .field-hint { margin: 0; }
  .cs-label {
    margin: 22px 0 10px;
    font-size: var(--fs-meta);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--text-dim, #959ca5);
  }
  .cs-card {
    display: flex;
    flex-direction: column;
    gap: 14px;
    padding: 18px 20px;
    background: var(--bg-surface, #15171b);
    border: 1px solid var(--c-line, #2a2e35);
    border-radius: var(--r-panel);
  }
  .cs-card .field { margin: 0; }
  .cs-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; align-items: stretch; }
  @media (max-width: 1000px) { .cs-grid { grid-template-columns: 1fr; } }
  .cs-card-title {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: var(--fs-small);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--lt-ffffff, #fff);
  }
  .cs-opt { margin-left: auto; font-size: var(--fs-meta); font-weight: 700; letter-spacing: 0.01em; color: var(--text-dim, #8d949c); }
  .cs-url-row { display: flex; align-items: center; gap: 10px; }
  .cs-url {
    flex: 1;
    min-width: 0;
    height: 44px;
    padding: 0 14px;
    background: var(--bg-card-raised, #1c1f24);
    border: 1px solid #454a66;
    border-radius: var(--r-ctl);
    color: var(--lt-ffffff, #fff);
    font-size: var(--fs-body);
    outline: none;
  }
  .cs-url::placeholder { color: #8d949c; }
  .cs-url:focus { border-color: var(--accent-primary, #4f94e6); background: var(--lt-22262c, #22262c); }
  .cs-load { height: 44px; min-width: 84px; font-size: var(--fs-body); font-weight: 700; }
  .cs-clear { height: 44px; width: 44px; padding: 0; justify-content: center; }
  .cs-edit-btn { width: 100%; min-height: 44px; justify-content: center; font-size: var(--fs-body); }
  .cs-actions { display: flex; align-items: center; justify-content: center; gap: 12px; flex-wrap: wrap; margin: 22px 0 6px; }
  .cs-actions .btn { min-height: 44px; padding: 0 22px; font-size: var(--fs-body); font-weight: 700; }
  .custom-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 16px;
    align-items: stretch;
  }
  @media (max-width: 1000px) { .custom-grid { grid-template-columns: 1fr; } }
  .image-card { justify-content: flex-start; }
  .frame-btn { width: 100%; justify-content: center; min-height: 42px; font-size: var(--fs-body); font-weight: 700; }
  .frame-note { margin: 0; font-size: var(--fs-meta); line-height: 1.5; color: var(--text-dim, #959ca5); }
  .frame-note strong { color: var(--lt-ffffff, #fff); font-weight: 700; }
  .preview-scale-note { font-weight: 500; text-transform: none; letter-spacing: 0; color: var(--text-dim, #959ca5); }
  .scaled-card { display: flex; justify-content: center; }
  .banner-stage-big-unused { position: relative; padding: 34px 28px; min-height: 180px; align-items: center; }
  .banner-stage-big.clickable { cursor: pointer; }
  .banner-stage-big.clickable:hover { border-color: var(--accent-primary, #4f94e6); }
  .stage-edit-hint { position: absolute; right: 14px; bottom: 12px; display: inline-flex; align-items: center; gap: 6px; padding: 4px 10px; border-radius: var(--r-ctl); background: rgba(0,0,0,0.78); border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.18); color: var(--lt-e3e6e9, #e3e6e9); font-size: var(--fs-meta); font-weight: 600; opacity: 0; transition: opacity 0.15s ease; pointer-events: none; }
  .banner-stage-big.clickable:hover .stage-edit-hint { opacity: 1; }

  .custom-card {
    background: var(--bg-surface, #15171b);
    border: 1px solid var(--c-line, #2a2e35);
    border-radius: var(--radius-sm, 4px);
    padding: 14px 16px;
    display: flex;
    flex-direction: column;
    gap: 12px;
  }
  .custom-card-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding-bottom: 10px;
    border-bottom: 1px solid var(--c-raised, #1f2328);
  }
  .card-head-title {
    font-size: var(--fs-meta);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--text-main, #e3e6e9);
    display: flex;
    align-items: center;
    gap: 7px;
  }
  .card-head-sub {
    font-size: var(--fs-meta);
    font-weight: 700;
    font-family: var(--font-mono);
    color: var(--text-dim, #8d949c);
    letter-spacing: 0.01em;
  }
  .color-badge {
    font-size: var(--fs-meta);
    font-weight: 600;
    font-family: var(--font-mono);
    padding: 2px 8px;
    border-radius: var(--r-tag);
    border: 1px solid;
    background: rgba(0, 0, 0, 0.35);
  }

  /* Color Controls Layout */
  .color-layout {
    display: grid;
    grid-template-columns: 78px 1fr;
    gap: 14px;
    align-items: center;
  }
  .color-box-preview {
    width: 78px;
    height: 78px;
    border-radius: var(--r-ctl);
    border: 1px solid #3a3d4a;
    transition: background 0.15s ease, box-shadow 0.15s ease;
  }
  .color-controls-right {
    display: flex;
    flex-direction: column;
    gap: 10px;
  }
  .hue-wrapper {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }
  .hue-slider {
    -webkit-appearance: none;
    appearance: none;
    width: 100%;
    height: 14px;
    border-radius: 3px;
    outline: none;
    background: linear-gradient(90deg, #ff0000 0%, #ffff00 17%, #00ff00 33%, #00ffff 50%, var(--lt-0000ff, #0000ff) 67%, #ff00ff 83%, #ff0000 100%);
    border: 1px solid var(--tablet-border-strong, #363b43);
    cursor: pointer;
  }
  .hue-slider::-webkit-slider-thumb {
    -webkit-appearance: none;
    appearance: none;
    width: 18px;
    height: 18px;
    border-radius: 50%;
    background: #ffffff;
    border: 2px solid var(--c-panel, #181b1f);
    box-shadow: none;
    cursor: pointer;
    transition: transform 0.1s ease;
  }
  .hue-slider::-webkit-slider-thumb:hover {
    transform: scale(1.15);
  }
  .hue-labels {
    display: flex;
    justify-content: space-between;
    font-size: var(--fs-meta);
    font-weight: 700;
    color: var(--text-dim, #c9ced4);
    letter-spacing: 0.01em;
    padding: 0 2px;
  }
  .hex-presets-row {
    display: flex;
    align-items: center;
    gap: 12px;
    flex-wrap: wrap;
  }
  .hex-input-wrap {
    display: inline-flex;
    align-items: center;
    gap: 6px;
  }
  .hex-lbl {
    font-size: var(--fs-meta);
    font-weight: 700;
    color: var(--text-dim, #c9ced4);
  }
  .hex-field {
    width: 86px;
    height: 30px;
    background: var(--c-panel, #181b1f) !important;
    border: 1px solid var(--c-line, #2a2e35) !important;
    border-radius: var(--r-ctl) !important;
    color: var(--lt-ffffff, #fff) !important;
    font-family: var(--font-mono) !important;
    font-size: var(--fs-meta) !important;
    font-weight: 700 !important;
    padding: 0 8px !important;
    min-height: 30px !important;
  }
  .hex-field:focus {
    border-color: var(--accent-primary) !important;
    outline: none;
  }
  .presets-container {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-wrap: wrap;
  }
  .swatch-btn {
    width: 24px;
    height: 24px;
    border-radius: var(--r-tag);
    border: 1px solid #3b3e4b;
    cursor: pointer;
    padding: 0;
    transition: transform 0.12s ease, border-color 0.12s ease, box-shadow 0.12s ease;
  }
  .swatch-btn:hover {
    transform: scale(1.18);
    border-color: #ffffff;
    box-shadow: none;
  }
  .swatch-btn.active {
    border: 2px solid #ffffff;
    box-shadow: none;
  }

  /* Image Controls Layout */
  .image-input-row {
    display: flex;
    gap: 8px;
    align-items: center;
  }
  .image-input-row input {
    flex: 1;
    min-width: 0;
    height: 34px !important;
    min-height: 34px !important;
    font-size: var(--fs-meta) !important;
    padding: 0 10px !important;
  }
  .btn-img-action {
    height: 34px !important;
    min-height: 34px !important;
    padding: 0 14px !important;
    font-size: var(--fs-meta) !important;
    font-weight: 700 !important;
    flex-shrink: 0;
  }
  .btn-img-clear {
    height: 34px !important;
    min-height: 34px !important;
    width: 34px !important;
    padding: 0 !important;
    background: var(--c-raised, #1f2328);
    border: 1px solid var(--c-line, #2a2e35);
    border-radius: var(--r-ctl);
    color: var(--lt-c9ced4, #c9ced4);
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: all 0.15s ease;
  }
  .btn-img-clear:hover {
    background: rgba(229, 72, 77, 0.15);
    border-color: #e5484d;
    color: var(--lt-ff8a8d, #ff8a8d);
  }
  .image-err-alert {
    font-size: var(--fs-meta);
    color: var(--tablet-danger, #ff5d50);
    display: flex;
    align-items: center;
    gap: 6px;
    background: var(--c-raised);
    border: 1px solid var(--c-line);
    padding: 6px 10px;
    border-radius: var(--r-ctl);
    border-left: 3px solid rgb(255, 93, 80);}
  /* Image Fit & Focus Settings */
  .image-fit-settings {
    display: flex;
    flex-direction: column;
    gap: 8px;
    background: var(--lt-111316, #111316);
    border: 1px solid var(--lt-22262c, #22262c);
    border-radius: var(--r-ctl);
    padding: 9px 11px;
  }
  .fit-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
  }
  .fit-label {
    font-size: var(--fs-meta);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--text-dim, #aeb5bd);
  }
  .fit-label-with-val {
    display: flex;
    align-items: center;
    gap: 7px;
  }
  .fit-val-num {
    font-size: var(--fs-meta);
    font-weight: 700;
    font-family: var(--font-mono);
    color: var(--accent-primary-light, #66a3eb);
    background: var(--c-hover);
    border: 1px solid var(--accent-primary);
    padding: 1px 6px;
    border-radius: var(--r-panel);
  }
  .fit-mode-btns,
  .pos-preset-btns {
    display: inline-flex;
    align-items: center;
    gap: 4px;
  }
  .fit-mode-btn,
  .pos-btn {
    background: var(--c-panel, #181b1f);
    border: 1px solid var(--c-line, #2a2e35);
    border-radius: var(--r-ctl);
    color: var(--text-dim, #aeb5bd);
    font-size: var(--fs-meta);
    font-weight: 600;
    padding: 3px 8px;
    cursor: pointer;
    transition: all 0.12s ease;
  }
  .fit-mode-btn:hover,
  .pos-btn:hover {
    color: var(--lt-ffffff, #ffffff);
    border-color: #3a4048;
    background: var(--lt-22262c, #22262c);
  }
  .fit-mode-btn.active,
  .pos-btn.active {
    background: var(--accent-primary);
    border-color: var(--accent-primary);
    color: var(--on-accent, #ffffff);
    text-shadow: none;
    font-weight: 700;
  }
  .slider-track-wrap {
    display: flex;
    flex-direction: column;
    gap: 3px;
    margin-top: 1px;
  }
  .img-pos-slider {
    -webkit-appearance: none;
    appearance: none;
    width: 100%;
    height: 6px;
    border-radius: 3px;
    background: var(--c-raised, #1f2328);
    border: 1px solid var(--c-line, #2a2e35);
    outline: none;
    cursor: pointer;
  }
  .img-pos-slider::-webkit-slider-thumb {
    -webkit-appearance: none;
    appearance: none;
    width: 14px;
    height: 14px;
    border-radius: 50%;
    background: var(--accent-primary-light);
    border: 2px solid #ffffff;
    box-shadow: none;
    cursor: pointer;
    transition: transform 0.1s ease;
    color: var(--on-accent, inherit);
}
  .img-pos-slider::-webkit-slider-thumb:hover {
    transform: scale(1.15);
  }
  .slider-ticks {
    display: flex;
    justify-content: space-between;
    font-size: var(--fs-meta);
    color: var(--text-muted, #8d949c);
    font-weight: 600;
    letter-spacing: 0.01em;
    padding: 0 2px;
  }

  .image-controls-wrap {
    display: grid;
    grid-template-columns: minmax(0, 1.15fr) minmax(0, 1fr);
    gap: 20px;
    align-items: start;
  }
  .image-controls-col { display: flex; flex-direction: column; gap: 12px; min-width: 0; }
  .image-preview-col { min-width: 0; }
  .img-photo { position: absolute; inset: 0; background-repeat: no-repeat; pointer-events: none; }
  @media (max-width: 1100px) { .image-controls-wrap { grid-template-columns: 1fr; } }

  .image-preview-panel {
    height: 230px;
    border-radius: var(--r-ctl);
    border: 1px dashed #30353c;
    background: var(--lt-0f1113, #0f1113);
    overflow: hidden;
    position: relative;
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--text-muted, #aeb5bd);
    font-size: var(--fs-meta);
    text-align: center;
    padding: 6px 12px;
    transition: border-color 0.15s ease;
  }
  .image-preview-panel.has-photo {
    border-style: solid;
    border-color: #3b3e4d;
    background-repeat: no-repeat;
    color: transparent;
  }
  .img-loaded-tag {
    position: absolute;
    bottom: 6px;
    right: 8px;
    background: rgba(0, 0, 0, 0.75);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.2);
    color: var(--lt-46c98b, #46c98b);
    font-size: var(--fs-meta);
    font-weight: 600;
    padding: 2px 7px;
    border-radius: var(--r-tag);
    display: flex;
    align-items: center;
    gap: 4px;
    pointer-events: none;
  }

  /* Live In-Game Banner Preview */
  .custom-live-preview-wrap {
    margin-top: 18px;
  }
  .custom-banner-frame {
    position: relative;
    min-height: 86px;
    border-radius: var(--r-panel);
    overflow: hidden;
    background: linear-gradient(90deg, rgba(var(--ltc-8-10-15, 8, 10, 15), 0.96) 0%, rgba(var(--ltc-14-18-26, 14, 18, 26), 0.98) 50%, rgba(var(--ltc-8-10-15, 8, 10, 15), 0.96) 100%);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.14);
    box-shadow: none;
    display: flex;
    align-items: center;
  }
  .custom-banner-photo-bg {
    position: absolute;
    right: 0;
    top: 0;
    bottom: 0;
    width: 44%;
    background-size: cover;
    background-position: center;
    background-repeat: no-repeat;
    opacity: 0.75;
    mask-image: linear-gradient(90deg, transparent 0%, rgba(0,0,0,1) 40%);
    -webkit-mask-image: linear-gradient(90deg, transparent 0%, rgba(0,0,0,1) 40%);
    pointer-events: none;
  }
  .custom-banner-overlay {
    position: absolute;
    inset: 0;
    background: linear-gradient(90deg, rgba(var(--ltc-8-10-15, 8, 10, 15), 0.94) 0%, rgba(var(--ltc-8-10-15, 8, 10, 15), 0.65) 55%, rgba(var(--ltc-8-10-15, 8, 10, 15), 0.2) 100%);
    pointer-events: none;
  }
  .custom-banner-inner {
    position: relative;
    z-index: 2;
    padding: 14px 18px;
    display: flex;
    align-items: center;
    gap: 14px;
    width: 100%;
  }
  .custom-banner-icon {
    width: 42px;
    height: 42px;
    border-radius: var(--r-tag);
    border: 1px solid;
    background: rgba(0, 0, 0, 0.35);
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
  }
  .custom-banner-text {
    flex: 1;
    min-width: 0;
  }
  .custom-banner-kicker {
    font-size: var(--fs-meta);
    font-weight: 700;
    letter-spacing: 0.01em;
    text-shadow: 0 1px 3px rgba(0, 0, 0, 0.8);
    margin-bottom: 2px;
  }
  .custom-banner-title {
    font-size: var(--fs-body);
    font-weight: 700;
    color: var(--lt-ffffff, #ffffff);
    text-shadow: 0 1px 4px rgba(0, 0, 0, 0.8);
    word-break: break-word;
  }
  .custom-banner-body {
    font-size: var(--fs-meta);
    color: var(--lt-e3e6e9, #e3e6e9);
    line-height: 1.4;
    margin-top: 3px;
    word-break: break-word;
  }
  .custom-banner-body.hint-dim {
    color: var(--text-muted, #aeb5bd);
    font-style: italic;
  }
  .custom-banner-status {
    flex-shrink: 0;
    align-self: center;
    padding: 5px 10px;
    border-radius: var(--r-tag);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.2);
    background: rgba(0, 0, 0, 0.4);
    font-size: var(--fs-meta);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--lt-ffffff, #ffffff);
  }

  /* Actions Bottom */
  .custom-actions-bottom {
    margin-top: 18px;
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: 16px;
    flex-wrap: wrap;
    padding-top: 4px;
  }
  .action-note {
    font-size: var(--fs-meta);
    color: var(--text-muted, #aeb5bd);
    line-height: 1.4;
  }
  .action-buttons-group {
    display: flex;
    align-items: center;
    gap: 12px;
    margin-left: auto;
  }
  .btn-preview-myself {
    min-height: 38px;
    padding: 0 16px;
    font-size: var(--fs-small);
    font-weight: 600;
    border-color: #3b3f54;
  }
  .saved-flash {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-size: var(--fs-body);
    font-weight: 600;
    color: var(--tablet-success);
  }
  .error {
    color: var(--tablet-danger);
    font-size: var(--fs-body);
    margin-bottom: 12px;
  }

  /* Modal Styling */
  .overlay {
    position: absolute;
    inset: 0;
    background: rgba(0, 0, 0, 0.72);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 50;
  }
  .announce-modal {
    width: 960px;
    max-width: 96%;
    background: var(--surface-dialog);
    border: 1px solid var(--border-dialog);
    border-radius: var(--radius-md, 4px);
    box-shadow: none;
    overflow: hidden;
    animation: pop 0.16s ease-out both;
  }
  @keyframes pop {
    from { opacity: 0; transform: scale(0.96); }
    to { opacity: 1; transform: scale(1); }
  }
  .modal-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 14px 18px;
    border-bottom: 1px solid var(--tablet-border);
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.02);
  }
  .modal-header-title {
    font-size: var(--fs-body);
    font-weight: 700;
    color: var(--text-main);
    display: flex;
    align-items: center;
    gap: 8px;
    letter-spacing: 0.01em;
  }
  .icon-btn-close {
    background: transparent;
    border: none;
    color: var(--text-dim);
    cursor: pointer;
    display: flex;
    align-items: center;
    padding: 4px;
    border-radius: var(--r-ctl);
    transition: color 0.15s;
  }
  .icon-btn-close:hover {
    color: var(--text-main);
  }
  .banner-stage {
    display: flex;
    justify-content: center;
    padding: 26px 20px;
    background: radial-gradient(ellipse at center, var(--bg-card-raised, #1c1f24) 0%, var(--lt-111316, #111316) 70%);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm, 4px);
    overflow-x: auto;
  }
  .modal-body {
    padding: 22px 26px;
    max-height: 78vh;
    overflow-y: auto;
  }
  .event-target-banner {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 9px 12px;
    margin-bottom: 16px;
    background: var(--tablet-panel-alt, rgba(255, 255, 255, 0.03));
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm, 4px);
  }
  .target-name {
    font-size: var(--fs-body);
    font-weight: 700;
    color: var(--text-main);
  }
  .preview-heading {
    font-size: var(--fs-small);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--tablet-text-faint);
    margin: 16px 0 8px;
  }

  /* Shard Banner Preview */
  .banner-preview {
    position: relative;
    border-radius: var(--r-panel);
    background: linear-gradient(90deg, rgba(var(--ltc-8-10-15, 8, 10, 15), 0.96) 0%, rgba(var(--ltc-14-18-26, 14, 18, 26), 0.98) 50%, rgba(var(--ltc-8-10-15, 8, 10, 15), 0.96) 100%);
    box-shadow: none;
    overflow: hidden;
    padding: 12px 16px;
  }
  .preview-line-top,
  .preview-line-bottom {
    position: absolute;
    left: 0;
    right: 0;
    height: 2px;
  }
  .preview-line-top { top: 0; }
  .preview-line-bottom { bottom: 0; }

  .preview-convoy {
    --preview-accent: var(--accent-primary);
  }
  .preview-info {
    --preview-accent: var(--accent-primary);
  }
  .preview-airdrop {
    --preview-accent: #46c98b;
  }
  .preview-hot {
    --preview-accent: #ff5d50;
  }
  .preview-rally {
    --preview-accent: #ffc857;
  }
  .preview-cw {
    --preview-accent: var(--accent-primary);
  }
  .preview-territory {
    --preview-accent: #c45ee0;
  }
  .banner-preview .preview-line-top,
  .banner-preview .preview-line-bottom {
    background: var(--preview-accent, #4f94e6);
  }
  .preview-content {
    display: flex;
    align-items: flex-start;
    gap: 12px;
  }
  .preview-icon {
    width: 36px;
    height: 36px;
    border-radius: var(--r-tag);
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.05);
    border: 1px solid var(--preview-accent, #4f94e6);
    color: var(--preview-accent, #4f94e6);
    flex-shrink: 0;
  }
  .preview-text {
    flex: 1;
    min-width: 0;
  }
  .preview-sub {
    font-size: var(--fs-meta);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--preview-accent, #4f94e6);
    margin-bottom: 2px;
  }
  .preview-title {
    font-size: var(--fs-body);
    font-weight: 700;
    color: var(--lt-ffffff, #fff);
    margin-bottom: 3px;
    white-space: pre-wrap;
    word-break: break-word;
  }
  .preview-desc {
    font-size: var(--fs-small);
    color: var(--text-dim, #c9ced4);
    line-height: 1.4;
    white-space: pre-wrap;
    word-break: break-word;
  }

  .audience-toggle-group {
    display: flex;
    gap: 8px;
    margin-top: 6px;
  }
  .audience-btn {
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    padding: 8px 12px;
    font-size: var(--fs-meta);
    font-weight: 600;
    border-radius: var(--radius-sm, 4px);
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.04);
    border: 1px solid var(--tablet-border-strong, #30353c);
    color: var(--text-dim, #c9ced4);
    cursor: pointer;
    transition: all 0.15s ease;
  }
  .audience-btn:hover {
    color: var(--text-main, #ffffff);
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.08);
  }
  .audience-btn.active {
    background: rgba(56, 189, 248, 0.14);
    border-color: rgba(56, 189, 248, 0.4);
    color: var(--accent-primary);
  }

  .modal-actions {
    display: flex;
    justify-content: flex-end;
    gap: 10px;
    padding: 14px 18px;
    border-top: 1px solid var(--tablet-border);
    background: rgba(0, 0, 0, 0.2);
  }

  /* Structured Unified Control Bar for Event Announcements */
  .ann-control-bar {
    background: var(--bg-surface, #15171b);
    border: 1px solid var(--c-line, #2a2e35);
    border-radius: var(--r-ctl);
    padding: 8px 14px;
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    margin-bottom: 12px;
  }
  .ctrl-filters-group {
    display: flex;
    align-items: center;
    gap: 10px;
    flex-wrap: wrap;
    flex: 1 1 auto;
  }
  .ctrl-search {
    display: flex;
    align-items: center;
    gap: 8px;
    height: 34px;
    padding: 0 10px;
    background: var(--c-panel, #181b1f);
    border: 1px solid var(--c-line, #2a2e35);
    border-radius: var(--r-ctl);
    color: var(--text-dim, #aeb5bd);
    min-width: 200px;
    flex: 1 1 200px;
    max-width: 320px;
    transition: border-color 0.15s ease;
  }
  .ctrl-search:focus-within {
    border-color: var(--accent-primary);
  }
  .ctrl-search input {
    flex: 1;
    min-width: 0;
    background: transparent;
    border: none;
    outline: none;
    color: var(--lt-ffffff, #ffffff);
    font-size: var(--fs-small);
    padding: 0;
  }
  .ctrl-search input::placeholder {
    color: var(--text-muted, #8d949c);
  }
  .ctrl-clear-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    background: transparent;
    border: none;
    color: var(--text-dim, #aeb5bd);
    cursor: pointer;
    padding: 2px;
  }
  .ctrl-clear-btn:hover {
    color: var(--lt-ffffff, #ffffff);
  }
  .ctrl-select-wrap {
    display: inline-flex;
    align-items: center;
    gap: 7px;
    height: 34px;
    padding: 0 8px 0 10px;
    background: var(--c-panel, #181b1f);
    border: 1px solid var(--c-line, #2a2e35);
    border-radius: var(--r-ctl);
  }
  .ctrl-select-lbl {
    font-size: var(--fs-meta);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--text-muted, #aeb5bd);
    white-space: nowrap;
  }
  .ctrl-select-wrap select {
    background: transparent;
    border: none;
    outline: none;
    color: var(--lt-ffffff, #ffffff);
    font-size: var(--fs-meta);
    font-weight: 600;
    cursor: pointer;
    padding-right: 4px;
  }
  .ctrl-select-wrap select option {
    background: var(--c-panel, #181b1f);
    color: var(--lt-ffffff, #ffffff);
  }
  .ctrl-paging-group {
    display: inline-flex;
    align-items: center;
    gap: 10px;
    flex-wrap: wrap;
  }
  .ctrl-rows-select {
    display: inline-flex;
    align-items: center;
    gap: 6px;
  }
  .ctrl-rows-lbl {
    font-size: var(--fs-meta);
    letter-spacing: 0.01em;
    font-weight: 700;
    color: var(--text-muted, #aeb5bd);
  }
  .ctrl-rows-select select {
    background: var(--c-panel, #181b1f);
    border: 1px solid var(--c-line, #2a2e35);
    border-radius: var(--r-ctl);
    color: var(--lt-ffffff, #ffffff);
    font-size: var(--fs-meta);
    font-weight: 600;
    padding: 2px 6px;
    height: 28px;
    cursor: pointer;
    outline: none;
  }
  .ctrl-rows-select select:focus {
    border-color: var(--accent-primary);
  }
  .ctrl-pager-actions {
    display: inline-flex;
    align-items: center;
    gap: 3px;
  }
  .ann-pg-btn {
    width: 28px;
    height: 28px;
    padding: 0;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    background: var(--c-raised, #1f2328);
    border: 1px solid var(--c-line, #2a2e35);
    border-radius: var(--r-ctl);
    color: var(--lt-e3e6e9, #e3e6e9);
    font-size: var(--fs-small);
    font-weight: 700;
    cursor: pointer;
    transition: all 0.12s ease;
  }
  .ann-pg-btn:hover:not(:disabled) {
    background: var(--accent-primary);
    border-color: var(--accent-primary);
    color: var(--on-accent, #ffffff);
    text-shadow: none;
  }
  .ann-pg-btn:disabled {
    opacity: 0.35;
    cursor: not-allowed;
    background: var(--c-panel, #181b1f);
  }
  .ann-pg-info {
    font-size: var(--fs-meta);
    font-weight: 700;
    font-family: var(--font-mono);
    color: var(--lt-ffffff, #ffffff);
    padding: 0 5px;
    white-space: nowrap;
  }
  .ctrl-meta-info {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    font-size: var(--fs-meta);
    color: var(--text-muted, #aeb5bd);
    padding-left: 8px;
    border-left: 1px solid var(--c-line, #2a2e35);
    white-space: nowrap;
  }
  .ctrl-meta-info strong {
    color: var(--lt-ffffff, #ffffff);
  }
  .ann-reset {
    background: transparent;
    border: none;
    padding: 0;
    color: var(--accent-primary-light, #66a3eb);
    font-size: var(--fs-meta);
    font-weight: 700;
    cursor: pointer;
  }
  .ann-reset:hover {
    text-decoration: underline;
  }

  /* Structured Table rules with explicit balanced columns */
  table.data-table.ann-table-structured {
    width: 100% !important;
    table-layout: fixed !important;
    border-spacing: 0 4px !important;
    border-collapse: separate !important;
  }
  table.data-table.ann-table-structured th {
    padding: var(--tbl-th-y) var(--tbl-x) !important;
    font-size: var(--fs-meta);
    letter-spacing: 0;
    font-weight: 600;
    color: var(--text-muted);
    background: var(--c-panel);
    border-bottom: 1px solid var(--c-line);
    vertical-align: middle !important;
    box-sizing: border-box !important;
    white-space: nowrap;
  }
  table.data-table.ann-table-structured td {
    padding: var(--tbl-td-y) var(--tbl-x) !important;
    font-size: var(--fs-body);
    border-bottom: 1px solid var(--c-line-soft);
    background: var(--c-panel, #181b1f) !important;
    vertical-align: middle !important;
    box-sizing: border-box !important;
    font-variant-numeric: tabular-nums;
  }
  table.data-table.ann-table-structured td:first-child {
    border-top-left-radius: var(--r-ctl) !important;
    border-bottom-left-radius: var(--r-ctl) !important;
    font-variant-numeric: tabular-nums;
  }
  table.data-table.ann-table-structured td:last-child {
    border-top-right-radius: var(--r-ctl) !important;
    border-bottom-right-radius: var(--r-ctl) !important;
    font-variant-numeric: tabular-nums;
  }
  table.data-table.ann-table-structured tbody tr:hover td {
    background: var(--c-raised, #1f2328) !important;
    font-variant-numeric: tabular-nums;
  }

  .col-name {
    width: 34% !important;
  }
  .col-name .event-name-text {
    display: block;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-weight: 600;
    color: var(--lt-eceef0, #eceef0);
  }
  .col-kind {
    width: 20% !important;
  }
  .col-status {
    width: 15% !important;
  }
  .col-starts {
    width: 19% !important;
  }
  .col-actions {
    width: 12% !important;
    text-align: right !important;
  }
  .btn-announce-compact {
    min-height: 28px !important;
    padding: 0 10px !important;
    font-size: var(--fs-meta) !important;
    font-weight: 600 !important;
    gap: 5px !important;
    border-radius: var(--r-ctl) !important;
    margin-left: auto;
  }
  .starts-text {
    font-size: var(--fs-meta);
    color: var(--text-dim, #c9ced4);
    font-family: var(--font-mono);
  }
  .ann-empty {
    text-align: center;
    padding: 24px 16px !important;
    color: var(--text-dim);
  }
</style>
