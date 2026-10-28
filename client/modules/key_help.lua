-- ─── On-screen key help ──────────────────────────────────────────────────────
-- One layout for every placer / recorder legend, so they all read the same way:
--
--   **TITLE**   status
--   info line (coordinates, count, ...)
--
--   **Key**  what it does          <- one action per line, keys in bold
--   ...
--
--   **E / Enter**  Confirm         <- the last block is always "finish / cancel"
--   **Backspace / Esc**  Cancel
--
-- `sections` is a list of blocks, each a list of { keys, label } rows. Blocks are
-- separated by a blank line. ox_lib's text UI renders the markdown.

NovaConvoy = NovaConvoy or {}

function NovaConvoy.KeyHelp(title, sections, opts)
    opts = opts or {}
    local head = ('**%s**'):format(title)
    if opts.status then head = head .. ('   %s'):format(opts.status) end
    if opts.info then head = head .. '  \n' .. opts.info end

    local blocks = { head }
    for _, section in ipairs(sections or {}) do
        local lines = {}
        for _, row in ipairs(section) do
            lines[#lines + 1] = ('**%s**  %s'):format(row[1], row[2])
        end
        if #lines > 0 then blocks[#blocks + 1] = table.concat(lines, '  \n') end
    end
    return table.concat(blocks, '\n\n')
end

function NovaConvoy.ShowKeyHelp(title, sections, opts)
    opts = opts or {}
    lib.showTextUI(NovaConvoy.KeyHelp(title, sections, opts), {
        position = opts.position or 'right-center',
        icon = opts.icon,
    })
end

-- GetEntityModel can throw ("script error in native 9f47b058362c84b5") for an entity
-- that is being streamed out, even right after DoesEntityExist said yes. Every model
-- lookup in this resource goes through here so one bad handle can never kill a thread.
function NovaConvoy.SafeEntityModel(entity)
    if not entity or entity == 0 then return 0 end
    if not DoesEntityExist(entity) or GetEntityType(entity) == 0 then return 0 end   -- nothing, or fixed map geometry
    local ok, model = pcall(GetEntityModel, entity)
    return ok and model or 0
end
