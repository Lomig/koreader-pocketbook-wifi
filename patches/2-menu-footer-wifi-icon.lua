--[[
Show a Wi-Fi icon next to the clock/battery in the menu footer.

The state is checked whenever the footer is redrawn and reflects the actual
radio state: isWifiOn() on PocketBook only means "connected", so the radio
can still be on (and draining the battery) when it returns false. Hence the
extra IFF_UP check on the interface — which is called eth0 on PocketBook,
and disappears entirely when the radio is off.

The glyphs are the same ones the reader footer uses for its Wi-Fi item.
--]]

local Device = require("device")
if not Device:hasWifiToggle() then return end

local BD = require("ui/bidi")
local NetworkMgr = require("ui/network/manager")
local TouchMenu = require("ui/widget/touchmenu")
local band = require("bit").band
local userpatch = require("userpatch")

local WIFI_ON = "\u{ECA8}"
local WIFI_OFF = "\u{ECA9}"

local function interfaceIsUp()
    for _, ifname in ipairs({ "eth0", "wlan0" }) do
        local f = io.open("/sys/class/net/" .. ifname .. "/flags", "r")
        if f then
            local flags = tonumber(f:read("*l"))
            f:close()
            if flags and band(flags, 1) ~= 0 then
                return true
            end
        end
    end
    return false
end

-- Idempotent, so menus whose updateItems passes through two of our wrappers
-- (see below) don't get the icon twice.
local function decorate(tm)
    local txt = tm.time_info and tm.time_info.text
    if not txt or txt == "" then return end
    if txt:find(WIFI_ON, 1, true) or txt:find(WIFI_OFF, 1, true) then return end
    local symbol = (NetworkMgr:isWifiOn() or interfaceIsUp()) and WIFI_ON or WIFI_OFF
    tm.time_info:setText(BD.wrap(symbol) .. " " .. txt)
end

local function wrapUpdateItems()
    local inner = TouchMenu.updateItems
    if inner == TouchMenu._wifi_icon_wrapper then return end
    -- updateItems' signature differs across KOReader versions, forward
    -- everything.
    local function wrapper(self, ...)
        inner(self, ...)
        decorate(self)
    end
    TouchMenu._wifi_icon_wrapper = wrapper
    TouchMenu.updateItems = wrapper
end

wrapUpdateItems()

-- SimpleUI replaces updateItems for its quick-settings tab without chaining
-- to the original (and restores/reinstalls it across plugin teardowns), so
-- get back on top whenever the plugin loads. No-op if it isn't installed.
pcall(userpatch.registerPatchPluginFunc, "simpleui", wrapUpdateItems)
