import SwiftUI

/// What an encrypted note's tab shows until it is unlocked: its name, a lock and a password field.
struct LockedNoteView: View {
    let document: NoteDocument
    let background: Color
    @State private var password = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text(verbatim: document.name)
                .appFont(.title3, weight: .semibold)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                SecureField(text: $password, prompt: Text(loc: "Password")) { Text(loc: "Password") }
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .focused($isFocused)
                    .onSubmit(unlock)
                    .disabled(document.isUnlocking)
                Button(loc: "Unlock", action: unlock)
                    .disabled(password.isEmpty || document.isUnlocking)
            }
            // Always there, so the layout doesn't jump when an error or the progress appears.
            ZStack {
                if document.isUnlocking {
                    ProgressView().controlSize(.small)
                } else if let message = document.unlockError {
                    Text(verbatim: message)
                        .appFont(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(minHeight: 32)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background)
        .onAppear {
            isFocused = true
            // Passwords entered since this note was locked may fit it.
            document.unlockSilently()
        }
        .onChange(of: document.unlockError) { if document.unlockError != nil { isFocused = true } }
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        document.unlock(password: password)
    }
}
