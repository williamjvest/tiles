import CoreGraphics
import CoreMedia
import Foundation
import VideoToolbox

/// Turns a livestream's FLV video tags into pictures: H.264 (the codec Tiles asks a camera's stream for), as a classic
/// FLV AVC tag or an enhanced-RTMP `avc1` one. Decoding is VideoToolbox's (the hardware decoder); a P-frame before the
/// first keyframe just doesn't decode.
public final class AVCDecoder: @unchecked Sendable { // used on the RTMP receiver's queue only
    /// A decoded picture, from VideoToolbox's callback.
    public var onImage: (@Sendable (CGImage) -> Void)?
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var lengthSize = 4
    private let failed = Failures()

    /// Frames that didn't decode, by VideoToolbox's status: for tests and tools, as a picture that stops coming says
    /// nothing else about why.
    public var failures: [OSStatus: Int] { failed.counts }

    public init() {}

    deinit { invalidate() }

    public func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
    }

    /// One FLV video tag body (an RTMP video message). `timestamp` is in milliseconds.
    public func decode(flvVideo tag: Data, timestamp: UInt32) {
        let b = [UInt8](tag)
        guard b.count >= 5 else { return }
        if b[0] & 0x80 != 0 {
            // Enhanced RTMP: frame type and packet type, then the codec's FourCC.
            guard b[1 ..< 5].elementsEqual(Array("avc1".utf8)) else { return }
            switch b[0] & 0x0F {
            case 0: configure(avcC: Array(b[5...]))                                   // SequenceStart
            case 1 where b.count > 8: frame(Array(b[8...]), pts: Int64(timestamp) + Int64(Self.sint24(b, 5)))  // CodedFrames
            case 3: frame(Array(b[5...]), pts: Int64(timestamp))                     // CodedFramesX: no offset
            default: break
            }
        } else {
            guard b[0] & 0x0F == 7 else { return } // AVC
            switch b[1] {
            case 0: configure(avcC: Array(b[5...]))
            case 1: frame(Array(b[5...]), pts: Int64(timestamp) + Int64(Self.sint24(b, 2)))
            default: break
            }
        }
    }

    /// The AVCDecoderConfigurationRecord: NAL length size, then the SPS and PPS the format is made from.
    private func configure(avcC c: [UInt8]) {
        guard c.count >= 7 else { return }
        lengthSize = Int(c[4] & 0x03) + 1
        var at = 5
        var sets: [[UInt8]] = []
        let spsCount = Int(c[at] & 0x1F); at += 1
        for _ in 0 ..< spsCount {
            guard at + 2 <= c.count else { return }
            let n = Int(c[at]) << 8 | Int(c[at + 1]); at += 2
            guard at + n <= c.count else { return }
            sets.append(Array(c[at ..< at + n])); at += n
        }
        guard at < c.count else { return }
        let ppsCount = Int(c[at]); at += 1
        for _ in 0 ..< ppsCount {
            guard at + 2 <= c.count else { return }
            let n = Int(c[at]) << 8 | Int(c[at + 1]); at += 2
            guard at + n <= c.count else { return }
            sets.append(Array(c[at ..< at + n])); at += n
        }
        guard sets.count >= 2 else { return }
        var newFormat: CMVideoFormatDescription?
        let status = withPointers(sets) { pointers, sizes in
            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: Int32(lengthSize), formatDescriptionOut: &newFormat)
        }
        guard status == noErr, let newFormat else { return }
        if let format, CMFormatDescriptionEqual(format, otherFormatDescription: newFormat), session != nil { return }
        format = newFormat
        makeSession()
    }

    /// A decompression session for `format`, in place of any before.
    private func makeSession() {
        invalidate()
        guard let format else { return }
        let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
        var newSession: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
                                           decoderSpecification: nil, imageBufferAttributes: attributes,
                                           outputCallback: nil, decompressionSessionOut: &newSession) == noErr else { return }
        session = newSession
    }

    /// One access unit, its NAL units length-prefixed as the stream carries them.
    private func frame(_ nalus: [UInt8], pts: Int64) {
        guard let session, let format, !nalus.isEmpty else { return }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: nalus.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: nalus.count, flags: 0, blockBufferOut: &block) == noErr,
              let block,
              nalus.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                    offsetIntoDestination: 0, dataLength: nalus.count) }) == noErr
        else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: pts, timescale: 1000),
                                        decodeTimeStamp: .invalid)
        var size = nalus.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return }
        let onImage = self.onImage
        let failed = self.failed
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            status, _, imageBuffer, _, _ in
            guard status == noErr, let imageBuffer else {
                if status != noErr { failed.add(status) }
                return
            }
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(imageBuffer, options: nil, imageOut: &image)
            if let image { onImage?(image) }
        }
        guard status != noErr else { return }
        failed.add(status)
        // A session the system took away answers this to every frame after (the hardware decoder of an iOS app that
        // went to the background): a new one for the same format, which decodes again from the next keyframe. The
        // camera's stream picked up again sends the same format, which kept the dead session.
        if status == kVTInvalidSessionErr { makeSession() }
    }

    /// Counts by status, from VideoToolbox's callback and the receiver's queue alike.
    private final class Failures: @unchecked Sendable {
        private let lock = NSLock()
        private var byStatus: [OSStatus: Int] = [:]
        func add(_ status: OSStatus) { lock.withLock { byStatus[status, default: 0] += 1 } }
        var counts: [OSStatus: Int] { lock.withLock { byStatus } }
    }

    private static func sint24(_ b: [UInt8], _ at: Int) -> Int32 {
        let v = Int32(b[at]) << 16 | Int32(b[at + 1]) << 8 | Int32(b[at + 2])
        return v & 0x80_0000 != 0 ? v - 0x100_0000 : v
    }

    private func withPointers<R>(_ sets: [[UInt8]], _ body: ([UnsafePointer<UInt8>], [Int]) -> R) -> R {
        let buffers = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            p.initialize(from: set, count: set.count)
            return p
        }
        defer { buffers.forEach { $0.deallocate() } }
        return body(buffers.map { UnsafePointer($0) }, sets.map(\.count))
    }
}
