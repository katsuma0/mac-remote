# Notes for App Review

Paste the relevant part into **App Review Information → Notes** for each app.

## iPhone app

```
Couchpad is a remote control for the user's own Mac. It needs the free companion Mac app "Couchpad Receiver" (submitted alongside / available on the Mac App Store, bundle id <BUNDLE_ID_PREFIX>.couchpad.mac).

How to test:
1. On a Mac (macOS 13+), install and open Couchpad Receiver. Click "Turn On", then "Pair iPhone…". Allow Accessibility when asked.
2. On the iPhone (same Wi-Fi), open Couchpad and tap "Scan Pairing Code", then scan the QR code on the Mac (or tap the Mac in the list and type the 6-digit code).
3. Move a finger on the trackpad area to move the Mac's pointer; tap to click; use the keyboard button to type; use the volume slider.

No account or login is needed. The app only communicates on the local network with the paired Mac; traffic is end-to-end encrypted (CryptoKit: X25519, HKDF, HMAC-SHA256, ChaChaPoly). The camera is only used to scan the pairing QR code.
```

## Mac app

```
Couchpad Receiver lets the user's own iPhone (running the free "Couchpad" iPhone app) control this Mac over the local network.

Why it needs Accessibility: it posts mouse and keyboard events (CGEvent) on the user's behalf, and – only when the user taps "Screen Mirroring" on their iPhone – presses the system Screen Mirroring menu bar item via the Accessibility API. It does nothing unless a paired iPhone sends a command.

Security: only iPhones paired by scanning a QR code shown on the Mac's screen (or entering a 6-digit code shown there, within 3 minutes, max 5 attempts) can connect. All traffic is end-to-end encrypted.

How to test:
1. Open the app, click "Turn On", then "Pair iPhone…" and allow Accessibility in System Settings.
2. Pair the Couchpad iPhone app by scanning the QR code, then use the trackpad on the iPhone.
The app keeps running in the menu bar when its window is closed (it's a background receiver); Quit is in the menu bar menu and the app menu.
```

## Export compliance (both apps)

When App Store Connect asks about encryption:
- "Does your app use encryption?" → **Yes**
- "Does your app qualify for any of the exemptions…?" → it uses only **standard encryption algorithms** (from Apple's CryptoKit) to protect the user's own data between their own devices, with no proprietary cryptography.

Apple then usually asks no further questions; if it asks for documentation, choose the option that the encryption is limited to standard algorithms provided by the operating system. If you're unsure, Apple's guide is at developer.apple.com → "Complying with Encryption Export Regulations".
