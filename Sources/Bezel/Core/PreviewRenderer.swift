import AVFoundation
import Observation

@MainActor
@Observable
final class PreviewRenderer {
    let layer = AVSampleBufferDisplayLayer()
    private(set) var framesPerSecond = 0

    private var frameCount = 0
    private var lastTick = Date()
    private var renderer: AVSampleBufferVideoRenderer { layer.sampleBufferRenderer }

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    func enqueue(_ sample: CMSampleBuffer) {
        if renderer.status == .failed {
            renderer.flush(removingDisplayedImage: true, completionHandler: nil)
        }
        renderer.enqueue(sample)

        frameCount += 1
        let now = Date()
        if now.timeIntervalSince(lastTick) >= 1 {
            framesPerSecond = Int(Double(frameCount) / now.timeIntervalSince(lastTick))
            frameCount = 0
            lastTick = now
        }
    }

    func flush() {
        renderer.flush(removingDisplayedImage: true, completionHandler: nil)
        frameCount = 0
        framesPerSecond = 0
        lastTick = Date()
    }
}
