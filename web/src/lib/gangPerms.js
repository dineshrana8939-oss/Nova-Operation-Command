// What a gang role can be allowed to do. ONE list, shared by the admin tablet's Gang Management and the gang's own Event Status
// panel, so the two can never offer different permissions. Only permissions the server really enforces (gang_service.lua).
export const GANG_PERMISSIONS = [
  { key: 'manageGang', label: 'Manage Gang', hint: 'Add and remove members, assign roles, edit role permissions and change the gang logo.' },
  { key: 'registerRoster', label: 'Register for Events', hint: 'Sign the gang up for events and edit its event roster.' },
];

// the role every member starts with: it cannot be renamed or deleted (the server refuses both too)
export const DEFAULT_GANG_ROLE = 'Member';
