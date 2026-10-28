<script>
  import Icon from '../../tablet/ui/Icon.svelte';

  // Player-only quick guide. Everything here is something a gang member can actually do in this tablet; tabs that depend
  // on a gang role are marked as such.
  const FEATURES = [
    { icon: 'list', name: 'Events', text: 'The list of upcoming and live events with cargo, difficulty, departure time and status. Open an event to see its details. Your gang leader (or a member with permission) can register the gang there and pick who goes.' },
    { icon: 'check', name: 'My Registrations', text: 'The events your gang has signed up for and who is on each roster. Only shown if your gang role lets you manage registrations.' },
    { icon: 'flag', name: 'Tournaments', text: 'Your group, your matches and results, and the road to the final once a tournament has been announced. The tree is highlighted for your gang and updates live.' },
    { icon: 'trophy', name: 'Leaderboard', text: 'Gang rankings per activity: Gang XP, win rate, leader and member count. See where you stand against other gangs.' },
    { icon: 'pin', name: 'Map Zone', text: 'The live map with your gang\'s territory, your Gang XP and its history, and the ranking. Leaders (or members with permission) grow a territory by painting land onto it: every painted cell costs Gang XP, so the bigger the area, the more XP is taken, and rubbing painted land out gives it back. The map fills the whole screen; press Details for the selected territory. Your gang leader answers and sends rival challenges. Territory auctions are bid on at the auction house.' },
    { icon: 'users', name: 'My Gang', text: 'Your gang\'s roster and roles. Everyone can look; leaders and permitted members can add members by server ID or name (or pick an online player), remove members, change roles, pass leadership and set the gang logo.' },
  ];
</script>

<div class="gg">
  <div class="grid">
    <section class="card">
      <h3><Icon name="info" size={15} /> Getting Started</h3>
      <ul>
        <li>Open this tablet with the <b>Event Status</b> key (<b>F6</b> by default) or type <b>/eventstatus</b>. <b>Esc</b> or the ✕ closes it.</li>
        <li>The tabs along the top switch between screens. Press one to open it.</li>
        <li>You only see the tabs your gang role allows, so a teammate may see more or fewer than you.</li>
      </ul>
    </section>

    <section class="card">
      <h3><Icon name="palette" size={15} /> Personalize Your Tablet</h3>
      <ul>
        <li>Open <b>Settings → Appearance</b>.</li>
        <li>Pick an <b>accent colour</b> and a <b>background</b> (dark, gradient or Light). The small preview shows how it will look.</li>
        <li>Press <b>Apply Theme</b> to use it. Nothing changes on the tablet until you do.</li>
        <li><b>Reset to Default</b> brings back the original blue and graphite look.</li>
      </ul>
    </section>

    <section class="card">
      <h3><Icon name="volume" size={15} /> Click Sounds</h3>
      <ul>
        <li>Open <b>Settings → UI Click Sounds</b> and switch it <b>On</b> or <b>Off</b>.</li>
        <li>It only affects the clicks in this tablet. Game sounds are not changed.</li>
      </ul>
    </section>

    <section class="card">
      <h3><Icon name="crosshair" size={15} /> Custom Crosshair</h3>
      <ul>
        <li>Open <b>Settings → Gameplay &amp; HUD</b> and switch <b>Custom Crosshair</b> On or Off. It takes effect straight away.</li>
        <li>It only changes <b>your own</b> screen, and it is remembered next time.</li>
        <li>It is used in TDM matches and the Practice Range, with a weapon in hand. Type <b>/crosshair</b> to change its look.</li>
      </ul>
    </section>
  </div>

  <section class="card wide">
    <h3><Icon name="users" size={15} /> Gang Features</h3>
    <div class="features">
      {#each FEATURES as f}
        <div class="feat">
          <span class="ico"><Icon name={f.icon} size={16} /></span>
          <div><b>{f.name}</b><p>{f.text}</p></div>
        </div>
      {/each}
    </div>
  </section>

  <section class="card wide">
    <h3><Icon name="warning" size={15} /> Quick Troubleshooting</h3>
    <div class="faq">
      <div><b>My theme didn't change.</b><p>Previewing is not enough: press <b>Apply Theme</b>. Settings are saved on this computer, so another computer starts with the default look.</p></div>
      <div><b>I still hear clicks after turning them off.</b><p>Check that <b>UI Click Sounds</b> says <b>Off</b> in this tablet's Settings. The switch only covers this tablet; other windows keep their own sounds. Close and reopen the tablet if it still clicks.</p></div>
      <div><b>My crosshair doesn't show.</b><p>Make sure <b>Custom Crosshair</b> is <b>On</b>, you are in a TDM match or the Practice Range, and you are holding a weapon. If it is on but hard to see, type <b>/crosshair</b> and raise its size or opacity.</p></div>
    </div>
  </section>
</div>

<style>
  .gg {
    flex: 1;
    min-height: 0;
    overflow-y: auto;
    display: flex;
    flex-direction: column;
    gap: 12px;
    padding-right: 4px;
  }
  .grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
  .card {
    padding: 12px 16px 14px;
    border-radius: var(--r-panel);
    background: var(--es-card);
    border: 1px solid var(--es-line);
  }
  h3 {
    display: flex;
    align-items: center;
    gap: 8px;
    margin: 0 0 8px;
    font-size: var(--fs-emph, 16px);
    font-weight: 700;
    color: var(--lt-ffffff, #fff);
  }
  h3 :global(svg) { color: var(--accent-primary-light, #66a3eb); }
  ul { margin: 0; padding-left: 18px; display: flex; flex-direction: column; gap: 4px; }
  li, p { font-size: var(--fs-small, 13.5px); line-height: 1.5; color: var(--text-dim); }
  p { margin: 2px 0 0; }
  b { color: var(--lt-ffffff, #fff); font-weight: 600; }

  .features { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px 20px; }
  .feat { display: flex; gap: 10px; align-items: flex-start; }
  .ico {
    flex: none;
    width: 30px; height: 30px;
    display: grid; place-items: center;
    border-radius: var(--r-ctl, 8px);
    color: var(--accent-primary-light, #66a3eb);
    background: var(--es-raised);
    border: 1px solid var(--es-line);
  }
  .faq { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 10px 20px; }

  @media (max-width: 1100px) {
    .grid, .features, .faq { grid-template-columns: 1fr; }
  }
</style>
