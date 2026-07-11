--[[
Cycle Wi-Fi around BookOrbit's automatic syncs on devices without a Wi-Fi
manager (e.g. PocketBook): bring the network up when a sync needs it, drop
it again once the sync settles.

The plugin already turns Wi-Fi off after suspend syncs, but only on
hasWifiManager devices, and its periodic every-N-pages push deliberately does
nothing while offline. So: make the periodic push request networking like the
lifecycle syncs do, and whenever a sync brought Wi-Fi up on its own account,
run NetworkMgr:afterWifiAction() a few seconds after the work is done — that
keeps the "Action when done with Wi-Fi" setting in charge of what happens.
Wi-Fi that was already on when the sync started is left alone.
--]]

local Device = require("device")
if Device:hasWifiManager() or not Device:hasWifiToggle() then return end

local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local userpatch = require("userpatch")

local SETTLE_SECONDS = 8

userpatch.registerPatchPluginFunc("bookorbit", function(plugin)
    local cycle_active = false

    local off_task
    off_task = function()
        -- Book snapshot jobs are async and may still be running.
        if plugin.getSyncCoordinator and plugin:getSyncCoordinator():isBusy() then
            UIManager:scheduleIn(SETTLE_SECONDS, off_task)
            return
        end
        cycle_active = false
        if NetworkMgr:isWifiOn() then
            logger.info("bookorbit wifi patch: sync settled, running afterWifiAction")
            NetworkMgr:afterWifiAction()
        end
    end

    local function scheduleOff()
        UIManager:unschedule(off_task)
        UIManager:scheduleIn(SETTLE_SECONDS, off_task)
    end

    -- updateProgress/getProgress defer themselves through willRerunWhenOnline
    -- while the network is down and rerun once connected, so they pass
    -- through here twice: once deferring (that's when Wi-Fi comes up on our
    -- account), once doing the actual request.
    local function wrapProgressCall(name)
        local orig = plugin[name]
        if type(orig) ~= "function" then return end
        plugin[name] = function(self, ensure_networking, ...)
            local deferring = ensure_networking and not NetworkMgr:isConnected()
            if deferring then
                cycle_active = true
            end
            UIManager:unschedule(off_task)
            orig(self, ensure_networking, ...)
            if cycle_active and not deferring then
                scheduleOff()
            end
        end
    end
    wrapProgressCall("updateProgress")
    wrapProgressCall("getProgress")

    -- Book snapshot syncs (suspend/close) report completion via on_finish —
    -- where the plugin only wires its Wi-Fi-off on hasWifiManager devices.
    local orig_snapshot = plugin.requestBookSnapshotSync
    if type(orig_snapshot) == "function" then
        plugin.requestBookSnapshotSync = function(self, opts)
            opts = opts or {}
            if (opts.ensure_networking or opts.go_online) and not NetworkMgr:isConnected() then
                cycle_active = true
            end
            if cycle_active then
                local prev_on_finish = opts.on_finish
                -- The device can enter standby right after a suspend sync, so
                -- a delayed turn-off may never run and the radio would stay
                -- on for the whole night. Turn it off right away there.
                local immediate = opts.reason == "suspend"
                opts.on_finish = function()
                    if prev_on_finish then pcall(prev_on_finish) end
                    if immediate then
                        UIManager:unschedule(off_task)
                        cycle_active = false
                        if NetworkMgr:isWifiOn() then
                            logger.info("bookorbit wifi patch: suspend sync done, dropping wifi")
                            NetworkMgr:afterWifiAction()
                        end
                    else
                        scheduleOff()
                    end
                end
            end
            return orig_snapshot(self, opts)
        end
    end

    -- BookOrbit reads page stats from statistics.sqlite3, but on suspend it
    -- can capture before the statistics plugin has flushed the current
    -- session to disk, so the snapshot comes out empty (pageStats=0). Flush
    -- statistics first. On close ReaderUI flushes everything beforehand, so
    -- only the suspend path needs this.
    local orig_suspend = plugin._onSuspend
    if type(orig_suspend) == "function" then
        local function suspendWithFlush(self, ...)
            local stats = self.ui and self.ui.statistics
            if stats and stats.insertDB then
                pcall(stats.insertDB, stats)
            end
            return orig_suspend(self, ...)
        end
        plugin._onSuspend = suspendWithFlush
        if plugin.onSuspend == orig_suspend then
            plugin.onSuspend = suspendWithFlush
        end
    end

    -- The stock periodic push relies on the connection being already up and
    -- silently does nothing offline.
    plugin.periodic_push_task = function()
        plugin.periodic_push_scheduled = false
        plugin.page_update_counter = 0
        if plugin.settings.auto_sync and (plugin.settings.pages_before_update or 0) > 0 then
            plugin:requestProgressPush(true, false, "periodic")
        end
    end

    logger.dbg("bookorbit wifi patch applied")
end)
