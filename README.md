# KOReader PocketBook Wi-Fi patches

Userpatches for KOReader on PocketBook, tested on an Era (FW6), a Verse
(Vivlio) and an Era Lite (FW7), with KOReader 2026.03 and 2026.07. They fix
[koreader/koreader#12705](https://github.com/koreader/koreader/issues/12705)
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
- `2-bookorbit-wifi-cycle.lua` — only relevant with the BookOrbit plugin: its
  put-away syncs (sleep, closing a book) never bring Wi-Fi up on their own on
  devices without a Wi-Fi manager, and the suspend snapshot was captured
  before the statistics plugin flushed the session to disk (so it pushed
  empty stats). With this, closing the cover flushes stats, connects, syncs,
  and powers the radio down before the device sleeps. Ported 2026-08-20 to
  the plugin's lifecycle-outbox API (plugin builds from 2026-08-06 on); the
  pre-outbox plugin needs the previous revision of this file. Suspend cycles
  use a fast 2 s radio-off check: on devices where the firmware owns the
  sleep (Era Lite), the process can be frozen a few seconds after the sync
  settles, and a slower check would leave the radio on all night.

## Install

Copy the `.lua` files to `applications/koreader/patches/` on the device
(create the folder if needed) and restart KOReader. Enable/disable them under
Tools → Patch management. Log output ends up in
`applications/koreader/crash.log`.

## Notes on the PocketBook network stack (FW6/FW7)

Things that took a while to figure out:

- The full Wi-Fi teardown is `NetDisconnect()` → `netagent net off` →
  `WiFiPower(0)` → `netagent wifi off`. All synchronous, no sleeps needed.
  The last step matters on some FW6 units where `WiFiPower(0)` alone leaves
  the radio up (issue #1); on FW7 `WiFiPower(0)` triggers it by itself, so
  there it's a no-op.
- `/ebrmain/bin/netagent` is what actually manages the network (it runs
  wpa_supplicant). Besides `net on`/`net off`/`status` it has undocumented
  `connect_silent` and `essid_silent` commands, found with strings(1) on the
  binary.
- FW7 (Era Lite) uses the same netagent machinery unchanged: cold-boot
  `NetConnectSilent` still returns NET_ABORTED (-12), and
  `netagent net on; netagent connect_silent` still connects in a few
  seconds. One visible difference: FW7's netagent echoes every invocation
  (`netagent called with parameters < … >`) to stdout, which ends up in
  crash.log — handy for debugging.
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
