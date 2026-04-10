import Foundation

enum LookPreset: String, Codable, CaseIterable, Hashable {
    case clean = "Clean"
    case film = "Film"
    case punch = "Punch"
    case mono = "Mono"
}

enum CaptionLook: String, Codable, CaseIterable, Hashable {
    case clean = "Clean"
    case bold = "Bold"
    case story = "Story"
}

struct ProjectStyleSettings: Codable, Hashable {
    var look: LookPreset
    var lookIntensity: Double
    var captionStyle: CaptionLook
    var colorCorrection: ColorCorrection

    static let `default` = ProjectStyleSettings(
        look: .clean,
        lookIntensity: 0.62,
        captionStyle: .clean,
        colorCorrection: .init()
    )
}

struct ColorCorrection: Codable, Hashable {
    var brightness: Double = 0       // -1 to 1
    var contrast: Double = 1         // 0 to 2
    var saturation: Double = 1       // 0 to 2
    var temperature: Double = 6500   // 2000 to 10000
    var highlights: Double = 0       // -1 to 1
    var shadows: Double = 0          // -1 to 1
    var vibrance: Double = 0         // -1 to 1
}
