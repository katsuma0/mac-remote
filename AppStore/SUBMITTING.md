# Putting Couchpad on the App Store

Both apps are free. You submit two apps: **Couchpad** (iPhone) and **Couchpad Receiver** (Mac).
Everything technical is already set up in `Couchpad.xcodeproj`; these are the steps only you can do.

---

## 0. One-time: join the Apple Developer Program

The free Apple ID used for testing on your own phone **can't** publish to the App Store.

1. Go to <https://developer.apple.com/programs/enroll/> and enroll as an **Individual** ($99/year).
   Approval usually takes a day or two.
2. When it's active, find your **Team ID**: developer.apple.com → Account → Membership details (10 characters, e.g. `ABCDE12345`).

## 1. Fill in your details (once)

Open `Config/Shared.xcconfig` in any text editor and set:

```
DEVELOPMENT_TEAM = ABCDE12345        ← your Team ID
BUNDLE_ID_PREFIX = com.yourname      ← something you own, all lowercase, e.g. com.katsuma
```

That gives the apps the IDs `com.yourname.couchpad` (iPhone) and `com.yourname.couchpad.mac` (Mac).

## 2. Check that both apps build and run

1. Open **Couchpad.xcodeproj** (at the top of the repository) in Xcode 16 or newer.
2. At the top of the window, choose the scheme **Couchpad Mac** → **My Mac** → press **▶︎**.
   The Mac app opens. Click **Turn On** and allow Accessibility when asked.
3. Choose the scheme **Couchpad** → your iPhone → **▶︎**. Pair by scanning the code on the Mac.

> Xcode signs everything automatically ("Automatically manage signing" is on). If it complains about the bundle ID, make sure `BUNDLE_ID_PREFIX` is unique to you.

## 3. Create the two apps in App Store Connect

Go to <https://appstoreconnect.apple.com> → **Apps** → **+** → **New App**, twice:

| | iPhone app | Mac app |
|---|---|---|
| Platform | iOS | macOS |
| Name | `Couchpad: Trackpad Remote` | `Couchpad Receiver` |
| Primary language | English | English |
| Bundle ID | `com.yourname.couchpad` | `com.yourname.couchpad.mac` |
| SKU | `couchpad-ios` | `couchpad-mac` |

(If a name is taken, try a variation – the name under the icon stays "Couchpad" either way.)

## 4. Publish the privacy policy

App Store Connect requires a public **Privacy Policy URL**. The policy is ready in `AppStore/PRIVACY.md`. Easiest ways to get a link:

- **GitHub Pages:** repository → Settings → Pages → Source: *Deploy from a branch*, `main`, `/ (root)`. The policy is then at
  `https://<your-github-name>.github.io/<repo-name>/AppStore/PRIVACY`.
  (Pages on a private repository needs a paid GitHub plan – otherwise use the next option.)
- **Any other site / Notion / Google Doc** set to "anyone with the link can view": paste the text there.

## 5. Fill in the App Store pages

For each app, in App Store Connect:

1. **App Information:** Category = Utilities. Content Rights: "No, it does not contain third-party content".
2. **Pricing and Availability:** Price = Free (USD 0). Choose countries.
3. **App Privacy:** Privacy Policy URL from step 4. Then **Get Started → "No, we do not collect data from this app"** → Publish. (True: Couchpad collects nothing.)
4. **The version page (1.0):**
   - Screenshots, description, keywords, support URL, promotional text: copy from `AppStore/Metadata.md`.
   - **App Review Information:** your contact details; turn **off** "Sign-in required"; paste the notes from `AppStore/ReviewNotes.md`.
   - **Age rating:** answer "None/No" to everything → 4+.

## 6. Upload the builds

For each app:

1. In Xcode choose the scheme (**Couchpad** with *Any iOS Device (arm64)*, or **Couchpad Mac** with *Any Mac*).
2. **Product → Archive**. When it finishes, the Organizer window opens.
3. **Distribute App → App Store Connect → Upload**, accept the defaults.
4. Wait for the email "has completed processing" (5–30 minutes).
5. On the version page in App Store Connect, under **Build**, click **+** and pick the upload.
6. **Export compliance:** see the bottom of `AppStore/ReviewNotes.md`.

## 7. Test with TestFlight (recommended)

Before submitting, install the uploaded iPhone build through **TestFlight** (App Store Connect → TestFlight → add yourself as a tester) and the Mac build the same way. That's exactly what reviewers will get.

## 8. Submit for review

On each version page click **Add for Review → Submit**. Submit the **Mac app first or both together**, because reviewers of the iPhone app need the Mac app to test it.

Review usually takes 1–3 days. If Apple asks a question, reply in App Store Connect → the app → **App Review**.

---

## Releasing an update later

1. In `Config/Shared.xcconfig`, raise `MARKETING_VERSION` (e.g. `1.1`) and `CURRENT_PROJECT_VERSION` (e.g. `2`).
2. In App Store Connect, click **+** next to the platform to create the new version and write "What's New".
3. Archive, upload and submit as above.

## What's different about the Mac App Store build

The App Store version runs in Apple's sandbox and can't use private parts of macOS. Compared with the development build from `MacServer/make-app.sh`:

- **Brightness:** −/+ buttons on the iPhone instead of a 0–100% slider (setting an exact brightness needs a private framework).
- **Sleep Display:** replaced by a **Lock Screen** button on the iPhone.
- Everything else – trackpad, keyboard, volume slider, mute, playback, Screen Mirroring, pairing – is the same.

The iPhone app adapts automatically to whichever Mac version it's connected to.

## If App Review rejects something

Common reasons and fixes:

- **"Guideline 2.1 – couldn't test because it requires another app":** reply with the steps in `ReviewNotes.md` and mention the Mac app's App Store link.
- **"Guideline 4.2 – minimum functionality" or "5.2.5 – Apple trademarks":** the names were chosen to avoid "Mac"/"Apple" in the app name; if they still object, rename in App Store Connect only (no code change needed).
- **Accessibility questions (Mac):** the explanation is in `ReviewNotes.md` – reply with it.
