-- ─── Reward announcement (client) ─────────────────────────────────────────────
-- The single receiver for the personal "you were paid" card. The server
-- (RewardService.Announce) sends it to ONLY the player who received the
-- reward, for every event type; this just hands it to the NUI, which queues and
-- draws it (web/src/lib/hud/RewardAnnouncement.svelte).

RegisterNetEvent('nova_convoytruck:client:rewardAnnouncement', function(card)
    if type(card) ~= 'table' or type(card.rewards) ~= 'table' or #card.rewards == 0 then return end
    SendNUIMessage({ action = 'rewardAnnouncement', card = card })
    NovaSound.route('reward')
end)
