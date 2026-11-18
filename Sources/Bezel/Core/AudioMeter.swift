import AudioToolbox
import AVFoundation
import Foundation

/// Converts a peak amplitude into the 0...1 meter value shown in the inspector.
enum AudioLevel {
    static func normalized(peak: Float, gain: Float = 1) -> Float {
        let scaled = peak * max(0, gain)
        guard scaled > 0.0001 else { return 0 }
        let decibels = 20 * log10(scaled)
        return max(0, min(1, (decibels + 60) / 60))
    }

    static func decibels(level: Float) -> Float {
        level <= 0.001 ? -60 : level * 60 - 60
    }

    static func smoothed(_ current: Float, _ target: Float) -> Float {
        target > current ? current * 0.25 + target * 0.75 : current * 0.88 + target * 0.12
    }
}

/// Applies the volume slider to microphone PCM before it is encoded.
enum AudioGain {
    /// Returns a scaled copy; capture buffers must not be modified in place.
    static func adjusted(_ gain: Float, sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard gain != 1, gain >= 0 else { return sampleBuffer }
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              stream.mFormatID == kAudioFormatLinearPCM,
              stream.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              stream.mBitsPerChannel == 32,
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return sampleBuffer }

        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            block,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &pointer
        ) == noErr, let pointer, length >= 4 else { return sampleBuffer }

        var data = Data(bytes: pointer, count: length)
        data.withUnsafeMutableBytes { raw in
            let samples = raw.bindMemory(to: Float.self)
            for index in 0..<samples.count {
                samples[index] = max(-1, min(1, samples[index] * gain))
            }
        }

        var newBlock: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &newBlock
        ) == kCMBlockBufferNoErr, let newBlock else { return sampleBuffer }

        let copied = data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!,
                blockBuffer: newBlock,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        guard copied == kCMBlockBufferNoErr else { return sampleBuffer }

        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            decodeTimeStamp: .invalid
        )
        var sampleSize = data.count
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: newBlock,
            formatDescription: format,
            sampleCount: CMSampleBufferGetNumSamples(sampleBuffer),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &copy
        ) == noErr else { return sampleBuffer }
        return copy
    }
}

/// Decodes the phone's AAC packets just enough to show a live level.
final class PhoneAudioMeter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "bezel.meter.phone")
    private var converter: AudioConverterRef?
    private var inputFormat: AudioStreamBasicDescription?
    private var packet: [UInt8] = []
    private var packetSize = 0
    private var packetPointer: UnsafeMutableRawPointer?
    private var packetSupplied = false
    private let packetDescription = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
    private var level: Float = 0
    private var lastEmit: UInt64 = 0
    private var loggedFailure = false

    var onLevel: (@Sendable (Float) -> Void)?
    var onFormat: (@Sendable (Double, Int) -> Void)?
    var onPCM: (@Sendable ([Float], Int, Int) -> Void)?

    deinit {
        if let converter { AudioConverterDispose(converter) }
        packetDescription.deallocate()
    }

    func configure(asc: Data) {
        guard let format = AudioFrames.formatDescription(asc: asc) else {
            Log.write("meter: unsupported phone audio")
            return
        }
        configure(format: format, cookie: asc)
    }

    func configure(format: CMAudioFormatDescription, cookie: Data? = nil) {
        queue.async { [self] in
            dispose()
            guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format) else {
                Log.write("meter: unsupported phone audio")
                return
            }

            var input = asbd.pointee
            let channels = max(1, input.mChannelsPerFrame)
            var output = AudioStreamBasicDescription(
                mSampleRate: input.mSampleRate > 0 ? input.mSampleRate : 48000,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4 * channels,
                mFramesPerPacket: 1,
                mBytesPerFrame: 4 * channels,
                mChannelsPerFrame: channels,
                mBitsPerChannel: 32,
                mReserved: 0
            )

            var created: AudioConverterRef?
            let status = AudioConverterNew(&input, &output, &created)
            guard status == noErr, let created else {
                Log.write("meter: phone decoder failed (\(status))")
                return
            }
            converter = created
            inputFormat = input

            if let cookie, !cookie.isEmpty {
                _ = cookie.withUnsafeBytes { bytes in
                    AudioConverterSetProperty(
                        created,
                        kAudioConverterDecompressionMagicCookie,
                        UInt32(cookie.count),
                        bytes.baseAddress!
                    )
                }
            } else {
                var cookieSize = 0
                if let cookie = CMAudioFormatDescriptionGetMagicCookie(format, sizeOut: &cookieSize),
                   cookieSize > 0 {
                    AudioConverterSetProperty(
                        created,
                        kAudioConverterDecompressionMagicCookie,
                        UInt32(cookieSize),
                        cookie
                    )
                }
            }
            loggedFailure = false
            Log.write("meter: phone decoder ready \(Int(input.mSampleRate))Hz \(channels)ch")
            onFormat?(input.mSampleRate, Int(channels))
        }
    }

    func process(_ frame: Data) {
        queue.async { [self] in
            guard let converter, let inputFormat else { return }
            let channels = max(1, Int(inputFormat.mChannelsPerFrame))
            var output = [Float](repeating: 0, count: 1024 * channels)
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels),
                    mDataByteSize: UInt32(output.count * 4),
                    mData: nil
                )
            )
            var packets = UInt32(1024)
            packet = [UInt8](frame)
            packetSize = frame.count
            packetSupplied = false

            let status: OSStatus = packet.withUnsafeMutableBytes { bytes in
                packetPointer = bytes.baseAddress
                return output.withUnsafeMutableBytes { out in
                    list.mBuffers.mData = out.baseAddress
                    list.mBuffers.mDataByteSize = UInt32(out.count)
                    return AudioConverterFillComplexBuffer(
                        converter,
                        phoneMeterInput,
                        Unmanaged.passUnretained(self).toOpaque(),
                        &packets,
                        &list,
                        nil
                    )
                }
            }
            packetPointer = nil

            guard status == noErr else {
                if !loggedFailure {
                    loggedFailure = true
                    Log.write("meter: phone decode failed (\(status))")
                }
                return
            }

            let count = min(Int(packets) * channels, output.count)
            var peak: Float = 0
            for index in 0..<count {
                peak = max(peak, abs(output[index]))
            }
            update(peak: peak)
            onPCM?(output, Int(packets), channels)
        }
    }

    func reset() {
        queue.async { [self] in
            dispose()
            level = 0
            onLevel?(0)
        }
    }

    fileprivate func supply(
        _ packets: UnsafeMutablePointer<UInt32>,
        _ data: UnsafeMutablePointer<AudioBufferList>,
        _ descriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?
    ) -> OSStatus {
        guard !packetSupplied, let packetPointer, packetSize > 0 else {
            packets.pointee = 0
            return noErr
        }
        packetSupplied = true
        packets.pointee = 1

        let buffers = UnsafeMutableAudioBufferListPointer(data)
        buffers[0].mNumberChannels = inputFormat?.mChannelsPerFrame ?? 1
        buffers[0].mDataByteSize = UInt32(packetSize)
        buffers[0].mData = packetPointer

        packetDescription.pointee = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(packetSize)
        )
        descriptions?.pointee = packetDescription
        return noErr
    }

    private func update(peak: Float) {
        level = AudioLevel.smoothed(level, AudioLevel.normalized(peak: peak))
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastEmit >= 50_000_000 else { return }
        lastEmit = now
        onLevel?(level)
    }

    private func dispose() {
        if let converter {
            AudioConverterDispose(converter)
            self.converter = nil
        }
        inputFormat = nil
        packet = []
        packetSize = 0
    }
}

private func phoneMeterInput(
    _ converter: AudioConverterRef,
    _ packets: UnsafeMutablePointer<UInt32>,
    _ data: UnsafeMutablePointer<AudioBufferList>,
    _ descriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return -1 }
    let meter = Unmanaged<PhoneAudioMeter>.fromOpaque(userData).takeUnretainedValue()
    return meter.supply(packets, data, descriptions)
}

/// Reads the selected microphone continuously so the level is visible before
/// recording, not only after checking the file.
final class MicLevelMonitor: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "bezel.meter.mic")
    private var deviceID: String?
    private var gain: Float = 1
    private var level: Float = 0
    private var lastEmit: UInt64 = 0
    private var requesting = false

    var onLevel: (@Sendable (Float) -> Void)?

    func start(id: String?, gain: Double) {
        queue.async { [self] in
            self.gain = Float(gain)
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                return
            }
            guard let device = Microphone.device(id: id) else { return }
            if session.isRunning, deviceID == device.uniqueID { return }

            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
            } else {
                Log.write("meter: mic input failed")
            }
            if session.outputs.isEmpty {
                output.audioSettings = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false
                ]
                output.setSampleBufferDelegate(self, queue: queue)
                if session.canAddOutput(output) {
                    session.addOutput(output)
                }
            }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
            deviceID = device.uniqueID
            Log.write("meter: mic \(device.localizedName) running=\(session.isRunning)")
        }
    }

    func wake() {
        guard !requesting else { return }
        requesting = true
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            guard let self else { return }
            self.requesting = false
            self.onLevel?(0)
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            deviceID = nil
            level = 0
            onLevel?(0)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            block,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &pointer
        ) == noErr, let pointer, length >= 4 else { return }

        let count = length / 4
        var peak: Float = 0
        pointer.withMemoryRebound(to: Float.self, capacity: count) { samples in
            for index in 0..<count {
                peak = max(peak, abs(samples[index]))
            }
        }
        level = AudioLevel.smoothed(level, AudioLevel.normalized(peak: peak))
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastEmit >= 50_000_000 else { return }
        lastEmit = now
        onLevel?(level)
    }
}
