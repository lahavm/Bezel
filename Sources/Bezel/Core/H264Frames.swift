import AVFoundation
import Foundation

/// Converts the device's Annex-B H.264 stream into AVCC sample buffers
/// that AVSampleBufferDisplayLayer can decode with VideoToolbox.
enum H264Frames {
    static func nalUnits(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var start: Int?
        var index = 0

        while index < bytes.count {
            if index + 3 <= bytes.count,
               bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                if let begin = start {
                    var end = index
                    if end > begin, bytes[end - 1] == 0 { end -= 1 } // 4-byte start code
                    if end > begin { units.append(data.subdata(in: begin..<end)) }
                }
                index += 3
                start = index
            } else {
                index += 1
            }
        }
        if let begin = start, begin < bytes.count {
            units.append(data.subdata(in: begin..<bytes.count))
        }
        return units
    }

    static func formatDescription(fromConfig config: Data) -> CMVideoFormatDescription? {
        let units = nalUnits(in: config)
        guard let sps = units.first(where: { ($0.first.map { $0 & 0x1F }) == 7 }),
              let pps = units.first(where: { ($0.first.map { $0 & 0x1F }) == 8 })
        else { return nil }

        var description: CMVideoFormatDescription?
        sps.withUnsafeBytes { spsBuffer in
            pps.withUnsafeBytes { ppsBuffer in
                guard let spsPointer = spsBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let ppsPointer = ppsBuffer.bindMemory(to: UInt8.self).baseAddress
                else { return }
                var pointers: [UnsafePointer<UInt8>] = [spsPointer, ppsPointer]
                var sizes: [Int] = [sps.count, pps.count]
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        return description
    }

    static func avcc(from packet: Data) -> Data? {
        let units = nalUnits(in: packet)
        guard !units.isEmpty else { return nil }
        var output = Data(capacity: packet.count + units.count * 4)
        for unit in units {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
            output.append(unit)
        }
        return output
    }

    static func sampleBuffer(
        avcc: Data,
        format: CMVideoFormatDescription,
        ptsMicros: Int64
    ) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        let length = avcc.count
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return nil }

        let copied = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: length
            )
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: ptsMicros, timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = length
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

        CMSetAttachment(
            sample,
            key: kCMSampleAttachmentKey_DisplayImmediately,
            value: kCFBooleanTrue,
            attachmentMode: kCMAttachmentMode_ShouldNotPropagate
        )
        return sample
    }
}
