import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MediaPicker: UIViewControllerRepresentable {
    enum Kind { case cameraPhoto, cameraVideo, libraryPhoto, libraryVideo }
    let kind: Kind
    let onImage: (UIImage) -> Void
    let onVideo: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = (kind == .cameraPhoto || kind == .cameraVideo) ? .camera : .photoLibrary
        picker.mediaTypes = (kind == .cameraVideo || kind == .libraryVideo) ? [UTType.movie.identifier] : [UTType.image.identifier]
        picker.videoQuality = .typeMedium
        picker.videoMaximumDuration = 120
        picker.allowsEditing = false
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: MediaPicker
        init(_ parent: MediaPicker) { self.parent = parent }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.onCancel() }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let url = info[.mediaURL] as? URL { parent.onVideo(url) }
            else if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            else { parent.onCancel() }
        }
    }
}

extension UIImage {
    func captureJPEG(maximumDimension: CGFloat = 1280) -> Data? {
        let scale = min(1, maximumDimension / max(size.width, size.height))
        let output = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: output, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: output))
        }.jpegData(compressionQuality: 0.88)
    }
}
