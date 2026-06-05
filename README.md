# DeviceSpoofLabs

A Magisk/KernelSU/APatch module for spoofing device identity properties. Spoofs device identity toward a configurable profile with persona management.

## What it does

Spoofs the device identity that apps see: model, brand, manufacturer, build fingerprint, serial number, and each app’s Android ID / SSAID. Property spoofing happens pre-zygote, before apps launch. It only changes safe identity strings, so it avoids risky hardware or framework changes that can break boot.

## Installation

1. Download the latest zip file from Releases.
2. In your root manager, open **Modules → Install from storage** and pick the zip.
3. Reboot
4. Open the module's WebUI, generate a persona, and reboot when prompted.

Nothing is spoofed automatically on module install, you must activate a persona first.

## Android ID (SSAID)

In the WebUI Config tab, open Android ID (SSAID), choose your target apps, set or generate a 16-hex value, then Apply & reboot.

**Note:** Open each target app once first. Android only creates an app's Android ID after the app reads it for the first time, so an app you've never opened has nothing to spoof yet. Open it once, then apply/reboot.

## Limitations

A root module can only change identity **strings**. It **cannot** spoof framework-level identifiers like **IMEI, IMSI, MediaDRM ID, GAID, or Keystore IDs**, and it deliberately leaves hardware props (CPU, chipset, screen) alone to avoid bootloops/crashes.

For complete spoofing, run the companion Xposed module [DeviceSpoofLab-Hooks](https://github.com/yubunus/DeviceSpoofLab-Hooks) alongside this one.

## Recovery

If your device bootloops after installing due to conflicting modules:

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
