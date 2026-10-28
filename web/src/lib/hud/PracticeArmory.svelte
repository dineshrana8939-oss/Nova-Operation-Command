<script>
  import { practiceArmoryOpen, practiceArmoryData } from '../stores.js';
  import { closePracticeArmory, invitePracticeSquad, kickPracticeSquad, deployPractice, selectPracticeWeapon } from '../api/practice.js';
  import Icon from '../tablet/ui/Icon.svelte';
  import { gangPrefs, gangThemeStyle } from '../gangPrefs.js';
  import '../tablet/tablet-theme.css';
  import '../../styles/flat.css';   // this window wears the same theme as the Event Status panel

  const MAX_SQUAD = 8;

  let selectedLocationId = null;
  let selectedWeapon = null;
  let inviteName = '';

  $: locations = $practiceArmoryData.locations || [];
  $: weapons = $practiceArmoryData.weapons || [];
  $: squad = $practiceArmoryData.squad || [];
  $: isHost = $practiceArmoryData.isHost !== false;

  // Default to the first option once data arrives, if nothing picked yet.
  $: if (!selectedLocationId && locations.length > 0) selectedLocationId = locations[0].id;
  $: if (!selectedWeapon && weapons.length > 0) selectedWeapon = weapons[0].weapon;

  $: selectedLocation = locations.find((l) => l.id === selectedLocationId) || null;
  $: selectedWeaponEntry = weapons.find((w) => w.weapon === selectedWeapon) || null;

  // Every member's own weapon pick is sent as it changes — only the host's
  // Deploy call reaches the server directly, so this is what lets a
  // non-host squadmate's choice actually take effect at deploy time.
  let lastSentWeapon = null;
  $: if (selectedWeapon && selectedWeapon !== lastSentWeapon) {
    lastSentWeapon = selectedWeapon;
    selectPracticeWeapon(selectedWeapon);
  }

  // Weapon class shown on each card and the silhouette it gets, read from the weapon's own name
  // (WEAPON_CARBINERIFLE -> rifle) — nothing extra is sent by the server.
  function weaponKind(w) {
    const n = String(w.weapon || '').toUpperCase().replace(/^WEAPON_/, '');
    if (/SNIPER|MARKSMAN/.test(n)) return 'sniper';
    if (/SHOTGUN/.test(n)) return 'shotgun';
    if (/SMG|MACHINEPISTOL|PDW/.test(n)) return 'smg';
    if (/^(COMBATMG|MG|GUSENBERG)/.test(n)) return 'mg';
    if (/RIFLE|CARBINE/.test(n)) return 'rifle';
    if (/PISTOL|REVOLVER/.test(n)) return 'pistol';
    return 'pistol';
  }
  const KIND_LABEL = { pistol: 'Pistol', smg: 'SMG', rifle: 'Rifle', shotgun: 'Shotgun', mg: 'Machine gun', sniper: 'Precision' };

  // The colour a training area's type gets (its tag text comes from the server: Open area, Urban, Hostile, Woods ...)
  function tagTone(tag) {
    const t = String(tag || '').toLowerCase();
    if (/urban|city/.test(t)) return 'amber';
    if (/hostile|danger|war/.test(t)) return 'red';
    if (/wood|forest|field/.test(t)) return 'green';
    return 'blue';
  }

  $: readyCount = squad.filter((m) => m.status !== 'pending').length;
  $: pendingCount = squad.filter((m) => m.status === 'pending').length;
  $: slots = Array.from({ length: MAX_SQUAD }, (_, i) => {
    if (i < readyCount) return 'ready';
    if (i < readyCount + pendingCount) return 'pending';
    return 'free';
  });

  function close() {
    closePracticeArmory();
    practiceArmoryOpen.set(false);
  }

  function invite() {
    const name = inviteName.trim();
    if (!name) return;
    invitePracticeSquad(name);
    inviteName = '';
  }

  function kick(memberSource) {
    kickPracticeSquad(memberSource);
  }

  function deploy() {
    if (!selectedLocationId || !selectedWeapon) return;
    deployPractice(selectedLocationId, selectedWeapon);
  }

  const initials = (name) => String(name || '?').trim().split(/\s+/).slice(0, 2).map((p) => p[0]).join('').toUpperCase();

  function handleKeydown(e) {
    if (e.key === 'Escape') close();
  }
</script>

<svelte:window on:keydown={$practiceArmoryOpen ? handleKeydown : undefined} />

{#if $practiceArmoryOpen}
  <div class="overlay" data-ui-scope="gang" data-bg={$gangPrefs.bgTheme} style={$gangThemeStyle}>
    <!-- weapon silhouettes (side view, barrel to the left) -->
    <svg width="0" height="0" style="position:absolute" aria-hidden="true">
      <defs>
        <symbol id="pa-pistol" viewBox="0 0 72 28" fill="currentColor"><path d="M6 5h44a2 2 0 012 2v6H41l-3 3v9h-9v-9l-1-3H6a2 2 0 01-2-2V7a2 2 0 012-2z"/></symbol>
        <symbol id="pa-smg" viewBox="0 0 72 28" fill="currentColor"><path d="M2 6h38l4-2h14l4 3h8v6H60l-4 3H38l-2 9h-8l2-9H20l-2 4h-6l1-4H2z"/></symbol>
        <symbol id="pa-rifle" viewBox="0 0 72 28" fill="currentColor"><path d="M1 8h22l3-2h20l3 2h6l7 3v4H55l-3 3H44l1 8h-8l-3-8H26l-2 4h-6l1-4H1z"/></symbol>
        <symbol id="pa-shotgun" viewBox="0 0 72 28" fill="currentColor"><path d="M1 9h40l3-1h12l7 5v3H56l-2 3H44l-4 4h-7l3-4H1z"/></symbol>
        <symbol id="pa-mg" viewBox="0 0 72 28" fill="currentColor"><path d="M1 7h24l3-2h18l3 2h7l8 4v4H57l-3 3H46v9H34v-9H26l-2 3h-6l1-3H1z"/></symbol>
        <symbol id="pa-sniper" viewBox="0 0 72 28" fill="currentColor"><path d="M1 12h26l2-1h12l2 1h4l5-2h9l9 4v4H61l-2 3H50l-2 4h-7l1-4H29l-2 2h-6l1-2H1zM22 4h14v3H22z"/></symbol>
      </defs>
    </svg>

    <div class="shell" role="dialog" aria-label="Practice range armory">
      <header class="topbar">
        <span class="mark"><Icon name="crosshair" size={20} /></span>
        <div class="heading">
          <h1>Practice range</h1>
          <p>Pick an area and a weapon, then bring your squad in</p>
        </div>
        <button type="button" class="close" on:click={close} aria-label="Close the armory"><kbd>Esc</kbd> Close</button>
      </header>

      <main class="workspace">
        <section class="left">
          <div class="section-head">
            <h2>Training area</h2>
            <span class="section-meta">{locations.length} available</span>
          </div>
          <div class="training-grid">
            {#each locations as loc (loc.id)}
              <button type="button" class="range" class:active={selectedLocationId === loc.id} aria-pressed={selectedLocationId === loc.id} on:click={() => (selectedLocationId = loc.id)}>
                <span class="pin tone-{tagTone(loc.tag)}"><Icon name="pin" size={16} /></span>
                <span class="range-text">
                  <strong>{loc.label}</strong>
                  <span class="chip tone-{tagTone(loc.tag)}">{loc.tag || 'Area'}</span>
                </span>
                {#if selectedLocationId === loc.id}<span class="tick"><Icon name="check" size={13} /></span>{/if}
              </button>
            {/each}
          </div>

          <div class="section-head weapon-head">
            <h2>Weapon</h2>
            <span class="section-meta">Your primary weapon for the session</span>
          </div>
          <div class="weapon-grid">
            {#each weapons as w (w.weapon)}
              <button type="button" class="weapon" class:selected={selectedWeapon === w.weapon} aria-pressed={selectedWeapon === w.weapon} on:click={() => (selectedWeapon = w.weapon)}>
                <span class="gun"><svg viewBox="0 0 72 28"><use href={`#pa-${weaponKind(w)}`} /></svg></span>
                <strong>{w.label}</strong>
                <span class="kind">{KIND_LABEL[weaponKind(w)]}{selectedWeapon === w.weapon ? ' · equipped' : ''}</span>
              </button>
            {/each}
          </div>
        </section>

        <aside class="right">
          <div class="section-head">
            <h2>Squad</h2>
            <span class="count"><i class="live-dot"></i>{squad.length} of {MAX_SQUAD}</span>
          </div>

          <div class="squad">
            <div class="slots-wrap">
              <div class="slots-head">
                <span>{squad.length} in the squad</span>
                <span class="slots-state" class:pending={pendingCount > 0}>{pendingCount > 0 ? `${pendingCount} invite${pendingCount === 1 ? '' : 's'} pending` : 'Everyone is ready'}</span>
              </div>
              <div class="slots">
                {#each slots as s}<i class={s}></i>{/each}
              </div>
            </div>

            {#if isHost}
              <form class="invite" on:submit|preventDefault={invite}>
                <input aria-label="Player name or server ID" placeholder="Player name or server ID" bind:value={inviteName} />
                <button type="submit" class="btn btn-primary"><Icon name="userPlus" size={15} /> Invite</button>
              </form>
            {/if}

            <div class="members">
              {#each squad as m (m.source)}
                <div class="member">
                  <div class="avatar" class:host={m.isHost}>
                    {#if m.isHost}<Icon name="crown" size={16} />{:else}{initials(m.name)}{/if}
                  </div>
                  <div class="member-info">
                    <div class="member-name">{m.name}</div>
                    <div class="member-role">{(m.isHost ? 'Squad leader' : 'Operative') + (m.ping != null ? ' · ' + m.ping + ' ms' : '')}</div>
                  </div>
                  <span class="status" class:ready={m.status !== 'pending'} class:pending={m.status === 'pending'}>{m.status === 'pending' ? 'Pending' : 'Ready'}</span>
                  {#if isHost && !m.isHost}
                    <button type="button" class="kick" aria-label={`Remove ${m.name}`} title="Remove from squad" on:click={() => kick(m.source)}><Icon name="close" size={12} /></button>
                  {/if}
                </div>
              {/each}
              {#if squad.length === 0}<div class="empty">Nobody in the squad yet — invite a player above.</div>{/if}
            </div>
          </div>
        </aside>
      </main>

      <footer class="footer">
        <div class="summary">
          <div><small>Area</small><strong>{selectedLocation?.label || '—'}</strong></div>
          <div><small>Weapon</small><strong class="accent">{selectedWeaponEntry?.label || '—'}</strong></div>
          <div><small>Squad</small><strong>{squad.length} of {MAX_SQUAD}</strong></div>
        </div>
        {#if isHost}
          <button type="button" class="btn btn-primary deploy" disabled={!selectedLocationId || !selectedWeapon} on:click={deploy}>
            <Icon name="play" size={16} /> Enter training area
          </button>
        {:else}
          <div class="waiting">Waiting for the squad leader to start…</div>
        {/if}
      </footer>
    </div>
  </div>
{/if}

<style>
  .overlay {
    position: absolute;
    inset: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(0, 0, 0, 0.62);
    z-index: 6000;
    pointer-events: all;
    font-family: var(--font-ui);
    font-variant-numeric: tabular-nums;

    --green: #46c98b;
    --amber: #ffc857;
    --red: #ff6b5e;
    --blue: var(--c-action);
    --line: var(--c-line);
    --card: var(--c-raised);
  }
  button { cursor: pointer; font-family: inherit; }
  h1, h2, p { margin: 0; }

  .shell {
    width: min(1240px, 94vw);
    max-height: min(820px, 92vh);
    display: flex;
    flex-direction: column;
    color: var(--c-text, #eceef0);
    background-color: #07090d;
    background-image:
      radial-gradient(ellipse 95% 65% at 50% 20%, rgba(65, 86, 111, 0.42) 0%, rgba(18, 25, 36, 0.74) 52%, rgba(6, 8, 12, 0.95) 100%),
      var(--tablet-bg-img, url('../../assets/tablet-bg.jpg'));
    background-size: cover;
    background-position: center;
    border: 1px solid var(--tablet-border-strong);
    border-radius: 16px;
    overflow: hidden;
    box-shadow: 0 24px 60px rgba(0, 0, 0, 0.65);
    animation: pop 0.16s ease-out both;
  }
  @keyframes pop {
    from { opacity: 0; transform: translateY(6px); }
    to { opacity: 1; transform: none; }
  }
  @media (prefers-reduced-motion: reduce) { .shell { animation: none; } }

  /* ── header ── */
  .topbar {
    flex: none;
    display: flex;
    align-items: center;
    gap: 14px;
    padding: 18px 24px;
    background: var(--c-base);
    border-bottom: 1px solid var(--line);
  }
  .mark {
    width: 44px; height: 44px; flex: none; display: grid; place-items: center; border-radius: 10px;
    color: var(--blue); background: var(--c-line); border: 1px solid var(--c-line);
  }
  .heading h1 {
    font-family: var(--font-display);
    font-stretch: var(--stretch-display);
    font-size: 28px; font-weight: 700; line-height: 1.05;
  }
  .heading p { margin-top: 3px; font-size: 14px; color: var(--c-text-3, #8d949c); }
  .close {
    margin-left: auto;
    display: inline-flex; align-items: center; gap: 8px;
    height: 36px; padding: 0 14px;
    color: var(--c-text-2, #c9ced4); font-size: 14px; font-weight: 600;
    background: var(--c-raised); border: 1px solid var(--line); border-radius: 9px;
    transition: border-color 0.15s, color 0.15s;
  }
  .close:hover { color: #fff; border-color: var(--c-action); }
  kbd {
    font: 600 12px var(--font-ui); padding: 2px 7px; border-radius: 5px;
    color: var(--c-text-2, #c9ced4); border: 1px solid var(--tablet-border-strong); background: var(--c-raised);
  }
  button:focus-visible, input:focus-visible { outline: 2px solid var(--blue); outline-offset: 2px; }

  .workspace {
    flex: 1;
    min-height: 0;
    display: grid;
    grid-template-columns: minmax(0, 1fr) 380px;
  }
  .left { min-width: 0; padding: 22px 24px 24px; overflow-y: auto; border-right: 1px solid var(--line); }
  .right { min-width: 0; display: flex; flex-direction: column; padding: 22px 22px 24px; background: var(--c-base); }
  .left { scrollbar-width: thin; scrollbar-color: var(--tablet-border-strong) transparent; }

  .section-head { display: flex; align-items: baseline; justify-content: space-between; margin-bottom: 12px; }
  .section-head h2 { font-family: var(--font-display); font-stretch: var(--stretch-display); font-size: 20px; font-weight: 600; }
  .section-meta { font-size: 13.5px; color: var(--c-text-3, #8d949c); }
  .weapon-head { margin-top: 26px; }

  /* ── training areas ── */
  .training-grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 10px; }
  .range {
    position: relative;
    display: flex; align-items: center; gap: 12px;
    min-height: 72px; padding: 12px 14px; text-align: left;
    color: inherit; background: var(--card); border: 1px solid var(--line); border-radius: 12px;
    transition: border-color 0.15s, background 0.15s;
  }
  .range:hover { border-color: var(--tablet-border-strong); background: var(--c-raised); }
  .range.active { border-color: var(--c-action); background: linear-gradient(90deg, var(--c-line), var(--c-raised)); }
  .pin {
    flex: none; width: 36px; height: 36px; display: grid; place-items: center; border-radius: 9px;
    background: var(--c-base); border: 1px solid var(--line);
  }
  .range-text { min-width: 0; display: flex; flex-direction: column; align-items: flex-start; gap: 5px; }
  .range-text strong { max-width: 100%; font-size: 16px; font-weight: 600; line-height: 1.2; color: #fff; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .chip { height: 20px; padding: 0 8px; display: inline-flex; align-items: center; border-radius: 6px; font-size: 12.5px; font-weight: 600; }
  .tick { position: absolute; top: 8px; right: 8px; width: 20px; height: 20px; display: grid; place-items: center; border-radius: 50%; color: #fff; background: var(--c-action); }

  .tone-blue { color: var(--blue); }
  .tone-amber { color: var(--amber); }
  .tone-red { color: var(--red); }
  .tone-green { color: var(--green); }
  .chip.tone-blue { background: var(--c-line); }
  .chip.tone-amber { background: rgba(255, 200, 87, 0.12); }
  .chip.tone-red { background: rgba(255, 107, 94, 0.12); }
  .chip.tone-green { background: rgba(70, 201, 139, 0.12); }

  /* ── weapons ── */
  .weapon-grid { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 10px; }
  .weapon {
    display: flex; flex-direction: column; align-items: flex-start; gap: 3px;
    padding: 12px 14px 13px; text-align: left; color: inherit;
    background: var(--card); border: 1px solid var(--line); border-radius: 12px;
    transition: border-color 0.15s, background 0.15s;
  }
  .weapon:hover { border-color: var(--tablet-border-strong); background: var(--c-raised); }
  .weapon.selected { border-color: var(--c-action); background: linear-gradient(90deg, var(--c-line), var(--c-raised)); }
  .gun {
    width: 100%; height: 52px; margin-bottom: 6px; display: grid; place-items: center; border-radius: 8px;
    color: var(--c-text-3, #8d949c); background: var(--c-base);
    transition: color 0.15s;
  }
  .gun svg { width: 72px; height: 28px; }
  .weapon:hover .gun { color: var(--c-text-2, #c9ced4); }
  .weapon.selected .gun { color: var(--blue); }
  .weapon strong { font-size: 15.5px; font-weight: 600; color: #fff; }
  .kind { font-size: 13px; color: var(--c-text-3, #8d949c); }
  .weapon.selected .kind { color: var(--blue); }

  /* ── squad ── */
  .count { display: inline-flex; align-items: center; gap: 8px; font-size: 13.5px; color: var(--c-text-2, #c9ced4); }
  .live-dot { width: 7px; height: 7px; border-radius: 50%; background: var(--green); }
  .squad {
    flex: 1; min-height: 0; display: flex; flex-direction: column; gap: 14px; padding: 14px;
    background: var(--card); border: 1px solid var(--line); border-radius: 12px;
  }
  .slots-head { display: flex; justify-content: space-between; margin-bottom: 8px; font-size: 13.5px; color: var(--c-text-3, #8d949c); }
  .slots-state { color: var(--green); font-weight: 600; }
  .slots-state.pending { color: var(--amber); }
  .slots { display: grid; grid-template-columns: repeat(8, 1fr); gap: 5px; }
  .slots i { height: 6px; border-radius: 3px; background: var(--c-raised); }
  .slots i.ready { background: var(--green); }
  .slots i.pending { background: var(--amber); }

  .invite { display: flex; gap: 8px; }
  .invite input {
    flex: 1; min-width: 0; height: 42px; padding: 0 14px;
    color: #fff; font: 500 14.5px var(--font-ui);
    background: var(--c-base); border: 1px solid var(--line); border-radius: 9px; outline: none;
  }
  .invite input:focus { border-color: var(--c-action); box-shadow: 0 0 0 2px var(--c-line); }
  .invite input::placeholder { color: var(--c-text-3, #8d949c); }
  .invite .btn { flex: none; min-height: 42px; padding: 0 16px; }

  .members { flex: 1; min-height: 0; display: flex; flex-direction: column; gap: 8px; overflow-y: auto; scrollbar-width: thin; scrollbar-color: var(--tablet-border-strong) transparent; }
  .member { display: flex; align-items: center; gap: 12px; min-height: 58px; padding: 8px 12px; background: var(--c-base); border: 1px solid var(--line); border-radius: 10px; }
  .avatar {
    flex: none; width: 38px; height: 38px; display: grid; place-items: center; border-radius: 50%;
    color: var(--c-text-2, #c9ced4); font-size: 13.5px; font-weight: 700;
    background: var(--c-raised); border: 1px solid var(--line);
  }
  .avatar.host { color: #f2c35b; background: rgba(242, 195, 91, 0.14); border-color: rgba(242, 195, 91, 0.4); }
  .member-info { flex: 1; min-width: 0; }
  .member-name { font-size: 15px; font-weight: 600; color: #fff; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .member-role { margin-top: 2px; font-size: 13px; color: var(--c-text-3, #8d949c); }
  .status { display: inline-flex; align-items: center; gap: 6px; height: 24px; padding: 0 10px; border-radius: 12px; font-size: 13px; font-weight: 600; }
  .status::before { content: ''; width: 6px; height: 6px; border-radius: 50%; background: currentColor; }
  .status.ready { color: var(--green); background: rgba(70, 201, 139, 0.12); }
  .status.pending { color: var(--amber); background: rgba(255, 200, 87, 0.12); }
  .kick {
    flex: none; width: 30px; height: 30px; display: grid; place-items: center; color: var(--red);
    background: transparent; border: 1px solid rgba(255, 107, 94, 0.4); border-radius: 8px;
    transition: background 0.15s, color 0.15s;
  }
  .kick:hover { background: var(--red); color: #160b0a; }
  .empty { display: grid; place-items: center; min-height: 72px; padding: 0 12px; text-align: center; font-size: 14px; color: var(--c-text-3, #8d949c); border: 1px dashed var(--line); border-radius: 10px; }

  /* ── footer ── */
  .footer {
    flex: none; display: flex; align-items: center; justify-content: space-between; gap: 24px;
    padding: 16px 24px; background: var(--c-base); border-top: 1px solid var(--line);
  }
  .summary { display: grid; grid-template-columns: repeat(3, minmax(130px, 230px)); gap: 28px; }
  .summary small { display: block; margin-bottom: 3px; font-size: 13px; color: var(--c-text-3, #8d949c); }
  .summary strong { font-size: 16.5px; font-weight: 600; color: #fff; }
  .summary .accent { color: var(--blue); }
  .deploy { min-height: 48px; padding: 0 28px; font-size: 16px; }
  .waiting { font-size: 14.5px; color: var(--c-text-2, #c9ced4); }

  @media (max-width: 1150px) {
    .weapon-grid { grid-template-columns: repeat(3, minmax(0, 1fr)); }
    .workspace { grid-template-columns: minmax(0, 1fr) 340px; }
  }
  @media (max-width: 900px) {
    .workspace { grid-template-columns: 1fr; overflow-y: auto; }
    .training-grid, .weapon-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  }

  /* ── flat, theme-driven (Black + White / Black + Blue / Black + Gold) ── */
  .shell { background: var(--c-panel); background-image: none; border: 1px solid var(--tablet-border-strong); border-radius: var(--r-panel); box-shadow: none; }
  .topbar, .footer { background: var(--c-base); }
  .right { background: var(--c-base); }
  .mark { border-radius: var(--r-ctl); color: var(--on-accent); background: var(--c-action); border-color: transparent; }
  .close { border-radius: var(--r-ctl); background: var(--c-raised); }
  .close:hover { color: var(--text-main); border-color: var(--tablet-border-hover); }
  kbd { border-radius: 4px; background: transparent; }
  .range, .weapon, .squad, .member, .empty { border-radius: var(--r-ctl); }
  .range, .weapon, .squad { background: var(--c-raised); }
  .range:hover, .weapon:hover { border-color: var(--tablet-border-hover); background: var(--c-hover); }
  .range.active, .weapon.selected { background: var(--c-action); border-color: var(--c-action); color: var(--on-accent); }
  .range.active .range-text strong, .weapon.selected strong { color: var(--on-accent); }
  .weapon.selected .kind, .weapon.selected .gun { color: var(--on-accent); }
  .pin, .gun { border-radius: var(--r-ctl); background: var(--c-base); }
  .weapon.selected .gun { background: transparent; }
  .tick { border-radius: 4px; color: var(--c-action); background: var(--on-accent); }
  .chip { border-radius: 4px; }
  .chip.tone-blue { color: #fff; background: #3b82f6; }
  .chip.tone-amber { color: #0a0a0a; background: #f59e0b; }
  .chip.tone-red { color: #fff; background: #ef4444; }
  .chip.tone-green { color: #0a0a0a; background: #22c55e; }
  .range.active .chip { outline: 1px solid var(--on-accent); }
  .status { border-radius: 4px; }
  .status.ready { color: #0a0a0a; background: #22c55e; }
  .status.pending { color: #0a0a0a; background: #f59e0b; }
  .slots i { border-radius: 2px; background: var(--c-line); }
  .invite input { border-radius: var(--r-ctl); background: var(--c-base); }
  .invite input:focus { border-color: var(--c-action); box-shadow: none; }
  .member { background: var(--c-base); }
  .avatar { border-radius: var(--r-ctl); }
  .avatar.host { color: #0a0a0a; background: #f2c35b; border-color: transparent; }
  .kick { border-radius: var(--r-ctl); color: #fff; background: #ef4444; border-color: #ef4444; }
  .kick:hover { background: #dc2626; color: #fff; }
  .live-dot { border-radius: 2px; }
</style>
