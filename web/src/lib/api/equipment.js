import { invoke } from './nui.js';

// The throwables shop ped (not a convoy checkpoint NPC) — location and
// on/off state are both admin-settable from the tablet instead of a fixed
// config.lua coordinate/flag.
export const getEquipmentVendorLocation = () => invoke('nova_convoytruck:getEquipmentVendorLocation');
// `placed` (optional): { x, y, z, heading } from the ped placement hologram; without it the server uses where the admin stands.
export const setEquipmentVendorLocation = (placed) => invoke('nova_convoytruck:setEquipmentVendorLocation', placed);
export const setEquipmentVendorEnabled = (enabled) => invoke('nova_convoytruck:setEquipmentVendorEnabled', enabled);

// The escort vehicle shop ped — same admin-movable/toggleable-live pattern.
export const getEscortShopLocation = () => invoke('nova_convoytruck:getEscortShopLocation');
export const setEscortShopLocation = (placed) => invoke('nova_convoytruck:setEscortShopLocation', placed);
// The rally Token Vendor ped (trade race tokens for a special vehicle).
export const getTokenVendorLocation = () => invoke('nova_convoytruck:tokenVendor:getLocation');
export const setTokenVendorLocation = (placed) => invoke('nova_convoytruck:setTokenVendorLocation', placed);
export const setTokenVendorEnabled = (enabled) => invoke('nova_convoytruck:setTokenVendorEnabled', enabled);
export const setEscortShopEnabled = (enabled) => invoke('nova_convoytruck:setEscortShopEnabled', enabled);
