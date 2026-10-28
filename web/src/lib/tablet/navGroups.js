// The admin tablet's menu, grouped by what the admin is doing (overview / events / tournaments / territory / people &
// standings / setup; live operations sit on the Dashboard). Ids are unchanged — CreatorAccess.adminOnlyTabs in config.lua, the
// staff permission sections and the persisted currentView all key off them. Ordered by how often you reach for each during play.
// Shared by the tablet itself (floating top tabs, or the side rail) and the User Guide, so a new tab shows up in both.
//   title = the full name (side rail, guide)    short = the label on the floating tab    icon = the group's icon
export const NAV_GROUPS = [
  { title: 'Operations', short: 'Operations', icon: 'grid', color: '#5aa2f0', items: [
    { id: 'dashboard', label: 'Dashboard', icon: 'grid' },
  ] },
  { title: 'Event Management', short: 'Events', icon: 'list', color: '#2dd4bf', items: [
    { id: 'create',      label: 'Create Event',  icon: 'plus' },
    { id: 'convoys',     label: 'Manage Events', icon: 'list' },
    { id: 'participants', label: 'Active Participants', icon: 'person-group' },
    { id: 'savedroutes', label: 'Saved Routes',  icon: 'route' },
    { id: 'completed',   label: 'Event History', icon: 'history' },
  ] },
  { title: 'Tournaments', short: 'Tournaments', icon: 'crown', color: '#a78bfa', items: [
    { id: 'tournaments',       label: 'Tournaments',        icon: 'crown' },
    // its own page for the live tree; shown to whoever may see Tournaments (perm = the permission section it follows)
    { id: 'tournamenttree',    label: 'Tournament Tree',    icon: 'route', perm: 'tournaments' },
    { id: 'tournamenthistory', label: 'Tournament History', icon: 'fileText' },
  ] },
  // Territory: the Map Zone is the home of everything (map, painting price, hand over / delete, Gang XP); wars have their own
  // page; the auction results are the record of who won what ('territories' keeps its permission id).
  { title: 'Territory System', short: 'Territory', icon: 'pin', color: '#5fd38d', items: [
    // the Map Zone's own tabs are sub pages (the floating row under the bar): same view, a different 'sub'.
    // Ordered by how often an admin reaches for them: the map, live wars, the auction record, the logs and rankings, and the rarely
    // touched Painting Price last. Everything about ONE gang (members, territory, XP, notices, warnings, disband) is Community → Gang Management.
    { id: 'mapzone',           view: 'mapzone', sub: 'map',       label: 'Territory Map',        icon: 'pin',      perm: 'mapzone' },
    { id: 'rivals',      label: 'Rival Wars',      icon: 'crosshair' },
    { id: 'territories', label: 'Auction Results', icon: 'fileText' },
    { id: 'mapzone-xp',        view: 'mapzone', sub: 'xp',        label: 'XP Log',               icon: 'activity', perm: 'mapzone' },
    { id: 'mapzone-history',   view: 'mapzone', sub: 'history',   label: 'Ownership Log',        icon: 'history',  perm: 'mapzone' },
    { id: 'mapzone-board',     view: 'mapzone', sub: 'board',     label: 'XP Rankings',          icon: 'trophy',   perm: 'mapzone' },
    { id: 'mapzone-expansion', view: 'mapzone', sub: 'expansion', label: 'Painting Price',       icon: 'zap',      perm: 'mapzone' },
  ] },
  { title: 'Gangs & Community', short: 'Community', icon: 'shield', color: '#ff9f5a', items: [
    { id: 'gangs',        label: 'Gang Management',     icon: 'shield' },
  ] },
  { title: 'Leaderboards', short: 'Leaderboards', icon: 'trophy', color: '#f2c35b', items: [
    { id: 'leaderboard',         label: 'Gang Leaderboard',     icon: 'trophy' },
    { id: 'civilianleaderboard', label: 'Civilian Leaderboard', icon: 'medal' },
  ] },
  // Announcements, Staff and Settings are main tabs of their own. An item may name the page it opens (view) and a sub page of it (sub):
  // the three Announcements pages and World Peds are sub pages, shown as the floating row under the bar. 'perm' = the permission
  // section that decides who sees the item (default: its id).
  { title: 'Announcements', short: 'Announcements', icon: 'megaphone', color: '#f2a65a', items: [
    { id: 'announcements',         view: 'announcements', sub: 'events', label: 'Event Announcements', icon: 'calendar',  perm: 'announcements' },
    { id: 'announcements-custom',  view: 'announcements', sub: 'custom', label: 'Custom Announcement', icon: 'megaphone', perm: 'announcements' },
    { id: 'announcements-banners', view: 'announcements', sub: 'banners', label: 'Event Banner Images', icon: 'image',    perm: 'announcements' },
  ] },
  { title: 'Staff Management', short: 'Staff', icon: 'shield', color: '#9fb0c7', items: [
    // the three pages of Staff Management are sub pages (the floating row under the bar): same view, a different 'sub'
    { id: 'staff',          view: 'staff', sub: 'staff',    label: 'Staffs',   icon: 'users',   perm: 'staff' },
    { id: 'staff-roles',    view: 'staff', sub: 'roles',    label: 'Roles',    icon: 'shield',  perm: 'staff' },
    { id: 'staff-activity', view: 'staff', sub: 'activity', label: 'Activity', icon: 'history', perm: 'staff' },
  ] },
  { title: 'Settings', short: 'Settings', icon: 'gear', color: '#7bb6f2', items: [
    { id: 'settings',  view: 'settings', sub: 'general',   label: 'Preferences & server', icon: 'gear', perm: 'settings' },
    { id: 'worldpeds', view: 'settings', sub: 'worldpeds', label: 'World Peds',          icon: 'user', perm: 'worldpeds' },
  ] },
  { title: 'Help', short: 'Help', icon: 'fileText', color: '#7bb6f2', items: [
    // the guide's four categories are sub pages; Guide.svelte maps each to the category of docs/user_guide.md with that name
    { id: 'guide',           view: 'guide', sub: 'start-here', label: 'Start here', icon: 'grid',     perm: 'guide' },
    { id: 'guide-events',    view: 'guide', sub: 'events',     label: 'Events',     icon: 'flag',     perm: 'guide' },
    { id: 'guide-systems',   view: 'guide', sub: 'systems',    label: 'Systems',    icon: 'gear',     perm: 'guide' },
    { id: 'guide-reference', view: 'guide', sub: 'reference',  label: 'Reference',  icon: 'fileText', perm: 'guide' },
  ] },
];
