import { tick } from 'svelte';

// After a placement / recording session the tablet comes back on the same
// screen, but the new vector or ped can sit below the fold. Scrolls it into
// view and flashes it briefly so the admin sees where it landed without
// hunting for it. The short delay lets the tablet finish restoring first.
export function reveal(el) {
  if (!el) return;
  el.scrollIntoView({ behavior: 'smooth', block: 'center' });
  el.classList.add('reveal-flash');
  setTimeout(() => el.classList.remove('reveal-flash'), 2200);
}

export async function revealLast(selector) {
  await tick();
  await new Promise((r) => setTimeout(r, 150));
  const els = document.querySelectorAll(selector);
  reveal(els[els.length - 1]);
}
