<script>
  import { announcement, checkpointHud, prepCountdown } from './hudStore.js';
  import { eventBanners } from './eventBannerStore.js';
  import { inferEventKey, announcementSubtitle, announcementStatus, announcementImage } from './announcementModel.js';
  import AnnouncementCard from './AnnouncementCard.svelte';

  // CheckpointHud sits fixed at top:32px and runs ~80px tall — when it's up
  // (checkpoint holds, which is exactly when a "Convoy Held" banner fires
  // too) this banner's default top:90px overlapped it. Push down to clear
  // it whenever the checkpoint bar is visible.
  $: topOffset = $checkpointHud.visible || $prepCountdown.visible ? 92 : 30;

  // Which event owns this message decides the colour + icon (see eventThemes.js). Status (started / captured /
  // failed...) is shown in the right-hand badge instead of recolouring the whole card.
  $: eventKey = inferEventKey($announcement.type, $announcement.title, $announcement.message);
  $: status = announcementStatus(eventKey, $announcement.type, $announcement.title, $announcement.status);
  $: subtitle = announcementSubtitle(eventKey, $announcement.type, $announcement.title, $announcement.message);
  // explicit announcement image, else the one saved for the event in the Event Banner Images tab
  $: image = announcementImage($eventBanners[eventKey], $announcement);
</script>

{#if $announcement.visible}
  {#key $announcement.key}
    <div class="ann-wrap" style="--ann-top:{topOffset}px;">
      <AnnouncementCard
        {eventKey}
        {subtitle}
        title={$announcement.title}
        message={$announcement.message}
        {status}
        gang={$announcement.gang}
        bannerImg={image.img}
        bannerPos={image.pos}
        bannerFit={image.fit}
        bannerZoom={image.zoom}
        bannerColor={$announcement.bannerColor}
        durationMs={$announcement.durationMs || 7000}
      />
    </div>
  {/key}
{/if}

<style>
  .ann-wrap {
    position: fixed;
    top: var(--ann-top, 30px);
    left: 0;
    right: 0;
    display: flex;
    justify-content: center;
    pointer-events: none;
    z-index: 9999;
    transition: top 0.25s ease;
  }
</style>