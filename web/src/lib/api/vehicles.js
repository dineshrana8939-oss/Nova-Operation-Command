import { invoke, fetchNui } from './nui.js';

export const getVehicleCatalog = () => invoke('nova_convoytruck:getVehicleCatalog');
export const addVehicleCatalogEntry = (model, label, category, imageUrl) =>
  invoke('nova_convoytruck:addVehicleCatalogEntry', model, label, category, imageUrl);
export const deleteVehicleCatalogEntry = (id) => invoke('nova_convoytruck:deleteVehicleCatalogEntry', id);

// Client-side only check (streamed model data isn't available server-side).
export const validateModel = (model) => fetchNui('validateModel', { model });
