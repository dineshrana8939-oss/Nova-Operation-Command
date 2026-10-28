<script>
  // Pure renderer — used by the live in-game crosshair and the panel preview.
  export let cfg;
  export let kick = 0; // extra gap (px) while firing

  $: t = cfg.thickness;
  $: s = cfg.size;
  $: g = cfg.gap + kick;
  $: op = cfg.opacity / 100;
  const VIEW = 90;
</script>

<svg width={VIEW * 2} height={VIEW * 2} viewBox="{-VIEW} {-VIEW} {VIEW * 2} {VIEW * 2}" style="opacity:{op}" aria-hidden="true">
  {#each [true, false] as isOutline}
    {@const e = isOutline ? 1 : 0}
    {@const fill = isOutline ? '#000' : cfg.color}
    {@const sw = t + (isOutline ? 2 : 0)}
    {#if !isOutline || cfg.outline}
      {#if cfg.shape === 'cross' || cfg.shape === 'tshape'}
        {#if cfg.shape === 'cross'}<rect x={-t / 2 - e} y={-(g + s) - e} width={t + 2 * e} height={s + 2 * e} {fill} />{/if}
        <rect x={-t / 2 - e} y={g - e} width={t + 2 * e} height={s + 2 * e} {fill} />
        <rect x={-(g + s) - e} y={-t / 2 - e} width={s + 2 * e} height={t + 2 * e} {fill} />
        <rect x={g - e} y={-t / 2 - e} width={s + 2 * e} height={t + 2 * e} {fill} />
      {:else if cfg.shape === 'dot'}
        <circle r={Math.max(s / 3, t) + e} {fill} />
      {:else if cfg.shape === 'circle'}
        <circle r={s + g / 2} fill="none" stroke={fill} stroke-width={sw} />
      {:else if cfg.shape === 'diamond'}
        <polygon points="0,{-(s + g / 2)} {s + g / 2},0 0,{s + g / 2} {-(s + g / 2)},0" fill="none" stroke={fill} stroke-width={sw} stroke-linejoin="miter" />
      {:else if cfg.shape === 'chevron'}
        <polyline points="{-s},{g + s} 0,{g} {s},{g + s}" fill="none" stroke={fill} stroke-width={sw} stroke-linejoin="miter" stroke-linecap="butt" />
      {/if}
    {/if}
  {/each}

  {#if cfg.centerDot && cfg.shape !== 'dot'}
    {#if cfg.outline}<circle r={cfg.dotSize / 2 + 1} fill="#000" />{/if}
    <circle r={cfg.dotSize / 2} fill={cfg.color} />
  {/if}
</svg>
