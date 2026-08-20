--[[
Actually power off Wi-Fi on PocketBook (koreader/koreader#12705).

Stock turnOffWifi() only calls NetDisconnect(), which drops the connection
but leaves the radio powered — the system status bar still shows Wi-Fi after
quitting KOReader and the battery drains overnight. Do the full teardown
instead: NetDisconnect() -> netagent net off -> WiFiPower(0)
-> netagent wifi off.

The final `netagent wifi off` matters on FW6, where WiFiPower(0) alone can
leave the radio up (reported by Mark31415 in issue #1); on FW7 (Era Lite)
WiFiPower(0) already triggers it, so there it's a harmless no-op.
--]]

local Device = require("device")
if not Device:isPocketBook() then return end

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local userpatch = require("userpatch")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")

-- ffi/inkview only exists on master; 2026.03 and older load the lib directly.
local ok, inkview = pcall(require, "ffi/inkview")
if not ok then
    require("ffi/inkview_h")
    inkview = require("ffi").load("inkview")
end

local NETAGENT = "/ebrmain/bin/netagent"

-- keepWifiAlive is a local inside the stock initNetworkManager; fish it out
-- so we unschedule the same closure the stock code schedules.
local keepWifiAlive = userpatch.getUpValue(NetworkMgr.turnOnWifi, "keepWifiAlive")

function NetworkMgr:turnOffWifi(complete_callback)
    if keepWifiAlive then
        UIManager:unschedule(keepWifiAlive)
    end

    inkview.NetDisconnect()
    local has_netagent = lfs.attributes(NETAGENT, "mode") == "file"
    if has_netagent then
        os.execute(NETAGENT .. " net off")
    end
    inkview.WiFiPower(0)
    if has_netagent then
        os.execute(NETAGENT .. " wifi off")
    end

    logger.info("wifi-off patch: radio powered down, QueryNetwork =",
        inkview.QueryNetwork())

    if complete_callback then
        complete_callback()
    end
end
