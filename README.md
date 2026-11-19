# Mac Remote

Control your MacBook from your iPhone: trackpad, clicks, scrolling, typing, keyboard shortcuts, volume, media and brightness. Made for using your Mac from bed or the couch.

It has two parts:

| Part | Folder | What it does |
|---|---|---|
| **MacRemoteServer** | `MacServer/` | A small program that runs on your Mac and does the actual mouse moves and key presses. |
| **Mac Remote** (iPhone app) | `iOS/` | The remote. Finds your Mac automatically and sends it commands. |

## How they connect

The phone finds the Mac with Bonjour (the system AirDrop and AirPlay use to find devices) and connects over the local network:

- **Same Wi-Fi:** works right away.
- **No shared Wi-Fi:** peer-to-peer is turned on (Apple's AWDL, the same direct Wi-Fi + Bluetooth link AirDrop uses). If Wi-Fi and Bluetooth are on on both devices, they can usually still find each other.
- **By IP:** if discovery doesn't work, type the Mac's IP address in the app (port `51515`).

A 6-digit **PIN** shown on the Mac stops other people on your network from connecting. The phone remembers the PIN and reconnects by itself next time.

> Plain Bluetooth isn't used because iOS can't act as a Bluetooth keyboard or mouse for a Mac without special hardware. The Wi-Fi/AWDL route is faster and needs no pairing.

---

## 1. Set up the Mac side

You need Xcode, or just the Command Line Tools (`xcode-select --install`).

### The Mac app (easiest)

Build and install **Mac Remote.app** once:

```bash
cd MacServer
./make-app.sh
```

This puts **Mac Remote** in your Applications folder and opens it. From then on, open it like any app: from Launchpad, Spotlight (⌘ Space → "Mac Remote") or the Dock.

- Click **Connect – make this Mac findable**. Your iPhone can now see the Mac.
- The window shows your **PIN**, whether an iPhone is connected, and an Activity log.
- An icon in the **menu bar** (top right) shows it's running. You can close the window and it keeps running there. Use the menu bar icon to stop it, show the window again, or quit.
- Options: start automatically when the app opens, open at login, allow direct connections without Wi-Fi.

**Give it Accessibility permission.** The first time you click Connect, macOS asks. Turn on **Mac Remote** in System Settings → Privacy & Security → Accessibility. The window shows a warning until it's on.

If you've signed in to Xcode, the script signs the app with your Apple Development certificate, so macOS keeps the permission when you rebuild. Otherwise you may have to turn it off and on again after running `./make-app.sh` again.

After `git pull`, run `./make-app.sh` again to update the app.

### Or run it from Terminal

```bash
cd MacServer
swift run -c release
```

It prints something like:

```
🖥  Mac Remote server for “Your MacBook Pro”
🔑 PIN: 482913
```

Here it's **Terminal** that needs Accessibility permission: System Settings → Privacy & Security → **Accessibility** → turn on **Terminal**. Then press Ctrl+C and run it again.

If macOS asks whether to allow incoming network connections or local network access, click **Allow**.

Run only one of these at a time: the app, Terminal, or the login agent below.

### Optional: a background service with no window

If you don't want the app, this runs the server invisibly at every login:

```bash
cd MacServer
./install-agent.sh
```

This builds it, installs it to `~/Library/Application Support/MacRemote/`, starts it in the background and prints your PIN. You'll need to allow **MacRemoteServer** under Accessibility once. If you rebuild later, macOS may need that permission again: remove the old entry with "−" and run the script again.

To remove it: `./uninstall-agent.sh`

Other options:
```bash
swift run -c release MacRemoteServer --show-pin     # print the PIN
swift run -c release MacRemoteServer --reset-pin    # make a new PIN
swift run -c release MacRemoteServer --set-pin 1234 # choose your own
```

## 2. Put the app on your iPhone

1. Open `iOS/MacRemote.xcodeproj` in **Xcode 16 or newer**.
2. Click the **MacRemote** project → **MacRemote** target → **Signing & Capabilities**:
   - **Team:** choose your Apple ID. A free account works: Xcode → Settings → Accounts → "+".
   - **Bundle Identifier:** change `com.yourname.MacRemote` to something unique, like `com.<yourname>.MacRemote`.
3. Plug in your iPhone (or use the same Wi-Fi after the first time), pick it at the top of Xcode, and press **Run ▶**.
4. On the iPhone, the first time only:
   - Turn on **Developer Mode** if asked: Settings → Privacy & Security → Developer Mode.
   - Trust your developer certificate: Settings → General → VPN & Device Management.
   - When the app asks about **Local Network**, tap **Allow**.

With a free Apple ID the app stops working after 7 days. Just press Run in Xcode again to renew it. A paid developer account lasts a year.

## 3. Use it

Open Mac Remote, tap your Mac, and enter the PIN.

Everything is on one screen:

- **Top bar:** your Mac's name, the **Screen Mirroring** button (📺) and **Settings** (⚙︎).
- **Volume:** mute button and a 0–100% slider.
- **Brightness:** 0–100% slider and a **sleep display** button. The slider controls the built-in screen. External monitors can't be dimmed this way.
- **Playback:** previous, play/pause, next.
- **Trackpad:**
  - One finger: move the pointer (faster swipes move it farther)
  - Tap: click. Double-tap: double-click
  - Two-finger tap: right-click
  - Two fingers: scroll
  - Touch and hold, then move: drag (or hold **Left** and move with another finger)
- **Bottom row:** **Left**, **Double** (double-click), **Right**, and ⌨️ **keyboard**. The keyboard sends what you type straight to the Mac. While it's open, the media controls hide to make room, and a row of extra keys appears (esc, tab, arrows, ⌘C/⌘V/⌘Z, Spotlight…). **More** in that row opens the full key page: paste and send longer text, ⌘⌥⌃⇧ modifiers, page up/down, and shortcuts such as Mission Control, app switcher, zoom and Lock Screen.

**Screen Mirroring** lists the TVs and Apple TVs your Mac can mirror to. Tap one to start, or tap the one marked Mirroring to stop. It works by pressing the Screen Mirroring menu in your Mac's menu bar for you, using the same Accessibility permission as the mouse. Keep its icon in the menu bar: System Settings → Control Center → Screen Mirroring → **Always Show in Menu Bar**. If it stops working after a macOS update, run `swift run -c release MacRemoteServer --dump-menubar Mirroring` and send the output to whoever maintains this.

**Settings:** pointer speed, scroll speed, reverse scrolling, haptics, disconnect.

## Troubleshooting

- **The Mac doesn't show up in the app:** make sure MacRemoteServer is running and both devices are on the same Wi-Fi. Check iPhone Settings → Privacy & Security → **Local Network** → Mac Remote is on. On a Mac with the firewall on, allow incoming connections for the server. As a fallback, connect by IP.
- **It connects, but nothing moves:** this is Accessibility permission. Turn it on (see step 1) and restart the server.
- **Brightness slider is greyed out:** your Mac's display doesn't allow setting brightness this way. This is normal for external monitors.
- **Screen Mirroring shows an error:** make sure the TV is on and on the same Wi-Fi, and that the Screen Mirroring icon is shown in the Mac's menu bar. Apple sometimes changes the menu bar in new macOS versions; the `--dump-menubar Mirroring` option prints what the server can see.
- **"Wrong PIN":** run `--show-pin` on the Mac. After 5 wrong tries the server locks for a minute.

## Security notes

- The PIN is checked before any command is accepted, and wrong attempts are rate-limited.
- Traffic isn't encrypted, so anyone on the *same local network* could in theory see what you type. That's fine at home. Avoid typing passwords through it on public Wi-Fi.
- The server only runs while you're logged in, and only does what the app sends: mouse, keyboard, media keys, volume, display sleep.

## Project layout

```
MacServer/                      Swift package for the Mac
  Sources/MacRemoteServer/
    Entry.swift                 starts the app, or the command-line server when run from Terminal
    MacRemoteApp.swift          the Mac app: window, menu bar icon, app icon
    AppModel.swift              the app's state: start/stop, PIN, permissions, login item
    PinStore.swift, Log.swift   PIN file and log shared by the app and the command line
    RemoteServer.swift          Bonjour + TCP listener, PIN check, command dispatch
    InputController.swift       mouse / keyboard / media-key events (CGEvent)
    SystemActions.swift         volume (osascript), display sleep (pmset)
    Brightness.swift            built-in display brightness (DisplayServices)
    Mirroring.swift             AirPlay screen mirroring via the menu bar (Accessibility API)
    MenuBarInspector.swift      --dump-menubar diagnostic
    Protocol.swift              wire format (same file as the iOS one)
  make-app.sh                   builds and installs Mac Remote.app
  install-agent.sh / uninstall-agent.sh
iOS/
  MacRemote.xcodeproj
  Info.plist                    Local Network + Bonjour permission strings
  project.yml                   backup XcodeGen spec
  MacRemote/
    MacRemoteApp.swift, ContentView.swift
    RemoteConnection.swift      discovery, connection, auto-reconnect, motion coalescing
    ConnectView.swift           pick a Mac / enter PIN
    RemoteScreen.swift          main screen: media controls, trackpad, buttons, Screen Mirroring sheet
    Trackpad.swift              multi-touch trackpad + mouse buttons
    KeyCapture.swift            live keyboard → Mac
    KeysScreen.swift, SettingsScreen.swift
    Protocol.swift
```

The protocol is newline-separated JSON over TCP, e.g. `{"t":"move","dx":3.5,"dy":-1}`, `{"t":"key","s":"c","m":["cmd"]}`, `{"t":"media","s":"volup"}`.
