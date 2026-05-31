# Mac Input Tweak

Mac Input Tweak is a small macOS menu bar app for two input fixes:

- `Enable instant Caps Lock`: press Caps Lock and immediately type English letters in ALL CAPS, including when you were using Apple Chinese Simplified or Traditional Pinyin.
- `Enable window-specific input memory`: remember the input source you used in each window, then restore it when you switch back to that window.

Both features are optional. If a checkbox is off, that part of macOS input behavior stays normal.

## What You Get

- Instant Caps Lock response with no macOS press-and-hold delay.
- ALL CAPS English typing from English, Apple Chinese Simplified Pinyin, and Apple Chinese Traditional Pinyin.
- Optional per-window input source memory for normal typing.
- A menu bar icon so you know the app is still running.
- A simple control window with two checkboxes.

## Download and Install

1. Download `Mac-Input-Tweak-2.0.0.zip` from the GitHub Releases page.
2. Unzip it.
3. Drag `Mac Input Tweak.app` into your `Applications` folder.
4. Open `Mac Input Tweak.app`.
5. Turn on the features you want.
6. Grant the macOS permissions the app asks for.

If macOS warns that the app was downloaded from the internet, right-click the app, choose `Open`, then choose `Open` again.

## How to Use

- Launch the app: the control window, Dock icon, and menu bar icon appear.
- Check `Enable instant Caps Lock` if you want Windows-like Caps Lock behavior.
- Check `Enable window-specific input memory` if you want each window to remember its own input source.
- Close the control window: the app keeps running in the menu bar and the Dock icon disappears.
- Left-click the menu bar icon: bring the control window and Dock icon back.
- Right-click the menu bar icon: toggle either feature or quit the app.

To stop the app completely, right-click the menu bar icon and choose `Quit`.

## Permissions

Mac Input Tweak may need macOS privacy permissions:

- Accessibility: needed by both features.
- Input Monitoring: needed by instant Caps Lock.

Open:

`System Settings -> Privacy & Security`

Then enable `Mac Input Tweak` under:

- Accessibility
- Input Monitoring

The app window also has buttons for `Open Accessibility` and `Open Input Monitoring`.

## Start With macOS

If you want Mac Input Tweak to start automatically:

1. Open `System Settings`.
2. Go to `General -> Login Items & Extensions`.
3. Add `Mac Input Tweak.app` to `Open at Login`.

## Build From Source

If you want to build the app yourself:

```bash
xcodegen generate
open MacInputTweak.xcodeproj
```

Then build or run the `MacInputTweak` scheme in Xcode.

Xcode creates `Mac Input Tweak.app` in its build output folder. The source repo does not store a built `.app` file.

## Developer Notes

- Instant Caps Lock uses an internal Caps Lock state instead of trusting macOS's delayed Caps Lock state.
- Caps Lock key events are swallowed while instant mode is enabled.
- Letter keys are rewritten to uppercase only while Caps mode is on.
- Window-specific input memory pauses while Caps mode is on so it does not fight the Caps Lock behavior.
- Caps Lock keycap light sync is best-effort and may depend on keyboard hardware.
