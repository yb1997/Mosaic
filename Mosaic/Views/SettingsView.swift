import SwiftUI

/// The panes listed in the Settings sidebar, in order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, videos, profiles, updates

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .videos: "Videos"
        case .profiles: "Profiles"
        case .updates: "Updates"
        }
    }

    /// The SF Symbol, filled on coloured tiles and outlined on clear glass.
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .videos: "play"
        case .profiles: "rectangle.stack"
        case .updates: "arrow.down.to.line"
        }
    }

    /// The icon's colour in the Default and Dark icon styles.
    var tint: Color {
        switch self {
        case .general: .gray
        case .videos: .pink
        case .profiles: .indigo
        case .updates: .blue
        }
    }
}

/// App settings, laid out like System Settings: a sidebar of panes and the
/// selected pane on the right. Wallpapers themselves are picked in the menu bar panel.
struct SettingsView: View {
    @AppStorage("settingsPane") private var pane = SettingsPane.general
    /// Panes visited before and after the current one, for the back and forward buttons.
    @State private var backStack: [SettingsPane] = []
    @State private var forwardStack: [SettingsPane] = []

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: Binding(get: { pane }, set: { if let new = $0 { show(new) } })) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    SettingsIcon(pane: pane)
                }
                .tag(pane)
            }
            // Show the desktop through the sidebar, blurred, even when the window isn't active.
            .scrollContentBackground(.hidden)
            .background(SidebarBlur().ignoresSafeArea())
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch pane {
                case .general: GeneralSettingsPane()
                case .videos: VideoSettingsPane()
                case .profiles: Form { ProfileSettingsSection() }
                case .updates: Form { UpdateSettingsSection() }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(pane.title)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    ControlGroup {
                        Button("Back", systemImage: "chevron.left", action: goBack)
                            .disabled(backStack.isEmpty)
                            .keyboardShortcut("[", modifiers: .command)
                            .help("Show the previous pane")
                        Button("Forward", systemImage: "chevron.right", action: goForward)
                            .disabled(forwardStack.isEmpty)
                            .keyboardShortcut("]", modifiers: .command)
                            .help("Show the next pane")
                    }
                    .controlGroupStyle(.navigation)
                }
            }
        }
        .frame(minWidth: 680, minHeight: 450)
        .background(SettingsWindowTracker())
    }

    /// Picking a pane in the sidebar starts a new branch of history, as in a browser.
    private func show(_ new: SettingsPane) {
        guard new != pane else { return }
        backStack.append(pane)
        forwardStack.removeAll()
        pane = new
    }

    private func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(pane)
        pane = previous
    }

    private func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(pane)
        pane = next
    }
}

/// A blur of whatever is behind the window. The standard sidebar material is
/// nearly opaque and goes flat when the window isn't active.
private struct SidebarBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// The icon style chosen in System Settings → Appearance (Default, Dark,
/// Clear or Tinted), so the sidebar icons follow it as System Settings' own do.
@MainActor @Observable
private final class IconAppearance {
    enum Style { case regular, dark, clear, tinted }

    static let shared = IconAppearance()

    /// `AppleIconAppearanceTheme` in the global domain (undocumented), such as
    /// "RegularAutomatic", "ClearDark" or "TintedLight". Default is "Regular",
    /// and the Dark style is stored as "RegularDark".
    private(set) var theme = IconAppearance.readTheme()

    private init() {
        let refresh: @Sendable (Notification) -> Void = { _ in
            Task { @MainActor in IconAppearance.shared.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: Notification.Name("NSWorkspaceIconAppearanceConfigurationDidChangeNotification"),
            object: nil, queue: .main, using: refresh)
        // In case that isn't posted to this app: check again when coming back from System Settings.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: refresh)
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main, using: refresh)
    }

    private static func readTheme() -> String {
        UserDefaults.standard.string(forKey: "AppleIconAppearanceTheme") ?? "RegularAutomatic"
    }

    private func refresh() {
        let new = Self.readTheme()
        if new != theme { theme = new }
    }

    var style: Style {
        if theme.hasPrefix("Clear") { return .clear }
        if theme.hasPrefix("Tinted") { return .tinted }
        if theme == "RegularDark" { return .dark }
        return .regular
    }

    /// Whether the icons are drawn dark: forced by the style, or following the system appearance.
    func isDark(in scheme: ColorScheme) -> Bool {
        if theme.hasSuffix("Dark") { return true }
        if theme.hasSuffix("Light") { return false }
        return scheme == .dark
    }
}

/// A sidebar icon drawn like System Settings' own: a glyph on a small rounded
/// tile, coloured, dark, clear glass or tinted to match the system icon style.
private struct SettingsIcon: View {
    let pane: SettingsPane
    @Environment(\.colorScheme) private var colorScheme
    private let appearance = IconAppearance.shared
    private let tile = RoundedRectangle(cornerRadius: 5.5, style: .continuous)

    var body: some View {
        let dark = appearance.isDark(in: colorScheme)
        switch appearance.style {
        case .regular:
            glyph(.white)
                .background(pane.tint.gradient, in: tile)
                .overlay(rim(opacity: 0.35))
        case .dark:
            glyph(pane.tint)
                .background(darkTile, in: tile)
                .overlay(rim(opacity: 0.18))
        case .tinted:
            if dark {
                glyph(.accentColor)
                    .background(darkTile, in: tile)
                    .overlay(rim(opacity: 0.18))
            } else {
                glyph(.white)
                    .background(Color.accentColor.gradient, in: tile)
                    .overlay(rim(opacity: 0.35))
            }
        case .clear:
            // The text colour, so it reads on the light or dark sidebar behind the glass.
            glyph(.primary, filled: false)
                .glassEffect(.clear, in: tile)
        }
    }

    private var darkTile: some ShapeStyle {
        LinearGradient(colors: [Color(white: 0.24), Color(white: 0.15)], startPoint: .top, endPoint: .bottom)
    }

    private func glyph(_ color: Color, filled: Bool = true) -> some View {
        Image(systemName: pane.symbol)
            .symbolVariant(filled ? .fill : .none)
            .font(.system(size: 11, weight: filled ? .semibold : .medium))
            .foregroundStyle(color)
            .frame(width: 20, height: 20)
    }

    /// The thin light edge, brightest along the top, that Apple's tiles have.
    private func rim(opacity: Double) -> some View {
        tile.strokeBorder(
            LinearGradient(colors: [.white.opacity(opacity), .white.opacity(opacity * 0.25)], startPoint: .top, endPoint: .bottom),
            lineWidth: 0.5)
    }
}

private struct GeneralSettingsPane: View {
    @Environment(LoginItem.self) private var loginItem
    @AppStorage(WallpaperFade.defaultsKey) private var fadesWallpaperChanges = true

    var body: some View {
        Form {
            Section {
                Toggle("Open at Login", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.set($0) }))
                if loginItem.needsApproval {
                    LabeledContent("Waiting for approval in Login Items") {
                        Button("Open System Settings…") { loginItem.openSystemSettings() }
                            .buttonStyle(.glass)
                    }
                }
                if let error = loginItem.error {
                    Text(error).foregroundStyle(.red)
                }
            }

            Section {
                Toggle("Fade Between Wallpapers", isOn: $fadesWallpaperChanges)
            } footer: {
                Text("Lock screen images show while the Mac is locked and switch back when you unlock.")
            }
        }
        .onAppear { loginItem.refresh() }
    }
}

private struct VideoSettingsPane: View {
    @Environment(WallpaperStore.self) private var store
    @AppStorage(VideoFormat.frameRateKey) private var frameRate = VideoFormat.standard.frameRate
    @AppStorage(VideoFormat.qualityKey) private var quality = VideoFormat.standard.quality
    @AppStorage(VideoFormat.pausesOnBatteryKey) private var pausesOnBattery = false
    @State private var storageUsed: Int64?

    var body: some View {
        Form {
            Section {
                Picker("Frame Rate", selection: $frameRate) {
                    ForEach(FrameRate.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                // Original quality keeps the source's frames too.
                .disabled(quality == .original)
                Picker("Quality", selection: $quality) {
                    ForEach(VideoQuality.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } header: {
                Text("New Videos")
            } footer: {
                Text("New videos use these settings. Change one screen’s video from its tile’s menu.")
            }

            Section {
                Toggle("Pause on Battery Power", isOn: $pausesOnBattery)
            } header: {
                Text("Playback")
            } footer: {
                Text("Videos are muted and pause while hidden, locked, asleep or in Low Power Mode.")
            }

            Section("Storage") {
                LabeledContent("Wallpapers use \(storageUsed.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.imagesDirectory])
                    }
                    .buttonStyle(.glass)
                }
            }
        }
        .task { storageUsed = await store.storageUsed() }
    }
}
