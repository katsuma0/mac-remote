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

```bash
cd MacServer
swift run -c release
```

It prints something like:

```
🖥  Mac Remote server for “Your MacBook Pro”
🔑 PIN: 482913
```

**Give it Accessibility permission.** macOS will ask the first time. If it doesn't:
System Settings → Privacy & Security → **Accessibility** → turn on **Terminal** (or whichever terminal app you ran it from). Then press Ctrl+C and run it again. Without this, the mouse and keyboard won't respond.

If macOS asks whether to allow incoming network connections or local network access, click **Allow**.

### Optional: start it automatically at login

So you don't need a Terminal window open:

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

**Screen Mirroring** lists the TVs and Apple TVs your Mac can mirror to. Tap one to start, or tap the one marked Mirroring to stop. It works by operating the Screen Mirroring menu in your Mac's Control Center. The first time, your Mac asks whether Terminal (or MacRemoteServer) may control **System Events**: click **OK**. If you clicked Don't Allow, turn it on under System Settings → Privacy & Security → Automation.

**Settings:** pointer speed, scroll speed, reverse scrolling, haptics, disconnect.

## Troubleshooting

- **The Mac doesn't show up in the app:** make sure MacRemoteServer is running and both devices are on the same Wi-Fi. Check iPhone Settings → Privacy & Security → **Local Network** → Mac Remote is on. On a Mac with the firewall on, allow incoming connections for the server. As a fallback, connect by IP.
- **It connects, but nothing moves:** this is Accessibility permission. Turn it on (see step 1) and restart the server.
- **Brightness slider is greyed out:** your Mac's display doesn't allow setting brightness this way. This is normal for external monitors.
- **Screen Mirroring shows an error:** make sure the TV is on and on the same Wi-Fi, and that System Events is allowed under Privacy & Security → Automation. Apple sometimes changes Control Center's layout in new macOS versions. If it says it couldn't find Screen Mirroring, send me the message.
- **"Wrong PIN":** run `--show-pin` on the Mac. After 5 wrong tries the server locks for a minute.

## Security notes

- The PIN is checked before any command is accepted, and wrong attempts are rate-limited.
- Traffic isn't encrypted, so anyone on the *same local network* could in theory see what you type. That's fine at home. Avoid typing passwords through it on public Wi-Fi.
- The server only runs while you're logged in, and only does what the app sends: mouse, keyboard, media keys, volume, display sleep.

## Project layout

```
MacServer/                      Swift package for the Mac
  Sources/MacRemoteServer/
    main.swift                  startup, PIN, permission check
    RemoteServer.swift          Bonjour + TCP listener, PIN check, command dispatch
    InputController.swift       mouse / keyboard / media-key events (CGEvent)
    SystemActions.swift         volume (osascript), display sleep (pmset)
    Brightness.swift            built-in display brightness (DisplayServices)
    Mirroring.swift             AirPlay screen mirroring via Control Center (AppleScript)
    Protocol.swift              wire format (same file as the iOS one)
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
