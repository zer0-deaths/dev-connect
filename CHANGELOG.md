# Changelog

## [1.2.7] - 2026-09-30

- Connect on an already-paired Android row. Unpair stays next to it. Connect uses the live tls-connect port when dns-sd has one.

## [1.2.6] - 2026-09-30

- Tapping a phone in the pairing-code flow stays on the code pad. A failed connect no longer opens QR.

## [1.2.5] - 2026-09-30

- Keep dns-sd phones on screen. An empty `adb mdns services` poll no longer clears the scan list.

## [1.2.4] - 2026-09-30

- Poll while the shelf is open or an add/pair flow is up, even if the host leaves activeWidgetIDs empty.
- Discover phones with dns-sd as well as `adb mdns services`, which is often empty, and show already-paired connect targets in the code scan.

## [1.2.3] - 2026-09-30

- Poll devices only while the widget is on a shelf: every 2 seconds with the shelf open, every 30 seconds with it closed, and not at all when the widget is not placed. Opening the shelf refreshes at once.
- Find Xcode's devicectl on disk once per activation and run it directly. Without Xcode the iOS side is skipped and xcrun is never run.
- Declare shelf-read for observing the shelf.
- Report an iPhone unpair from the command's outcome, and never read a previous run's JSON.
- Kill a timed-out command that ignores terminate instead of crashing on its exit status.
- Ignore results from a scan, pair or connect that was replaced or cancelled, and keep a new phone from cancelling a pair in progress.

## [1.2.2] - 2026-09-30

- Cancel scans and pairing when the droplet is disabled, and ignore late command results.
- Skip a new device scan while one is still running.
- Native Settings pane rooted in DropletSettingsPane.

## [1.2.1] - 2026-09-19

- Pair Android from the shelf with a QR code or a 6-digit wireless debugging code.
- Pair iPhone over USB with Trust, and unpair from the same list.
- Android and iOS sections in Settings, with Unpair on each phone.
