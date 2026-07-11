# KOReader PocketBook Wi-Fi patches

Userpatches for KOReader on PocketBook, tested on an Era (FW6) with KOReader
2026.03. They fix [koreader/koreader#12705](https://github.com/koreader/koreader/issues/12705)
plus a couple of things around it:

- `2-pocketbook-wifi-off.lua` — "Wi-Fi off" actually powers the radio down.
  Stock KOReader only calls `NetDisconnect()`, which drops the connection but
  leaves the radio on, draining the battery overnight.
- `2-pocketbook-wifi-silent-connect.lua` — connect to a known network without
  the system network dialog. Falls back to the dialog when it can't.
- `2-menu-footer-wifi-icon.lua` — Wi-Fi status icon next to the clock/battery
  in the menu footer, based on the actual radio state.
- `2-pocketbook-net-diag.lua` — throwaway probe that dumps the state of the
  network stack to `wifi-diag.txt`. Not needed by the fixes; kept around
  because it's how the netagent commands below were found.

## Install

Copy the `.lua` files to `applications/koreader/patches/` on the device
(create the folder if needed) and restart KOReader. Enable/disable them under
Tools → Patch management. Log output ends up in
`applications/koreader/crash.log`.

## Notes on the FW6 network stack

Things that took a while to figure out:

- The full Wi-Fi teardown is `NetDisconnect()` → `netagent net off` →
  `WiFiPower(0)`. All three are synchronous, no sleeps needed.
- `/ebrmain/bin/netagent` is what actually manages the network on FW6 (it
  runs wpa_supplicant). Besides `net on`/`net off`/`status` it has
  undocumented `connect_silent` and `essid_silent` commands, found with
  strings(1) on the binary.
- `NetConnectSilent(NULL)` only works while the agent is running: on a cold
  boot it returns NET_ABORTED (-12), but after `netagent net on` the same
  call connects within a few seconds. The old profile APIs
  (`EnumWirelessNetworks()`, `EnumConnections()`) return nothing on FW6, so
  connecting by profile name isn't an option — but it isn't needed either.
- Never read the stdout of `netagent net on`/`connect_silent` to EOF: they
  can stay around as the resident agent, so the read blocks forever and
  freezes the UI. Spawn them in the background and poll `QueryNetwork()`
  instead. `net off` and `status` print and exit, those are fine.
- `isWifiOn()` on PocketBook means "connected", not "radio powered" — the
  radio can be on with `isWifiOn()` false, which is exactly the bug scenario.
  The footer icon therefore also checks IFF_UP on the interface. The Wi-Fi
  interface is called `eth0` on PocketBook, and it disappears entirely when
  the radio is off.
- The SimpleUI plugin replaces `TouchMenu.updateItems` for its quick-settings
  tab without chaining to the original, so a plain wrap misses that tab.
  `userpatch.registerPatchPluginFunc("simpleui", ...)` re-wraps after the
  plugin loads.
- KOReader 2026.03 has no `ffi/inkview` module yet (use `ffi/inkview_h` +
  `ffi.load("inkview")`) and `TouchMenu:updateItems` has a different
  signature than current master. The patches handle both.

## Upstream

The two fixes map onto `NetworkMgr:turnOffWifi`/`turnOnWifi` in
`frontend/device/pocketbook/device.lua`.
