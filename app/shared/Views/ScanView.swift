// Scan: the first screen before any household, and Family's Add. The camera full-bleed, the
// mark above it, one line of help, Paste a link as a text button; the display name is asked on
// the first join only. On a Mac or without a camera, the link field is what there is.
import SwiftUI

struct ScanView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    var asSheet = false
    @State private var pasting = false
    @State private var link = ""
    @State private var name = ""
    @State private var problem: String?
    @State private var busy = false
    @State private var scanned: String?
    @FocusState private var focus: Field?

    enum Field { case link, name }

    private var needsName: Bool { session.context?.displayName.isEmpty ?? true }

    var body: some View {
        ZStack {
            Tokens.ground.ignoresSafeArea()
            VStack(spacing: Tokens.space5) {
                Mark(size: 48)
                    .padding(.top, Tokens.space6)
                if QRScanner.isAvailable, !pasting {
                    QRScanner { code in
                        guard scanned == nil else { return }
                        scanned = code
                        accept(code)
                    }
                    .frame(maxWidth: 480, maxHeight: 480)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.radiusMD))
                    .padding(.horizontal, Tokens.space4)
                    .accessibilityLabel(Text("Camera"))
                }
                HelpLine(text: asSheet ? "Scan the invite the owner shows you." : "Scan your family's invite.")
                if pasting || !QRScanner.isAvailable {
                    VStack(spacing: Tokens.space3) {
                        TextField("Invite link or code", text: $link)
                            .accessibilityIdentifier("invite-link")
                            .textFieldStyle(.plain)
                            .focused($focus, equals: .link)
                            .font(Tokens.mono(.body))
                            .padding(Tokens.space3)
                            .background(Tokens.surfaceSunk, in: RoundedRectangle(cornerRadius: Tokens.radiusSM))
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            #endif
                            .onSubmit { if needsName { focus = .name } else { accept(link) } }
                        if needsName {
                            TextField("Your name, as the family sees it", text: $name)
                                .accessibilityIdentifier("display-name")
                                .textFieldStyle(.plain)
                                .focused($focus, equals: .name)
                                .padding(Tokens.space3)
                                .background(Tokens.surfaceSunk, in: RoundedRectangle(cornerRadius: Tokens.radiusSM))
                                .onSubmit { accept(link) }
                        }
                        Button {
                            accept(link)
                        } label: {
                            if busy {
                                ProgressView()
                            } else {
                                Text("Join")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("join")
                        .disabled(busy || link.trimmingCharacters(in: .whitespaces).isEmpty || (needsName && name.trimmingCharacters(in: .whitespaces).isEmpty))
                    }
                    .padding(.horizontal, Tokens.space5)
                    .frame(maxWidth: 480)
                } else {
                    Button("Paste a link") {
                        pasting = true
                        focus = .link
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Tokens.accent)
                }
                ProblemLine(text: problem)
                    .padding(.horizontal, Tokens.space5)
                Spacer()
            }
        }
        .onAppear {
            if !QRScanner.isAvailable { focus = .link }
        }
        .task {
            // a UI test's QR, read as the camera would read it
            if let png = UITestHooks.qrPNG, scanned == nil, let code = UITestHooks.decodeQR(png: png) {
                scanned = code
                accept(code)
            }
        }
        .toolbar {
            if asSheet {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func accept(_ text: String) {
        guard !busy else { return }
        // a scanned invite on a first join still needs the name: show the field with the code in it
        if needsName, name.trimmingCharacters(in: .whitespaces).isEmpty {
            link = text
            pasting = true
            focus = .name
            scanned = nil
            return
        }
        busy = true
        problem = nil
        Task {
            do {
                try await session.accept(text, displayName: name.trimmingCharacters(in: .whitespaces))
                if asSheet { dismiss() }
            } catch {
                problem = error.localizedDescription
                scanned = nil
            }
            busy = false
        }
    }
}
