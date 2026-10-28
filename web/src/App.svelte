<script>
  import { onMount } from 'svelte';
  import Hud from './lib/hud/Hud.svelte';
  import Tablet from './lib/tablet/Tablet.svelte';
  import LiveConvoyPanel from './lib/livepanel/LiveConvoyPanel.svelte';
  import MinigameOverlay from './lib/minigames/MinigameOverlay.svelte';
  import PracticeArmory from './lib/hud/PracticeArmory.svelte';
  import MatchResults from './lib/hud/MatchResults.svelte';
  import CrosshairPanel from './lib/hud/CrosshairPanel.svelte';
  import PedMenu from './lib/hud/PedMenu.svelte';
  import LeaderTalk from './lib/hud/LeaderTalk.svelte';
  import TdmOutcome from './lib/hud/TdmOutcome.svelte';
  import { tdmOutcome } from './lib/hud/tdmOutcomeStore.js';
  import { leaderTalk } from './lib/hud/leaderTalkStore.js';
  import { pedMenu } from './lib/hud/pedMenuStore.js';
  import AirdropMarker from './lib/hud/AirdropMarker.svelte';
  import ContainerInfo from './lib/hud/ContainerInfo.svelte';
  import ContainerBidder from './lib/hud/ContainerBidder.svelte';
  import ContainerTimer from './lib/hud/ContainerTimer.svelte';
  import { setContainerTimer } from './lib/hud/containerTimerStore.js';
  import ContainerCivilianPanel from './lib/hud/ContainerCivilianPanel.svelte';
  import { setCivilianInfo } from './lib/hud/containerCivilianStore.js';
  import VehicleRewardTag from './lib/hud/VehicleRewardTag.svelte';
  import { setVehicleRewardInfos } from './lib/hud/vehicleRewardStore.js';
  import { setVehicleClaim } from './lib/hud/vehicleClaimStore.js';
  import VehicleClaimBar from './lib/hud/VehicleClaimBar.svelte';
  import PropPlacer from './lib/placer/PropPlacer.svelte';
  import TerritoryHud from './lib/hud/TerritoryHud.svelte';
  import CrackdownHud from './lib/hud/CrackdownHud.svelte';
  import { handleCrackdownMessage } from './lib/hud/crackdownStore.js';
  import { handleTerritoryMessage } from './lib/territory/territoryStore.js';
  import Showroom from './lib/showroom/Showroom.svelte';
  import { handleShowroomMessage } from './lib/showroom/showroomStore.js';
  import CivilianRegistrationModal from './lib/civilian/CivilianRegistrationModal.svelte';
  import { handlePlacerMessage } from './lib/placer/placerStore.js';
  import { handleBidderMessage } from './lib/hud/bidderStore.js';
  import { setContainerInfos } from './lib/hud/containerInfoStore.js';
  import { setAirdropMarkers } from './lib/hud/airdropMarkerStore.js';
  import { startMinigame, closeMinigame } from './lib/minigames/minigameStore.js';
  import { handleHudMessage } from './lib/hud/hudStore.js';
  import { handleCraneAudio } from './lib/audio/craneAudio.js';
  import { handlePlaySound } from './lib/audio/soundPlayer.js';
  import { initUiClickSound } from './lib/audio/uiClickSound.js';
  import { setEventBanners } from './lib/hud/eventBannerStore.js';
  import { tabletOpen, tabletMinimized, livePanelOpen, livePanelBrand, barricadePropRemoved, decorVehicleRemoved, propEditRequest, routeRecordingResult, zoneRecordingResult, convoyListVersion, staffVersion, gangVersion, practiceArmoryOpen, practiceArmoryData, matchResultsOpen, matchResultsData, civilianRegistrationOpen, civilianRegistrationData } from './lib/stores.js';

  function onMessage(event) {
    const data = event.data;
    if (!data || !data.action) return;

    if (data.action === 'tablet:open') {
      tabletOpen.set(true);
    } else if (data.action === 'tablet:close') {
      tabletOpen.set(false);
    } else if (data.action === 'tablet:minimize') {
      tabletMinimized.set(true);
    } else if (data.action === 'tablet:restore') {
      tabletMinimized.set(false);
    } else if (data.action === 'barricadePropRemovedInWorld') {
      barricadePropRemoved.set({ cpKey: data.cpKey, index: data.index });
    } else if (data.action === 'decorVehicleRemovedInWorld') {
      decorVehicleRemoved.set({ cpKey: data.cpKey, index: data.index });
    } else if (data.action === 'propEditRequested') {
      propEditRequest.set({ kind: data.kind, cpKey: data.cpKey, index: data.index });
    } else if (typeof data.action === 'string' && data.action.startsWith('placer:')) {
      handlePlacerMessage(data);
    } else if (data.action === 'livepanel:open') {
      if (data.title !== undefined) livePanelBrand.set({ title: data.title || 'Event Status', badge: data.badge || '' });
      livePanelOpen.set(true);
    } else if (data.action === 'livepanel:close') {
      livePanelOpen.set(false);
    } else if (data.action === 'routeRecording:complete') {
      // `target` identifies WHICH builder asked for this recording session
      // (set when it called startRouteRecording). Only the screen that owns
      // the session may consume the points — this is what stops a Rally
      // recording from being appended to a Convoy's route (or vice versa),
      // which is how one event's vectors ended up appearing in another's
      // builder. A missing target falls through as 'CONVOY' for backwards
      // compatibility with an older client that didn't send one.
      routeRecordingResult.set({ target: data.target || 'CONVOY', points: data.points || [] });
    } else if (data.action === 'zoneRecording:complete') {
      zoneRecordingResult.set({ target: data.target || 'HOT_CARGO', points: data.points || [] });
    } else if (data.action === 'convoyListChanged') {
      convoyListVersion.update((v) => v + 1);
    } else if (data.action === 'staff:changed') {
      staffVersion.update((v) => v + 1);
    } else if (data.action === 'gang:changed') {
      gangVersion.update((v) => ({ n: v.n + 1, gangId: data.gangId ?? null, gangName: data.gangName ?? null }));
    } else if (data.action === 'minigame:start') {
      // Temporary diagnostic — see the matching Lua-side print in
      // client/modules/minigames.lua's PlayMinigame for what this pairs
      // with. FiveM mirrors NUI console output into the player's F8
      // console by default, so this should be visible there.
      console.log('[minigame] start received', data);
      startMinigame(data);
    } else if (data.action === 'airdropMarker:update') {
      setAirdropMarkers(data.markers);
    } else if (data.action === 'craneAudio') {
      handleCraneAudio(data);
    } else if (data.action === 'playSound') {
      handlePlaySound(data);
    } else if (data.action === 'containerInfo:frame') {
      setContainerInfos(data.items);
    } else if (data.action === 'cwTimer:frame') {
      setContainerTimer(data);
    } else if (data.action === 'cwCivilianInfo:frame') {
      setCivilianInfo(data);
    } else if (data.action === 'cwVehicleReward:frame') {
      setVehicleRewardInfos(data.items);
    } else if (data.action === 'cwVehicleClaim:state') {
      setVehicleClaim(data);
    } else if (typeof data.action === 'string' && data.action.startsWith('crackdown:')) {
      handleCrackdownMessage(data);
    } else if (typeof data.action === 'string' && data.action.startsWith('territory:')) {
      handleTerritoryMessage(data);
    } else if (typeof data.action === 'string' && data.action.startsWith('showroom:')) {
      handleShowroomMessage(data);
    } else if (typeof data.action === 'string' && data.action.startsWith('bidder:')) {
      handleBidderMessage(data);
    } else if (data.action === 'minigame:close') {
      closeMinigame(false);
    } else if (data.action === 'pedMenu:open') {
      pedMenu.set({ title: data.title, subtitle: data.subtitle, items: data.items || [], accounts: data.accounts !== false });
    } else if (data.action === 'pedMenu:close') {
      pedMenu.set(null);
    } else if (data.action === 'tdmOutcome:show') {
      tdmOutcome.set({ banner: data.banner || null, pos: {} });
    } else if (data.action === 'tdmOutcome:pos') {
      tdmOutcome.update((o) => (o ? { ...o, pos: data.pos || {} } : o));
    } else if (data.action === 'tdmOutcome:hide') {
      tdmOutcome.set(null);
    } else if (data.action === 'leaderTalk:show') {
      leaderTalk.set({ speaker: data.speaker || {}, line: data.line || '', facts: data.facts || [], options: data.options || [], node: data.node || '' });
    } else if (data.action === 'leaderTalk:close') {
      leaderTalk.set(null);
    } else if (data.action === 'practiceArmory:open') {
      practiceArmoryData.set({
        locations: data.locations || [],
        weapons: data.weapons || [],
        squad: data.squad || [],
        isHost: data.isHost !== false,
      });
      practiceArmoryOpen.set(true);
    } else if (data.action === 'practiceArmory:close') {
      practiceArmoryOpen.set(false);
    } else if (data.action === 'practiceArmory:squadUpdate') {
      practiceArmoryData.update((cur) => ({ ...cur, squad: data.squad || [] }));
    } else if (data.action === 'matchResults:show') {
      matchResultsData.set({
        mode: data.mode || 'practice',
        eventName: data.eventName || '',
        duration: data.duration || '',
        scoreA: data.scoreA,
        scoreB: data.scoreB,
        players: data.players || [],
        outcome: data.outcome || null,
      });
      matchResultsOpen.set(true);
    } else if (data.action === 'matchResults:hide') {
      matchResultsOpen.set(false);
    } else if (data.action === 'civilianRegistration:open') {
      civilianRegistrationData.set(data);
      civilianRegistrationOpen.set(true);
    } else if (data.action === 'civilianRegistration:close') {
      civilianRegistrationOpen.set(false);
    } else if (data.action === 'updateEventBanners') {
      setEventBanners(data.banners);
    } else {
      handleHudMessage(data);
    }
  }

  onMount(() => {
    window.addEventListener('message', onMessage);
    const stopClickSound = initUiClickSound();
    return () => {
      window.removeEventListener('message', onMessage);
      stopClickSound();
    };
  });
</script>

<Hud />
<AirdropMarker />
<ContainerInfo />
<ContainerTimer />
<ContainerCivilianPanel />
<VehicleRewardTag />
<VehicleClaimBar />
<ContainerBidder />
<TerritoryHud />
<CrackdownHud />
<Tablet />
<LiveConvoyPanel />
<MinigameOverlay />
<PracticeArmory />
<MatchResults />
<CrosshairPanel />
<PedMenu />
<LeaderTalk />
<TdmOutcome />
<PropPlacer />
<CivilianRegistrationModal />
<Showroom />
