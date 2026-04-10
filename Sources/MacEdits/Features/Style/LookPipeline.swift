import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Foundation

enum LookPipeline {
    static func makePreviewComposition(
        for asset: AVAsset,
        style: ProjectStyleSettings
    ) -> AVVideoComposition? {
        guard style.look != .clean || hasColorCorrection(style.colorCorrection) else {
            return nil
        }

        return AVVideoComposition(asset: asset) { request in
            let sourceImage = request.sourceImage.clampedToExtent()
            let output = applyStyle(
                to: sourceImage,
                style: style
            )
            request.finish(with: output.cropped(to: request.sourceImage.extent), context: nil)
        }
    }

    static func applyStyle(to image: CIImage, style: ProjectStyleSettings) -> CIImage {
        var result = applyLook(to: image, look: style.look, intensity: Float(style.lookIntensity))
        result = applyColorCorrection(to: result, correction: style.colorCorrection)
        return result
    }

    private static func applyLook(to image: CIImage, look: LookPreset, intensity: Float) -> CIImage {
        switch look {
        case .clean:
            let controls = CIFilter.colorControls()
            controls.inputImage = image
            controls.contrast = 1 + (0.08 * intensity)
            controls.saturation = 1 + (0.06 * intensity)
            controls.brightness = 0.01 * intensity
            return controls.outputImage ?? image

        case .film:
            let controls = CIFilter.colorControls()
            controls.inputImage = image
            controls.contrast = 1 + (0.14 * intensity)
            controls.saturation = 1 - (0.08 * intensity)

            let warm = CIFilter.temperatureAndTint()
            warm.inputImage = controls.outputImage ?? image
            warm.neutral = CIVector(x: 6500, y: 0)
            warm.targetNeutral = CIVector(
                x: CGFloat(5200 - (400 * intensity)),
                y: CGFloat(6 * intensity)
            )
            return warm.outputImage ?? image

        case .punch:
            let controls = CIFilter.colorControls()
            controls.inputImage = image
            controls.contrast = 1 + (0.22 * intensity)
            controls.saturation = 1 + (0.28 * intensity)
            controls.brightness = 0.015 * intensity

            let vibrance = CIFilter.vibrance()
            vibrance.inputImage = controls.outputImage ?? image
            vibrance.amount = 0.55 * intensity
            return vibrance.outputImage ?? image

        case .mono:
            let mono = CIFilter.photoEffectNoir()
            mono.inputImage = image

            let controls = CIFilter.colorControls()
            controls.inputImage = mono.outputImage ?? image
            controls.contrast = 1 + (0.16 * intensity)
            return controls.outputImage ?? image
        }
    }

    private static func applyColorCorrection(to image: CIImage, correction: ColorCorrection) -> CIImage {
        guard hasColorCorrection(correction) else { return image }

        var result = image

        // Brightness, contrast, saturation
        if correction.brightness != 0 || correction.contrast != 1 || correction.saturation != 1 {
            let controls = CIFilter.colorControls()
            controls.inputImage = result
            controls.brightness = Float(correction.brightness)
            controls.contrast = Float(correction.contrast)
            controls.saturation = Float(correction.saturation)
            result = controls.outputImage ?? result
        }

        // Temperature
        if correction.temperature != 6500 {
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = result
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: CGFloat(correction.temperature), y: 0)
            result = temp.outputImage ?? result
        }

        // Highlights & Shadows
        if correction.highlights != 0 || correction.shadows != 0 {
            let hs = CIFilter.highlightShadowAdjust()
            hs.inputImage = result
            hs.highlightAmount = Float(1 - correction.highlights)
            hs.shadowAmount = Float(correction.shadows)
            result = hs.outputImage ?? result
        }

        // Vibrance
        if correction.vibrance != 0 {
            let vib = CIFilter.vibrance()
            vib.inputImage = result
            vib.amount = Float(correction.vibrance)
            result = vib.outputImage ?? result
        }

        return result
    }

    private static func hasColorCorrection(_ cc: ColorCorrection) -> Bool {
        cc.brightness != 0 ||
        cc.contrast != 1 ||
        cc.saturation != 1 ||
        cc.temperature != 6500 ||
        cc.highlights != 0 ||
        cc.shadows != 0 ||
        cc.vibrance != 0
    }
}
