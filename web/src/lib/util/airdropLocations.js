// Predefined pool of 25 accessible San Andreas outdoor locations for GANG_AIRDROP supply drops.
// These locations provide varied terrain across the map and prevent camping fixed coordinates.
export const PREDEFINED_AIRDROP_LOCATIONS = [
  { id: 'loc_1', label: 'Sandy Shores Airfield Hangar', name: 'Sandy Shores Airfield', x: 1733.24, y: 3307.72, z: 41.22, area: 'Sandy Shores' },
  { id: 'loc_2', label: 'Grapeseed Grain Silos', name: 'Grapeseed Farms', x: 2443.15, y: 4976.22, z: 46.56, area: 'Grapeseed' },
  { id: 'loc_3', label: 'Grand Senora Desert Oil Pumps', name: 'Grand Senora Desert', x: 606.32, y: 2858.45, z: 39.95, area: 'Grand Senora Desert' },
  { id: 'loc_4', label: 'Mount Chiliad Trail Foothills', name: 'Mount Chiliad Foothills', x: -771.55, y: 5598.12, z: 33.48, area: 'Mount Chiliad' },
  { id: 'loc_5', label: 'Paleto Bay Lumber Yard', name: 'Paleto Bay Sawmill', x: -551.98, y: 5326.11, z: 73.60, area: 'Paleto Bay' },
  { id: 'loc_6', label: 'Lago Zancudo Wetlands', name: 'Lago Zancudo Marsh', x: -2286.14, y: 2521.88, z: 3.42, area: 'Lago Zancudo' },
  { id: 'loc_7', label: 'Tataviam Reservoir Hillside', name: 'Tataviam Mountains', x: 1985.44, y: 533.82, z: 161.02, area: 'Tataviam Mountains' },
  { id: 'loc_8', label: 'Cypress Flats Freight Depot', name: 'Cypress Flats Rail Yard', x: 987.32, y: -2125.41, z: 30.48, area: 'Cypress Flats' },
  { id: 'loc_9', label: 'Murrieta Oil Field Pumps', name: 'Murrieta Oil Fields', x: 1560.12, y: -1802.77, z: 88.54, area: 'Murrieta Heights' },
  { id: 'loc_10', label: 'Elysian Island Cargo Pier', name: 'Elysian Island Docks', x: 142.18, y: -2900.56, z: 5.90, area: 'Elysian Island' },
  { id: 'loc_11', label: 'LSIA South Perimeter Fence', name: 'LSIA Runway Perimeter', x: -982.41, y: -2995.12, z: 13.95, area: 'Los Santos Airport' },
  { id: 'loc_12', label: 'Terminal Island Dry Docks', name: 'Terminal Industrial Basin', x: 1134.62, y: -3194.22, z: 5.90, area: 'Terminal' },
  { id: 'loc_13', label: 'Palmer-Taylor Power Substation', name: 'Palmer-Taylor Power Station', x: 2695.88, y: 1662.34, z: 24.52, area: 'Palmer-Taylor' },
  { id: 'loc_14', label: 'Redwood Lights Dirt Track', name: 'Redwood Lights Construction', x: 893.22, y: 2073.44, z: 53.60, area: 'Redwood Lights' },
  { id: 'loc_15', label: 'Davis Quartz Stone Quarry', name: 'Davis Quartz Quarry', x: 2954.12, y: 2788.65, z: 39.12, area: 'Davis Quartz' },
  { id: 'loc_16', label: 'Alamo Sea North Beach', name: 'Alamo Sea Shoreline', x: 1325.45, y: 4310.88, z: 38.15, area: 'Alamo Sea' },
  { id: 'loc_17', label: 'Mount Josiah River Valley', name: 'Mount Josiah Valley', x: -1108.32, y: 2694.15, z: 19.82, area: 'Mount Josiah' },
  { id: 'loc_18', label: 'Tongva Valley Vineyard Slopes', name: 'Tongva Valley Hills', x: -1475.22, y: 1502.88, z: 114.25, area: 'Tongva Hills' },
  { id: 'loc_19', label: 'Banham Canyon Coastal Overlook', name: 'Banham Canyon Clearing', x: -2180.45, y: -395.12, z: 13.20, area: 'Banham Canyon' },
  { id: 'loc_20', label: 'Land Act Dam Overlook Ridge', name: 'Land Act Dam Spillway', x: 1654.88, y: 19.45, z: 167.35, area: 'Land Act Reservoir' },
  { id: 'loc_21', label: 'El Burro Heights Scrap Field', name: 'El Burro Scrap Yard', x: 1390.22, y: -2065.77, z: 52.00, area: 'El Burro Heights' },
  { id: 'loc_22', label: 'Paleto Forest Mountain Trail', name: 'Paleto Forest Clearing', x: -415.65, y: 6325.12, z: 12.45, area: 'Paleto Forest' },
  { id: 'loc_23', label: 'Mount Gordo Ridge Clearing', name: 'Mount Gordo Ridge', x: 2110.35, y: 4775.22, z: 41.20, area: 'Mount Gordo' },
  { id: 'loc_24', label: 'San Chianski Beach Cove', name: 'San Chianski Mountain Pass', x: 3325.12, y: 5160.88, z: 18.42, area: 'San Chianski' },
  { id: 'loc_25', label: 'Chumash Coastal Highway Bluff', name: 'Chumash Coastal Bluff', x: -3150.22, y: 1115.45, z: 20.65, area: 'Chumash' },
];

/**
 * Randomly samples `count` distinct locations from the predefined pool.
 * Accepts an optional `customPool` (e.g. from Config.Airdrop via bootstrap).
 */
export function sampleAirdropLocations(count, customPool = null) {
  const n = Math.max(1, Number(count) || 1);
  const source = Array.isArray(customPool) && customPool.length > 0 ? customPool : PREDEFINED_AIRDROP_LOCATIONS;
  const pool = [...source];

  // Fisher-Yates shuffle
  for (let i = pool.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [pool[i], pool[j]] = [pool[j], pool[i]];
  }

  const result = [];
  for (let i = 0; i < n; i++) {
    if (i < pool.length) {
      result.push(pool[i]);
    } else {
      // If user requested more than pool length, wrap around with small jitter
      const base = pool[i % pool.length];
      const jitterX = (Math.random() - 0.5) * 40;
      const jitterY = (Math.random() - 0.5) * 40;
      result.push({
        ...base,
        id: `${base.id}_extra_${i}`,
        x: Math.round((base.x + jitterX) * 100) / 100,
        y: Math.round((base.y + jitterY) * 100) / 100,
        name: `${base.name} #${i + 1}`,
      });
    }
  }

  return result;
}
