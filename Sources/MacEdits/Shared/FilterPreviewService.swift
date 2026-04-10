import AVFoundation
import AppKit
import CoreImage
import SwiftUI

@MainActor
@Observable
final class FilterPreviewService {
    private var cache: [String: NSImage] = [:]
    private var sourceFrame: CGImage?
    private var sourceKey: String = ""
    private var generating = false

    func previewImage(for preset: LookPreset, intensity: Double) -> NSImage? {
        let key = "\(sourceKey)_\(preset.rawValue)_\(Int(intensity * 100))"
        return cache[key]
    }

    func updateSourceFrame(from player: AVPlayer) {
        guard !generating else { return }
        guard let item = player.currentItem,
              let asset = item.asset as? AVURLAsset else { return }

        let time = player.currentTime()
        let key = "\(asset.url.lastPathComponent)_\(time.seconds)"
        guard key != sourceKey else { return }

        generating = true
        let url = asset.url

        Task { @MainActor [weak self] in
            let frame = await Self.extractFrame(url: url, time: time)
            self?.sourceFrame = frame
            self?.sourceKey = key
            self?.cache.removeAll()
            if let frame {
                await self?.generateAllPreviews(frame: frame)
            }
            self?.generating = false
        }
    }

    private func generateAllPreviews(frame: CGImage) async {
        let intensities: [Double] = [0.62]
        for preset in LookPreset.allCases {
            for intensity in intensities {
                let key = "\(sourceKey)_\(preset.rawValue)_\(Int(intensity * 100))"
                if cache[key] != nil { continue }

                let style = ProjectStyleSettings(
                    look: preset,
                    lookIntensity: intensity,
                    captionStyle: .clean,
                    colorCorrection: ColorCorrection()
                )

                let image = Self.applyFilter(to: frame, style: style)
                cache[key] = image
            }
        }
    }

    private static func applyFilter(to frame: CGImage, style: ProjectStyleSettings) -> NSImage? {
        let ciImage = CIImage(cgImage: frame)
        let filtered = LookPipeline.applyStyle(to: ciImage, style: style)

        let context = CIContext()
        guard let output = context.createCGImage(filtered, from: filtered.extent) else { return nil }
        return NSImage(cgImage: output, size: NSSize(width: output.width, height: output.height))
    }

    private static func extractFrame(url: URL, time: CMTime) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 200, height: 200)

        do {
            let (image, _) = try await generator.image(at: time)
            return image
        } catch {
            return nil
        }
    }
}
