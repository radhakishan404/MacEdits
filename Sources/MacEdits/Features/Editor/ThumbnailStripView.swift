@preconcurrency import AVFoundation
import AppKit
import Foundation
import SwiftUI

struct ThumbnailStripView: View {
    let asset: ProjectAsset
    let projectURL: URL
    let clipDuration: Double
    let lane: TrackKind

    @State private var thumbnails: [NSImage] = []
    @State private var waveformSamples: [CGFloat] = []
    @State private var isLoading = false

    private static let imageCache = NSCache<NSString, NSArray>()
    private static let waveformCache = NSCache<NSString, NSArray>()

    var body: some View {
        GeometryReader { geometry in
            content(width: geometry.size.width)
                .task(id: cacheKey) {
                    loadThumbnailsIfNeeded(for: geometry.size.width)
                }
        }
    }

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        let images = displayImages(width: width)

        switch asset.type {
        case .video, .image:
            HStack(spacing: 2) {
                ForEach(images.indices, id: \.self) { index in
                    Image(nsImage: images[index])
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .clipped()
                }
            }
        case .audio:
            waveformView(width: width)
        case .unknown:
            Color.white.opacity(0.06)
        }
    }

    private func waveformView(width: CGFloat) -> some View {
        let bars = displayWaveformSamples(width: width)
        return ZStack {
            LinearGradient(
                colors: [waveformTint.opacity(0.18), Color.black.opacity(0.08)],
                startPoint: .leading,
                endPoint: .trailing
            )

            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(bars.enumerated()), id: \.offset) { index, value in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [waveformTint.opacity(0.95), waveformTint.opacity(0.32)],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: index.isMultiple(of: 5) ? 5 : 4, height: max(8, value * 34))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func displayImages(width: CGFloat) -> [NSImage] {
        if thumbnails.isEmpty {
            return Array(repeating: placeholderImage, count: max(3, Int(width / 70)))
        }
        return thumbnails
    }

    private func displayWaveformSamples(width: CGFloat) -> [CGFloat] {
        let targetCount = max(14, Int(width / 8))
        if waveformSamples.isEmpty {
            return Array(repeating: 0.28, count: targetCount)
        }
        if waveformSamples.count == targetCount {
            return waveformSamples
        }
        return Self.resampleWaveform(waveformSamples, targetCount: targetCount)
    }

    private var cacheKey: String {
        "\(projectURL.path)-\(asset.fileName)-\(clipDuration)"
    }

    private func loadThumbnailsIfNeeded(for width: CGFloat) {
        guard thumbnails.isEmpty || (asset.type == .audio && waveformSamples.isEmpty) else { return }
        guard !isLoading else { return }

        if asset.type == .audio,
           let cachedWaveform = Self.waveformCache.object(forKey: cacheKey as NSString) as? [NSNumber],
           !cachedWaveform.isEmpty {
            waveformSamples = cachedWaveform.map { CGFloat(truncating: $0) }
            return
        }

        if asset.type == .audio,
           let diskWaveform = loadWaveformSamplesFromDisk(),
           !diskWaveform.isEmpty {
            let boxed = diskWaveform.map { NSNumber(value: Double($0)) }
            Self.waveformCache.setObject(boxed as NSArray, forKey: cacheKey as NSString)
            waveformSamples = diskWaveform
            return
        }

        if let cachedImages = Self.imageCache.object(forKey: cacheKey as NSString) as? [NSImage], !cachedImages.isEmpty {
            thumbnails = cachedImages
            if asset.type != .audio {
                return
            }
        }

        isLoading = true

        let requestedCount = max(3, min(8, Int(width / 68)))
        let mediaURL = projectURL
            .appendingPathComponent("media", isDirectory: true)
            .appendingPathComponent(asset.fileName)

        DispatchQueue.global(qos: .userInitiated).async {
            let generatedImages = Self.generateThumbnails(
                assetType: asset.type,
                mediaURL: mediaURL,
                requestedCount: requestedCount,
                clipDuration: clipDuration
            )
            let generatedWaveform = asset.type == .audio
                ? Self.generateWaveformSamples(mediaURL: mediaURL, targetCount: max(14, Int(width / 8)))
                : []

            DispatchQueue.main.async {
                isLoading = false

                if !generatedImages.isEmpty {
                    Self.imageCache.setObject(generatedImages as NSArray, forKey: cacheKey as NSString)
                    thumbnails = generatedImages
                }
                if !generatedWaveform.isEmpty {
                    let boxed = generatedWaveform.map { NSNumber(value: Double($0)) }
                    Self.waveformCache.setObject(boxed as NSArray, forKey: cacheKey as NSString)
                    waveformSamples = generatedWaveform
                    saveWaveformSamplesToDisk(generatedWaveform)
                }
            }
        }
    }

    nonisolated private static func generateThumbnails(
        assetType: AssetType,
        mediaURL: URL,
        requestedCount: Int,
        clipDuration: Double
    ) -> [NSImage] {
        switch assetType {
        case .image:
            guard let image = NSImage(contentsOf: mediaURL) else {
                return []
            }
            return Array(repeating: image, count: requestedCount)
        case .video:
            let sourceAsset = AVURLAsset(url: mediaURL)
            let generator = AVAssetImageGenerator(asset: sourceAsset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 220, height: 220)

            let step = max(0.1, clipDuration / Double(requestedCount))
            var generated: [NSImage] = []
            for index in 0..<requestedCount {
                let time = CMTime(seconds: Double(index) * step, preferredTimescale: 600)
                if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                    generated.append(NSImage(cgImage: cgImage, size: .zero))
                }
            }
            return generated
        case .audio, .unknown:
            return []
        }
    }

    nonisolated private static func generateWaveformSamples(mediaURL: URL, targetCount: Int) -> [CGFloat] {
        guard let file = try? AVAudioFile(forReading: mediaURL) else {
            return []
        }

        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
            let channelData = buffer.floatChannelData
        else {
            return []
        }

        do {
            try file.read(into: buffer)
        } catch {
            return []
        }

        let channelCount = Int(format.channelCount)
        let sampleCount = Int(buffer.frameLength)
        guard sampleCount > 0 else {
            return []
        }

        let stride = max(1, sampleCount / targetCount)
        var samples: [CGFloat] = []
        samples.reserveCapacity(targetCount)

        for bucket in 0..<targetCount {
            let start = bucket * stride
            let end = min(sampleCount, start + stride)
            if start >= end {
                samples.append(0.05)
                continue
            }

            var peak: Float = 0
            for frame in start..<end {
                var mixed: Float = 0
                for channel in 0..<channelCount {
                    mixed += abs(channelData[channel][frame])
                }
                peak = max(peak, mixed / Float(channelCount))
            }
            samples.append(CGFloat(max(0.06, min(1, peak))))
        }

        return samples
    }

    private var placeholderImage: NSImage {
        let size = NSSize(width: 120, height: 120)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedWhite: 0.14, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        NSColor(calibratedWhite: 0.24, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 18, y: 18, width: 84, height: 84), xRadius: 18, yRadius: 18).fill()
        image.unlockFocus()
        return image
    }

    private var waveformTint: Color {
        switch lane {
        case .music:
            return Color(red: 0.83, green: 0.27, blue: 0.95)
        case .voiceover:
            return Color(red: 1.0, green: 0.37, blue: 0.65)
        case .video:
            return Color(red: 0.99, green: 0.80, blue: 0.18)
        case .captions:
            return AppTheme.accent
        }
    }

    nonisolated private static func resampleWaveform(_ samples: [CGFloat], targetCount: Int) -> [CGFloat] {
        guard !samples.isEmpty else { return [] }
        guard targetCount > 0 else { return samples }
        guard samples.count != targetCount else { return samples }

        return (0..<targetCount).map { index in
            let position = Double(index) / Double(max(1, targetCount - 1)) * Double(max(1, samples.count - 1))
            let lower = Int(position.rounded(.down))
            let upper = min(samples.count - 1, lower + 1)
            let progress = CGFloat(position - Double(lower))
            return samples[lower] + ((samples[upper] - samples[lower]) * progress)
        }
    }

    private func waveformCacheFileURL() -> URL {
        let directory = projectURL
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent("waveforms", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(asset.id.uuidString).json")
    }

    private func loadWaveformSamplesFromDisk() -> [CGFloat]? {
        let url = waveformCacheFileURL()
        guard let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([Double].self, from: data)
        else {
            return nil
        }
        return values.map { CGFloat($0) }
    }

    private func saveWaveformSamplesToDisk(_ samples: [CGFloat]) {
        let url = waveformCacheFileURL()
        let values = samples.map(Double.init)
        guard let data = try? JSONEncoder().encode(values) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
