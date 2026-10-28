-- Remembers the name of every command this resource registers (the client and the server each keep their own list), so the
-- User Guide can list commands that nobody has described in docs/user_guide.md yet. RegisterCommand is wrapped only inside this
-- resource's own Lua environment; nothing else on the server is affected.
NovaCommandNames = NovaCommandNames or {}

local nativeRegisterCommand = RegisterCommand
RegisterCommand = function(name, handler, restricted)
    if type(name) == 'string' then NovaCommandNames[#NovaCommandNames + 1] = name end
    return nativeRegisterCommand(name, handler, restricted)
end
