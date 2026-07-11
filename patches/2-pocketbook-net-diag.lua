--[[
One-shot probe of the PocketBook network stack. Writes wifi-diag.txt next to
crash.log; skipped while that file exists (delete it to re-run). Read-only,
doesn't connect or reconfigure anything. Not needed by the other patches —
it's how the netagent commands were found in the first place.
--]]

local Device = require("device")
if not Device:isPocketBook() then return end

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local diag_path = DataStorage:getDataDir() .. "/wifi-diag.txt"
if lfs.attributes(diag_path, "mode") then return end

local TIMEOUT = ""
if os.execute("timeout 1 true >/dev/null 2>&1") == 0 then
    TIMEOUT = "timeout 5 "
elseif os.execute("timeout -t 1 true >/dev/null 2>&1") == 0 then
    TIMEOUT = "timeout -t 5 "
end

local probes = {
    { "date", "date" },
    { "uname", "uname -a" },
    { "netagent no-args (usage?)", "/ebrmain/bin/netagent" },
    { "netagent help", "/ebrmain/bin/netagent help" },
    { "netagent bogus arg (usage?)", "/ebrmain/bin/netagent xyzzy" },
    { "netagent status", "/ebrmain/bin/netagent status" },
    { "netagent binary strings", "strings /ebrmain/bin/netagent 2>&1 | grep -i -E \"usage|connect|silent|wifi|profile|net (on|off)\" | head -60" },
    { "net-ish binaries in /ebrmain/bin", "ls /ebrmain/bin 2>&1 | grep -i -E \"net|wifi|wpa|iw|dhcp\"" },
    { "net-ish binaries in PATH dirs", "ls /bin /sbin /usr/bin /usr/sbin 2>/dev/null | grep -i -E \"wpa|iw|dhcp\"" },
    { "wpa_cli status", "wpa_cli status" },
    { "wpa_cli list_networks", "wpa_cli list_networks" },
    { "wpa_supplicant control sockets", "ls -la /var/run/wpa_supplicant /tmp/wpa_supplicant 2>&1" },
    { "processes (wpa/net/dhcp)", "ps w 2>&1 | grep -i -E \"wpa|netagent|dhcp|hostap\" | grep -v grep" },
    { "interfaces", "ls /sys/class/net" },
    { "proc net wireless", "cat /proc/net/wireless" },
    { "iwconfig", "iwconfig" },
    { "ebrmain config dir", "ls -la /ebrmain/config 2>&1 | head -60" },
    { "var config dirs", "ls -la /var/config /mnt/secure 2>&1 | head -60" },
    { "wifi/network named files under /ebrmain (3 levels)", "find /ebrmain -maxdepth 3 -iname \"*wifi*\" 2>/dev/null | head -30; find /ebrmain -maxdepth 3 -iname \"*network*\" 2>/dev/null | head -30" },
}

local f = io.open(diag_path, "w")
if not f then
    logger.warn("net-diag patch: cannot open", diag_path)
    return
end

for _, probe in ipairs(probes) do
    local name, cmd = probe[1], probe[2]
    f:write("========== ", name, "\n$ ", cmd, "\n")
    local p = io.popen(TIMEOUT .. cmd .. " 2>&1")
    if p then
        f:write(p:read("*a") or "")
        p:close()
    else
        f:write("(popen failed)\n")
    end
    f:write("\n")
end
f:close()
logger.info("net-diag patch: wrote", diag_path)
