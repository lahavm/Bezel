import AVFoundation
import Foundation

enum MicError: LocalizedError {
    case denied
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .denied: return "Microphone access is off. Enable it in System Settings › Privacy & Security › Microphone."
        case .failed(let message): return message
        }
    }
}

/// Records the Mac microphone to its own AAC file alongside the video.
/// Kept separate so the phone stream stays untouched, with no re-encoding.
final class MicRecorder: @unchecked Sendable {
    private var recorder: AVAudioRecorder?
    private(set) var url: URL?

    var isRunning: Bool { recorder?.isRecording ?? false }

    func start() async throws -> URL {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw MicError.denied
        }

        let directory = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bezel", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let fileURL = directory.appendingPathComponent("Bezel Mic \(formatter.string(from: Date())).m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000
        ]
        let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
        recorder.isMeteringEnabled = false
        guard recorder.record() else {
            throw MicError.failed("The microphone could not start recording.")
        }

        self.recorder = recorder
        self.url = fileURL
        Log.write("mic: recording \(fileURL.lastPathComponent)")
        return fileURL
    }

    func stop() -> URL? {
        guard let recorder, let url else {
            self.recorder = nil
            return nil
        }
        recorder.stop()
        self.recorder = nil
        self.url = nil
        return url
    }
}
