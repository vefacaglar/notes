import SwiftUI

/// Remembers SwiftUI's `openWindow` so the model can open a window while none is left to handle the requests
/// (the last tab of every window was closed, the app was reopened from the Dock, a file came in from Finder).
private struct WindowOpenerCapture: ViewModifier {
    let model: NotesModel
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear { model.captureOpenWindow(openWindow) }
    }
}

extension NotesModel {
    func captureOpenWindow(_ openWindow: OpenWindowAction) {
        openWindowAction = { request in
            switch request {
            case .main: openWindow(id: NotesApp.mainWindowID)
            case .workspace(let id): openWindow(id: NotesApp.workspaceWindowID, value: id)
            }
        }
    }
}

extension View {
    func capturesOpenWindow(_ model: NotesModel) -> some View {
        modifier(WindowOpenerCapture(model: model))
    }
}
