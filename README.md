# Tether

Per-device settings for the things plugged into a Mac:

- **Monitor brightness.** A slider for each external monitor, and the keyboard's brightness keys
  change whichever screen the pointer is on.
- **Screensaver.** Ten animated 3D scenes, path-traced on the Mac's GPU and drawn as one picture
  across all the screens, for a set time or until you stop it. The displays stay awake while it runs.
- **Mouse wheel direction.** A wheel scrolls the traditional way while the trackpad keeps natural
  scrolling, so there's no switch to flip when the mouse is plugged in or unplugged.

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
  scroll events or take over the brightness keys without it. The sliders work either way.
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

While Tether is running, its **cable icon** sits in the menu bar at the top right. Click it for
the panel:

| In the panel | Does |
|---|---|
| **Displays**: Brightness, a slider per external monitor | Sets that monitor's brightness |
| **Displays**: Screensaver, a scene, how long, **Start** (or Return) | Runs the screensaver. Any key, click, mouse movement or switch to another app ends it |
| **Displays**: Lock when it ends | Locks the Mac when the screensaver ends, however it ends. On by default |
| **Mouse**: Traditional wheel | Turns the wheel direction below off or on |
| **⚙** | Opens Settings |
| **⋯** (or right-click the icon) | **Launch at Login**, **Update Tether**, the version, **Quit Tether** |

Two monitors are named **Left** and **Right** by how they're arranged, because identical monitors
give macOS the same name.

| Press | To |
|---|---|
| The brightness keys, pointer on an external monitor | Change that monitor, in the same sixteen steps as the built-in screen |
| The brightness keys, pointer on the built-in screen | Change the built-in screen, as always |

| Scene | Shows |
|---|---|
| Campfire | A campfire in a moonlit forest clearing, by a tent and a misty lake |
| Neon City | A rain-soaked street of walk-ups, faulty neon signs and traffic, seen from a footbridge |
| Neon Lines | A concrete gallery at night: neon sculptures, and light trails mirrored in a black floor |
| Retro Grid | An endless synthwave drive toward a striped sunset, past mesas and palms |
| Orb Runner | A ship that flies itself through gates in a sandstone canyon and racks up a score |
| Aurora | Aurora curtains over snowy peaks, mirrored in a still lake by a log cabin |
| Deep Sea | A reef with kelp, a school of fish, glowing jellyfish, sunbeams and caustics |
| Starfield | A ringed planet in a nebula, with rocks tumbling and stars streaming past |
| Lava Lamp | A lava lamp on a desk at night, rain on the window and a city behind it |
| Fireflies | A meadow at the edge of a wood on a summer night, full of fireflies |

| Device | Scrolls |
|---|---|
| Trackpad, Magic Mouse | The way macOS is set (natural) |
| Mouse with a wheel | The traditional way: wheel down moves the page down |

### Settings

- **Displays.** Whether the brightness keys follow the pointer onto external monitors.
- **Mouse.** Traditional wheel scrolling, the same switch as in the panel.
- **Launch at login**, and whether Accessibility access is granted.

## Uninstall

```sh
~/Applications/Tether.app/Contents/Resources/setup.sh --uninstall
```

This removes the app, its settings, the login item, the Accessibility entry, and the signing
certificate.

## Troubleshooting

**A monitor isn't in the panel.** It didn't answer Tether's brightness command. Monitors take
commands over the video cable, and some adapters don't pass them on: an HDMI-to-USB-C cable is a
common one. A direct HDMI, DisplayPort or USB-C connection does. A few monitors also have a
"DDC/CI" switch in their own menu, which has to be on.

**The brightness keys or the wheel direction do nothing.** Tether probably doesn't have
Accessibility access. The panel shows **Grant Accessibility Access…** while it's missing. If System Settings
already shows Tether as on, select it, remove it with **−**, then quit Tether from its menu and
open it again (Spotlight → Tether); macOS will ask again.

**The trackpad scrolls the traditional way.** Natural scrolling is off in System Settings, and
the panel says so. Turn it on under **System Settings → Trackpad**. Tether leaves the wheel alone
while it's off, because the wheel is already traditional.

**A mouse isn't affected.** Tether tells devices apart by how they scroll: a wheel sends whole
steps, a trackpad sends a continuous stream. A mouse whose own software smooths its scrolling
looks like a trackpad and keeps the macOS direction.

## How it works

Tether is built on [swift-app-kit](https://github.com/VedAtal/swift-app-kit), which provides the
parts my menu bar apps share: the install script, the panel's frame and the standard menu, the
Settings window layout, launch at login, and updates. This repo holds only what's specific to
Tether:

```
Sources/Tether/
├── main.swift            Starts the app through swift-app-kit
├── AppDelegate.swift     Turns the event tap on and off, routes its events
├── PanelView.swift       The panel: brightness sliders, the wheel switch
├── Displays.swift        The monitors that take commands, their brightness, the brightness keys
├── DDC.swift             Sends a monitor commands over its video cable
├── EventTap.swift        Changes or swallows input events (needs Accessibility)
├── WheelScroll.swift     Reverses wheel scroll events
├── Screensaver/
│   ├── Screensaver.swift     A window per screen, what ends it, keeping the displays awake
│   ├── SaverLayout.swift     Where each screen sits in the picture
│   ├── SaverScene.swift      What a scene declares: camera, meshes, lights, its Metal, motion
│   ├── SaverRenderer.swift   Baking a scene's light, then drawing every screen each frame
│   ├── ShaderCore.swift      The path tracer, live pass, particles and film finish, in Metal
│   ├── ShaderPrelude.swift   What every scene's Metal gets: lighting, noise, SDF helpers
│   ├── GPUWorld.swift        A scene's meshes and lights on the GPU, ready for ray tracing
│   ├── ScreenTargets.swift   One screen's baked images, bloom and upscaler
│   ├── Mesh.swift            Building meshes in code
│   ├── Procedural.swift      Noise and seeded random numbers for building scenes
│   └── Scenes/               One file per scene, and the list of them
├── SettingsView.swift    Tether's sections of the Settings window
└── Preferences.swift     The settings, saved in UserDefaults
app.env                   Name, bundle ID, icons: what swift-app-kit's setup builds
setup.sh                  Fetches swift-app-kit and runs its install script
```

A few details that aren't obvious:

- **macOS has one scroll direction.** The natural scrolling switch under Trackpad and the one
  under Mouse are the same setting. Tether leaves it alone and changes events instead.
- **It only sees scroll events and media keys.** The event tap asks for those two kinds and
  nothing else, so typing and clicks never reach Tether.
- **Monitor commands use private macOS calls.** Apple silicon has no public API for DDC/CI, the
  commands a monitor takes over its cable. Tether looks the private ones up at run time, so a
  macOS that drops them costs the brightness feature and nothing else.
- **Identical monitors are told apart by port.** Two of the same model report the same name and
  serial number. The one thing linking a screen to its command channel is the port it's on, so
  that is what Tether matches them by.
- **One picture across the screens.** Every screen draws the same scene, through a window onto
  the part of it where that screen sits in the display arrangement. The scene's scale is set by
  the band of height all the screens share, so its main subject shows on each of them.
- **Scenes look through one window.** The eye stands still and every screen is a pane of a
  window onto the world: each screen's rays pass through its own part of one image plane, so a
  line crossing from one screen to the next stays straight. All screens draw the same moment, so
  flames, sparks and traffic match across them.
- **The light is path-traced once, then mixed live.** Because the eye never moves, a scene's
  still parts look the same every frame. When the screensaver starts, Tether path-traces them
  with the GPU's hardware ray tracing into one image per light (the moon, the fire, each neon
  circuit) while the picture fades in, then keeps refining them between frames for a minute or
  two. Each frame scales those images by each light's current brightness, so a flicker relights
  a fully path-traced scene for almost nothing, and draws what moves (flames, wax, cars, fish,
  rain) live on top. A film finish follows: bloom, halation, AgX tone mapping, grain, and one
  vignette across all the screens rather than one per screen.
- **Everything is made from code.** There are no image, model or video files: meshes are built
  when a scene starts, surfaces are Metal functions (bark, granite, wet asphalt, neon), and all
  of it is compiled then, in under 3 seconds. Compiling ahead of time needs full Xcode.
- **Metal only.** SceneKit is soft-deprecated, and neither it nor RealityKit can bake light this
  way, so the renderer uses Metal, plus MetalFX to upscale on Retina screens.
- **What it needs.** macOS 26, and an M3 or later for the first clean picture to take seconds:
  M1 and M2 ray-trace without hardware help. The screensaver holds about 1 GB of GPU memory
  while it runs and frees it when it stops.
- **Locking uses a private macOS call**, the one behind the system's Lock Screen command, looked
  up at run time. Keeping the displays awake also keeps macOS from locking on its idle timer, so
  Tether locks instead. The lock screen goes up before Tether's windows come down, so the desktop
  never shows unlocked.
- **Keeping the displays awake** is `caffeinate -d`, with `-t` for a set time, and `-w` so it ends
  if Tether quits first. Tether stops it as soon as the screensaver ends.
- **A drag skips values.** A monitor takes commands more slowly than a slider asks for them, so
  each monitor gets the newest value when it's ready for one.
- **Three deltas per axis.** A scroll event carries each axis in lines, in points, and as a
  fixed-point number, and different apps read different ones. Tether negates all three, lines
  first, because setting the line delta resets the other two.
- **Waiting for access.** macOS refuses the tap until Accessibility is granted. Tether retries
  every 2 seconds for 5 minutes after launch, and again each time the panel opens.

### Development

```sh
./setup.sh --local        # build and install what is in this folder right now
./setup.sh --build-only   # build and sign build/Tether.app without installing
swift build               # just compile
```

To change the shared parts (panel frame, menu, Settings layout, install script), edit
[swift-app-kit](https://github.com/VedAtal/swift-app-kit) and build Tether against your local
copy with `swift package edit swift-app-kit --path ../swift-app-kit`. The kit's README explains
the rest of the workflow.

The project builds with only the Command Line Tools, so the code avoids SwiftUI's `@State` and
`@StateObject`, whose macro plugin only comes with full Xcode.

## License

MIT. See [LICENSE](LICENSE).
