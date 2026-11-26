import SwiftUI
import UIKit

/// The Tools sheet: Presentation, Apps and Clipboard.
struct ToolsSheet: View {
    @EnvironmentObject var remote: RemoteConnection
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    PresentationView()
                } label: {
                    ToolRow(icon: "play.rectangle.fill", color: .orange, title: "Presentation",
                            subtitle: "Next / previous slide, start, black screen, timer")
                }
                if remote.supports(Capability.apps) {
                    NavigationLink {
                        AppsView()
                    } label: {
                        ToolRow(icon: "square.grid.3x3.fill", color: .blue, title: "Apps",
                                subtitle: "Switch between, open and quit apps on the Mac")
                    }
                }
                if remote.supports(Capability.clipboard) {
                    NavigationLink {
                        ClipboardView()
                    } label: {
                        ToolRow(icon: "doc.on.clipboard.fill", color: .green, title: "Clipboard",
                                subtitle: "Send text to the Mac, or get the Mac's clipboard")
                    }
                }
            }
            .navigationTitle("Tools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct ToolRow: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Presentation

struct PresentationView: View {
    @EnvironmentObject var remote: RemoteConnection
    @AppStorage("presentationApp") private var appRaw = PresentationApp.keynote.rawValue
    @AppStorage("haptics") private var haptics = true
    @State private var startedAt: Date?
    @State private var slide = 1

    enum PresentationApp: String, CaseIterable, Identifiable {
        case keynote, powerpoint, slides
        var id: String { rawValue }

        var title: String {
            switch self {
            case .keynote: return "Keynote"
            case .powerpoint: return "PowerPoint"
            case .slides: return "Google Slides"
            }
        }

        /// The app's "start slideshow" shortcut.
        var start: (key: String, modifiers: [String]) {
            switch self {
            case .keynote: return ("p", ["cmd", "alt"])
            case .powerpoint: return ("return", ["cmd", "shift"])
            case .slides: return ("return", ["cmd"])
            }
        }
    }

    private var app: PresentationApp { PresentationApp(rawValue: appRaw) ?? .keynote }

    var body: some View {
        VStack(spacing: 14) {
            Picker("App", selection: $appRaw) {
                ForEach(PresentationApp.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)

            HStack {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(elapsedText(at: context.date))
                        .font(.system(.title2, design: .monospaced).weight(.semibold))
                }
                Spacer()
                Text("Slide \(slide)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    startedAt = startedAt == nil ? Date() : nil
                    slide = 1
                } label: {
                    Image(systemName: startedAt == nil ? "timer" : "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(startedAt == nil ? "Start timer" : "Reset timer")
            }

            HStack(spacing: 10) {
                SmallAction(title: "Start", icon: "play.fill") {
                    remote.key(app.start.key, app.start.modifiers)
                    if startedAt == nil { startedAt = Date() }
                    slide = 1
                }
                SmallAction(title: "Black", icon: "rectangle.fill") { remote.key("b") }
                SmallAction(title: "End", icon: "stop.fill") { remote.key("escape") }
            }

            HStack(spacing: 12) {
                SlideButton(icon: "chevron.left", title: "Back") {
                    remote.key("left")
                    slide = max(1, slide - 1)
                    tap()
                }
                .frame(maxWidth: .infinity)
                SlideButton(icon: "chevron.right", title: "Next", prominent: true) {
                    remote.key("right")
                    slide += 1
                    tap()
                }
                .frame(maxWidth: .infinity)
                .layoutPriority(1)
            }
            .frame(maxHeight: .infinity)
        }
        .padding()
        .navigationTitle("Presentation")
        .navigationBarTitleDisplayMode(.inline)
        // Keep the iPhone awake while presenting.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func elapsedText(at date: Date) -> String {
        guard let startedAt else { return "0:00" }
        let seconds = max(0, Int(date.timeIntervalSince(startedAt)))
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func tap() {
        if haptics { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    }
}

private struct SmallAction: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.bordered)
    }
}

private struct SlideButton: View {
    let icon: String
    let title: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 44, weight: .bold))
                Text(title).font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(prominent ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color(.secondarySystemBackground)),
                        in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Apps

struct AppsView: View {
    @EnvironmentObject var remote: RemoteConnection

    private var running: [AppInfo] { remote.macApps.filter(\.running) }
    private var others: [AppInfo] { remote.macApps.filter { !$0.running } }

    var body: some View {
        List {
            if remote.macApps.isEmpty {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Getting apps from your Mac…").foregroundStyle(.secondary)
                }
            }
            if !running.isEmpty {
                Section {
                    ForEach(running) { app in
                        Button {
                            remote.openApp(app.id)
                        } label: {
                            AppRow(app: app)
                        }
                        .swipeActions {
                            Button("Quit", role: .destructive) { remote.quitApp(app.id) }
                        }
                    }
                } header: {
                    Text("Open on your Mac")
                } footer: {
                    Text("Tap to switch to an app. Swipe left to quit it.")
                }
            }
            if !others.isEmpty {
                Section("Open an app") {
                    ForEach(others) { app in
                        Button {
                            remote.openApp(app.id)
                        } label: {
                            AppRow(app: app)
                        }
                    }
                }
            }
        }
        .navigationTitle("Apps")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { remote.refreshApps() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    remote.refreshApps()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .onAppear { remote.refreshApps() }
    }
}

private struct AppRow: View {
    let app: AppInfo

    var body: some View {
        HStack(spacing: 12) {
            if let data = app.icon.flatMap({ Data(base64Encoded: $0) }), let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: 36, height: 36)
            } else {
                Image(systemName: "app.dashed")
                    .font(.title2)
                    .frame(width: 36, height: 36)
            }
            Text(app.name)
                .foregroundStyle(.primary)
            Spacer()
            if app.active == true {
                Text("In front")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Clipboard

struct ClipboardView: View {
    @EnvironmentObject var remote: RemoteConnection
    @State private var text = ""
    @State private var sentConfirmation = false
    @State private var copiedConfirmation = false
    @State private var waitingForMac = false

    var body: some View {
        Form {
            Section {
                TextField("Text to send", text: $text, axis: .vertical)
                    .lineLimit(3...8)
                PasteButton(payloadType: String.self) { strings in
                    text = strings.first ?? ""
                }
                Button {
                    remote.sendClipboard(text)
                    sentConfirmation = true
                } label: {
                    Label(sentConfirmation ? "Sent – press ⌘V on the Mac" : "Send to Mac's Clipboard",
                          systemImage: sentConfirmation ? "checkmark.circle.fill" : "arrow.up.doc")
                }
                .disabled(text.isEmpty)
                Button {
                    remote.type(text)
                } label: {
                    Label("Type It on the Mac", systemImage: "keyboard")
                }
                .disabled(text.isEmpty)
            } header: {
                Text("iPhone → Mac")
            }

            Section {
                Button {
                    waitingForMac = true
                    copiedConfirmation = false
                    remote.requestClipboard()
                } label: {
                    Label("Get Mac's Clipboard", systemImage: "arrow.down.doc")
                }
                if let clip = remote.macClipboard {
                    if clip.isEmpty {
                        Text("The Mac's clipboard has no text.").foregroundStyle(.secondary)
                    } else {
                        Text(clip)
                            .lineLimit(12)
                            .textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = clip
                            copiedConfirmation = true
                        } label: {
                            Label(copiedConfirmation ? "Copied to iPhone" : "Copy to iPhone",
                                  systemImage: copiedConfirmation ? "checkmark.circle.fill" : "doc.on.doc")
                        }
                    }
                } else if waitingForMac {
                    ProgressView()
                }
            } header: {
                Text("Mac → iPhone")
            } footer: {
                Text("Text only. The clipboard is sent only when you tap a button, and it's end-to-end encrypted.")
            }
        }
        .navigationTitle("Clipboard")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: text) { _, _ in sentConfirmation = false }
    }
}
