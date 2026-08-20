--[[
Cycle Wi-Fi around BookOrbit's automatic syncs on devices without a Wi-Fi
manager (e.g. PocketBook): bring the network up when a sync needs it, drop
it again once the sync settles.

Since the plugin's lifecycle-outbox rework (2026-08-06), put-away snapshots
(suspend/close) are enqueued to a persistent outbox and drained through
requestLifecycleOutboxDrain(). The drain only connects for interactive
(manual) syncs; background drains return quietly while offline and wait for
the next NetworkConnected event. So: when a put-away drain finds the network
down, bring Wi-Fi up on the sync's account — the plugin's own
_onNetworkConnected() then drains the outbox — and run
NetworkMgr:afterWifiAction() once the work settles, keeping the "Action when
done with Wi-Fi" setting in charge. Wi-Fi that was already on when the sync
started is left alone.

Pull syncs (opening a book, resuming) still run only when Wi-Fi is already
on, so opening a book stays silent and connection-free.

Note on devices where the firmware owns the sleep (no KOReader-controlled
suspend, e.g. Era Lite): the device can freeze mid-connect right after the
power press. The connect then completes on the next wake-up and the outbox
drains there — progress reaches the server at wake instead of at sleep, and
the settle logic still powers the radio down afterwards.

This replaces the plugin's "skip sync when offline" option for put-away
syncs, which no longer matters with this patch installed.
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
    -- cycle_source: which event started the current sync-owned wifi session
    -- ("suspend" cycles get the fast settle, see settleSeconds()).
    local cycle_source

    local function coordinatorBusy()
        if not plugin.getSyncCoordinator then return false end
        local ok, coord = pcall(plugin.getSyncCoordinator, plugin)
        if not ok or not coord then return false end
        if coord.isBusy then return coord:isBusy() end
        if coord.status then
            local ok_s, status = pcall(coord.status, coord)
            return ok_s and status and (status.pending_count or 0) > 0
        end
        return false
    end

    -- On suspend the firmware can deep-freeze the process a few seconds
    -- after the last activity, so the drop must beat that window or the
    -- radio stays on for the whole night; elsewhere a longer settle avoids
    -- flapping the radio between back-to-back jobs.
    local function settleSeconds()
        return cycle_source == "suspend" and 2 or SETTLE_SECONDS
    end

    local off_task
    off_task = function()
        -- Outbox jobs are async and may still be running, and a connection
        -- attempt may still be in flight.
        if coordinatorBusy() or NetworkMgr.pending_connection then
            UIManager:scheduleIn(settleSeconds(), off_task)
            return
        end
        cycle_active = false
        cycle_source = nil
        if NetworkMgr:isWifiOn() then
            logger.info("bookorbit wifi patch: sync settled, running afterWifiAction")
            NetworkMgr:afterWifiAction()
        end
    end

    local function scheduleOff()
        UIManager:unschedule(off_task)
        UIManager:scheduleIn(settleSeconds(), off_task)
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
        cycle_source = nil
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

    -- The outbox drain: put-away sources are worth a connection — that's
    -- when saving progress matters, and turning the radio off again is
    -- deterministic (handled above). Everything else keeps the plugin's
    -- stock behavior (interactive drains connect via willRerunWhenConnected;
    -- background drains stay passive while offline).
    local CONNECTING_SOURCES = {
        suspend = true, -- cover closed / standby
        close = true,   -- book closed (exit to library)
    }
    local orig_drain = plugin.requestLifecycleOutboxDrain
    if type(orig_drain) == "function" then
        plugin.requestLifecycleOutboxDrain = function(self, source, interactive, ...)
            if CONNECTING_SOURCES[source] and not interactive
                    and not NetworkMgr:isConnected() then
                logger.info("bookorbit wifi patch: bringing wifi up for", source, "drain")
                cycle_active = true
                cycle_source = source
                scheduleOff()
                -- When the connection lands, the plugin's _onNetworkConnected
                -- drains the outbox; the drain below just records the entry.
                NetworkMgr:beforeWifiAction()
            elseif cycle_active then
                scheduleOff()
            end
            return orig_drain(self, source, interactive, ...)
        end
    else
        logger.warn("bookorbit wifi patch: requestLifecycleOutboxDrain missing, patch inactive")
    end

    -- The device can enter standby right after a suspend sync, so a delayed
    -- turn-off may never run and the radio would stay on for the whole
    -- night. Drop Wi-Fi right away when the last outbox entry of a
    -- suspend-started cycle finishes; while entries remain, let the chained
    -- drains keep going.
    local orig_submit = plugin.submitSyncJob
    if type(orig_submit) == "function" then
        plugin.submitSyncJob = function(self, job, ...)
            if type(job) == "table" and job.family == "lifecycle_outbox"
                    and cycle_active and cycle_source == "suspend" then
                local prev_on_finish = job.on_finish
                job.on_finish = function(...)
                    if prev_on_finish then pcall(prev_on_finish, ...) end
                    -- Re-check quickly: off_task drops the radio as soon as
                    -- the coordinator is idle, and keeps waiting while more
                    -- outbox entries are still draining.
                    UIManager:unschedule(off_task)
                    UIManager:scheduleIn(1, off_task)
                end
            end
            return orig_submit(self, job, ...)
        end
    end

    -- The full library sweep ("sync all books") also brings Wi-Fi up through
    -- its interactive path, with no turn-off of its own. Its completion isn't
    -- reachable from here, so lean on off_task's polling: schedule the drop
    -- now, it keeps rescheduling itself until the sweep is done.
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

    -- Decide which auto syncs may proceed while offline: put-away events are
    -- never skipped (their drain brings Wi-Fi up, above); pull events keep
    -- requiring an existing connection so opening/resuming a book never
    -- triggers a connection.
    local CONNECTING_EVENTS = {
        suspend = true,               -- cover closed / standby
        close = true,                 -- book closed (exit to library)
        network_disconnecting = true, -- push just before Wi-Fi goes down
    }
    if type(plugin.shouldSkipAutoSyncOffline) == "function" then
        plugin.shouldSkipAutoSyncOffline = function(_self, event)
            if CONNECTING_EVENTS[event] then return false end
            return not NetworkMgr:isOnline()
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
