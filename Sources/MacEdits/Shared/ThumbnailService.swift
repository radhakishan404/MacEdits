import AVFoundation
import AppKit
import SwiftUI

@MainActor
@Observable
final class ThumbnailService {
    static let shared = ThumbnailService()

    private var cache: [URL: NSImage] = [:]
    private var pending: Set<URL> = []

    func thumbnail(for projectURL: URL) -> NSImage? {
        if let cached = cache[projectURL] { return cached }
        guard !pending.contains(projectURL) else { return nil }
        pending.insert(projectURL)

        Task { @MainActor [weak self] in
            let image = await Self.generateProjectThumbnail(projectURL: projectURL)
            self?.cache[projectURL] = image
            self?.pending.remove(projectURL)
        }

        return nil
    }

    private static func generateProjectThumbnail(projectURL: URL) async -> NSImage? {
        let mediaDir = projectURL.appendingPathComponent("media", isDirectory: true)
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: mediaDir.path) else { return nil }

        let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi"]
        let videoFile = contents.first { file in
            videoExtensions.contains((file as NSString).pathExtension.lowercased())
        }

        guard let videoFile else { return nil }
        let url = mediaDir.appendingPathComponent(videoFile)
        return await generateThumbnail(from: url)
    }

    private static func generateThumbnail(from url: URL) async -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 520, height: 520)

        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        do {
            let (cgImage, _) = try await generator.image(at: time)
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            do {
                let (cgImage, _) = try await generator.image(at: .zero)
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            } catch {
                return nil
            }
        }
    }

    func invalidate(for projectURL: URL) {
        cache.removeValue(forKey: projectURL)
    }
}
