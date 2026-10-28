# Addon Vehicles

Put a custom truck's model files directly in this resource — no separate
car-pack resource needed.

1. Drop the model's `.ytd`/`.yft` files into `stream/`. (Only `.ytd`/`.yft` —
   don't put other files in there, e.g. a README; the game engine tries to
   register everything under a folder literally named `stream/` as a
   streaming asset and logs a harmless-but-noisy warning for anything that
   isn't.)
2. Replace `data/vehicles.meta` and `data/carvariations.meta` **entirely**
   with the same-named files from your vehicle's own download — don't try
   to hand-edit or merge into the ones already there. Those two are only
   placeholders and aren't even wired up yet (see step 3); `data/carcols.meta`
   and `data/handling.meta` you can merge your vehicle's `<Item>` block(s)
   into directly, those work as shipped.
3. Open `fxmanifest.lua` and uncomment all four `data_file` lines
   (`VEHICLE_METADATA_FILE`, `VEHICLE_VARIATION_FILE`, `CARCOLS_FILE`,
   `HANDLING_FILE`) — all four are commented out on purpose until this step.
   `VEHICLE_METADATA_FILE`/`VEHICLE_VARIATION_FILE` specifically need real,
   correctly-formed files first: two attempts at an empty placeholder for
   those two threw a real "Failed to parse ... well-formed XML/PSO file"
   error on every server start. `CARCOLS_FILE`/`HANDLING_FILE` stay
   commented too even though they parse fine empty — ANY resource with a
   registered `data_file` forces a full content-manifest reload for every
   connected player whenever THIS RESOURCE restarts (looks like the whole
   server restarting from their side), so there's no reason to pay that on
   every routine restart before there's actually real vehicle content
   behind it.
4. Register the model in the Convoy Command Tablet's Trucks tab → Vehicle
   Catalog → Register New Model, using the exact spawn name declared in the
   vehicle's own `vehicles.meta`.

Vanilla GTA vehicles need none of this — just register the normal spawn name
(e.g. `packer`, `mule3`) in the Vehicle Catalog directly.
