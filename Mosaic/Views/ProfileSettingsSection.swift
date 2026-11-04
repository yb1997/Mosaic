import SwiftUI

/// Rename and delete saved profiles. Saving and switching happen in the menu panel.
struct ProfileSettingsSection: View {
    @Environment(WallpaperStore.self) private var store
    @State private var pendingDelete: Profile?

    var body: some View {
        Section {
            if store.profiles.isEmpty {
                Text("No profiles yet. Use the profile menu in the menu bar panel to save the current wallpapers.")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.profiles) { profile in
                ProfileRow(profile: profile, isActive: store.activeProfile?.id == profile.id) {
                    pendingDelete = profile
                }
            }
        } header: {
            Text("Profiles")
        } footer: {
            Text("A profile keeps each screen’s desktop and lock screen images, including screens that aren’t connected.")
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let profile = pendingDelete { store.delete(profile) }
            }
        } message: {
            Text("Your current wallpapers stay as they are.")
        }
    }
}

/// A profile's name, read-only until the pencil is clicked. Return or Save
/// saves the new name; Escape puts the old one back.
private struct ProfileRow: View {
    @Environment(WallpaperStore.self) private var store
    let profile: Profile
    let isActive: Bool
    let onDelete: () -> Void
    @State private var draft: String?
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            if let draft {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Name", text: Binding(get: { draft }, set: { self.draft = $0 }))
                        .labelsHidden()
                        .focused($focused)
                        .onSubmit(commit)
                        .onExitCommand { self.draft = nil }
                        .onAppear { focused = true }
                    if isTaken(draft) {
                        Text("Another profile already has this name.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Save", action: commit)
                    .buttonStyle(.glassProminent)
                    .disabled(trimmed(draft).isEmpty || isTaken(draft))
                    .help("Save the new name")
            } else {
                Text(profile.name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isActive {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .help("Current wallpapers match this profile")
                }
                Button("Rename", systemImage: "pencil") { draft = profile.name }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .help("Rename \(profile.name)")
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .foregroundStyle(.red)
                    .help("Delete \(profile.name)")
            }
        }
    }

    private func trimmed(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isTaken(_ name: String) -> Bool {
        store.isProfileNameTaken(name, excluding: profile)
    }

    private func commit() {
        guard let draft, !trimmed(draft).isEmpty, !isTaken(draft) else { return }
        if trimmed(draft) != profile.name { store.rename(profile, to: trimmed(draft)) }
        self.draft = nil
    }
}
