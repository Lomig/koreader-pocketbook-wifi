--[[
Connect to Wi-Fi on PocketBook without the system network dialog.

Stock turnOnWifi() calls NetConnect(NULL), which pops up the system dialog.
NetConnectSilent(NULL) connects without any UI, but only works while the
network agent is running — on a cold boot it returns NET_ABORTED (-12).
So: power the radio, try NetConnectSilent, and if that fails start the agent
with `netagent net on; netagent connect_silent`, retrying NetConnectSilent
while polling the connection state. Falls back to the stock dialog after
15 s, so nothing is lost when there's no known network around.

Tested on an Era (FW6). The netagent commands aren't documented anywhere;
they come from running strings(1) on the binary.
--]]

local Device = require("device")
if not Device:isPocketBook() then return end

local DataStorage = require("datastorage")
local ffi = require("ffi")
local C = ffi.C
local band = require("bit").band
local logger = require("logger")
local userpatch = require("userpatch")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")

-- ffi/inkview only exists on master; 2026.03 and older load the lib directly.
local has_wrapper, inkview = pcall(require, "ffi/inkview")
if not has_wrapper then
    require("ffi/inkview_h")
    inkview = ffi.load("inkview")
end

-- Not declared in KOReader's inkview_h.
pcall(ffi.cdef, [[
int NetConnectSilent(const char *name);
]])

local NETAGENT = "/ebrmain/bin/netagent"
local CONNECT_LOG = DataStorage:getDataDir() .. "/wifi-connect.log"
local POLL_SECONDS = 15

local keepWifiAlive = userpatch.getUpValue(NetworkMgr.turnOnWifi, "keepWifiAlive")
local orig_turnOnWifi = NetworkMgr.turnOnWifi

local function isNetworkUp()
    return band(inkview.QueryNetwork(), C.NET_CONNECTED) ~= 0
end

local function readConnectLog()
    local f = io.open(CONNECT_LOG, "r")
    if not f then return "" end
    local s = f:read("*a") or ""
    f:close()
    return s
end

function NetworkMgr:turnOnWifi(complete_callback, interactive)
    inkview.WiFiPower(1)

    local ok, status = pcall(function() return inkview.NetConnectSilent(nil) end)
    if ok and status == C.NET_OK then
        logger.info("wifi patch: NetConnectSilent OK")
        if keepWifiAlive then keepWifiAlive() end
        if complete_callback then complete_callback() end
        return
    end
    logger.info("wifi patch: NetConnectSilent status =", ok and status or status)

    -- The net-up commands can stay around as the resident agent process, so
    -- never read their stdout to EOF — that blocks forever and freezes the
    -- UI. Fire and forget, then poll.
    os.remove(CONNECT_LOG)
    os.execute("(" .. NETAGENT .. " net on; " .. NETAGENT .. " connect_silent) > '"
        .. CONNECT_LOG .. "' 2>&1 &")
    logger.info("wifi patch: netagent connect_silent spawned, polling")

    local iter = 0
    local function poll()
        iter = iter + 1
        if isNetworkUp() then
            logger.info("wifi patch: connected after ~", iter,
                "s; netagent said:", readConnectLog())
            if keepWifiAlive then keepWifiAlive() end
            if complete_callback then complete_callback() end
            return
        end
        local out = readConnectLog()
        if out:find("command not recognized", 1, true) then
            logger.info("wifi patch: connect_silent not supported:", out)
            orig_turnOnWifi(self, complete_callback, interactive)
            return
        end
        -- The agent should be up by now; NetConnectSilent returns instantly
        -- when it can't connect.
        if iter == 3 or iter == 7 or iter == 11 then
            local retry_ok, retry_status = pcall(function() return inkview.NetConnectSilent(nil) end)
            logger.info("wifi patch: NetConnectSilent retry status =",
                retry_ok and retry_status or retry_status)
            if retry_ok and retry_status == C.NET_OK then
                if keepWifiAlive then keepWifiAlive() end
                if complete_callback then complete_callback() end
                return
            end
        end
        if iter < POLL_SECONDS then
            UIManager:scheduleIn(1, poll)
        else
            local p = io.popen("timeout 5 " .. NETAGENT .. " status 2>&1")
            local agent_status = p and (p:read("*a") or "") or "(popen failed)"
            if p then p:close() end
            logger.info("wifi patch: silent connect timed out; QueryNetwork =",
                inkview.QueryNetwork(), "; netagent said:", out, "; status:", agent_status)
            orig_turnOnWifi(self, complete_callback, interactive)
        end
    end
    UIManager:scheduleIn(1, poll)
end
