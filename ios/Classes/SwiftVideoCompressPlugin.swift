import Flutter
import AVFoundation

public class SwiftVideoCompressPlugin: NSObject, FlutterPlugin {
    private let channelName = "video_compress"
    private var exporter: AVAssetExportSession? = nil
    private var transcoder: BitrateTranscoder? = nil
    private var stopCommand = false
    private let channel: FlutterMethodChannel
    private let avController = AvController()
    
    init(channel: FlutterMethodChannel) {
        self.channel = channel
    }
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "video_compress", binaryMessenger: registrar.messenger())
        let instance = SwiftVideoCompressPlugin(channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? Dictionary<String, Any>
        switch call.method {
        case "getByteThumbnail":
            let path = args!["path"] as! String
            let quality = args!["quality"] as! NSNumber
            let position = args!["position"] as! NSNumber
            getByteThumbnail(path, quality, position, result)
        case "getFileThumbnail":
            let path = args!["path"] as! String
            let quality = args!["quality"] as! NSNumber
            let position = args!["position"] as! NSNumber
            getFileThumbnail(path, quality, position, result)
        case "getMediaInfo":
            let path = args!["path"] as! String
            getMediaInfo(path, result)
        case "compressVideo":
            let path = args!["path"] as! String
            let quality = args!["quality"] as! NSNumber
            let deleteOrigin = args!["deleteOrigin"] as! Bool
            let startTime = args!["startTime"] as? Double
            let duration = args!["duration"] as? Double
            let includeAudio = args!["includeAudio"] as? Bool
            let frameRate = args!["frameRate"] as? Int
            compressVideo(path, quality, deleteOrigin, startTime, duration, includeAudio,
                          frameRate, result)
        case "compressVideoToBitrate":
            guard let path = args?["path"] as? String,
                  let maxLongSide = args?["maxLongSide"] as? Int,
                  let videoBitrate = args?["videoBitrate"] as? Int else {
                result(FlutterError(code: channelName,
                                    message: "compressVideoToBitrate: missing arguments",
                                    details: nil))
                return
            }
            compressVideoToBitrate(
                path,
                BitrateTranscoder.Settings(
                    maxLongSide: maxLongSide,
                    videoBitrate: videoBitrate,
                    audioBitrate: args?["audioBitrate"] as? Int ?? 96_000,
                    maxFrameRate: args?["maxFrameRate"] as? Double ?? 30),
                result)
        case "cancelCompression":
            cancelCompression(result)
        case "deleteAllCache":
            Utility.deleteFile(Utility.basePath(), clear: true)
            result(true)
        case "setLogLevel":
            result(true)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    private func getBitMap(_ path: String,_ quality: NSNumber,_ position: NSNumber,_ result: FlutterResult)-> Data?  {
        let url = Utility.getPathUrl(path)
        let asset = avController.getVideoAsset(url)
        guard let track = avController.getTrack(asset) else { return nil }
        
        let assetImgGenerate = AVAssetImageGenerator(asset: asset)
        assetImgGenerate.appliesPreferredTrackTransform = true
        
        let timeScale = CMTimeScale(track.nominalFrameRate)
        let time = CMTimeMakeWithSeconds(Float64(truncating: position),preferredTimescale: timeScale)
        guard let img = try? assetImgGenerate.copyCGImage(at:time, actualTime: nil) else {
            return nil
        }
        let thumbnail = UIImage(cgImage: img)
        let compressionQuality = CGFloat(0.01 * Double(truncating: quality))
        return thumbnail.jpegData(compressionQuality: compressionQuality)
    }
    
    private func getByteThumbnail(_ path: String,_ quality: NSNumber,_ position: NSNumber,_ result: FlutterResult) {
        if let bitmap = getBitMap(path,quality,position,result) {
            result(bitmap)
        }
    }
    
    private func getFileThumbnail(_ path: String,_ quality: NSNumber,_ position: NSNumber,_ result: FlutterResult) {
        let fileName = Utility.getFileName(path)
        let url = Utility.getPathUrl("\(Utility.basePath())/\(fileName).jpg")
        Utility.deleteFile(path)
        if let bitmap = getBitMap(path,quality,position,result) {
            guard (try? bitmap.write(to: url)) != nil else {
                return result(FlutterError(code: channelName,message: "getFileThumbnail error",details: "getFileThumbnail error"))
            }
            // toastyai fix (2026-09-20): same defect as the compressVideo
            // readback — excludeFileProtocol strips the scheme but never
            // decodes, so this handed Dart a percent-encoded path that names no
            // real file whenever the name contains a space. `url.path` is the
            // decoded filesystem path, which is what every caller wanted.
            result(url.path)
        }
    }
    
    public func getMediaInfoJson(_ path: String)->[String : Any?] {
        let url = Utility.getPathUrl(path)
        let asset = avController.getVideoAsset(url)
        guard let track = avController.getTrack(asset) else { return [:] }
        
        let playerItem = AVPlayerItem(url: url)
        let metadataAsset = playerItem.asset
        
        let orientation = avController.getVideoOrientation(path)
        
        let title = avController.getMetaDataByTag(metadataAsset,key: "title")
        let author = avController.getMetaDataByTag(metadataAsset,key: "author")
        
        let duration = asset.duration.seconds * 1000
        let filesize = track.totalSampleDataLength
        
        let size = track.naturalSize.applying(track.preferredTransform)
        
        let width = abs(size.width)
        let height = abs(size.height)
        
        let dictionary = [
            "path":Utility.excludeFileProtocol(path),
            "title":title,
            "author":author,
            "width":width,
            "height":height,
            "duration":duration,
            "filesize":filesize,
            "orientation":orientation
            ] as [String : Any?]
        return dictionary
    }
    
    private func getMediaInfo(_ path: String,_ result: FlutterResult) {
        let json = getMediaInfoJson(path)
        let string = Utility.keyValueToJson(json)
        result(string)
    }
    
    
    @objc private func updateProgress(timer:Timer) {
        let asset = timer.userInfo as! AVAssetExportSession
        if(!stopCommand) {
            channel.invokeMethod("updateProgress", arguments: "\(String(describing: asset.progress * 100))")
        }
    }
    
    private func getExportPreset(_ quality: NSNumber)->String {
        switch(quality) {
        case 1:
            return AVAssetExportPresetLowQuality    
        case 2:
            return AVAssetExportPresetMediumQuality
        case 3:
            return AVAssetExportPresetHighestQuality
        case 4:
            return AVAssetExportPreset640x480
        case 5:
            return AVAssetExportPreset960x540
        case 6:
            return AVAssetExportPreset1280x720
        case 7:
            return AVAssetExportPreset1920x1080
        default:
            return AVAssetExportPresetMediumQuality
        }
    }
    
    private func getComposition(_ isIncludeAudio: Bool,_ timeRange: CMTimeRange, _ sourceVideoTrack: AVAssetTrack)->AVAsset {
        let composition = AVMutableComposition()
        if !isIncludeAudio {
            let compressionVideoTrack = composition.addMutableTrack(withMediaType: AVMediaType.video, preferredTrackID: kCMPersistentTrackID_Invalid)
            compressionVideoTrack!.preferredTransform = sourceVideoTrack.preferredTransform
            try? compressionVideoTrack!.insertTimeRange(timeRange, of: sourceVideoTrack, at: CMTime.zero)
        } else {
            return sourceVideoTrack.asset!
        }
        
        return composition    
    }
    
    private func compressVideo(_ path: String,_ quality: NSNumber,_ deleteOrigin: Bool,_ startTime: Double?,
                               _ duration: Double?,_ includeAudio: Bool?,_ frameRate: Int?,
                               _ result: @escaping FlutterResult) {
        let sourceVideoUrl = Utility.getPathUrl(path)
        let sourceVideoType = "mp4"
        
        let sourceVideoAsset = avController.getVideoAsset(sourceVideoUrl)
        let sourceVideoTrack = avController.getTrack(sourceVideoAsset)
        
        let compressionUrl =
            Utility.getPathUrl("\(Utility.basePath())/\(Utility.getFileName(path)).\(sourceVideoType)")
        
        let timescale = sourceVideoAsset.duration.timescale
        let minStartTime = Double(startTime ?? 0)
        
        let videoDuration = sourceVideoAsset.duration.seconds
        let minDuration = Double(duration ?? videoDuration)
        let maxDurationTime = minStartTime + minDuration < videoDuration ? minDuration : videoDuration
        
        let cmStartTime = CMTimeMakeWithSeconds(minStartTime, preferredTimescale: timescale)
        let cmDurationTime = CMTimeMakeWithSeconds(maxDurationTime, preferredTimescale: timescale)
        let timeRange: CMTimeRange = CMTimeRangeMake(start: cmStartTime, duration: cmDurationTime)
        
        let isIncludeAudio = includeAudio != nil ? includeAudio! : true
        
        // toastyai fix (2026-09-12): both of these were force-unwraps that took
        // the whole process down with EXC_BREAKPOINT. A source with no video
        // track, or AVFoundation declining to create an export session (which
        // it does under memory pressure — observed in the field at ~175MB
        // free), now surfaces as a catchable FlutterError instead.
        guard let sourceTrack = sourceVideoTrack else {
            result(FlutterError(code: "video_compress",
                                message: "Source has no video track",
                                details: nil))
            return
        }
        let session = getComposition(isIncludeAudio, timeRange, sourceTrack)
        
        guard let exporter = AVAssetExportSession(asset: session, presetName: getExportPreset(quality)) else {
            result(FlutterError(code: "video_compress",
                                message: "Could not create export session (device under memory pressure?)",
                                details: nil))
            return
        }
        
        exporter.outputURL = compressionUrl
        exporter.outputFileType = AVFileType.mp4
        exporter.shouldOptimizeForNetworkUse = true
        
        if frameRate != nil {
            let videoComposition = AVMutableVideoComposition(propertiesOf: sourceVideoAsset)
            videoComposition.frameDuration = CMTimeMake(value: 1, timescale: Int32(frameRate!))
            exporter.videoComposition = videoComposition
        }
        
        if !isIncludeAudio {
            exporter.timeRange = timeRange
        }
        
        Utility.deleteFile(compressionUrl.absoluteString)
        
        let timer = Timer.scheduledTimer(timeInterval: 0.1, target: self, selector: #selector(self.updateProgress),
                                         userInfo: exporter, repeats: true)
        
        exporter.exportAsynchronously(completionHandler: {
            timer.invalidate()
            if(self.stopCommand) {
                self.stopCommand = false
                var json = self.getMediaInfoJson(path)
                json["isCancel"] = true
                let jsonString = Utility.keyValueToJson(json)
                return result(jsonString)
            }
            // toastyai fix (2026-09-20): this handler used to probe the output
            // and return its media info REGARDLESS of how the export ended. A
            // failed export leaves nothing readable at that URL, so
            // getMediaInfoJson hit its `guard let track ... else { return [:] }`
            // and returned an EMPTY dictionary — which is still valid JSON, so
            // the Dart side saw a successful call and MediaInfo.fromJson died on
            // `file = File(path!)` with "Null check operator used on a null
            // value". That error names neither the failure nor its cause, so
            // every export failure in the field was effectively invisible: no
            // status, no reason, no crash report, just a mystery null-check on a
            // line that has nothing to do with exporting. Report the real thing.
            //
            // Ordering is deliberate. The cancel branch above owns .cancelled
            // and must keep its isCancel contract, so this sits after it; and it
            // returns BEFORE deleteOrigin so a failed export can never delete
            // the source file it just failed to convert.
            if exporter.status != .completed {
                let reason = exporter.error?.localizedDescription
                    ?? "no underlying NSError reported"
                result(FlutterError(
                    code: "video_compress",
                    message: "Export did not complete (status "
                        + "\(exporter.status.rawValue)): \(reason)",
                    details: nil))
                return
            }
            if deleteOrigin {
                let fileManager = FileManager.default
                do {
                    if fileManager.fileExists(atPath: path) {
                        try fileManager.removeItem(atPath: path)
                    }
                    self.exporter = nil
                    self.stopCommand = false
                }
                catch let error as NSError {
                    print(error)
                }
            }
            // toastyai fix (2026-09-20, second): this passed
            // `compressionUrl.absoluteString`, which PERCENT-ENCODES the path.
            // Utility.excludeFileProtocol only strips the "file://" prefix, it
            // never decodes — so a source whose name contains a space yielded a
            // path with a literal "%20" in it, naming a file that does not
            // exist. getTrack returned nil, getMediaInfoJson hit its
            // `else { return [:] }`, and the Dart side crashed on `File(path!)`.
            // Measured on macOS with the same code path: "NoSpaces_1.mp4" -> 1
            // video track either way; "Rec 2026 1.mp4" -> 0 tracks via
            // absoluteString, 1 via .path. Note the cancel branch above already
            // used the decoded `path`; only this one was wrong.
            var json = self.getMediaInfoJson(compressionUrl.path)
            // Defence in depth, independent of the bug above: an empty dict is
            // still valid JSON, so Dart saw a SUCCESSFUL call and then died on a
            // null path. Never hand back a success-shaped result for an output
            // we could not actually read. Checked before isCancel is inserted,
            // so this tests what getMediaInfoJson returned and nothing else.
            if json.isEmpty {
                result(FlutterError(
                    code: "video_compress",
                    message: "Export completed but its output could not be read: "
                        + compressionUrl.path,
                    details: nil))
                return
            }
            json["isCancel"] = false
            let jsonString = Utility.keyValueToJson(json)
            result(jsonString)
        })
    }
    
    /// toastyai addition (2026-09-26): the bitrate-targeted path — see
    /// BitrateTranscoder. Same output location and result shape as
    /// compressVideo (media info JSON of the output), so the Dart side reads
    /// both the same way; failures are FlutterErrors naming the real reason.
    private func compressVideoToBitrate(_ path: String,
                                        _ settings: BitrateTranscoder.Settings,
                                        _ result: @escaping FlutterResult) {
        let source = Utility.getPathUrl(path)
        let destination = Utility.getPathUrl(
            "\(Utility.basePath())/\(Utility.getFileName(path)).mp4")
        let transcoder = BitrateTranscoder()
        self.transcoder = transcoder
        stopCommand = false
        transcoder.transcode(
            source: source, destination: destination, settings: settings,
            progress: { p in
                DispatchQueue.main.async {
                    if !self.stopCommand {
                        self.channel.invokeMethod("updateProgress",
                                                  arguments: "\(p * 100)")
                    }
                }
            },
            completion: { outcome in
                DispatchQueue.main.async {
                    self.transcoder = nil
                    switch outcome {
                    case .failure(let failure):
                        self.stopCommand = false
                        result(FlutterError(code: "video_compress",
                                            message: failure.description,
                                            details: nil))
                    case .success:
                        // .path, never .absoluteString: see the percent-encoding
                        // note in compressVideo.
                        var json = self.getMediaInfoJson(destination.path)
                        if json.isEmpty {
                            result(FlutterError(
                                code: "video_compress",
                                message: "Transcode completed but its output could not be read: "
                                    + destination.path,
                                details: nil))
                            return
                        }
                        json["isCancel"] = false
                        result(Utility.keyValueToJson(json))
                    }
                }
            })
    }

    private func cancelCompression(_ result: FlutterResult) {
        exporter?.cancelExport()
        transcoder?.cancel()
        stopCommand = true
        result("")
    }
    
}
