import Foundation

struct Settings: Sendable, Equatable {
    enum Source: String, CaseIterable, Identifiable, Sendable {
        case screen = "Screen"
        case camera = "Camera"
        var id: String { rawValue }
    }

    enum Resolution: Int, CaseIterable, Identifiable, Sendable {
        case native = 0
        case uhd = 2160
        case qhd = 1440
        case fhd = 1080
        case hd = 720

        var id: Int { rawValue }
        var label: String {
            switch self {
            case .native: return "Native"
            case .uhd: return "4K"
            case .qhd: return "1440p"
            case .fhd: return "1080p"
            case .hd: return "720p"
            }
        }
    }

    var source: Source = .screen
    var resolution: Resolution = .fhd
    var fps: Int = 60
    var codec: String = "h264"
    var cameraFacing: String = "back"
}
