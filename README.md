# CapsLockFix

Small macOS app that provides deterministic, instant Caps Lock behavior with Chinese Pinyin compatibility.

## What it does

- Uses an internal virtual caps state instead of relying on `maskAlphaShift` from macOS.
- Listens for physical Caps Lock press events and toggles virtual caps immediately.
- Swallows Caps Lock `flagsChanged` events while the feature is enabled, removing the system debounce path.
- When virtual caps is ON:
  - switches Chinese Simplified/Traditional Pinyin input (`SCIM`/`TCIM`) to an ASCII keyboard layout immediately,
  - types A-Z as uppercase immediately.
- When virtual caps is OFF:
  - restores the input source that was active before caps was enabled.
- If keycap-light sync is unavailable, instant typing still works and the app shows a warning.

## Build in Xcode (creates `.app`)

1. Generate/open the Xcode project:
```bash
xcodegen generate
open CapsLockFix.xcodeproj
```
2. In Xcode, build or run the `CapsLockFix` scheme.

Xcode will produce `CapsLockFix.app` inside `DerivedData` only.
No custom packaging script is used.

## Runtime behavior

- Launch app: Dock icon + menu bar icon + controls window appear.
- Close controls window: Dock icon hides, app keeps running in menu bar.
- Left click menu bar icon: restores controls window and Dock icon.
- Right click menu bar icon: shows `Turn On/Off CapsLock Fix` and `Quit`.
- If the app is not running, or instant mode is toggled OFF, macOS Caps Lock behavior is unchanged.

## Optional: run as CLI during development

```bash
swift run CapsLockFix
```

This runs the app directly (no `.app` bundle output).

## App icon workflow

If you want to regenerate the icon design and update Xcode assets:

```bash
chmod +x scripts/generate_app_icon.sh
./scripts/generate_app_icon.sh
```

## Permissions

Grant these permissions to the binary in:
`System Settings -> Privacy & Security`

- Accessibility
- Input Monitoring

If permission is missing, the app will show an error status in the window.
Using the app's `Open Accessibility` / `Open Input Monitoring` buttons also triggers the system permission request so the app appears in those lists automatically.
