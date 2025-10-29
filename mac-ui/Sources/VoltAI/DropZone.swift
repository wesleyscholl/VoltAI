import SwiftUI
import AppKit

struct DropZone: NSViewRepresentable {
    var onDrop: ([URL]) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = DropView(onDrop: onDrop)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class DropView: NSView {
    private var onDrop: ([URL]) -> Void

    init(onDrop: @escaping ([URL]) -> Void) {
        self.onDrop = onDrop
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if let items = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [NSURL] {
            let urls = items.compactMap { $0 as URL }
            DispatchQueue.main.async { self.onDrop(urls) }
            return true
        }
        return false
    }
}
