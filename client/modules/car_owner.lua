-- ─── /carowner (client) ──────────────────────────────────────────────────────────────────────────
-- The admin's menu (ox_lib context menu): the Container Wars reward cars standing in the world. Pick one, type the
-- server ID of the player who won it, and the server makes them its owner (server/modules/car_owner.lua).

local MENU_ID = 'nova_convoytruck_carowner'

local function askForPlayer(car, reopen)
    local input = lib.inputDialog(('Give the %s'):format(car.label), {
        {
            type = 'number', label = 'Player server ID', icon = 'user', required = true, min = 1,
            description = car.winningBidder and ('Winning bidder of this container: %s'):format(car.winningBidder) or ('Plate %s'):format(car.plate),
        },
    })
    if not input or not input[1] then
        reopen()
        return
    end
    TriggerServerEvent('nova_convoytruck:carowner:transfer', car.id, math.floor(input[1]))
end

local function openMenu(cars)
    cars = cars or {}
    local options = {}

    local function reopen() openMenu(cars) end

    if #cars == 0 then
        options[1] = {
            title = 'No reward cars right now',
            description = 'Cars show up here when a container reward is set to "Spawn at container" and the winner opens the container.',
            icon = 'car', disabled = true,
        }
    end

    for _, car in ipairs(cars) do
        local handed = car.ownerName ~= nil
        local lines = { ('Plate %s · %s'):format(car.plate, car.eventName or 'Container Wars') }
        if handed then
            lines[#lines + 1] = ('Already given to %s'):format(car.ownerName)
        elseif car.winningBidder then
            lines[#lines + 1] = ('Winning bidder: %s'):format(car.winningBidder)
        end
        options[#options + 1] = {
            title = ('%s  (%s)'):format(car.label, car.model),
            description = table.concat(lines, '\n'),
            icon = handed and 'check' or 'car',
            iconColor = handed and '#52d24a' or nil,
            disabled = handed,
            metadata = {
                { label = 'Plate', value = car.plate },
                { label = 'Event', value = car.eventName or '—' },
                { label = 'Container', value = car.containerName or '—' },
                { label = 'Winning bidder', value = car.winningBidder or '—' },
                { label = 'Opened by (has the keys)', value = car.keyHolderName or '—' },
            },
            onSelect = function() askForPlayer(car, reopen) end,
        }
    end

    lib.registerContext({ id = MENU_ID, title = 'Container Wars — give a car to its winner', options = options })
    lib.showContext(MENU_ID)
end

RegisterNetEvent('nova_convoytruck:carowner:open', openMenu)
