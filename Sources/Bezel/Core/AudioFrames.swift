import AVFoundation
import Foundation

/// Turns the raw AAC packets from the scrcpy audio stream into sample buffers.
/// The stream carries an AudioSpecificConfig packet once, then bare AAC frames.
enum AudioFrames {
    static func formatDescription(asc: Data) -> CMAudioFormatDescription? {
        guard !asc.isEmpty else { return nil }

        var description = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        // Read the object type, sample rate index and channel config from the ASC.
        let bytes = [UInt8](asc)
        if bytes.count >= 2 {
            let objectType = bytes[0] >> 3
            let frequencyIndex = (bytes[0] & 0x07) << 1 | bytes[1] >> 7
            let channelConfig = (bytes[1] >> 3) & 0x0F
            if objectType == 31, bytes.count >= 3 {
                _ = bytes[1] & 0x3F << 5 | bytes[2] >> 3
            }
            let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
                                   16000, 12000, 11025, 8000, 7350]
            if frequencyIndex < rates.count {
                description.mSampleRate = rates[Int(frequencyIndex)]
            }
            if channelConfig > 0 {
                description.mChannelsPerFrame = UInt32(channelConfig)
            }
        }

        var formatDescription: CMAudioFormatDescription?
        var streamDescription = description
        let status = asc.withUnsafeBytes { cookie in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &streamDescription,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: asc.count,
                magicCookie: cookie.baseAddress,
                extensions: nil,
                formatDescriptionOut: &formatDescription
            )
        }
        return status == noErr ? formatDescription : nil
    }

    static func sampleBuffer(
        frame: Data,
        format: CMAudioFormatDescription,
        ptsMicros: Int64
    ) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: frame.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: frame.count,
            flags: 0,
            blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return nil }

        let copied = frame.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: frame.count
            )
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var sampleRate = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mSampleRate ?? 48000
        if sampleRate <= 0 { sampleRate = 48000 }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1024, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: ptsMicros, timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = frame.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }
        return sample
    }
}
