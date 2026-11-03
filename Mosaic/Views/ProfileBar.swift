import SwiftUI

/// The profile picker at the top of the menu panel: switch profiles, save the
/// current choices as a new one, or update the active one.
struct ProfileBar: View {
    @Environment(WallpaperStore.self) private var store
    @State private var isNaming = false
    @State private var newName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        if isNaming {
            nameField
        } else {
            picker
        }
    }

    private var picker: some View {
        let active = store.activeProfile
        return Menu {
            ForEach(store.profiles) { profile in
                Toggle(profile.name, isOn: Binding(
                    get: { profile.id == active?.id },
                    set: { _ in store.apply(profile) }
                ))
            }
            if !store.profiles.isEmpty { Divider() }
            Button("Save as New Profile…", systemImage: "plus") {
                newName = ""
                isNaming = true
            }
            if active == nil, let last = store.lastProfile {
                Button("Update “\(last.name)”", systemImage: "arrow.triangle.2.circlepath") {
                    store.overwrite(last)
                }
            }
        } label: {
            Label(active?.name ?? (store.profiles.isEmpty ? "No Profiles" : "Unsaved Changes"),
                  systemImage: "square.stack")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("Switch between saved sets of wallpapers")
    }

    private var nameField: some View {
        GlassEffectContainer {
            HStack(spacing: 6) {
                TextField("Profile name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit(save)
                    .onExitCommand { isNaming = false }
                Button("Cancel") { isNaming = false }
                    .buttonStyle(.glass)
                Button("Save", action: save)
                    .buttonStyle(.glassProminent)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .onAppear { nameFocused = true }
    }

    private var trimmedName: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        store.saveProfile(named: trimmedName)
        isNaming = false
    }
}
