# Dev Connect

A [Droppy](https://getdroppy.app) droplet for pairing phones from the shelf.

- **Android:** QR or 6-digit wireless debugging code via `adb`
- **iPhone:** USB plus Trust, via `xcrun devicectl`

## Build

Needs [DroppyKit](https://getdroppy.app/docs/droppykit) and `adb` (Android) / Xcode `devicectl` (iOS).

```bash
droppykit build
droppykit validate
```

Install the bundle into Droppy Playground:

```
~/Library/Application Support/Droppy Playground/Droplets/dev-connect/DevConnect.droplet
```

MIT license.
