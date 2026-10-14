# GymKit Probe

Minimal iOS app that answers one question before proposing a change to QZ:

> While Apple GymKit (healthd) is connected to the Life Fitness Discover SE4 bike,
> can a third-party app reach that connection with
> `retrieveConnectedPeripherals(withServices: [0x1826])` and receive Indoor Bike Data?

The app never writes to the bike. It only retrieves, connects locally, discovers,
reads the FTMS feature characteristic and subscribes to notifications
(Indoor Bike Data `2AD2`, Fitness Machine Status `2ADA`, Training Status `2AD3`).

Built with [xtool](https://github.com/xtool-org/xtool) on Linux, signed with a
free Apple ID (the app stops launching after 7 days; re-run `xtool dev` to renew).

## Files

| File | Purpose |
|---|---|
| `Package.swift` | SwiftPM package (iOS 17+, Swift 5 language mode) |
| `xtool.yml` | Bundle ID and the Info.plist to merge |
| `Info.plist` | Bluetooth usage text, `bluetooth-central` background mode |
| `Sources/GymKitProbe/Probe.swift` | CoreBluetooth logic and log |
| `Sources/GymKitProbe/IndoorBikeData.swift` | FTMS Indoor Bike Data decoder (handles the SE4 cadence-flag quirk) |
| `Sources/GymKitProbe/ContentView.swift` | UI: buttons, live power/cadence/speed, log, share |

If the bundle ID `com.oriolpetit.GymKitProbe` is rejected as taken, change it in `xtool.yml`.

## Option A: build in GitHub Actions, install from Linux (no local Swift/Xcode)

`.github/workflows/build.yml` builds an **unsigned** `GymKitProbe.ipa` on a
GitHub-hosted `macos-26` runner (Xcode 26.6) with `xtool dev build --ipa` and
uploads it as the `GymKitProbe-ipa` artifact (kept 14 days). It runs on every
push to `main`, on pull requests, and manually (Actions tab > Run workflow).

Laptop, one-time:
```bash
sudo apt-get install -y libimobiledevice-utils libfuse2t64
mkdir -p ~/.local/bin
curl -fL "https://github.com/xtool-org/xtool/releases/latest/download/xtool-$(uname -m).AppImage" \
  -o ~/.local/bin/xtool
chmod +x ~/.local/bin/xtool
xtool auth login        # mode "Password" for a free Apple ID (email, password, 2FA)
```

Each build:
```bash
cd ~/workplace/gymkit-probe
gh run list --workflow build.yml --limit 3             # wait for a successful run
gh run download --name GymKitProbe-ipa --dir /tmp/gymkit-probe-ipa
ideviceinfo | head -3                                  # iPhone connected and unlocked
xtool install /tmp/gymkit-probe-ipa/GymKitProbe.ipa    # provisions, signs with your Apple ID, installs
```
Then do steps 3–4 of "Build and install" below (trust the developer, allow Bluetooth).

## Option B: build locally on Linux

### One-time setup (Ubuntu, x86_64)

Based on xtool's Linux installation guide (xtool 1.22.2, October 2026).

1. **Swift 6.4 toolchain**: follow <https://swift.org/install/linux> (swiftly), then check:
   ```bash
   swift --version   # Swift version 6.4 ...
   ```
2. **Device tools** (`usbmuxd` is already installed on this machine):
   ```bash
   sudo apt-get install libimobiledevice-utils
   ```
3. **FUSE 2 for AppImages** (not installed on this machine):
   ```bash
   sudo apt-get install libfuse2t64
   ```
   Alternative without FUSE: run the AppImage with `--appimage-extract-and-run`.
4. **Xcode 27 .xip**: download in the browser from
   <https://developer.apple.com/download/all/?q=Xcode> (log in with an Apple ID,
   accept the licence). It is large; note where `Xcode_27*.xip` is saved.
5. **xtool**:
   ```bash
   mkdir -p ~/.local/bin
   curl -fL "https://github.com/xtool-org/xtool/releases/latest/download/xtool-$(uname -m).AppImage" \
     -o ~/.local/bin/xtool
   chmod +x ~/.local/bin/xtool
   xtool --help
   ```
6. **Log in and build the iOS SDK**:
   ```bash
   xtool setup
   ```
   - Login mode `1: Password` (free Apple ID; uses private Apple APIs, so xtool's
     docs suggest a throwaway Apple ID). Enter email, password and 2FA code.
   - When asked, give the path to `Xcode_27*.xip`. Then check:
     ```bash
     swift sdk list   # darwin
     ```

## Build and install

1. Connect the iPhone by USB, unlock it, and check: `ideviceinfo | head`.
2. From this folder:
   ```bash
   cd ~/workplace/gymkit-probe
   xtool dev
   ```
   - First build takes several minutes (iOS SDK modules).
   - Tap **Trust** on the iPhone if asked; re-run `xtool dev` if it errors after pairing.
   - If asked, enable **Settings > Privacy & Security > Developer Mode** (the iPhone restarts), then re-run.
3. On first launch: **Settings > General > VPN & Device Management > (your Apple ID) > Trust**.
4. Open the app and allow Bluetooth.

## Test protocol at the gym

Note the time of each step. Use the share button (top right) to send the log
to yourself after each test.

### Test A: reuse the GymKit connection (main question)

1. Open GymKit Probe, tap **Clear**, switch on **Poll every 2 s**.
2. Tap the iPhone on the bike's NFC reader, accept the Apple Fitness prompt, and
   start pedalling until Fitness shows live data.
3. Switch back to GymKit Probe and wait 10–20 s. Keep pedalling.

| What the log shows | Meaning |
|---|---|
| `FOUND LF-…` → `Local connection OK` → `BIKE DATA #1 …` with power | **It works.** QZ can do the same: propose it to Roberto. |
| `FOUND` but `FTMS 0x1826 NOT visible to this app` | iOS hides FTMS on GymKit links |
| `Subscribe 2AD2: notifying=true` but no `BIKE DATA` | Subscribed, but no data reaches the app |
| `Subscribe 2AD2: … error=…` | Access refused (security/permission) |
| Only `retrieveConnectedPeripherals(…) -> 0` lines | iOS does not expose the GymKit link to apps: the route is closed |

Also check that the Apple Fitness workout keeps receiving data while the probe is attached.

### Test B: does the bike advertise again after cancelling GymKit?

1. In the probe: **Clear**, switch on **Scan for LF- / FTMS adverts** and
   **Connect to advertised bike** (Poll can stay on).
2. Tap the bike, then immediately **cancel** the Apple Fitness prompt.
3. Wait 1–2 minutes with the probe in the foreground.

| What the log shows | Meaning |
|---|---|
| No `ADVERT` lines after the cancel | The bike only advertises for GymKit's own connection |
| `ADVERT 'LF-…'` then `Local connection OK` and `BIKE DATA` | A normal app can connect without GymKit's NFC data |
| `ADVERT` then `Connect FAILED` / `Disconnected` with an error | Bike advertises, but refuses pairing without the NFC data |

### Optional: Bluetooth packet capture

Reinstall the Bluetooth logging profile (it expired before 14 Oct), restart the
iPhone, run the tests, then trigger a sysdiagnose. The `.pklg` shows exactly what
the bike and iOS did on the radio.
