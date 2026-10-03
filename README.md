# DeviceSpoofLabs

A Magisk/KernelSU/APatch module for spoofing device identity properties. Spoofs device identity toward a configurable profile with persona management.

## What it does

Spoofs the device identity that apps see: model, brand, manufacturer, build fingerprint, serial number, and each app’s Android ID / SSAID. Property spoofing happens pre-zygote, before apps launch. It only changes safe identity strings, so it avoids risky hardware or framework changes that can break boot.

## Installation

1. Download `devicespooflab-vX.Y.zip` from the [Releases](https://github.com/yubunus/DeviceSpoofLab-Magisk/releases) page. Don't use GitHub's "Source code" archives, they are not installable modules.
2. In your root manager, open **Modules → Install from storage** and pick the zip.
3. Reboot
4. Open the module's WebUI, pick a device, tap **+ Generate**, and reboot when prompted.

Nothing is spoofed automatically on module install, you must activate a persona first.

## System updates

Before you install a system update, switch the persona off and reboot. Switch it back on after the update. A spoofed fingerprint can confuse which update your phone is offered.

## Android ID (SSAID)

In the WebUI Config tab, open Android ID (SSAID): switch it on, choose your target apps, and set or generate a 16-hex value. Changes are saved as you make them and apply on the next reboot.

**Note:** Open each target app once first. Android only creates an app's Android ID after the app reads it for the first time, so an app you've never opened has nothing to spoof yet. Open it once, then reboot.

To get the original Android IDs back, switch the persona off and reboot, or uninstall the module. Disabling the module in your root manager does **not** restore them, because a disabled module's scripts don't run.

## Known effects on some phones

The persona applies to the whole system, so your phone's own software sees it too. Depending on the phone:

- The first boot after you switch personas can take longer than usual. Android sees a new build fingerprint and treats it like an OS update.
- The phone's own updater may stop offering updates while a persona is on. With a Pixel persona, Google "system update" notifications that can't be installed may appear.
- Some manufacturer apps and services may behave differently or refuse to run. For example, Samsung apps may refuse to run on a "Pixel".
- VoLTE / RCS may stop working on some carriers.
- The serial shown by `adb devices` may change to the persona's serial.
- After you switch a persona off, do a normal reboot. A root manager's "soft reboot" may keep the spoofed values.

## Limitations

A root module can only change identity **strings**. It **cannot** spoof framework-level identifiers like **IMEI, IMSI, MediaDRM ID, GAID, or Keystore IDs**, and it deliberately leaves hardware props (CPU, chipset, screen) alone to avoid bootloops/crashes.

For complete spoofing, run the companion Xposed module [DeviceSpoofLab-Hooks](https://github.com/yubunus/DeviceSpoofLab-Hooks) alongside this one. It spoofs per app, so system apps keep the real identity.

## Recovery

If the phone does not finish starting up twice in a row while a persona is on, the module switches the persona off by itself, and the next start uses your real identity. So if your phone gets stuck or keeps restarting after you switch a persona on, restart it again (hold the power button if you have to). If Android shows a screen that offers **Try again** or **Factory data reset**, choose **Try again**.

The persona is kept. The WebUI, or `devicespooflabs status` from a root shell, shows that it was switched off, and you can switch it on again.

A start counts as finished once the phone has been up and stable for about half a minute, so restarting the phone sooner than that twice in a row also switches the persona off. The protection works from the second start after you install the module, and only with a normal restart, not a root manager's "soft reboot". To turn it off, create the empty file `/data/adb/devicespooflab/config/boot_guard_off`.

If your device still bootloops, for example because of conflicting modules:

1. Boot into safe mode (hold Volume Down during boot on most devices).
2. Open your root manager and disable or uninstall the module.
3. Reboot normally.

Alternatively, via ADB:

```sh
adb shell touch /data/adb/modules/devicespooflab/disable   # disable
# or
adb shell rm -rf /data/adb/modules/devicespooflab           # uninstall
```

## License

This project is licensed under the [MIT License](https://opensource.org/licenses/MIT).
