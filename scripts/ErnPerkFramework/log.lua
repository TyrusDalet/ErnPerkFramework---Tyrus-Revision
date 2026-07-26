--[[
ErnPerkFramework for OpenMW.
Copyright (C) 2025 Erin Pentecost
2026 Robbie Barker

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
]]
local settings = require("scripts.ErnPerkFramework.settings")

local lastLoggedMessageCategory = nil

--- Returns the active debug verbosity.
--- `enableLogging` is kept as a legacy fallback for existing saves/configs.
--- @return number verbosity 0 off, 1 important, 2 detailed, 3 trace.
local function configuredVerbosity()
    local verbosity = 0
    local ok, value = pcall(function()
        return settings.debugVerbosity
    end)
    if ok then
        verbosity = tonumber(value) or 0
    end
    if verbosity <= 0 then
        local legacyOK, legacyEnabled = pcall(function()
            return settings.enableLogging
        end)
        if legacyOK and legacyEnabled then
            verbosity = 1
        end
    end
    return verbosity
end

--- Normalizes old and new logging signatures.
--- Supported forms:
---   log(category, message)           -> level 1
---   log(level, category, message)    -> explicit level
local function normalizeArgs(a, b, c)
    if type(a) == "number" then
        return a, b, c
    end
    return 1, a, b
end

local function Log(a, b, c)
    local level, category, message = normalizeArgs(a, b, c)
    if configuredVerbosity() < level then
        return
    end
    if (category ~= nil) and (lastLoggedMessageCategory == category) then
        return
    end
    if type(message) == "function" then
        print(message())
    else
        print(message)
    end
    lastLoggedMessageCategory = category
end

return Log
