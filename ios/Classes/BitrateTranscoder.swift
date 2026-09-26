import AVFoundation

/// toastyai addition (2026-09-26): re-encode a video at a bitrate WE choose.
///
/// AVAssetExportSession presets pick their own bitrate, and it is high:
/// measured with avconvert on the same presets, 720p came out at 6.7 Mbps, so a
/// 50 MB upload cap held only ~63 s of video and anything longer compressed for
/// a minute and was then refused (Kris, 64 s clip, 2026-09-26). Messaging apps
/// encode to a size budget instead. This does the same with an
/// AVAssetReader -> AVAssetWriter pipeline: decode, let the writer scale to the
/// target size, encode H.264 at an explicit average bitrate, AAC audio at an
/// explicit bitrate.
///
/// Deliberately independent of Flutter so it can be compiled and exercised on
/// macOS against real files; the plugin only adapts its callbacks.
///
/// Two things it does NOT copy from the export path, both on purpose:
///  * no AVVideoComposition. `AVMutableVideoComposition(propertiesOf:)` is what
///    turned a non-canonical rotation matrix into a garbage render size and a
///    black block baked into every frame (fork note, 2026-09-13). The frames
///    are encoded unrotated and the rotation rides as track metadata.
///  * the source's transform is not copied verbatim: only its rotation is kept,
///    and the translation is recomputed for the OUTPUT size. A translation
///    expressed in the source's pixels is wrong once the frame is scaled, and a
///    non-canonical one is exactly the case that broke before.
public final class BitrateTranscoder {
    public struct Settings {
        /// Longest side of the output, in pixels, before rotation. Sources that
        /// are already smaller are not upscaled.
        public let maxLongSide: Int
        /// Average video bitrate, bits per second.
        public let videoBitrate: Int
        /// AAC bitrate, bits per second.
        public let audioBitrate: Int
        /// Frames closer together than 1/maxFrameRate are dropped, so a 60 fps
        /// source spends its bitrate on 30 sharper frames rather than 60 soft
        /// ones. Done by timestamp, never with a video composition (see above).
        public let maxFrameRate: Double

        public init(maxLongSide: Int, videoBitrate: Int, audioBitrate: Int,
                    maxFrameRate: Double) {
            self.maxLongSide = maxLongSide
            self.videoBitrate = videoBitrate
            self.audioBitrate = audioBitrate
            self.maxFrameRate = maxFrameRate
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case noVideoTrack
        case setup(String)
        case failed(String)
        case cancelled

        public var description: String {
            switch self {
            case .noVideoTrack: return "Source has no video track"
            case .setup(let m): return "Transcode setup failed: \(m)"
            case .failed(let m): return "Transcode failed: \(m)"
            case .cancelled: return "Transcode cancelled"
            }
        }
    }

    private let queue = DispatchQueue(label: "video_compress.bitrate_transcoder")
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    private var cancelled = false

    public init() {}

    /// Output dimensions for a source of [natural] size: the long side capped at
    /// [maxLongSide], aspect kept, both sides even (H.264 needs 4:2:0 pairs).
    public static func outputSize(natural: CGSize, maxLongSide: Int) -> (Int, Int) {
        let w = abs(natural.width), h = abs(natural.height)
        let long = max(w, h)
        let scale = long > CGFloat(maxLongSide) ? CGFloat(maxLongSide) / long : 1
        func even(_ v: CGFloat) -> Int { max(2, Int((v * scale / 2).rounded()) * 2) }
        return (even(w), even(h))
    }

    /// The source's ROTATION, re-anchored so the rotated output frame of
    /// [width]x[height] starts at the origin. Players read this as-is.
    public static func canonicalTransform(_ t: CGAffineTransform, width: Int,
                                          height: Int) -> CGAffineTransform {
        var r = CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: 0, ty: 0)
        let box = CGRect(x: 0, y: 0, width: width, height: height).applying(r)
        r.tx = -box.minX
        r.ty = -box.minY
        return r
    }

    public func cancel() {
        queue.async { self.cancelled = true }
    }

    public func transcode(source: URL, destination: URL, settings: Settings,
                          progress: @escaping (Double) -> Void,
                          completion: @escaping (Result<Void, Failure>) -> Void) {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            completion(.failure(.noVideoTrack))
            return
        }
        let audioTrack = asset.tracks(withMediaType: .audio).first
        let duration = max(asset.duration.seconds, 0.001)

        try? FileManager.default.removeItem(at: destination)

        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        } catch {
            completion(.failure(.setup(error.localizedDescription)))
            return
        }
        writer.shouldOptimizeForNetworkUse = true

        // VIDEO: decode to NV12, let the writer scale and encode.
        let videoOut = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ])
        videoOut.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOut) else {
            completion(.failure(.setup("reader refused the video output")))
            return
        }
        reader.add(videoOut)

        let (w, h) = BitrateTranscoder.outputSize(
            natural: videoTrack.naturalSize, maxLongSide: settings.maxLongSide)
        let sourceFps = videoTrack.nominalFrameRate > 0
            ? Double(videoTrack.nominalFrameRate) : 30
        let videoIn = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: w,
                AVVideoHeightKey: h,
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: settings.videoBitrate,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
                    AVVideoExpectedSourceFrameRateKey:
                        min(sourceFps, settings.maxFrameRate),
                ],
            ])
        videoIn.expectsMediaDataInRealTime = false
        videoIn.transform = BitrateTranscoder.canonicalTransform(
            videoTrack.preferredTransform, width: w, height: h)
        guard writer.canAdd(videoIn) else {
            completion(.failure(.setup("writer refused the video input")))
            return
        }
        writer.add(videoIn)

        // AUDIO: decode to 16-bit stereo PCM (downmixing anything wider), then
        // AAC at the requested bitrate. Stereo at 44.1 kHz is what every AAC
        // encoder accepts at every bitrate we would ask for.
        var audioOut: AVAssetReaderTrackOutput?
        var audioIn: AVAssetWriterInput?
        if let audioTrack = audioTrack {
            let out = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ])
            out.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: settings.audioBitrate,
                ])
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(out), writer.canAdd(input) else {
                completion(.failure(.setup("audio track could not be re-encoded")))
                return
            }
            reader.add(out)
            writer.add(input)
            audioOut = out
            audioIn = input
        }

        guard reader.startReading() else {
            completion(.failure(.setup(
                reader.error?.localizedDescription ?? "reader did not start")))
            return
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            completion(.failure(.setup(
                writer.error?.localizedDescription ?? "writer did not start")))
            return
        }
        writer.startSession(atSourceTime: .zero)
        self.reader = reader
        self.writer = writer

        let group = DispatchGroup()
        let minGap = 1.0 / settings.maxFrameRate * 0.9
        var lastKept = -Double.infinity
        var lastReported = -1.0

        // Pump one input from its output until the source runs dry, the writer
        // stops accepting, or we are cancelled. `done` guards the group so a
        // late callback can never leave it twice.
        func pump(_ input: AVAssetWriterInput, _ output: AVAssetReaderTrackOutput,
                  isVideo: Bool) {
            var done = false
            group.enter()
            input.requestMediaDataWhenReady(on: queue) {
                if done { return }
                while input.isReadyForMoreMediaData {
                    if self.cancelled {
                        done = true; input.markAsFinished(); group.leave(); return
                    }
                    guard let sample = output.copyNextSampleBuffer() else {
                        done = true; input.markAsFinished(); group.leave(); return
                    }
                    if isVideo {
                        let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        if t.isFinite, t - lastKept < minGap { continue }
                        lastKept = t
                        let p = min(1, max(0, t / duration))
                        if p - lastReported >= 0.01 {
                            lastReported = p
                            progress(p)
                        }
                    }
                    if !input.append(sample) {
                        done = true; input.markAsFinished(); group.leave(); return
                    }
                }
            }
        }

        pump(videoIn, videoOut, isVideo: true)
        if let a = audioIn, let o = audioOut { pump(a, o, isVideo: false) }

        group.notify(queue: queue) {
            if self.cancelled {
                reader.cancelReading()
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: destination)
                completion(.failure(.cancelled))
                return
            }
            if reader.status == .failed || writer.status == .failed {
                let why = writer.error?.localizedDescription
                    ?? reader.error?.localizedDescription ?? "unknown"
                reader.cancelReading()
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: destination)
                completion(.failure(.failed(why)))
                return
            }
            writer.finishWriting {
                if writer.status == .completed {
                    completion(.success(()))
                } else {
                    try? FileManager.default.removeItem(at: destination)
                    completion(.failure(.failed(
                        writer.error?.localizedDescription
                            ?? "writer ended with status \(writer.status.rawValue)")))
                }
            }
        }
    }
}
