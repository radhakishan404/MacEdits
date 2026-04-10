import AppKit
import AVFoundation
import SwiftUI

struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeNSView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.setSession(session)
        view.setVideoGravity(videoGravity)
        return view
    }

    func updateNSView(_ nsView: PreviewContainerView, context: Context) {
        nsView.setSession(session)
        nsView.setVideoGravity(videoGravity)
    }

    static func dismantleNSView(_ nsView: PreviewContainerView, coordinator: ()) {
        nsView.clearSession()
    }
}

final class PreviewContainerView: NSView {
    private let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.videoGravity = .resizeAspect
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }

    func setSession(_ session: AVCaptureSession) {
        previewLayer.session = session
    }

    func setVideoGravity(_ gravity: AVLayerVideoGravity) {
        previewLayer.videoGravity = gravity
    }

    func clearSession() {
        previewLayer.session = nil
    }
}
