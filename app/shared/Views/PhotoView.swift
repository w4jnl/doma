// A spot's pictures: the current one large with who took it and when, the older ones in a strip
// under it; Rename and Remove in the More menu, the same two the tile offers on a long-press,
// a rename in a field above the picture and Remove armed under the title; and the departure
// sweep, which walks a home's spots with the camera open and one tap per spot.
import SwiftUI

struct PhotoView: View {
    var spot: SpotRow
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var photos: Live<[PhotoRow]>?
    @State private var shown: String?
    @State private var taking = false
    /// The name as the title; a rename shows here before the fold catches up.
    @State private var name: String?
    @State private var renaming = false
    @State private var renameText = ""
    @State private var arming = false
    @State private var disarm: Task<Void, Never>?
    @FocusState private var renameFocused: Bool

    var body: some View {
        let all = photos?.value ?? []
        let current = all.first { $0.id == shown } ?? all.first
        VStack(spacing: Tokens.space3) {
            if renaming {
                renameRow
            } else if arming {
                Button {
                    arming = false
                    disarm?.cancel()
                    try? HomeActions.archiveSpot(spot.id, in: session)
                    dismiss()
                } label: {
                    Text("Really remove?")
                        .font(.caption)
                        .foregroundStyle(Tokens.onOut)
                        .padding(.horizontal, Tokens.space2)
                        .padding(.vertical, Tokens.space1)
                        .background(Tokens.out, in: RoundedRectangle(cornerRadius: Tokens.radiusSM))
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("really-remove-spot")
            }
            PhotoImage(photoID: current?.id, thumb: false)
                .aspectRatio(4 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.radiusMD))
                .frame(maxWidth: Tokens.contentMax)
                .padding(.horizontal, Tokens.space4)
                .accessibilityIdentifier("photo")
            if let current {
                HStack(spacing: Tokens.space1) {
                    if let who = session.name(of: current.takenBy) {
                        Text("taken by \(who)")
                    } else {
                        Text("taken")
                    }
                    RelativeText(millis: current.takenAt)
                }
                .font(.footnote)
                .foregroundStyle(Tokens.inkMuted)
            } else {
                HelpLine(text: "No picture of this spot yet. Take one before you leave.")
                    .padding(.horizontal, Tokens.space4)
            }
            if all.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: Tokens.space2) {
                        ForEach(all) { p in
                            Button {
                                shown = p.id
                            } label: {
                                PhotoImage(photoID: p.id, thumb: true)
                                    .frame(width: Tokens.thumb, height: Tokens.thumb)
                                    .clipShape(RoundedRectangle(cornerRadius: Tokens.radiusMD))
                                    .overlay(RoundedRectangle(cornerRadius: Tokens.radiusMD).strokeBorder(Tokens.accent, lineWidth: p.id == current?.id ? 2 : 0))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("picture from \(RelativeText.string(for: Date(timeIntervalSince1970: Double(p.takenAt) / 1000), locale: Locale.current))"))
                        }
                    }
                    .padding(.horizontal, Tokens.space4)
                }
                .scrollIndicators(.hidden)
            }
            Spacer()
        }
        .padding(.top, Tokens.space3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.ground)
        .animation(Motion.of(reduceMotion, Motion.quick), value: renaming)
        .animation(Motion.of(reduceMotion, Motion.quick), value: arming)
        .navigationTitle(name ?? spot.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    taking = true
                } label: {
                    Label("Take a picture", systemImage: "camera")
                }
                Menu {
                    Button("Rename") {
                        arming = false
                        disarm?.cancel()
                        renameText = name ?? spot.name
                        renaming = true
                    }
                    Button("Remove", role: .destructive) {
                        renaming = false
                        arm()
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("spot-more")
            }
        }
        .navigationDestination(isPresented: $taking) {
            SweepView(home: HomeCard(id: spot.homeID, name: "", missing: 0, staples: 0, spots: [spot]))
        }
        .onAppear(perform: observe)
        .onChange(of: session.scope) { observe() }
    }

    /// The field above the picture with the spot's new name.
    private var renameRow: some View {
        HStack(spacing: Tokens.space3) {
            TextField("Name", text: $renameText)
                .textFieldStyle(.plain)
                .focused($renameFocused)
                .submitLabel(.done)
                .onSubmit(commitRename)
                .accessibilityIdentifier("rename-spot")
                .onAppear { renameFocused = true }
            Button("Cancel") { renaming = false }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.inkMuted)
        }
        .frame(minHeight: Tokens.rowH)
        .padding(.horizontal, Tokens.space4)
        .frame(maxWidth: Tokens.contentMax)
        #if os(macOS)
        .onExitCommand { renaming = false }
        #endif
    }

    private func commitRename() {
        let t = renameText.trimmingCharacters(in: .whitespaces)
        renaming = false
        guard !t.isEmpty, t != (name ?? spot.name) else { return }
        try? HomeActions.renameSpot(spot.id, to: t, in: session)
        name = t
    }

    /// Remove asks once more, in a button that disarms by itself after four seconds.
    private func arm() {
        arming = true
        disarm?.cancel()
        disarm = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { arming = false }
        }
    }

    private func observe() {
        guard let scope = session.scope else { return }
        let id = spot.id
        photos = Live(session.store, initial: []) { db in try Queries.photos(db, scope, spotID: id) }
    }
}

/// Take photos: the camera open, one spot at a time in the home's order, one tap per spot;
/// Skip passes a spot, Done leaves early, the last picture leaves by itself.
struct SweepView: View {
    var home: HomeCard
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var shutter = Shutter()
    @State private var index = 0
    @State private var busy = false

    private var spot: SpotRow? { index < home.spots.count ? home.spots[index] : nil }

    var body: some View {
        ZStack {
            if Shutter.hasCamera {
                CameraView(shutter: shutter)
                    .ignoresSafeArea()
            } else {
                Tokens.surfaceSunk
                    .ignoresSafeArea()
                    .overlay {
                        VStack(spacing: Tokens.space2) {
                            Image(systemName: "camera")
                                .imageScale(.large)
                            Text("No camera here")
                        }
                        .foregroundStyle(Tokens.inkMuted)
                    }
            }
            VStack {
                if let spot {
                    VStack(spacing: Tokens.space1) {
                        Text(spot.name)
                            .font(.headline)
                        if home.spots.count > 1 {
                            Text("\(index + 1) of \(home.spots.count)")
                                .font(Tokens.mono(.footnote))
                        }
                    }
                    .foregroundStyle(Tokens.ink)
                    .padding(.horizontal, Tokens.space4)
                    .padding(.vertical, Tokens.space2)
                    .background(Tokens.surface.opacity(0.9), in: RoundedRectangle(cornerRadius: Tokens.radiusMD))
                    .padding(.top, Tokens.space3)
                    .accessibilityElement(children: .combine)
                }
                Spacer()
                HStack {
                    if home.spots.count > 1 {
                        Button("Skip", action: advance)
                            .foregroundStyle(Tokens.ink)
                    }
                    Spacer()
                    Button(action: take) {
                        Circle()
                            .fill(Tokens.ink)
                            .frame(width: Tokens.thumb, height: Tokens.thumb)
                            .overlay(Circle().strokeBorder(Tokens.ground, lineWidth: 3).padding(Tokens.space1))
                            .opacity(busy ? 0.5 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(busy || spot == nil)
                    .accessibilityLabel(Text("Take the picture"))
                    .accessibilityIdentifier("shutter")
                    Spacer()
                    Button("Done") { dismiss() }
                        .foregroundStyle(Tokens.ink)
                }
                .padding(.horizontal, Tokens.space5)
                .padding(.bottom, Tokens.space5)
            }
        }
        .navigationTitle(home.name.isEmpty ? Text("Take a picture") : Text("Take photos"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        #endif
    }

    private func take() {
        guard let spot, !busy else { return }
        busy = true
        shutter.capture(label: spot.name) { data in
            if let data, let id = try? HomeActions.addPhoto(data, spot: spot.id, in: session), let jpeg = Pictures.jpeg(from: data) {
                session.photos.put(jpeg.data, photoID: id)
            }
            busy = false
            advance()
        }
    }

    private func advance() {
        if index + 1 < home.spots.count {
            index += 1
        } else {
            dismiss()
        }
    }
}
