# WhatCable

> **What can this USB-C cable actually do?**

**Website: [whatcable.uk](https://whatcable.uk)** (overview, screenshots, and CLI docs)

A small macOS menu bar app that tells you, in plain English, what each USB-C cable plugged into your Mac can actually do, and **why your Mac might be charging slowly**.

USB-C hides a lot under one connector. Anything from a USB 2.0 charge-only cable to a 240W / 40 Gbps Thunderbolt 4 cable, all looking identical in your drawer. macOS already exposes the relevant info via IOKit; WhatCable surfaces it as a friendly menu bar popover.

<a href="https://www.producthunt.com/products/whatcable?embed=true&utm_source=badge-top-post-badge&utm_medium=badge&utm_campaign=badge-whatcable" target="_blank" rel="noopener noreferrer"><img alt="WhatCable - Know what your USB-C cable can really do | Product Hunt" width="250" height="54" src="https://api.producthunt.com/widgets/embed-image/v1/top-post-badge.svg?post_id=1153432&theme=light&period=daily&t=1779720313376"></a>

[![Latest release](https://img.shields.io/github/v/release/darrylmorley/whatcable)](https://github.com/darrylmorley/whatcable/releases/latest)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)](https://github.com/darrylmorley/whatcable)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![WhatCable Pro](https://img.shields.io/badge/WhatCable%20Pro-%C2%A39.99-orange)](https://whatcable.uk/pro)

![WhatCable popover](docs/screenshot.webp)

## What it shows

Per port, in plain English:

- **At-a-glance headline:** Thunderbolt / USB4, USB device, Display connected, Charging only, Slow USB / charge-only cable, Nothing connected
- **Charging diagnostic:** when something's plugged in, a banner identifies the bottleneck:
  - *"Cable is limiting charging speed"* (cable rated below the charger)
  - *"Charging at 30W (charger can do up to 96W)"* (Mac is asking for less, e.g. battery near full)
  - *"Charging well at 96W"* (everything matches)
  - *"Battery full, not charging"* (plugged in, battery full, so the Mac isn't drawing power)
- **Data-speed diagnostic:** a plain-English verdict on what's limiting the link, the Mac port, the cable, or the device. For example *"Cable is limiting data speed"*, *"Device runs at 10 Gbps, this is the fastest it supports, not a cable problem"*, or *"Running slower than expected"* when the link came up degraded. Shown inline, in the CLI, and in JSON.
- **Cable e-marker info:** the cable's actual speed (USB 2.0, 5 / 10 / 20 / 40 / 80 Gbps), current rating (3 A / 5 A up to 60W / 100W / 240W), and the chip's vendor
- **Cable trust signals:** an orange card appears when the e-marker reports values that look unusual against the USB-PD spec, like a zero vendor ID, a reserved bit pattern in the speed / current / cable-latency fields, or a VID that isn't in USB-IF's published list. Wording is hedged on purpose: a flag means "this looks unusual," not "this cable is fake."
- **Charger PDO list:** every voltage profile the charger advertises (5V / 9V / 12V / 15V / 20V…) with the currently negotiated profile highlighted in real time
- **Connected device identity:** vendor name and product type, decoded from the PD Discover Identity response
- **Attached USB devices:** storage, hubs, and peripherals listed under the physical port they're plugged into, with their negotiated speed
- **Thunderbolt fabric:** when a Thunderbolt / USB4 link is active, shows per-lane speed, generation (TB3, TB4, TB5), and the full switch topology for multi-hop connections through docks
- **Cable identification:** if the cable's e-marker fingerprint matches a known cable in the bundled database, the brand and model are shown alongside the raw specs
- **Active transports:** USB 2 / USB 3 / Thunderbolt / DisplayPort
- **Desktop widget:** small, medium, and large WidgetKit widgets showing live cable status on your desktop
- **⌥-click** the menu bar icon (or flip the toggle in Settings) to reveal the underlying IOKit properties for engineers

Click the **gear icon** in the popover header to open Settings, where you can:

- Hide empty ports
- Launch at login
- Run as a regular Dock app instead of a menu bar icon
- Adjust the font size
- Show technical details (the same raw IOKit data that ⌥-click reveals)
- Switch language (English, Armenian, Brazilian Portuguese, French, German, Hindi, Italian, Japanese, Korean, Latvian, Norwegian, Polish, Russian, Simplified Chinese, Spanish, Traditional Chinese, or follow your system default)
- Get notifications when cables are connected or disconnected
- Contribute anonymised port and power diagnostics to improve hardware coverage (opt-in, manual)

Right-click the menu bar icon for **Refresh**, a **Keep window open** toggle (handy for screenshots and demos), **Settings…**, **Contribute Diagnostic Data…**, **Check for Updates…**, **About**, **WhatCable on GitHub**, and **Quit**.

## WhatCable Pro

WhatCable is free and open source. If you find it useful, you can support the project by picking up [WhatCable Pro](https://whatcable.uk/pro), which unlocks extra features:

- Live power metering and PD contract inspection
- Power Monitor with a live system power-input graph
- **Negotiation Diagnostics:** the full per-connection breakdown, what the Mac port, cable, and device each support vs what was negotiated, side by side with the weak link highlighted, plus an e-marker vs Thunderbolt-controller cross-check
- **Display Diagnostics:** reads your monitor's live display mode straight from macOS and compares it against what the DisplayPort link is carrying, so a screen stuck below its top resolution or refresh has an explanation. Shows the true resolution even on 5K and 6K displays, confirms full quality when a screen reaches its top mode via compression (DSC), and names any HDMI or DisplayPort adapter in the chain
- Port health counters and cable resistance estimation
- Pin diagrams and liquid detection status
- Pro screens open inside the app, with an optional detach into their own window
- Works even on Macs that don't expose live per-port metering

One-time purchase, works on up to 2 Macs. See [whatcable.uk/pro](https://whatcable.uk/pro) for details.

[![Buy WhatCable Pro](https://img.shields.io/badge/Buy%20WhatCable%20Pro-%C2%A39.99-orange?style=for-the-badge)](https://whatcable.uk/pro)

## Install

Visit [whatcable.uk](https://whatcable.uk) for an overview and screenshots, or install directly below.

Download the latest `WhatCable.zip` from the [Releases page](https://github.com/darrylmorley/whatcable/releases/latest), unzip, and drag `WhatCable.app` to `/Applications`.

The app is signed with a Developer ID and notarised by Apple, so there are no Gatekeeper warnings.

It's not on the Mac App Store on purpose: App Sandbox blocks the low-level IOKit reads WhatCable depends on, so it ships signed and notarised outside the store instead.

Requires macOS 14 (Sonoma) or later, Apple Silicon only. On Intel Macs, the USB-C ports are driven by Intel Titan Ridge / JHL9580 Thunderbolt 3 controllers, and the USB-PD state and cable e-marker data WhatCable depends on are not exposed through any public IOKit accessor.

> **Note:** The manual install gives you the menu bar app only. The `whatcable` CLI is bundled inside the `.app` and is not on your PATH by default. If you want to use it from the shell, see the [Command-line interface](#command-line-interface) section below for the one-line symlink. Or install via Homebrew, which sets up the CLI automatically.

### Homebrew

```bash
brew tap darrylmorley/whatcable
brew install --cask whatcable
```

This installs the menu bar app and symlinks the `whatcable` CLI into your PATH.

### Homebrew, CLI only (no menu bar app)

If you don't want the menu bar app, install just the command-line tool:

```bash
brew tap darrylmorley/whatcable
brew install whatcable-cli
```

Same signed and notarised binary, packaged on its own. Useful in terminal-only or scripting environments. Pick one of the two Homebrew installs (both ship the same `whatcable` binary).

## Command-line interface

A `whatcable` binary ships alongside the menu bar app, driven by the same diagnostic engine:

```text
$ whatcable

USB-C Port 1
  ✓ Charging well at 96W
  Cable: 5A, 100W, USB4 40 Gbps
  Charger: 5V / 9V / 15V / 20V PDOs

USB-C Port 2
  ! Cable is limiting charging speed
  Cable: 3A, 60W, USB 2.0
  Device: External SSD, USB 10 Gbps
```

Flags:

```bash
whatcable                # human-readable summary of every port
whatcable --json         # structured JSON, pipe into jq
whatcable --watch        # stream updates as cables come and go (Ctrl+C to exit)
whatcable --raw          # include underlying IOKit properties
whatcable --report       # open a pre-filled GitHub issue for the connected cable
whatcable --test-kit     # run diagnostic probes and submit anonymised data
whatcable --desktop      # launch the GUI app in Dock mode
whatcable --popover      # launch the GUI app in menu bar mode
whatcable --version
whatcable --help
```

Pro from the command line:

```bash
whatcable --monitor                        # Pro: live power telemetry (Ctrl+C to exit)
whatcable --monitor-json                   # Pro: live power telemetry as newline-delimited JSON
whatcable --activate XXXX-XXXX-XXXX-XXXX   # validate and store a Pro licence
whatcable --licence                        # show current licence status
whatcable --deactivate                     # remove the stored licence
whatcable --pro                            # show Pro features, open purchase page
```

The CLI prints a one-line Pro hint at the end of plain text output for unlicensed users. Run `whatcable --silence-pro-hints` to hide it (or `--show-pro-hints` to bring it back). Suppressed automatically when output is piped, redirected, or used with `--json`.

If you installed the `.app` manually rather than via Homebrew, the CLI lives at `WhatCable.app/Contents/Helpers/whatcable`. Symlink it into your PATH if you want it on the shell:

```bash
ln -s /Applications/WhatCable.app/Contents/Helpers/whatcable /usr/local/bin/whatcable
```

The Homebrew install does this for you automatically.

## How it works

WhatCable reads four families of IOKit services. No entitlements, no private APIs, no helper daemons:

| Service | What it gives us |
| --- | --- |
| `AppleHPMInterfaceType10/11/12` (M3-era), `AppleTCControllerType10/11` (M1 / M2), and `IOPort` (M4 Mac mini front ports) | Per-port state: connection, transports, plug orientation, e-marker presence. `Type11` is what M2 MacBook Air uses for its MagSafe 3 port. |
| `IOPortFeaturePowerSource` | Full PDO list from the connected source, with the live "winning" PDO |
| `IOPortTransportComponentCCUSBPDSOP`, `...SOPp`, `...SOPpp` | PD Discover Identity VDOs from the port partner (SOP), the cable's near-end e-marker (SOP'), and the far-end e-marker (SOP'') if present |
| XHCI controller subtree | Each connected USB device is paired to its physical port via the XHCI port node's `UsbIOPort` registry path, falling back to a bus-index derived from the controller's `locationID` upper byte and the port's `hpm` SPMI ancestor on machines that don't expose `UsbIOPort`. |

Cable speed and power decoding follow the USB Power Delivery spec (aligned to USB-PD R3.2 V1.2, March 2026). Vendor names come from a bundled SQLite database (`whatcable.db`) that merges USB-IF's published vendor list, the community `usb.ids` list, and a curated set of cable fingerprints reported by users.

## Build from source

```bash
swift build                  # compile everything
swift run WhatCable          # run the menu bar app (dev mode, no widget or bundle structure)
swift run whatcable-cli      # run the CLI
swift test                   # run the test suite
```

Requires Swift 5.9+ (Xcode 15+). Note: `swift run WhatCable` launches a working dev build but without the widget extension or proper `.app` bundle. For a distributable build, use the build scripts below.

## Build a distributable .app

```bash
./scripts/smoke-test.sh
```

Builds, signs, notarises (if configured), and smoke-tests the app. Produces `dist/WhatCable.app` and `dist/WhatCable.zip`. Safe to run on any branch, any time. Does not touch the Homebrew tap.

**Modes:**

| Configuration | Result |
| --- | --- |
| No `.env` | Ad-hoc signed. Works locally; Gatekeeper warns on other Macs. |
| `.env` with `DEVELOPER_ID` | Developer ID signed + hardened runtime. |
| `.env` with `DEVELOPER_ID` + `NOTARY_PROFILE` | Full notarisation + stapled ticket. Gatekeeper-clean for everyone. |

**Cutting a release:**

```bash
# write release-notes/v<version>.md first, then:
./scripts/release.sh <version>
```

The wrapper does the whole pipeline: bumps the version, runs build-app.sh
(which builds, signs, notarises, smoke-tests, and bumps the local cask),
tags and pushes the commit, creates the GitHub release with the notes
file, verifies the uploaded asset's sha matches the local zip, copies the
notes into the tap, and pushes the tap. Use `--dry-run` first to validate
state. Requires `gh` (auth'd) and the env vars from `.env.example`.

**One-time setup for full notarisation:**

```bash
# 1. Find your signing identity
security find-identity -v -p codesigning

# 2. Store notarytool credentials in the keychain
xcrun notarytool store-credentials "WhatCable-notary" \
    --apple-id "you@example.com" \
    --team-id "ABCDE12345" \
    --password "<app-specific-password>"   # generate at appleid.apple.com

# 3. Create your .env from the template
cp .env.example .env
# ...and fill in DEVELOPER_ID
```

## Caveats

- **Cable e-marker info only appears for cables that carry one.** Most USB-C cables under 60 W are unmarked. Any Thunderbolt / USB4 cable, any 5 A / 100 W+ cable, and most quality data cables will be e-marked.
- **Some cables only reveal their e-marker once something is plugged in at the other end.** The chip in the cable's plug runs off VCONN (a small power rail your Mac feeds into the cable) and only answers when the host issues a "Discover Identity" message. With nothing attached, some Macs read the e-marker straight away, others wait until they see a real partner to negotiate with. If a cable shows up as basic when bare, plug a charger, dock, or device into the far end and check again.
- **WhatCable reads from the Mac's USB-C port, the connected device or charger, and the cable itself.** It cross-checks what each part of the chain reports, so if a cable claims high specs but the negotiated result is lower, you'll see where the mismatch is. That said, software cannot verify what's physically inside the jacket. If a cable's e-marker chip claims 240W / 40 Gbps but the wiring can't deliver, the chip is lying, not WhatCable. The trust-signals card flags a small set of internal-consistency tells (zero VID, reserved bit patterns in the Cable VDO, a VID not in the USB-IF list). These are common in budget cables and don't necessarily mean anything is wrong. They're informational, not a verdict.
- **PD spec coverage:** the decoder is aligned to USB-PD R3.2 V1.2 (March 2026). Earlier 3.0 / 3.1 cables work fine.
- **Vendor name lookup uses a bundled database** (thousands of USB-IF entries plus the community usb.ids list). VIDs assigned after the bundled snapshot will show as "Unregistered / unknown" and trip a trust-signal flag until the database is refreshed.

## Linux port

[@abrauchli](https://github.com/abrauchli) built a Rust port for Linux called [usbeehive](https://github.com/abrauchli/usbeehive). Install it with `cargo install usbeehive`. It reads from the kernel's typec sysfs interface rather than IOKit, so it's an independent implementation rather than a fork. It started life as a `whatcable` crate on crates.io before being renamed to avoid confusion with this repo. He's also working on [usbee](https://github.com/abrauchli/usbee), a GNOME UI for it (early stage, but the basics work).

## Privacy

WhatCable reads USB-C port state directly from IOKit on your Mac. All of that happens locally. Nothing is sent anywhere automatically.

**Cable reports:** If you use the "Report this cable" button on an e-marked cable, WhatCable builds a pre-filled GitHub issue containing the cable's vendor ID, product ID, and capability flags (VDOs). Your browser opens with that data in the issue form. Nothing is submitted until you click the button in GitHub yourself. Once submitted, the issue is public.

**Update checks:** WhatCable periodically checks the GitHub Releases API to see if a newer version is available. No personal data or hardware info is included in that request.

**Diagnostic data:** Settings has an opt-in **Contribute Diagnostic Data** button. When you press it, WhatCable collects anonymised USB-C port and power IOKit details from your Mac and submits them to help improve hardware coverage. It only runs when you click it; nothing is collected or sent unless you choose to.

## Contributing

Issues and PRs welcome. The code is small and tries to stay readable.

**Where to start:**

| Module | Role |
| --- | --- |
| [`Sources/WhatCable/`](Sources/WhatCable/) | Main menu bar app UI (SwiftUI popover, settings, notifications) |
| [`Sources/WhatCableCore/`](Sources/WhatCableCore/) | Shared diagnostic logic, PD bit decoding, text formatting |
| [`Sources/WhatCableDarwinBackend/`](Sources/WhatCableDarwinBackend/) | IOKit watchers (port state, PD identity, power sources, USB devices, Thunderbolt fabric) |
| [`Sources/WhatCableAppKit/`](Sources/WhatCableAppKit/) | Plugin registry and extension points (hooks for Pro features, CLI commands, menu items) |
| [`Sources/WhatCablePlugins/`](Sources/WhatCablePlugins/) | Pro features (power metering, licence, cable and display diagnostics, liquid detection) |
| [`Sources/WhatCableWidget/`](Sources/WhatCableWidget/) | WidgetKit extension (small/medium/large desktop widgets) |
| [`Sources/WhatCableCLI/`](Sources/WhatCableCLI/) | CLI binary, shares Core/Backend/Plugins with the app |

### Translations

WhatCable uses `.lproj/.strings` files for localisation. Each module (`WhatCable` and `WhatCableCore`) has its own set under `Sources/<module>/Resources/<lang>.lproj/Localizable.strings`.

To add a new language:

1. Copy `en.lproj/Localizable.strings` from both modules into a new `<lang>.lproj/` directory
2. Translate the values (leave the keys as-is)
3. Make sure format specifiers (`%@`, `%lld`, `%1$@`, etc.) match the English originals exactly
4. Run `plutil -lint` on your files to check for syntax errors
5. Add the language to the picker in [`Sources/WhatCable/Views/SettingsView.swift`](Sources/WhatCable/Views/SettingsView.swift)

### Diagnostic data

The single most helpful thing you can do is hit **Contribute Diagnostic Data** in Settings. It runs a short set of C probes that gather anonymised port and power data from your Mac, then submits the results. The whole process takes a few seconds, nothing is sent without your explicit click, and no personal information is included.

More device data means better hardware coverage, fewer edge-case bugs, and more accurate diagnostics for everyone. If you have unusual hardware (docks, hubs, TB5 gear, high-wattage chargers), your report is especially valuable.

Cable reports are also very welcome. If you have an e-marked cable, use the "Report this cable" button in the app (or `whatcable --report` from the CLI) to submit its fingerprint. These reports build the bundled cable database so WhatCable can show brand and model info for known cables. Every report you submit helps other users identify their cables at a glance.

## Credits

Built by [Darryl Morley](https://github.com/darrylmorley).

**Contributors:**
- [@rolandgroen](https://github.com/rolandgroen) - option-click technical details, gear menu in popover
- [@0x687931](https://github.com/0x687931) - UI polish, hardware matching, updater hardening, USB-C/MagSafe fix
- [@blech](https://github.com/blech) - USB device matching for hubs, settings view, Cmd+R refresh shortcut
- [@willhsieh](https://github.com/willhsieh) - window/Dock mode
- [@hobostay](https://github.com/hobostay) - SIGTERM handling, charging threshold fix, installer temp file leak fix
- [@JimmFly](https://github.com/JimmFly) - localisation infrastructure, Simplified Chinese translation
- [@IonBazan](https://github.com/IonBazan) - i18n migration to .lproj/.strings, Polish translation, obsolete vendor IDs
- [@bovirus](https://github.com/bovirus) - Italian translation
- [@Vardan933](https://github.com/Vardan933) - Armenian translation
- [@jimmyorz](https://github.com/jimmyorz) - Traditional Chinese translation
- [@dohun0310](https://github.com/dohun0310) - Korean translation
- [@shpokas](https://github.com/shpokas) - Latvian translation
- [@abrauchli](https://github.com/abrauchli) - screenshot fix
- [@durul](https://github.com/durul) - updater security audit
- [@nervous-inhuman](https://github.com/nervous-inhuman) - USB device matching and port state bug reports
- [@hgschmie](https://github.com/hgschmie) - e-marker and Thunderbolt cable documentation that led to e-marker detection
- [@joeshaw](https://github.com/joeshaw) - dual power source bug report, Thunderbolt data samples
- [@jlbyrne-76](https://github.com/jlbyrne-76) - M4 Mac Mini front port e-marker bug report, cable reports
- [@stevetrease](https://github.com/stevetrease) - M3 and M4 ioreg dumps, TB3 data samples
- [@jshier](https://github.com/jshier) - M3 Ultra Thunderbolt data, AppleSmartBattery dumps
- [@NoFr1ends](https://github.com/NoFr1ends) - TB5 hardware confirmation (JHL9580 dock, M5 Pro)
- [@iFindProblems](https://github.com/iFindProblems) - Dock mode bug reports
- [@NaiveTomcat](https://github.com/NaiveTomcat) - Power Monitor regression and MagSafe PD contract bug reports
- [@pandoratactful](https://github.com/pandoratactful) - active Thunderbolt cable e-marker mismatch report

**Sponsors:**
- [@1A1zRyan](https://github.com/1A1zRyan)
- [@SpartanDavie](https://github.com/SpartanDavie)
- [@zippykeyop](https://github.com/zippykeyop)

Thanks to everyone who has filed cable reports, bug reports, and IOKit dumps. These contributions directly improve the cable database and help WhatCable handle more hardware correctly.

Inspired by every time someone has asked "*is this cable any good?*".
