# Tether

Per-device settings for the things plugged into a Mac. For now it does one thing: a mouse wheel
scrolls the traditional way while the trackpad keeps natural scrolling, so there's no switch to
flip when the mouse is plugged in or unplugged.

It runs in the menu bar and uses almost no memory.

## Setup

```sh
curl -fsSL https://raw.githubusercontent.com/VedAtal/swift-app-kit/main/scripts/install.sh | bash -s tether
```

That one command does everything:

1. Checks that Swift is installed. If it isn't, it opens Apple's Command Line Tools installer;
   re-run the command once that finishes. Full Xcode isn't needed.
2. Downloads the latest version from GitHub ([VedAtal/tether](https://github.com/VedAtal/tether)),
   along with [swift-app-kit](https://github.com/VedAtal/swift-app-kit), the parts it shares with
   my other menu bar apps.
3. Creates a local code-signing certificate (first run only, see
   [why](https://github.com/VedAtal/swift-app-kit#how-setupsh-fits-together)).
4. Builds Tether and installs it to `~/Applications/Tether.app`, then deletes the download.
5. Launches it and sets it to start at login.

To work on Tether, clone the repo (`git clone https://github.com/VedAtal/tether.git`). Its
`setup.sh` takes:

| Command | Installs |
|---|---|
| `./setup.sh` | The latest commit on GitHub (the default) |
| `./setup.sh --local` | This folder as it is, including changes you haven't committed or pushed |
| `./setup.sh --build-only` | Nothing. It just builds `build/Tether.app` from this folder |
| `./setup.sh --uninstall` | Nothing. It removes Tether completely ([details](#uninstall)) |

**Two manual steps:**

- The first time Tether runs, macOS asks you to allow it under
  **System Settings → Privacy & Security → Accessibility**. Turn it on. Tether can't change
  scroll events without it.
- Keep **natural scrolling** on in **System Settings → Trackpad**. That is the trackpad's
  direction; Tether turns the wheel's back around.

### Updating

**To the latest on GitHub:** click **Update Tether** in the menu bar menu, or run `./setup.sh` in
a clone. Both download anything newer, rebuild, and restart Tether. If you're already on the
latest commit, they say so and change nothing. Your settings and the Accessibility permission
stay.

**To try local changes before pushing them:** run `./setup.sh --local`. The next
**Update Tether** or plain `./setup.sh` replaces that build with whatever is on GitHub.

The menu shows which version is running, for example **Version 59ba24f · built 2 minutes ago**.
If an update fails, nothing is replaced, and the full output is in
`~/Library/Logs/Tether/update.log`.

## Using it

| Device | Scrolls |
|---|---|
| Trackpad, Magic Mouse | The way macOS is set (natural) |
| Mouse with a wheel | The traditional way: wheel down moves the page down |

There's nothing to press. Plug a mouse in or unplug it and each device keeps its direction.

While Tether is running, its **cable icon** sits in the menu bar at the top right. Click it for
**Traditional Mouse Wheel** (a checkmark; click to turn it off or on), plus **Launch at Login**,
**Settings…**, **Update Tether**, and **Quit Tether**.

### Settings

- **Mouse.** Traditional wheel scrolling, the same switch as the menu item.
- **Launch at login**, and whether Accessibility access is granted.

## Uninstall

```sh
~/Applications/Tether.app/Contents/Resources/setup.sh --uninstall
```

This removes the app, its settings, the login item, the Accessibility entry, and the signing
certificate.

## Troubleshooting

**The wheel still scrolls the natural way.** Tether probably doesn't have Accessibility access.
The menu bar menu shows **Grant Accessibility Access…** while it's missing. If System Settings
already shows Tether as on, select it, remove it with **−**, then quit Tether from its menu and
open it again (Spotlight → Tether); macOS will ask again.

**The trackpad scrolls the traditional way.** Natural scrolling is off in System Settings, and
the menu says so. Turn it on under **System Settings → Trackpad**. Tether leaves the wheel alone
while it's off, because the wheel is already traditional.

**A mouse isn't affected.** Tether tells devices apart by how they scroll: a wheel sends whole
steps, a trackpad sends a continuous stream. A mouse whose own software smooths its scrolling
looks like a trackpad and keeps the macOS direction.

## How it works

Tether is built on [swift-app-kit](https://github.com/VedAtal/swift-app-kit), which provides the
parts my menu bar apps share: the install script, the menu bar menu's standard items, the
Settings window layout, launch at login, and updates. This repo holds only what's specific to
Tether:

```
Sources/Tether/
├── main.swift            Starts the app through swift-app-kit
├── AppDelegate.swift     Turns the scroll tap on and off, adds Tether's menu items
├── ScrollTap.swift       Reverses wheel scroll events (needs Accessibility)
├── SettingsView.swift    Tether's section of the Settings window
└── Preferences.swift     The settings, saved in UserDefaults
app.env                   Name, bundle ID, icons: what swift-app-kit's setup builds
setup.sh                  Fetches swift-app-kit and runs its install script
```

A few details that aren't obvious:

- **macOS has one scroll direction.** The natural scrolling switch under Trackpad and the one
  under Mouse are the same setting. Tether leaves it alone and changes events instead.
- **It only sees scroll events.** The event tap asks for scroll-wheel events and nothing else,
  so keystrokes and clicks never reach Tether.
- **Three deltas per axis.** A scroll event carries each axis in lines, in points, and as a
  fixed-point number, and different apps read different ones. Tether negates all three, lines
  first, because setting the line delta resets the other two.
- **Waiting for access.** macOS refuses the tap until Accessibility is granted. Tether retries
  every 2 seconds for 5 minutes after launch, and again each time the menu opens.

### Development

```sh
./setup.sh --local        # build and install what is in this folder right now
./setup.sh --build-only   # build and sign build/Tether.app without installing
swift build               # just compile
```

To change the shared parts (menu, Settings layout, install script), edit
[swift-app-kit](https://github.com/VedAtal/swift-app-kit) and build Tether against your local
copy with `swift package edit swift-app-kit --path ../swift-app-kit`. The kit's README explains
the rest of the workflow.

The project builds with only the Command Line Tools, so the code avoids SwiftUI's `@State` and
`@StateObject`, whose macro plugin only comes with full Xcode.

## License

MIT. See [LICENSE](LICENSE).
