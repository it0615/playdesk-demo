import AppKit
import SwiftUI

struct KeyCaptureView: NSViewRepresentable {
    let onKey: (String) -> Void

    func makeNSView(context: Context) -> KeyReceiver {
        let view = KeyReceiver()
        view.onKey = onKey
        return view
    }

    func updateNSView(_ nsView: KeyReceiver, context: Context) { nsView.onKey = onKey }
}

final class KeyReceiver: NSView {
    var onKey: ((String) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func keyDown(with event: NSEvent) {
        if let key = event.charactersIgnoringModifiers { onKey?(key) }
    }
}
