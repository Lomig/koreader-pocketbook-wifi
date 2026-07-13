--[[
Cycle Wi-Fi around BookOrbit's automatic syncs on devices without a Wi-Fi
manager (e.g. PocketBook): bring the network up when a sync needs it, drop
it again once the sync settles.

The plugin already turns Wi-Fi off after suspend syncs, but only on
hasWifiManager devices. So: whenever a sync brought Wi-Fi up on its own
account, run NetworkMgr:afterWifiAction() once the work is done — that keeps
the "Action when done with Wi-Fi" setting in charge of what happens. Wi-Fi
that was already on when the sync started is left alone, and the periodic
every-N-pages push keeps its stock behavior (passive while offline; the
suspend sync picks the stats up).

The plugin's "skip sync when offline" option is also relaxed here: with this
patch installed, being offline is not a reason to skip — the sync brings
Wi-Fi up itself.
--]]

local Device = require("device")
if Device:hasWifiManager() or not Device:hasWifiToggle() then return end

local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local userpatch = require("userpatch")

local SETTLE_SECONDS = 8

-- Points at the current plugin instance's cycle reset; see the turnOffWifi
-- hook below.
local clear_cycle

userpatch.registerPatchPluginFunc("bookorbit", function(plugin)
    local cycle_active = false

    local off_task
    off_task = function()
        -- Book snapshot and sweep jobs are async and may still be running,
        -- and a connection attempt may still be in flight.
        if (plugin.getSyncCoordinator and plugin:getSyncCoordinator():isBusy())
                or NetworkMgr.pending_connection then
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

    -- cycle_active means "the current wifi session was started by a sync".
    -- A failed connection attempt would leave it set with no completion to
    -- consume it, and the next sync completing during a wifi session the
    -- user started would then wrongly power the radio down. Every radio-off
    -- path funnels through turnOffWifi, so reset the flag there: after that,
    -- a set flag can only refer to the session it was set for. Hooked once,
    -- after all userpatches have loaded (this runs at plugin instantiation),
    -- so we wrap the fixed turnOffWifi rather than the stock one.
    clear_cycle = function()
        cycle_active = false
        UIManager:unschedule(off_task)
    end
    if not NetworkMgr._bookorbit_cycle_hooked then
        NetworkMgr._bookorbit_cycle_hooked = true
        local orig_turnOffWifi = NetworkMgr.turnOffWifi
        NetworkMgr.turnOffWifi = function(self, ...)
            if clear_cycle then clear_cycle() end
            return orig_turnOffWifi(self, ...)
        end
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

    -- The full library sweep ("sync all books") also brings Wi-Fi up through
    -- willRerunWhenOnline, with no turn-off of its own. Its completion isn't
    -- reachable from here, so lean on off_task's isBusy() polling: schedule
    -- the drop now, it keeps rescheduling itself until the sweep is done.
    local orig_sweep = plugin.requestSweep
    if type(orig_sweep) == "function" then
        plugin.requestSweep = function(self, ...)
            logger.info("bookorbit wifi patch: sweep requested; wifiOn =",
                NetworkMgr:isWifiOn(), "connected =", NetworkMgr:isConnected(),
                "online =", NetworkMgr:isOnline())
            if not NetworkMgr:isConnected() then
                cycle_active = true
            end
            if cycle_active then
                scheduleOff()
            end
            return orig_sweep(self, ...)
        end
    end

    -- skip_sync_when_offline makes _onSuspend/_onResume bail out before they
    -- can bring Wi-Fi up — self-defeating with this patch installed, since
    -- bringing Wi-Fi up for a sync is its whole point. Let the syncs proceed;
    -- the silent-connect patch gives up quietly when no known network is
    -- around, so nothing nags on the beach. Login is still checked before
    -- this in _onSuspend, so we only relax the offline gate.
    if type(plugin.shouldSkipAutoSyncOffline) == "function" then
        plugin.shouldSkipAutoSyncOffline = function(_self, event)
            logger.info("bookorbit wifi patch: not skipping offline sync for", event)
            return false
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

    logger.dbg("bookorbit wifi patch applied")
end)
