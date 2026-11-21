import SwiftUI
import UIKit

/// The one main screen: media controls on top, trackpad in the middle, mouse buttons at the bottom.
struct RemoteScreen: View {
    @EnvironmentObject var remote: RemoteConnection
    @AppStorage("pointerSpeed") private var pointerSpeed = 1.5
    @AppStorage("scrollSpeed") private var scrollSpeed = 1.0
    @AppStorage("invertScroll") private var invertScroll = false
    @AppStorage("haptics") private var haptics = true

    @State private var typing = false
    @State private var showSettings = false
    @State private var showMirroring = false
    @State private var showMoreKeys = false

    var body: some View {
        VStack(spacing: 10) {
            header

            // While typing, the keyboard takes half the screen, so the media controls step aside
            // to leave room for the trackpad.
            if !typing {
                MediaControls(haptics: haptics)
            }

            trackpad

            if typing {
                SpecialKeysBar(onMore: { showMoreKeys = true })
            }

            mouseButtons
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(
            KeyCaptureField(isActive: $typing,
                            onText: { remote.type($0) },
                            onBackspace: { remote.key("delete") })
                .frame(width: 0, height: 0)
        )
        .animation(.easeInOut(duration: 0.2), value: typing)
        .sheet(isPresented: $showSettings) {
            SettingsScreen().environmentObject(remote)
        }
        .sheet(isPresented: $showMirroring) {
            MirroringSheet().environmentObject(remote)
        }
        .sheet(isPresented: $showMoreKeys) {
            KeysScreen().environmentObject(remote)
        }
    }

    // MARK: Header: Mac name, Screen Mirroring, Settings

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(remote.state == .connected(remote.macName) ? Color.green : Color.yellow)
                .frame(width: 8, height: 8)
            Text(remote.macName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer()
            HeaderButton(icon: "airplayvideo", label: "Screen Mirroring") { showMirroring = true }
            HeaderButton(icon: "gearshape", label: "Settings") { showSettings = true }
        }
        .padding(.top, 4)
    }

    // MARK: Trackpad

    private var trackpad: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(.secondarySystemBackground))
            VStack(spacing: 6) {
                Image(systemName: "hand.draw")
                    .font(.system(size: 30))
                Text("Tap to click · Two-finger tap to right-click\nTwo fingers to scroll · Hold to drag")
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.tertiary)
            .allowsHitTesting(false)

            TrackpadSurface(remote: remote,
                            pointerSpeed: pointerSpeed,
                            scrollSpeed: scrollSpeed,
                            invertScroll: invertScroll,
                            haptics: haptics)
        }
        .frame(maxHeight: .infinity)
        .layoutPriority(1)
    }

    // MARK: Bottom row: Left, Double-click, Right, Keyboard

    private var mouseButtons: some View {
        HStack(spacing: 8) {
            MouseButtonView(title: "Left", right: false, haptics: haptics)
            Button {
                if haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                remote.doubleClick()
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "cursorarrow.click.2")
                    Text("Double").font(.caption2)
                }
                .frame(width: 64)
                .frame(maxHeight: .infinity)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            MouseButtonView(title: "Right", right: true, haptics: haptics)
            Button {
                typing.toggle()
            } label: {
                Image(systemName: typing ? "keyboard.chevron.compact.down" : "keyboard")
                    .font(.title3)
                    .frame(width: 56)
                    .frame(maxHeight: .infinity)
                    .background(typing ? Color.accentColor.opacity(0.3) : Color(.tertiarySystemFill),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .frame(height: 60)
    }
}

private struct HeaderButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: 40, height: 36)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Volume, brightness, playback

struct MediaControls: View {
    @EnvironmentObject var remote: RemoteConnection
    let haptics: Bool

    @State private var volume: Double = 50
    @State private var editingVolume = false
    @State private var brightness: Double = 50
    @State private var editingBrightness = false

    var body: some View {
        VStack(spacing: 10) {
            // Volume: mute button + 0–100% slider
            HStack(spacing: 10) {
                SmallIconButton(icon: remote.macMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                highlighted: remote.macMuted, haptics: haptics) {
                    remote.toggleMute()
                }
                Slider(value: $volume, in: 0...100, step: 1, onEditingChanged: { editing in
                    editingVolume = editing
                    if !editing { remote.setVolume(volume) }
                })
                .opacity(remote.macMuted ? 0.5 : 1)
                Text("\(Int(volume))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }

            // Brightness: a 0–100% slider where the Mac supports it, otherwise −/+ (the brightness
            // keys); then sleep display, or lock screen where the Mac can't sleep the display.
            HStack(spacing: 10) {
                if remote.supports(Capability.brightnessSlider) {
                    Image(systemName: "sun.max.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 40)
                    Slider(value: $brightness, in: 0...100, step: 1, onEditingChanged: { editing in
                        editingBrightness = editing
                        if !editing { remote.setBrightness(brightness) }
                    })
                } else {
                    SmallIconButton(icon: "sun.min.fill", highlighted: false, haptics: haptics) {
                        remote.media("brightdown")
                    }
                    .accessibilityLabel("Dimmer")
                    Text("Brightness")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    SmallIconButton(icon: "sun.max.fill", highlighted: false, haptics: haptics) {
                        remote.media("brightup")
                    }
                    .accessibilityLabel("Brighter")
                }
                if remote.supports(Capability.sleepDisplay) {
                    SmallIconButton(icon: "moon.zzz.fill", highlighted: false, haptics: haptics) {
                        remote.system("sleepdisplay")
                    }
                    .accessibilityLabel("Sleep display")
                } else {
                    SmallIconButton(icon: "lock.fill", highlighted: false, haptics: haptics) {
                        remote.key("q", ["cmd", "ctrl"])
                    }
                    .accessibilityLabel("Lock screen")
                }
            }

            // Playback
            HStack(spacing: 10) {
                PlaybackButton(icon: "backward.fill", haptics: haptics) { remote.media("prev") }
                PlaybackButton(icon: "playpause.fill", haptics: haptics) { remote.media("play") }
                PlaybackButton(icon: "forward.fill", haptics: haptics) { remote.media("next") }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onAppear {
            volume = remote.macVolume
            brightness = remote.macBrightness
        }
        .onChange(of: volume) { _, value in
            if editingVolume { remote.setVolume(value) }
        }
        .onChange(of: brightness) { _, value in
            if editingBrightness { remote.setBrightness(value) }
        }
        .onReceive(remote.$macVolume) { value in
            if !editingVolume { volume = value }
        }
        .onReceive(remote.$macBrightness) { value in
            if !editingBrightness { brightness = value }
        }
    }
}

private struct SmallIconButton: View {
    let icon: String
    let highlighted: Bool
    let haptics: Bool
    let action: () -> Void

    var body: some View {
        Button {
            if haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            action()
        } label: {
            Image(systemName: icon)
                .font(.body)
                .frame(width: 40, height: 34)
                .background(highlighted ? Color.red.opacity(0.25) : Color(.tertiarySystemFill),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct PlaybackButton: View {
    let icon: String
    let haptics: Bool
    let action: () -> Void

    var body: some View {
        Button {
            if haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            action()
        } label: {
            Image(systemName: icon)
                .font(.title3)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Screen mirroring

struct MirroringSheet: View {
    @EnvironmentObject var remote: RemoteConnection
    @Environment(\.dismiss) private var dismiss

    private var isMirroring: Bool { remote.mirrorScreens.contains(where: \.connected) }

    var body: some View {
        NavigationStack {
            List {
                if let error = remote.mirrorError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    if remote.mirrorLoading {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Asking your Mac…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(remote.mirrorScreens) { screen in
                        Button {
                            if screen.connected {
                                remote.mirrorStop()
                            } else {
                                remote.mirrorConnect(screen.name)
                            }
                        } label: {
                            HStack {
                                Label(screen.name, systemImage: "tv")
                                    .foregroundStyle(.primary)
                                Spacer()
                                if screen.connected {
                                    Text("Mirroring")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .disabled(remote.mirrorLoading)
                    }
                    if !remote.mirrorLoading && remote.mirrorScreens.isEmpty && remote.mirrorError == nil {
                        Text("No screens found. Make sure your TV or Apple TV is on and on the same Wi-Fi, then refresh.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Screens your Mac can mirror to")
                } footer: {
                    Text("Tap a screen to start mirroring, or tap the one marked Mirroring to stop.")
                }

                Section {
                    Button("Stop Mirroring", role: .destructive) { remote.mirrorStop() }
                        .disabled(!isMirroring || remote.mirrorLoading)
                    Button("Open Screen Mirroring menu on the Mac") { remote.mirrorOpenOnMac() }
                } footer: {
                    Text("This presses the Screen Mirroring menu on your Mac for you. Keep its icon in the Mac's menu bar: System Settings → Control Center → Screen Mirroring → Always Show in Menu Bar.")
                }
            }
            .navigationTitle("Screen Mirroring")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        remote.mirrorRefresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(remote.mirrorLoading)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { remote.mirrorRefresh() }
        }
    }
}
