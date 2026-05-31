# CapsLock Fix

CapsLock Fix is a small macOS menu bar app that makes Caps Lock feel instant.

When the app is running and the feature is enabled, pressing Caps Lock immediately puts you into ALL CAPS typing. Press Caps Lock again and typing goes back to normal.

This is especially useful if you switch between English and Apple Chinese Pinyin input methods. You can stay in Simplified or Traditional Pinyin, press Caps Lock, type uppercase English immediately, then press Caps Lock again and continue normal Chinese typing.

## What You Get

- Instant Caps Lock response with no macOS press-and-hold delay.
- Works from English input, Apple Chinese Simplified Pinyin, and Apple Chinese Traditional Pinyin.
- Keeps your current input method selected instead of bouncing between input sources.
- Shows a menu bar icon so you know the app is still running.
- Simple checkbox to turn the fix on or off.
- If the app is not running, or the checkbox is off, macOS goes back to its normal Caps Lock behavior.

## Download and Install

1. Download `CapsLockFix-1.0.0.zip` from the GitHub Releases page.
2. Unzip it.
3. Drag `CapsLockFix.app` into your `Applications` folder.
4. Open `CapsLockFix.app`.
5. Turn on `Enable instant Caps Lock`.
6. Grant the two permissions macOS asks for: Accessibility and Input Monitoring.

If macOS warns that the app was downloaded from the internet, right-click the app, choose `Open`, then choose `Open` again.

## How to Use

- Launch the app: the control window, Dock icon, and menu bar icon appear.
- Check `Enable instant Caps Lock`: the fix turns on.
- Press Caps Lock once: type English letters in ALL CAPS immediately.
- Press Caps Lock again: return to normal typing.
- Close the control window: the app keeps running in the menu bar and the Dock icon disappears.
- Left-click the menu bar icon: bring the control window and Dock icon back.
- Right-click the menu bar icon: turn CapsLock Fix on/off or quit the app.

To stop the app completely, right-click the menu bar icon and choose `Quit`.

## Permissions

CapsLock Fix needs two macOS permissions because it has to watch the Caps Lock key and rewrite letter keystrokes while Caps mode is on.

Open:

`System Settings -> Privacy & Security`

Then enable `CapsLockFix` under:

- Accessibility
- Input Monitoring

The app window also has buttons for `Open Accessibility` and `Open Input Monitoring`.

## Start With macOS

If you want CapsLock Fix to start automatically:

1. Open `System Settings`.
2. Go to `General -> Login Items & Extensions`.
3. Add `CapsLockFix.app` to `Open at Login`.

## Build From Source

If you want to build the app yourself:

```bash
xcodegen generate
open CapsLockFix.xcodeproj
```

Then build or run the `CapsLockFix` scheme in Xcode.

Xcode creates `CapsLockFix.app` in its build output folder. The source repo does not store a built `.app` file.

## Developer Notes

- The app uses an internal Caps Lock state instead of trusting macOS's delayed Caps Lock state.
- Caps Lock key events are swallowed while the feature is enabled.
- Letter keys are rewritten to uppercase only while Caps mode is on.
- Chinese Pinyin input stays selected, which avoids the unstable input-source switching behavior from earlier versions.
- Caps Lock keycap light sync is best-effort and may depend on keyboard hardware.
