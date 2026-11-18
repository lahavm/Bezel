import AVFoundation
import Foundation

/// Plays the decoded phone audio live through the Mac speakers / headphones.
final class PhoneAudioPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private let queue = DispatchQueue(label: "bezel.audio.player")
    private var isRunning = false
    private var enabled = true
    private var volume: Float = 1.0

    func setEnabled(_ enabled: Bool) {
        queue.async { [self] in
            self.enabled = enabled
            self.player.volume = enabled ? self.volume : 0
        }
    }

    func setVolume(_ volume: Double) {
        queue.async { [self] in
            self.volume = Float(volume)
            self.player.volume = self.enabled ? Float(volume) : 0
        }
    }

    func configure(sampleRate: Double, channels: Int) {
        queue.async { [self] in
            let rate = sampleRate > 0 ? sampleRate : 48000
            let chCount = AVAudioChannelCount(max(1, min(2, channels)))
            if isRunning, let fmt = format, fmt.sampleRate == rate, fmt.channelCount == chCount {
                return
            }
            tearDown()
            guard let newFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: chCount) else { return }
            format = newFormat
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: newFormat)
            do {
                try engine.start()
                player.play()
                player.volume = enabled ? volume : 0
                isRunning = true
                Log.write("player: listening to phone at \(Int(rate))Hz \(chCount)ch")
            } catch {
                Log.write("player: engine start failed \(error.localizedDescription)")
            }
        }
    }

    func play(samples: [Float], frameCount: Int, channels: Int) {
        guard isRunning, enabled, volume > 0.001 else { return }
        queue.async { [self] in
            guard isRunning, enabled, let format, channels == Int(format.channelCount), frameCount > 0 else { return }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
            buffer.frameLength = AVAudioFrameCount(frameCount)
            guard let channelData = buffer.floatChannelData else { return }

            if channels == 1 {
                channelData[0].initialize(from: samples, count: frameCount)
            } else if channels == 2 {
                for f in 0..<frameCount {
                    channelData[0][f] = samples[f * 2]
                    channelData[1][f] = samples[f * 2 + 1]
                }
            }
            player.scheduleBuffer(buffer)
        }
    }

    func stop() {
        queue.async { [self] in
            tearDown()
        }
    }

    private func tearDown() {
        if isRunning {
            player.stop()
            engine.stop()
            engine.disconnectNodeOutput(player)
            engine.detach(player)
            isRunning = false
        }
        format = nil
    }
}
