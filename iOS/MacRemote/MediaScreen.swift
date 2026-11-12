import SwiftUI
import UIKit

struct MediaScreen: View {
    @EnvironmentObject var remote: RemoteConnection
    @State private var volume: Double = 50
    @State private var editingVolume = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    GroupBox("Volume") {
                        VStack(spacing: 16) {
                            HStack(spacing: 12) {
                                BigButton(icon: "speaker.wave.1.fill", label: "Down") { remote.media("voldown") }
                                BigButton(icon: "speaker.slash.fill", label: "Mute") { remote.media("mute") }
                                BigButton(icon: "speaker.wave.3.fill", label: "Up") { remote.media("volup") }
                            }
                            HStack {
                                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                                Slider(value: $volume, in: 0...100, step: 1, onEditingChanged: { editing in
                                    editingVolume = editing
                                    if !editing { remote.setVolume(volume) }
                                })
                                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                            }
                            Text("\(Int(volume))%")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    GroupBox("Playback") {
                        HStack(spacing: 12) {
                            BigButton(icon: "backward.fill", label: "Previous") { remote.media("prev") }
                            BigButton(icon: "playpause.fill", label: "Play/Pause") { remote.media("play") }
                            BigButton(icon: "forward.fill", label: "Next") { remote.media("next") }
                        }
                    }

                    GroupBox("Screen") {
                        VStack(spacing: 12) {
                            HStack(spacing: 12) {
                                BigButton(icon: "sun.min.fill", label: "Dimmer") { remote.media("brightdown") }
                                BigButton(icon: "sun.max.fill", label: "Brighter") { remote.media("brightup") }
                            }
                            HStack(spacing: 12) {
                                BigButton(icon: "moon.zzz.fill", label: "Sleep Display") { remote.system("sleepdisplay") }
                                BigButton(icon: "lock.fill", label: "Lock Screen") { remote.key("q", ["cmd", "ctrl"]) }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Media")
            .onAppear { volume = remote.macVolume }
            .onChange(of: volume) { _, newValue in
                if editingVolume { remote.setVolume(newValue) }
            }
            .onReceive(remote.$macVolume) { v in
                if !editingVolume { volume = v }
            }
        }
    }
}

struct BigButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title2)
                Text(label).font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
        }
        .buttonStyle(.bordered)
    }
}
