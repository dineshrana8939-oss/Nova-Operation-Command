-- ─── Nova Convoy — server compatibility check ─────────────────────────────────────────────────────────────────────
-- Says once at start which FXServer artifact and game build this server runs and warns about what the script needs. It changes nothing.
--   · Lua 5.4 (the manifest asks for lua54) needs artifact 4752 or later.
--   · The convoy trucks, airdrops, peds and props are created by the server: OneSync must be on.
--   · Props / vehicles of newer DLCs (the h4_ Cayo Perico props need game build 2189, the xm_ ones 2060) are optional: where the build does
--     not have one the script uses a fallback (Config.Territory.auction.projectorModelFallbacks for the auction projector).

CreateThread(function()
    Wait(4000)
    local version = GetConvar('version', '')
    local artifact = tonumber(version:match('v%d+%.%d+%.%d+%.(%d+)') or version:match('(%d%d%d%d+)'))
    local build = GetConvarInt('sv_enforceGameBuild', 0)
    local onesync = GetConvar('onesync', 'off')
    print(('^2[NovaConvoy]^0 FXServer artifact %s, game build %s, OneSync %s'):format(tostring(artifact or version), build > 0 and tostring(build) or 'default (not enforced)', onesync))
    if artifact and artifact < 4752 then
        print('^1[NovaConvoy] This artifact is older than 4752: Lua 5.4 (lua54) is not supported. Update the server artifact.^0')
    end
    if onesync == 'off' then
        print('^1[NovaConvoy] OneSync is off. Server-side vehicles, peds and props (convoy trucks, airdrops, the territory projector) need it: set onesync on.^0')
    end
    if build > 0 and build < 2189 then
        print(('^3[NovaConvoy] Game build %d is older than 2189: Cayo Perico (h4_) props are missing; fallbacks are used where the script has them.^0'):format(build))
    end
end)
