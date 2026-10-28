// Inline stroke icons for the HUD cards (from the supplied HUD designs). These
// are fixed in-repo constants, never user input, so they are safe to render
// with {@html}. Stroke/size come from the parent (.hx-iconbox svg).
export const HUD_ICONS = {
  convoy: '<svg viewBox="0 0 24 24"><path d="M4 16h16"/><path d="M5 16v-5l2-3h8l3 3v5"/><path d="M18 11h2l1 2v3h-3"/><circle cx="8" cy="17" r="2"/><circle cx="18" cy="17" r="2"/></svg>',
  airdrop: '<svg viewBox="0 0 24 24"><path d="M6 4h12l-1 4H7L6 4z"/><path d="M8 8v8l4 4 4-4V8"/><path d="M10 12h4"/></svg>',
  hotcargo: '<svg viewBox="0 0 24 24"><path d="M5 8h14v11H5z"/><path d="M8 8V5h8v3"/><path d="M5 12h14"/><path d="M10 12v7"/></svg>',
  rally: '<svg viewBox="0 0 24 24"><path d="M4 16h16"/><path d="M6 16l1-6h10l1 6"/><circle cx="8" cy="18" r="1.5"/><circle cx="16" cy="18" r="1.5"/><path d="M8 10l2-3h4l2 3"/></svg>',
  containerwars: '<svg viewBox="0 0 24 24"><path d="M3 10h18v9H3z"/><path d="M7 10v9M11 10v9M15 10v9"/><path d="M19 10v9"/><path d="M12 3v4"/><path d="M9 7h6"/></svg>',
  territory: '<svg viewBox="0 0 24 24"><path d="M12 21s-6-5.2-6-10a6 6 0 0112 0c0 4.8-6 10-6 10z"/><path d="M12 8v5M9.5 10.5h5"/></svg>',
  rivals: '<svg viewBox="0 0 24 24"><path d="M4 4l7 7M20 4l-7 7"/><path d="M4 20l7-7M20 20l-7-7"/><path d="M9 15l-3 3M15 15l3 3"/></svg>',
  tdm: '<svg viewBox="0 0 24 24"><path d="M7 6h10v12H7z"/><path d="M4 9h3M17 9h3M4 15h3M17 15h3"/><path d="M10 10h4M10 14h4"/></svg>',
  police: '<svg viewBox="0 0 24 24"><path d="M4 10h16v9H4z"/><path d="M7 10l2-4h6l2 4"/><path d="M12 3v3"/><path d="M9 3h6"/></svg>',
  checkpoint: '<svg viewBox="0 0 24 24"><path d="M12 3l7 3v5c0 4.7-2.9 8.3-7 10-4.1-1.7-7-5.3-7-10V6l7-3z"/><path d="M9 12l2 2 4-4"/></svg>',
  success: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M8 12l2.5 2.5L16 9"/></svg>',
  danger: '<svg viewBox="0 0 24 24"><path d="M12 3l9 17H3L12 3z"/><path d="M12 9v5"/><path d="M12 17h.01"/></svg>',
  info: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M12 10v6"/><path d="M12 7h.01"/></svg>',
  truck: '<svg viewBox="0 0 24 24"><path d="M3 7h11v8H3V7zm11 3h4l3 3v2h-7v-5z"/><circle cx="6.5" cy="17.5" r="1.6"/><circle cx="17.5" cy="17.5" r="1.6"/></svg>',
};

export function hudIcon(name) {
  return HUD_ICONS[name] || HUD_ICONS.info;
}
