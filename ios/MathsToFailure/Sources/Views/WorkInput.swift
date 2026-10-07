import SwiftUI
import PencilKit
import PhotosUI
import UIKit

enum ImageTools {
    /// Flattens onto white, shrinks to a sensible size and returns JPEG data for the model.
    static func jpeg(from data: Data, maxSide: CGFloat = 1800) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return jpeg(from: image, maxSide: maxSide)
    }

    static func jpeg(from image: UIImage, maxSide: CGFloat = 1800) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let flat = renderer.image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return flat.jpegData(compressionQuality: 0.85)
    }
}

// MARK: - Apple Pencil canvas

@MainActor
final class CanvasHolder: ObservableObject {
    let canvas = PKCanvasView()
    let toolPicker = PKToolPicker()

    /// Renders the drawing on white, ready for marking. Nil when nothing has been drawn.
    func exportJPEG() -> Data? {
        let bounds = canvas.bounds
        guard bounds.width > 0, !canvas.drawing.strokes.isEmpty else { return nil }
        let drawn = canvas.drawing.image(from: bounds, scale: 2)
        let renderer = UIGraphicsImageRenderer(size: bounds.size)
        let flat = renderer.image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: bounds.size))
            drawn.draw(in: CGRect(origin: .zero, size: bounds.size))
        }
        return ImageTools.jpeg(from: flat)
    }

    func clear() { canvas.drawing = PKDrawing() }
}

private struct PencilCanvasView: UIViewRepresentable {
    let holder: CanvasHolder

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = holder.canvas
        canvas.drawingPolicy = .anyInput          // Apple Pencil, finger or mouse
        canvas.overrideUserInterfaceStyle = .light // black ink on white, whatever the system theme
        canvas.backgroundColor = .white
        canvas.isOpaque = true
        holder.toolPicker.addObserver(canvas)
        holder.toolPicker.setVisible(true, forFirstResponder: canvas)
        DispatchQueue.main.async { canvas.becomeFirstResponder() }
        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {}
}

/// Write the solution directly in the app. Each page is added as an image.
struct PencilSheet: View {
    var onPage: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var holder = CanvasHolder()
    @State private var pages = 0

    var body: some View {
        NavigationStack {
            PencilCanvasView(holder: holder)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(pages == 0 ? "Your working" : "Page \(pages + 1)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Add another page") {
                            if let jpeg = holder.exportJPEG() {
                                onPage(jpeg)
                                pages += 1
                                holder.clear()
                            }
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            if let jpeg = holder.exportJPEG() { onPage(jpeg) }
                            dismiss()
                        }
                        .bold()
                    }
                }
        }
    }
}

// MARK: - Camera (iPad only; Mac has no camera picker)

#if !targetEnvironment(macCatalyst)
struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
#endif
