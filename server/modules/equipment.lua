-- ─── Nova Convoy — Police Equipment Vendor (server) ───────────────────────────
-- Server-side validation, fund deduction, and inventory delivery for tactical gear.

RegisterNetEvent('nova_convoytruck:equipment:server:purchase', function(itemIndex, account)
    local src = source
    if not Config.PoliceEquipment.enabled then return end
    -- Player-chosen payment method (client presents a Cash/Bank submenu) —
    -- previously hardcoded to Config.PoliceEquipment.moneyAccount, so an
    -- officer with the funds in the other account just got "insufficient
    -- funds" with no way to pay from where the money actually was.
    account = (account == 'bank' or account == 'cash') and account or Config.PoliceEquipment.moneyAccount

    if not Bridge.IsPolice(src) then
        TriggerClientEvent('nova_convoytruck:client:notify', src, 'You are not authorized to buy this.', 'error')
        return
    end

    if not Runtime.hasActiveConvoy() then
        TriggerClientEvent('nova_convoytruck:client:notify', src, 'No convoy is currently active — this is only available during a live event.', 'error')
        return
    end

    local item = Config.PoliceEquipment.items[itemIndex]
    if not item then return end

    local ok = Bridge.RemoveMoney(src, item.price, account)
    if not ok then
        TriggerClientEvent('nova_convoytruck:client:notify', src, ('Insufficient %s funds.'):format(account), 'error')
        return
    end

    local itemName = item.weapon:lower()
    local given = Inventory.AddItem(src, itemName, item.ammo or 1)
    if not given then
        Bridge.AddMoney(src, item.price, account) -- refund — the charge already went through above
        TriggerClientEvent('nova_convoytruck:client:notify', src, ('Could not give "%s" — item not found in your inventory system, refunded.'):format(itemName), 'error')
        return
    end
    TriggerClientEvent('nova_convoytruck:client:notify', src, ('Purchased %s.'):format(item.label), 'success')
end)
