<script>
  // The one heading used for every INTERNAL section of an event / route form ("Event Details", "Announcement", ...).
  // It is a strip with a blue accent edge: you can see where a section starts, what it is called, and that the fields
  // below it belong to it, until the next strip. Styles live in tablet-theme.css (.form-section-head).
  //   <FormSectionHead title="Event Details" hint="What players see in lists" />
  export let title = '';
  export let hint = '';
</script>

<div class="form-section-head" role="heading" aria-level="3">
  <span class="form-section-title">{title}</span>
  {#if hint}<span class="form-section-hint">{hint}</span>{/if}
  <slot />
</div>
