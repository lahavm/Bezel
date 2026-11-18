import Foundation

struct Settings: Sendable, Equatable, Codable {
    enum Source: String, CaseIterable, Identifiable, Sendable, Codable {
        case screen = "Screen"
        case camera = "Camera"
        var id: String { rawValue }
    }

    enum Resolution: Int, CaseIterable, Identifiable, Sendable, Codable {
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

    enum Audio: String, CaseIterable, Identifiable, Sendable, Codable {
        case none = "None"
        case device = "Phone"
        case microphone = "Phone mic"
        var id: String { rawValue }
    }

    enum WebcamShape: String, CaseIterable, Identifiable, Sendable, Codable {
        case rounded = "Rounded"
        case rectangle = "Rectangle"
        case circle = "Circle"
        case heart = "Heart"
        var id: String { rawValue }

        var isSquare: Bool {
            self == .circle || self == .heart
        }
    }

    enum WebcamSize: String, CaseIterable, Identifiable, Sendable, Codable {
        case small = "Small"
        case medium = "Medium"
        case large = "Large"
        var id: String { rawValue }

        var scale: Double {
            switch self {
            case .small: return 0.20
            case .medium: return 0.28
            case .large: return 0.38
            }
        }
    }

    enum Target: String, CaseIterable, Identifiable, Sendable, Codable {
        case phone = "Phone"
        case both = "Both"
        var id: String { rawValue }
        var recordsWebcam: Bool { self == .both }
        var label: String { self == .phone ? "Phone" : "Phone + Mac camera" }
    }

    var source: Source = .screen
    var audio: Audio = .device
    var target: Target = .phone
    var macMic = false
    /// nil means Auto: the connected external mic, else the system default.
    var micId: String?
    var separateFiles = false
    var recordingsFolder = ""
    var resolution: Resolution = .fhd
    /// 0 means "native": the phone's own refresh rate, no cap requested.
    var fps: Int = 60
    var codec: String = "h264"
    var cameraFacing: String = "back"
    var cameraId: Int?
    var phoneVolume: Double = 1
    var micVolume: Double = 1
    var hearPhoneAudio: Bool = true
    var webcamShape: WebcamShape = .rounded
    var webcamSize: WebcamSize = .medium
    var webcamScale: Double = 0.28
    /// Normalized center of the camera overlay, measured from the top-left.
    var webcamX: Double = 0.82
    var webcamY: Double = 0.75
    var webcamBlur = false
    var webcamBlurAmount: Double = 0.5

    static var defaultFolder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bezel", isDirectory: true)
    }

    var outputDirectory: URL {
        recordingsFolder.isEmpty
            ? Self.defaultFolder
            : URL(fileURLWithPath: recordingsFolder, isDirectory: true)
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case source, audio, target, macMic, micId, separateFiles, recordingsFolder
        case resolution, fps, codec, cameraFacing, cameraId
        case phoneVolume, micVolume, hearPhoneAudio, webcamShape, webcamSize, webcamScale, webcamX, webcamY, webcamBlur, webcamBlurAmount
    }

    /// Decodes missing keys with their defaults, so adding a setting never
    /// resets everything else.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decodeIfPresent(Source.self, forKey: .source) ?? .screen
        audio = try container.decodeIfPresent(Audio.self, forKey: .audio) ?? .device
        target = try container.decodeIfPresent(Target.self, forKey: .target) ?? .phone
        macMic = try container.decodeIfPresent(Bool.self, forKey: .macMic) ?? false
        micId = try container.decodeIfPresent(String.self, forKey: .micId)
        separateFiles = try container.decodeIfPresent(Bool.self, forKey: .separateFiles) ?? false
        recordingsFolder = try container.decodeIfPresent(String.self, forKey: .recordingsFolder) ?? ""
        resolution = try container.decodeIfPresent(Resolution.self, forKey: .resolution) ?? .fhd
        fps = try container.decodeIfPresent(Int.self, forKey: .fps) ?? 60
        codec = try container.decodeIfPresent(String.self, forKey: .codec) ?? "h264"
        cameraFacing = try container.decodeIfPresent(String.self, forKey: .cameraFacing) ?? "back"
        cameraId = try container.decodeIfPresent(Int.self, forKey: .cameraId)
        phoneVolume = try container.decodeIfPresent(Double.self, forKey: .phoneVolume) ?? 1
        micVolume = try container.decodeIfPresent(Double.self, forKey: .micVolume) ?? 1
        hearPhoneAudio = try container.decodeIfPresent(Bool.self, forKey: .hearPhoneAudio) ?? true
        webcamShape = try container.decodeIfPresent(WebcamShape.self, forKey: .webcamShape) ?? .rounded
        webcamSize = try container.decodeIfPresent(WebcamSize.self, forKey: .webcamSize) ?? .medium
        webcamScale = try container.decodeIfPresent(Double.self, forKey: .webcamScale) ?? 0.28
        webcamX = try container.decodeIfPresent(Double.self, forKey: .webcamX) ?? 0.82
        webcamY = try container.decodeIfPresent(Double.self, forKey: .webcamY) ?? 0.75
        webcamBlur = try container.decodeIfPresent(Bool.self, forKey: .webcamBlur) ?? false
        webcamBlurAmount = try container.decodeIfPresent(Double.self, forKey: .webcamBlurAmount) ?? 0.5
    }

    static func load() -> Settings {
        guard let data = UserDefaults.standard.data(forKey: "bezel.settings"),
              let decoded = try? JSONDecoder().decode(Settings.self, from: data)
        else { return Settings() }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: "bezel.settings")
    }
}
