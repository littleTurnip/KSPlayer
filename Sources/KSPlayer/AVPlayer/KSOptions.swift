//
//  KSOptions.swift
//  KSPlayer-tvOS
//
//  Created by kintan on 2018/3/9.
//

import AVFoundation
import SwiftUI
#if os(tvOS) || os(xrOS)
import DisplayCriteria
#endif
import AVKit
import OSLog

open class KSOptions {
    public internal(set) var formatName = ""
    public internal(set) var prepareTime = 0.0
    public internal(set) var dnsStartTime = 0.0
    public internal(set) var tcpStartTime = 0.0
    public internal(set) var tcpConnectedTime = 0.0
    public internal(set) var openTime = 0.0
    public internal(set) var findTime = 0.0
    public internal(set) var readyTime = 0.0
    public internal(set) var readAudioTime = 0.0
    public internal(set) var readVideoTime = 0.0
    public internal(set) var decodeAudioTime = 0.0
    public internal(set) var decodeVideoTime = 0.0
    public init() {
        formatContextOptions["user_agent"] = userAgent
        // 参数的配置可以参考protocols.texi 和 http.c
        // 这个一定要，不然有的流就会判断不准FieldOrder
        formatContextOptions["scan_all_pmts"] = 1
        // ts直播流需要加这个才能一直直播下去，不然播放一小段就会结束了。
        formatContextOptions["reconnect"] = 1
        formatContextOptions["reconnect_streamed"] = 1
        // 需要加这个超时，不然从wifi切换到4g就会一直卡住
        formatContextOptions["rw_timeout"] = 10_000_000
        // 这个是用来开启http的链接复用（keep-alive）。vlc默认是打开的，所以这边也默认打开。
        // 开启这个，百度网盘的视频链接无法播放
        // formatContextOptions["multiple_requests"] = 1
        // 下面是用来处理秒开的参数，有需要的自己打开。默认不开，不然在播放某些特殊的ts直播流会频繁卡顿。
//        formatContextOptions["auto_convert"] = 0
//        formatContextOptions["fps_probe_size"] = 3
//        formatContextOptions["max_analyze_duration"] = 300 * 1000
        // 默认情况下允许所有协议，只有嵌套协议才需要指定这个协议子集，例如m3u8里面有http。
//        formatContextOptions["protocol_whitelist"] = "file,http,https,tcp,tls,crypto,async,cache,data,httpproxy"
        // 开启这个，纯ipv6地址会无法播放。并且有些视频结束了，但还会一直尝试重连。所以这个值默认不设置
//        formatContextOptions["reconnect_at_eof"] = 1
        // 开启这个，会导致tcp Failed to resolve hostname 还会一直重试
//        formatContextOptions["reconnect_on_network_error"] = 1
        // There is total different meaning for 'listen_timeout' option in rtmp
        // set 'listen_timeout' = -1 for rtmp、rtsp
//        formatContextOptions["listen_timeout"] = 3
        decoderOptions["threads"] = "auto"
        decoderOptions["refcounted_frames"] = "1"
        decoderOptions["flags"] = "+copy_opaque"
    }

    open func playerLayerDeinit() {
        #if os(tvOS) || os(xrOS)
        runOnMainThread {
            UIApplication.shared.windows.first?.avDisplayManager.preferredDisplayCriteria = nil
        }
        #endif
    }

    // MARK: avplayer options

    public var avOptions = [String: Any]()

    // MARK: playback options

    public static var stackSize = 65536
    public var startPlayTime: TimeInterval = 0
    public var startPlayRate: Float = 1.0
    public var registerRemoteControll: Bool = true // 默认支持来自系统控制中心的控制
    public static var firstPlayerType: MediaPlayerProtocol.Type = KSAVPlayer.self
    public static var secondPlayerType: MediaPlayerProtocol.Type? = KSMEPlayer.self
    /// 是否开启秒开
    public static var isSecondOpen = false
    /// 开启精确seek
    public static var isAccurateSeek = false
    /// Applies to short videos only
    public static var isLoopPlay = false
    /// 是否自动播放，默认true
    public static var isAutoPlay = true
    /// seek完是否自动播放
    public static var isSeekedAutoPlay = true
    /// 是否开启秒开
    public var isSecondOpen = KSOptions.isSecondOpen
    /// 开启精确seek
    public var isAccurateSeek = KSOptions.isAccurateSeek
    /// Applies to short videos only
    public var isLoopPlay = KSOptions.isLoopPlay
    /// seek完是否自动播放
    public var isSeekedAutoPlay = KSOptions.isSeekedAutoPlay
    /*
     AVSEEK_FLAG_BACKWARD: 1
     AVSEEK_FLAG_BYTE: 2
     AVSEEK_FLAG_ANY: 4
     AVSEEK_FLAG_FRAME: 8
     */
    public var seekFlags = Int32(1)

    open func adaptable(state: VideoAdaptationState?) -> (Int64, Int64)? {
        guard let state, let last = state.bitRateStates.last, CACurrentMediaTime() - last.time > maxBufferDuration / 2, let index = state.bitRates.firstIndex(of: last.bitRate) else {
            return nil
        }
        let isUp = state.loadedCount > Int(Double(state.fps) * maxBufferDuration / 2)
        if isUp != state.isPlayable {
            return nil
        }
        if isUp {
            if index < state.bitRates.endIndex - 1 {
                return (last.bitRate, state.bitRates[index + 1])
            }
        } else {
            if index > state.bitRates.startIndex {
                return (last.bitRate, state.bitRates[index - 1])
            }
        }
        return nil
    }

    open func liveAdaptivePlaybackRate(loadingState _: LoadingState) -> Float? {
        nil
        //        if loadingState.isFirst {
        //            return nil
        //        }
        //        if loadingState.loadedTime > preferredForwardBufferDuration + 5 {
        //            return 1.2
        //        } else if loadingState.loadedTime < preferredForwardBufferDuration / 2 {
        //            return 0.8
        //        } else {
        //            return 1
        //        }
    }

    // MARK: record options

    public var outputURL: URL?

    // MARK: Demuxer options

    public var formatContextOptions = [String: Any]()
    public var nobuffer = false
    open func process(url _: URL) -> AbstractAVIOContext? {
        nil
    }

    // MARK: decoder options

    public var decoderOptions = [String: Any]()
    public var codecLowDelay = false
    public var lowres = UInt8(0)
    /**
     在创建解码器之前可以对KSOptions和assetTrack做一些处理。例如判断fieldOrder为tt或bb的话，那就自动加videofilters
     */
    open func process(assetTrack: some MediaPlayerTrack) {
        if assetTrack.mediaType == .video {
            if [FFmpegFieldOrder.bb, .bt, .tt, .tb].contains(assetTrack.fieldOrder) {
                // todo 先不要用yadif_videotoolbox，不然会crash。这个后续在看下要怎么解决
                hardwareDecode = false
                asynchronousDecompression = false
                let yadif = hardwareDecode ? "yadif_videotoolbox" : "yadif"
                var yadifMode = KSOptions.yadifMode
                //                if let assetTrack = assetTrack as? FFmpegAssetTrack {
                //                    if assetTrack.realFrameRate.num == 2 * assetTrack.avgFrameRate.num, assetTrack.realFrameRate.den == assetTrack.avgFrameRate.den {
                //                        if yadifMode == 1 {
                //                            yadifMode = 0
                //                        } else if yadifMode == 3 {
                //                            yadifMode = 2
                //                        }
                //                    }
                //                }
                if KSOptions.deInterlaceAddIdet {
                    videoFilters.append("idet")
                }
                videoFilters.append("\(yadif)=mode=\(yadifMode):parity=-1:deint=1")
                if yadifMode == 1 || yadifMode == 3 {
                    assetTrack.nominalFrameRate = assetTrack.nominalFrameRate * 2
                }
            }
        }
    }

    // MARK: network options

    public static var useSystemHTTPProxy = true
    // 没事不要设置probesize，不然会导致fps判断不准确。除非是很为了秒开或是其他原因才进行设置。
    public var probesize: Int64?
    public var maxAnalyzeDuration: Int64?
    public var referer: String? {
        didSet {
            if let referer {
                formatContextOptions["referer"] = "Referer: \(referer)"
            } else {
                formatContextOptions["referer"] = nil
            }
        }
    }

    public var userAgent: String? = "KSPlayer" {
        didSet {
            formatContextOptions["user_agent"] = userAgent
        }
    }

    /**
     you can add http-header or other options which mentions in https://developer.apple.com/reference/avfoundation/avurlasset/initialization_options

     to add http-header init options like this
     ```
     options.appendHeader(["Referer":"https:www.xxx.com"])
     ```
     */
    public func appendHeader(_ header: [String: String]) {
        var oldValue = avOptions["AVURLAssetHTTPHeaderFieldsKey"] as? [String: String] ?? [
            String: String
        ]()
        oldValue.merge(header) { _, new in new }
        avOptions["AVURLAssetHTTPHeaderFieldsKey"] = oldValue
        var str = formatContextOptions["headers"] as? String ?? ""
        for (key, value) in header {
            str.append("\(key):\(value)\r\n")
        }
        formatContextOptions["headers"] = str
    }

    public func setCookie(_ cookies: [HTTPCookie]) {
        avOptions[AVURLAssetHTTPCookiesKey] = cookies
        let cookieStr = cookies.map { cookie in "\(cookie.name)=\(cookie.value)" }.joined(separator: "; ")
        appendHeader(["Cookie": cookieStr])
    }

    // MARK: cache options

    /// 最低缓存视频时间
    public static var preferredForwardBufferDuration = 3.0
    /// 最大缓存视频时间
    public static var maxBufferDuration = 30.0
    public var seekUsePacketCache = false
    /// 最低缓存视频时间
    @Published
    public var preferredForwardBufferDuration = KSOptions.preferredForwardBufferDuration
    /// 最大缓存视频时间
    public var maxBufferDuration = KSOptions.maxBufferDuration
    // 缓冲算法函数
    open func playable(capacitys: [CapacityProtocol], isFirst: Bool, isSeek: Bool) -> LoadingState {
        let packetCount = capacitys.map(\.packetCount).min() ?? 0
        let frameCount = capacitys.map(\.frameCount).min() ?? 0
        let isEndOfFile = capacitys.allSatisfy(\.isEndOfFile)
        let loadedTime = capacitys.map(\.loadedTime).min() ?? 0
        let progress = preferredForwardBufferDuration == 0 ? 100 : loadedTime * 100.0 / preferredForwardBufferDuration
        // 简化逻辑，不要frameCount为0就认为不能播放
        let isPlayable = capacitys.allSatisfy { capacity in
            if capacity.isEndOfFile {
                return true
            }
            if (syncDecodeVideo && capacity.mediaType == .video) || (syncDecodeAudio && capacity.mediaType == .audio) {
                if capacity.frameCount >= 2 {
                    return true
                }
            }
            if isFirst || isSeek {
                // 让纯音频能更快的打开
                if capacity.mediaType == .audio || isSecondOpen {
                    return capacity.loadedTime >= self.preferredForwardBufferDuration / 2
                }
            }
            return capacity.loadedTime >= self.preferredForwardBufferDuration
        }
        return LoadingState(loadedTime: loadedTime, progress: progress, packetCount: packetCount,
                            frameCount: frameCount, isEndOfFile: isEndOfFile, isPlayable: isPlayable,
                            isFirst: isFirst, isSeek: isSeek)
    }

    // MARK: audio options

    public static var audioPlayerType: AudioOutput.Type = AudioEnginePlayer.self
    public var audioFilters = [String]()
    public var syncDecodeAudio = false
    open func wantedAudio(tracks _: [MediaPlayerTrack]) -> MediaPlayerTrack? {
        nil
    }

    open func audioFrameMaxCount(fps: Float, channelCount: Int) -> UInt8 {
        let count = (Int(fps) * channelCount) >> 2
        if count >= UInt8.max {
            return UInt8.max
        } else {
            return UInt8(count)
        }
    }

    // MARK: subtile options

    static let fontsDir = URL(fileURLWithPath: NSTemporaryDirectory() + "fontsDir")
    public static var isASSUseImageRender = false
    // 丢弃掉字幕自带的样式，用自定义的样式
    public static var stripSubtitleStyle = true
    public static var textColor: Color = .white
    public static var textBackgroundColor: Color = .clear
    public static var textFont: UIFont {
        textBold ? .boldSystemFont(ofSize: textFontSize) : .systemFont(ofSize: textFontSize)
    }

    public static var textFontSize = SubtitleModel.Size.standard.rawValue
    public static var textBold = false
    public static var textItalic = false
    public static var textPosition = TextPosition()
    public static var audioRecognizes = [any AudioRecognize]()
    @available(iOS 17.0, macOS 14.0, tvOS 17.0, *)
    public static var subtitleDynamicRange = Image.DynamicRange.high
    public var autoSelectEmbedSubtitle = true
    public var isSeekImageSubtitle = false
    public var subtitleTimeInterval = 0.1
    open func wantedSubtitle(tracks: [MediaPlayerTrack]) -> MediaPlayerTrack? {
        if autoSelectEmbedSubtitle {
            return tracks.first {
                $0.language == Locale.currentLanguage
            } ?? tracks.first
        } else {
            return nil
        }
    }

    // MARK: video options

    /// 开启VR模式的陀飞轮
    public static var enableSensor = true
    public static var isClearVideoWhereReplace = true
    public static var videoPlayerType: (VideoOutput & UIView).Type = MetalPlayView.self
    public static var yadifMode = 1
    public static var deInterlaceAddIdet = false
    public static var hardwareDecode = true
    /// 默认不用自研的硬解，因为有些视频的AVPacket的pts顺序是不对的，只有解码后的AVFrame里面的pts是对的。
    /// 但是ts格式的视频seek完之后，FFmpeg的硬解会失败，需要切换到硬解才可以。自研的硬解不会失败，但是会有一小段的花屏。
    public static var asynchronousDecompression = false
    public static var isPipPopViewController = false
    public static var canStartPictureInPictureAutomaticallyFromInline = true
    public static var preferredFrame = false
    #if os(tvOS)
    // tvos 只能在tmp上创建文件
    public static var recordDir: URL? = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("record")
    #else
    public static var recordDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("record")
    #endif
    public static var doviMatrix = simd_float3x3(1)
    public static let displayEnumPlane = PlaneDisplayModel()
    public static let displayEnumDovi = DoviDisplayModel()
    @MainActor
    public static let displayEnumVR = VRDisplayModel()
    @MainActor
    public static let displayEnumVRBox = VRBoxDisplayModel()
    @available(tvOS 14.0, *)
    public static var pictureInPictureType: (KSPictureInPictureProtocol & AVPictureInPictureController).Type = KSPictureInPictureController.self
    public static var videoSoftDecodeThreadCount = 4
    public var isHDR = false
    public var display: DisplayEnum = displayEnumPlane
    public var videoDelay = 0.0 // s
    public var autoRotate = true
    public var destinationDynamicRange: DynamicRange?
    public var videoAdaptable = true
    public var videoFilters = [String]()
    public var syncDecodeVideo = false
    public var hardwareDecode = KSOptions.hardwareDecode
    public var asynchronousDecompression = KSOptions.asynchronousDecompression
    public var videoDisable = false
    public var canStartPictureInPictureAutomaticallyFromInline = KSOptions.canStartPictureInPictureAutomaticallyFromInline
    public var automaticWindowResize = true
    public var videoSoftDecodeThreadCount = KSOptions.videoSoftDecodeThreadCount
    open func preferredFrame(fps: Float) -> Bool {
        KSOptions.preferredFrame || fps > 61
    }

    open func wantedVideo(tracks _: [MediaPlayerTrack]) -> MediaPlayerTrack? {
        nil
    }

    open func videoFrameMaxCount(fps: Float, naturalSize _: CGSize, isLive: Bool) -> UInt8 {
        if isLive {
            return fps > 49 ? 8 : 4
        } else {
            return fps > 49 ? 16 : 8
        }
    }

    /// customize dar
    /// - Parameters:
    ///   - sar: SAR(Sample Aspect Ratio)
    ///   - par: PAR(Pixel Aspect Ratio)
    /// - Returns: DAR(Display Aspect Ratio)
    open func customizeDar(sar _: CGSize, par _: CGSize) -> CGSize? {
        nil
    }

    // 虽然只有iOS才支持PIP。但是因为AVSampleBufferDisplayLayer能够支持HDR10+。所以默认还是推荐用AVSampleBufferDisplayLayer
    open func isUseDisplayLayer() -> Bool {
        display === KSOptions.displayEnumPlane
    }

    open func availableDynamicRange() -> DynamicRange? {
        guard let destinationDynamicRange else {
            return nil
        }
        let availableHDRModes = DynamicRange.availableHDRModes
        if availableHDRModes.contains(destinationDynamicRange) {
            return destinationDynamicRange
        } else {
            return availableHDRModes.first
        }
    }

    @MainActor
    open func updateVideo(refreshRate: Float, isDovi: Bool, formatDescription: CMFormatDescription) {
        let dynamicRange = isDovi ? .dolbyVision : formatDescription.dynamicRange
        isHDR = dynamicRange.isHDR
        #if os(tvOS) || os(xrOS)
        /**
         快速更改preferredDisplayCriteria，会导致isDisplayModeSwitchInProgress变成true。
         例如退出一个视频，然后在3s内重新进入的话。所以不判断isDisplayModeSwitchInProgress了
         */
        guard let displayManager = UIApplication.shared.windows.first?.avDisplayManager,
              displayManager.isDisplayCriteriaMatchingEnabled
        else {
            return
        }
        displayManager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: refreshRate, videoDynamicRange: dynamicRange.rawValue)
        #endif
    }

    private var videoClockDelayCount = 0
    open func videoClockSync(main: KSClock, nextVideoTime: TimeInterval, fps: Double, frameCount: Int) -> (Double, ClockProcessType) {
        let desire = main.getTime() - videoDelay
        let diff = nextVideoTime - desire
//        KSLog("[video] video diff \(diff) nextVideoTime \(nextVideoTime) main \(main.time.seconds)")
        if diff >= 1 / fps / 2 {
            return (diff, .remain)
        } else {
            if diff < -4 / fps {
                videoClockDelayCount += 1
                /// 之前有一次因为mainClock的时间戳不准，导致diff很大，所以这边要判断下delay的次数在做seek、dropGOPPacket、flush处理，避免误伤。
                let log = "[video] video delay=\(diff), clock=\(desire), frameCount=\(frameCount) delay count=\(videoClockDelayCount)"

                if diff < -8, videoClockDelayCount % 80 == 0 {
                    KSLog("\(log) seek video track")
                    return (diff, .seek)
                }
                if diff < -1, videoClockDelayCount % 10 == 0 {
                    if frameCount == 1 {
                        KSLog("\(log) drop gop Packet")
                        return (diff, .dropGOPPacket)
                    } else {
                        KSLog("\(log) flush video track")
                        return (diff, .flush)
                    }
                }
                let count: Int
                if videoClockDelayCount == 1 {
                    // 第一次delay的话，就先只丢一帧。防止seek之后第一次播放丢太多帧
                    count = 1
                } else {
                    count = Int(-diff * fps / 4.0)
                }
                KSLog("\(log) drop \(count) frame")
                return (diff, .dropFrame(count: count))
            } else {
                videoClockDelayCount = 0
                return (diff, .next)
            }
        }
    }

    // MARK: log options

    public static var logLevel = LogLevel.warning
    public static var logger: LogHandler = OSLog(lable: "KSPlayer")
    open func urlIO(log: String) {
        if log.starts(with: "Original list of addresses"), dnsStartTime == 0 {
            dnsStartTime = CACurrentMediaTime()
        } else if log.starts(with: "Starting connection attempt to"), tcpStartTime == 0 {
            tcpStartTime = CACurrentMediaTime()
        } else if log.starts(with: "Successfully connected to"), tcpConnectedTime == 0 {
            tcpConnectedTime = CACurrentMediaTime()
        }
    }

    open func filter(log _: String) {}

    open func sei(string: String) {
        KSLog("sei \(string)")
    }
}

public extension KSOptions {
    internal static func deviceCpuCount() -> Int {
        var ncpu = UInt(0)
        var len: size_t = MemoryLayout.size(ofValue: ncpu)
        sysctlbyname("hw.ncpu", &ncpu, &len, nil, 0)
        return Int(ncpu)
    }

    static func setAudioSession() {
        #if os(macOS)
//        try? AVAudioSession.sharedInstance().setRouteSharingPolicy(.longFormAudio)
        #else
        var category = AVAudioSession.sharedInstance().category
        if category != .playAndRecord {
            category = .playback
        }
        #if os(tvOS)
        try? AVAudioSession.sharedInstance().setCategory(category, mode: .moviePlayback, policy: .longFormAudio)
        #else
        try? AVAudioSession.sharedInstance().setCategory(category, mode: .moviePlayback, policy: .longFormVideo)
        #endif
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    #if !os(macOS)
    static func isSpatialAudioEnabled(channelCount _: AVAudioChannelCount) -> Bool {
        if #available(tvOS 15.0, iOS 15.0, *) {
            let isSpatialAudioEnabled = AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.isSpatialAudioEnabled }
            try? AVAudioSession.sharedInstance().setSupportsMultichannelContent(isSpatialAudioEnabled)
            return isSpatialAudioEnabled
        } else {
            return false
        }
    }

    static func outputNumberOfChannels(channelCount: AVAudioChannelCount) -> AVAudioChannelCount {
        let maximumOutputNumberOfChannels = AVAudioChannelCount(AVAudioSession.sharedInstance().maximumOutputNumberOfChannels)
        let preferredOutputNumberOfChannels = AVAudioChannelCount(AVAudioSession.sharedInstance().preferredOutputNumberOfChannels)
        let isSpatialAudioEnabled = isSpatialAudioEnabled(channelCount: channelCount)
        let isUseAudioRenderer = KSOptions.audioPlayerType == AudioRendererPlayer.self
        KSLog("[audio] maximumOutputNumberOfChannels: \(maximumOutputNumberOfChannels), preferredOutputNumberOfChannels: \(preferredOutputNumberOfChannels), isSpatialAudioEnabled: \(isSpatialAudioEnabled), isUseAudioRenderer: \(isUseAudioRenderer) ")
        let maxRouteChannelsCount = AVAudioSession.sharedInstance().currentRoute.outputs.compactMap {
            $0.channels?.count
        }.max() ?? 2
        KSLog("[audio] currentRoute max channels: \(maxRouteChannelsCount)")
        var channelCount = channelCount
        if channelCount > 2 {
            let minChannels = min(maximumOutputNumberOfChannels, channelCount)
            #if os(tvOS) || targetEnvironment(simulator)
            if !(isUseAudioRenderer && isSpatialAudioEnabled) {
                // 不要用maxRouteChannelsCount来判断，有可能会不准。导致多音道设备也返回2（一开始播放一个2声道，就容易出现），也不能用outputNumberOfChannels来判断，有可能会返回2
//                channelCount = AVAudioChannelCount(min(AVAudioSession.sharedInstance().outputNumberOfChannels, maxRouteChannelsCount))
                channelCount = minChannels
            }
            #else
            // iOS 外放是会自动有空间音频功能，但是蓝牙耳机有可能没有空间音频功能或者把空间音频给关了，。所以还是需要处理。
            if !isSpatialAudioEnabled {
                channelCount = minChannels
            }
            #endif
        } else {
            channelCount = 2
        }
        // 不在这里设置setPreferredOutputNumberOfChannels,因为这个方法会在获取音轨信息的时候，进行调用。
        KSLog("[audio] outputNumberOfChannels: \(AVAudioSession.sharedInstance().outputNumberOfChannels) output channelCount: \(channelCount)")
        return channelCount
    }
    #endif
}
