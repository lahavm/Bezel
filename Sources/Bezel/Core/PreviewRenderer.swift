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
        if let error = renderer.error {
            Log.write("renderer: failed \(error.localizedDescription)")
            renderer.flush(removingDisplayedImage: true, completionHandler: nil)
        }
        renderer.enqueue(retimed(sample))

        frameCount += 1
        let now = Date()
        if now.timeIntervalSince(lastTick) >= 2 {
            framesPerSecond = Int(Double(frameCount) / now.timeIntervalSince(lastTick))
            frameCount = 0
            lastTick = now
        }
    }

    /// The phone stamps frames with its own uptime, which has nothing to do with
    /// the Mac's clock. The layer schedules presentation by PTS, so it showed the
    /// first frame and held the rest as not yet due. Re-stamp on the host clock,
    /// exactly like the camera preview's samples.
    private func retimed(_ sample: CMSampleBuffer) -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        )
        return status == noErr ? (copy ?? sample) : sample
    }

    /// The frame the preview is showing right now, already decoded by the
    /// layer. This is how scrcpy takes a screenshot: no extra decode pass.
    func displayedPixelBuffer() -> CVPixelBuffer? {
        renderer.displayedPixelBuffer()
    }

    func flush() {
        renderer.flush(removingDisplayedImage: true, completionHandler: nil)
        frameCount = 0
        framesPerSecond = 0
        lastTick = Date()
    }
}
