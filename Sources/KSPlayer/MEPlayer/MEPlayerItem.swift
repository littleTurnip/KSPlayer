//
//  MEPlayerItem.swift
//  KSPlayer
//
//  Created by kintan on 2018/3/9.
//

import AVFoundation
import CoreText
import FFmpegKit
import Libavcodec
import Libavfilter
import Libavformat
import Libavutil

public final class MEPlayerItem: Sendable {
    private let url: URL
    let options: KSOptions
    private let operationQueue = OperationQueue()
    private let condition = NSCondition()
    private var formatCtx: UnsafeMutablePointer<AVFormatContext>?
    private var outputFormatCtx: UnsafeMutablePointer<AVFormatContext>?
    private var outputPacket: UnsafeMutablePointer<AVPacket>?
    private var streamMapping = [Int: Int]()
    private var openOperation: BlockOperation?
    private var readOperation: BlockOperation?
    private var closeOperation: BlockOperation?
    private var seekingCompletionHandler: ((Bool) -> Void)?
    // 没有音频数据可以渲染
    private var isAudioStalled = true
    private var audioClock = KSClock()
    private var videoClock = KSClock()
    private var isFirst = true
    private var isSeek = false
    private var allPlayerItemTracks = [PlayerItemTrackProtocol]()
    private var maxFrameDuration = 10.0
    private var videoAudioTracks = [CapacityProtocol]()
    private var videoTrack: SyncPlayerItemTrack<VideoVTBFrame>?
    private var audioTrack: SyncPlayerItemTrack<AudioFrame>?
    private(set) var assetTracks = [FFmpegAssetTrack]()
    private var videoAdaptation: VideoAdaptationState?
    private var videoDisplayCount = UInt8(0)
    private var seekByBytes = false
    private var lastVideoClock = KSClock()
    private var ioContext: AbstractAVIOContext?
    private var pbArray = [PBClass]()
    private var interrupt = false
    private var defaultIOOpen: ((UnsafeMutablePointer<AVFormatContext>?, UnsafeMutablePointer<UnsafeMutablePointer<AVIOContext>?>?, UnsafePointer<CChar>?, Int32, UnsafeMutablePointer<OpaquePointer?>?) -> Int32)? = nil
    private var defaultIOClose: ((UnsafeMutablePointer<AVFormatContext>?, UnsafeMutablePointer<AVIOContext>?) -> Int32)? = nil

    public private(set) var chapters: [Chapter] = []
    public var playbackRate: Float {
        get {
            Float(videoClock.rate)
        }
        set {
            audioClock.rate = Double(newValue)
            videoClock.rate = Double(newValue)
        }
    }

    public var currentPlaybackTime: TimeInterval {
        state == .seeking ? seekTime : (mainClock().time - startTime).seconds
    }

    private var seekTime = TimeInterval(0)
    private var startTime = CMTime.zero
    // duration 不用在减去startTime了
    private var initDuration: TimeInterval = 0 {
        didSet {
            duration = initDuration
        }
    }

    private var initFileSize: Int64 = 0 {
        didSet {
            fileSize = initFileSize
        }
    }

    public private(set) var duration: TimeInterval = 0
    public private(set) var fileSize: Int64 = 0

    public private(set) var naturalSize = CGSize.one
    private var error: NSError? {
        didSet {
            if error != nil {
                state = .failed
            }
        }
    }

    private var state = MESourceState.idle {
        didSet {
            switch state {
            case .opened:
                delegate?.sourceDidOpened()
            case .reading:
                timer.fireDate = .distantPast
            case .closed:
                timer.invalidate()
            case .failed:
                delegate?.sourceDidFailed(error: error)
                timer.fireDate = .distantFuture
            case .idle, .opening, .seeking, .paused, .finished:
                break
            }
        }
    }

    private lazy var timer: Timer = .scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
        self?.codecDidChangeCapacity()
    }

    lazy var dynamicInfo = DynamicInfo { [weak self] in
        // metadata可能会实时变化。所以把它放在DynamicInfo里面
        toDictionary(self?.formatCtx?.pointee.metadata)
    } bytesRead: { [weak self] in
        guard let self else { return 0 }
        if self.state != .opening, let preload = self.ioContext as? PreLoadProtocol, preload.loadedSize > 0 {
            return preload.urlPos
        } else {
            return self.pbArray.map(\.bytesRead).reduce(0, +) ?? 0
        }
    } audioBitrate: { [weak self] in
        Int(8 * (self?.audioTrack?.bitrate ?? 0))
    } videoBitrate: { [weak self] in
        Int(8 * (self?.videoTrack?.bitrate ?? 0))
    }

    private static var onceInitial: Void = {
//        if let urls = try? FileManager.default.contentsOfDirectory(at: KSOptions.fontsDir, includingPropertiesForKeys: nil) {
//            CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
//        }
        var result = avformat_network_init()
        av_log_set_callback { ptr, level, format, args in
            guard let format else {
                return
            }
            var log = String(cString: format)
            let arguments: CVaListPointer? = args
            if let arguments {
                log = NSString(format: log, arguments: arguments) as String
            }
            if let ptr {
                let avclass = ptr.assumingMemoryBound(to: UnsafePointer<AVClass>.self).pointee
                if avclass == avfilter_get_class() {
                    let context = ptr.assumingMemoryBound(to: AVFilterContext.self).pointee
                    if let opaque = context.graph?.pointee.opaque {
                        let options = Unmanaged<KSOptions>.fromOpaque(opaque).takeUnretainedValue()
                        options.filter(log: log)
                    }
                } else if avclass != nil, let namePtr = avclass.pointee.class_name, String(cString: namePtr) == "URLContext" {
                    let context = ptr.assumingMemoryBound(to: URLContext.self).pointee

                    /// 因为这里需要获取playerItem。所以如果有其他的播放器内核的话，那需要重新设置av_log_set_callback，不然在这里会crash。
                    /// 其他播放内核不设置interrupt_callback的话，那也不会有问题
                    if let opaque = context.interrupt_callback.opaque, context.interrupt_callback.callback != nil {
                        let playerItem = Unmanaged<MEPlayerItem>.fromOpaque(opaque).takeUnretainedValue()
                        if playerItem.state != .closed, playerItem.options != nil {
                            // 不能在这边判断playerItem.formatCtx。不然会报错Simultaneous accesses
                            playerItem.options.urlIO(log: String(log))
                            if log.starts(with: "Will reconnect at") {
                                let seconds = playerItem.mainClock().time.seconds
                                playerItem.videoTrack?.seekTime = seconds
                                playerItem.audioTrack?.seekTime = seconds
                            }
                        }
                    }
                }
            }
            // 找不到解码器
            if log.hasPrefix("parser not found for codec") {
                KSLog(level: .error, log)
            }
            KSLog(level: LogLevel(rawValue: level) ?? .warning, log)
        }
    }()

    weak var delegate: MEPlayerDelegate?
    public init(url: URL, options: KSOptions) {
        self.url = url
        self.options = options
        operationQueue.name = "KSPlayer_" + String(describing: self).components(separatedBy: ".").last!
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.qualityOfService = .userInteractive
        _ = MEPlayerItem.onceInitial
        // 一开始要清空字体，不然字体太多用ass加载的话，会内存暴涨
        try? FileManager.default.removeItem(at: KSOptions.fontsDir)
        timer.tolerance = 0.02
        timer.fireDate = .distantFuture
    }

    @MainActor
    func select(track: some MediaPlayerTrack) -> Bool {
        if track.isEnabled {
            return false
        }
        assetTracks.filter { $0.mediaType == track.mediaType }.forEach {
            $0.isEnabled = track === $0
        }
        guard let assetTrack = track as? FFmpegAssetTrack else {
            return false
        }
        if assetTrack.mediaType == .video {
            findBestAudio(videoTrack: assetTrack)
        } else if assetTrack.mediaType == .subtitle {
            if assetTrack.isImageSubtitle {
                if options.isSeekImageSubtitle {
                    assetTracks.filter { $0.mediaType == track.mediaType }.forEach {
                        $0.subtitle?.outputRenderQueue.flush()
                    }
                } else {
                    return false
                }
            } else {
                return false
            }
        }

        // 切换轨道的话，要把缓存给清空了，这样seek才不会走缓存
        for track in allPlayerItemTracks {
            track.seek(time: currentPlaybackTime)
        }
        seek(time: currentPlaybackTime) { _ in
        }
        return true
    }

    deinit {}
}

// MARK: private functions

extension MEPlayerItem {
    private func openThread() {
        formatCtx?.pointee.interrupt_callback.opaque = nil
        formatCtx?.pointee.interrupt_callback.callback = nil
        pbArray.removeAll()
        avformat_close_input(&self.formatCtx)
        formatCtx = avformat_alloc_context()
        guard let formatCtx else {
            error = NSError(errorCode: .formatCreate)
            return
        }
        var interruptCB = AVIOInterruptCB()
        interruptCB.opaque = Unmanaged.passUnretained(self).toOpaque()
        interruptCB.callback = { ctx -> Int32 in
            guard let ctx else {
                return 0
            }
            let formatContext = Unmanaged<MEPlayerItem>.fromOpaque(ctx).takeUnretainedValue()
            if formatContext.interrupt {
                return 1
            }
            switch formatContext.state {
            case .finished, .closed, .failed:
                return 1
            default:
                return 0
            }
        }
        formatCtx.pointee.interrupt_callback = interruptCB
        formatCtx.pointee.opaque = Unmanaged.passUnretained(self).toOpaque()
        setHttpProxy()
        ioContext = options.process(url: url, interrupt: interruptCB)
        if let ioContext {
            // 如果要自定义协议的话，那就用avio_alloc_context，对formatCtx.pointee.pb赋值
            formatCtx.pointee.pb = ioContext.getContext()
            pbArray.append(PBClass(pb: formatCtx.pointee.pb))
            if ioContext is PreLoadProtocol {
                options.seekUsePacketCache = false
            }
        }
        defaultIOOpen = formatCtx.pointee.io_open
        // 处理m3u8这种有子url的情况。
        formatCtx.pointee.io_open = { s, pb, url, flags, options -> Int32 in
            guard let s, let url else {
                return -1
            }
            let playerItem = Unmanaged<MEPlayerItem>.fromOpaque(s.pointee.opaque).takeUnretainedValue()
            let result = playerItem.defaultIOOpen?(s, pb, url, flags, options) ?? -1
            if result >= 0 {
                playerItem.pbArray.append(PBClass(pb: pb?.pointee))
            }
//            if let ioContext = playerItem.ioContext, let url = URL(string: String(cString: url)), var subPb = ioContext.addSub(url: url, flags: flags, options: options, s.pointee.interrupt_callback) {
//                pb?.pointee = subPb
//                return 0
//            } else {
//                return -1
//            }
            return result
        }
//         avformat_close_input这个函数会调用io_close2。但是自定义协议是不会调用io_close2这个函数
        defaultIOClose = formatCtx.pointee.io_close2
        formatCtx.pointee.io_close2 = { s, pb -> Int32 in
            guard let s else {
                return -1
            }
            let playerItem = Unmanaged<MEPlayerItem>.fromOpaque(s.pointee.opaque).takeUnretainedValue()
            if let index = playerItem.pbArray.firstIndex(where: { $0.pb == pb }) {
                let pbClass = playerItem.pbArray.remove(at: index)
                playerItem.pbArray.first?.add(num: pbClass.bytesRead)
            }
            let result = playerItem.defaultIOClose?(s, pb) ?? -1
            return result
        }
        let urlString: String
        if url.isFileURL {
            urlString = url.path
        } else {
            urlString = url.absoluteString
        }
        var avOptions = options.formatContextOptions.avOptions
        var result = avformat_open_input(&self.formatCtx, urlString, nil, &avOptions)
        av_dict_free(&avOptions)
        if result == swift_AVERROR_EOF {
            state = .finished
            delegate?.sourceDidFinished()
            return
        }
        guard result == 0 else {
            error = .init(errorCode: .formatOpenInput, avErrorCode: result)
            // opaque设置为空的话，可能会crash。但是我本地无法复现，暂时先注释掉吧。
//            formatCtx.pointee.interrupt_callback.opaque = nil
//            formatCtx.pointee.interrupt_callback.callback = nil
            avformat_close_input(&self.formatCtx)
            return
        }
        options.openTime = CACurrentMediaTime()
        formatCtx.pointee.flags |= AVFMT_FLAG_GENPTS
        if options.nobuffer {
            formatCtx.pointee.flags |= AVFMT_FLAG_NOBUFFER
        }
        if let probesize = options.probesize {
            formatCtx.pointee.probesize = probesize
        }
        if let maxAnalyzeDuration = options.maxAnalyzeDuration {
            formatCtx.pointee.max_analyze_duration = maxAnalyzeDuration
        }
        result = avformat_find_stream_info(formatCtx, nil)
        guard result == 0 else {
            error = .init(errorCode: .formatFindStreamInfo, avErrorCode: result)
            formatCtx.pointee.interrupt_callback.opaque = nil
            formatCtx.pointee.interrupt_callback.callback = nil
            avformat_close_input(&self.formatCtx)
            return
        }
        // FIXME: hack, ffplay maybe should not use avio_feof() to test for the end
        formatCtx.pointee.pb?.pointee.eof_reached = 0
        let flags = formatCtx.pointee.iformat.pointee.flags
        maxFrameDuration = flags & AVFMT_TS_DISCONT == AVFMT_TS_DISCONT ? 10.0 : 3600.0
        options.findTime = CACurrentMediaTime()
        options.formatName = String(cString: formatCtx.pointee.iformat.pointee.name)
        seekByBytes = (flags & AVFMT_NO_BYTE_SEEK == 0) && (flags & (AVFMT_TS_DISCONT | AVFMT_NOTIMESTAMPS) != 0) && options.formatName != "ogg"
        if formatCtx.pointee.start_time != Int64.min {
            startTime = CMTime(value: formatCtx.pointee.start_time, timescale: AV_TIME_BASE)
            videoClock.time = startTime
            audioClock.time = startTime
        }
        initDuration = TimeInterval(max(formatCtx.pointee.duration, 0) / Int64(AV_TIME_BASE))
        dynamicInfo.byteRate = formatCtx.pointee.bit_rate / 8
        // 尽量少调用avio_size，这个会调用fileSize，可能会触发网络请求
        initFileSize = avio_size(formatCtx.pointee.pb)
        createCodec(formatCtx: formatCtx)
        if formatCtx.pointee.nb_chapters > 0 {
            chapters.removeAll()
            for i in 0 ..< formatCtx.pointee.nb_chapters {
                if let chapter = formatCtx.pointee.chapters[Int(i)]?.pointee {
                    let timeBase = Timebase(chapter.time_base)
                    let start = timeBase.cmtime(for: chapter.start).seconds
                    let end = timeBase.cmtime(for: chapter.end).seconds
                    let metadata = toDictionary(chapter.metadata)
                    let title = metadata["title"] ?? ""
                    chapters.append(Chapter(start: start, end: end, title: title))
                }
            }
        }

        if videoTrack == nil, audioTrack == nil {
            state = .failed
        } else {
            state = .opened
            read()
        }
    }

    @MainActor
    public func startRecord(url: URL) {
        stopRecord()
        let filename = url.isFileURL ? url.path : url.absoluteString
        var ret = avformat_alloc_output_context2(&outputFormatCtx, nil, nil, filename)
        guard let outputFormatCtx, let formatCtx else {
            KSLog(NSError(errorCode: .formatOutputCreate, avErrorCode: ret))
            return
        }
        var index = 0
        var audioIndex: Int?
        var videoIndex: Int?
        let formatName = outputFormatCtx.pointee.oformat.pointee.name.flatMap { String(cString: $0) }
        for i in 0 ..< Int(formatCtx.pointee.nb_streams) {
            if let inputStream = formatCtx.pointee.streams[i] {
                let codecType = inputStream.pointee.codecpar.pointee.codec_type
                if [AVMEDIA_TYPE_AUDIO, AVMEDIA_TYPE_VIDEO, AVMEDIA_TYPE_SUBTITLE].contains(codecType) {
                    if codecType == AVMEDIA_TYPE_AUDIO {
                        if let audioIndex {
                            streamMapping[i] = audioIndex
                            continue
                        } else {
                            audioIndex = index
                        }
                    } else if codecType == AVMEDIA_TYPE_VIDEO {
                        if let videoIndex {
                            streamMapping[i] = videoIndex
                            continue
                        } else {
                            videoIndex = index
                        }
                    }
                    if let outStream = avformat_new_stream(outputFormatCtx, nil) {
                        streamMapping[i] = index
                        index += 1
                        avcodec_parameters_copy(outStream.pointee.codecpar, inputStream.pointee.codecpar)
                        if codecType == AVMEDIA_TYPE_SUBTITLE, formatName == "mp4" || formatName == "mov" {
                            outStream.pointee.codecpar.pointee.codec_id = AV_CODEC_ID_MOV_TEXT
                        }
                        if inputStream.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_HEVC {
                            outStream.pointee.codecpar.pointee.codec_tag = CMFormatDescription.MediaSubType.hevc.rawValue.bigEndian
                        } else {
                            outStream.pointee.codecpar.pointee.codec_tag = 0
                        }
                    }
                }
            }
        }
        avio_open(&(outputFormatCtx.pointee.pb), filename, AVIO_FLAG_WRITE)
        ret = avformat_write_header(outputFormatCtx, nil)
        guard ret >= 0 else {
            KSLog(NSError(errorCode: .formatWriteHeader, avErrorCode: ret))
            avformat_close_input(&self.outputFormatCtx)
            return
        }
        outputPacket = av_packet_alloc()
    }

    private func createCodec(formatCtx: UnsafeMutablePointer<AVFormatContext>) {
        allPlayerItemTracks.removeAll()
        assetTracks.removeAll()
        videoAdaptation = nil
        videoTrack = nil
        audioTrack = nil
        videoAudioTracks.removeAll()
        assetTracks = (0 ..< Int(formatCtx.pointee.nb_streams)).compactMap { i in
            if let coreStream = formatCtx.pointee.streams[i] {
                coreStream.pointee.discard = AVDISCARD_ALL
                if let assetTrack = FFmpegAssetTrack(stream: coreStream) {
                    if assetTrack.mediaType == .subtitle {
                        // 有遇到字幕的startTime不准，需要从formatCtx取，才是准的
                        assetTrack.startTime = startTime
                        let subtitle = SyncPlayerItemTrack<SubtitleFrame>(mediaType: .subtitle, frameCapacity: 255, options: options)
                        assetTrack.subtitle = subtitle
                        allPlayerItemTracks.append(subtitle)
                    }
                    assetTrack.seekByBytes = seekByBytes
                    return assetTrack
                } else if coreStream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_ATTACHMENT {
                    // 有的字体附件的codec_id 为0
                    if coreStream.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_TTF || coreStream.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_OTF ||
                        coreStream.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_NONE
                    {
                        let metadata = toDictionary(coreStream.pointee.metadata)
                        if let filename = metadata["filename"], let extradata = coreStream.pointee.codecpar.pointee.extradata {
                            let extradataSize = coreStream.pointee.codecpar.pointee.extradata_size
                            let data = Data(bytes: extradata, count: Int(extradataSize))
                            var fontsDir = KSOptions.fontsDir
                            try? FileManager.default.createDirectory(at: fontsDir, withIntermediateDirectories: true)
                            fontsDir.appendPathComponent(filename)
                            try? data.write(to: fontsDir)
                            let result = CTFontManagerRegisterFontsForURL(fontsDir as CFURL, .process, nil)
                        }
                    }
                }
            }
            return nil
        }
        let subtitles = assetTracks.filter {
            $0.mediaType == .subtitle
        }
        // 因为本地视频加载很快，所以要在这边就把图片字幕给打开。不然前几秒的图片视频可能就无法展示出来了。
        options.wantedSubtitle(tracks: subtitles)?.isEnabled = true
        var videoIndex: Int32 = -1
        if !options.videoDisable {
            let videos = assetTracks.filter { $0.mediaType == .video }
            let wantedStreamNb: Int32
            if !videos.isEmpty, let track = options.wantedVideo(tracks: videos) {
                wantedStreamNb = track.trackID
            } else {
                wantedStreamNb = -1
            }
            videoIndex = av_find_best_stream(formatCtx, AVMEDIA_TYPE_VIDEO, wantedStreamNb, -1, nil, 0)
            if let first = videos.first(where: { $0.trackID == videoIndex }) {
                first.isEnabled = true
                let rotation = first.rotation
                if rotation > 0, options.autoRotate {
                    options.hardwareDecode = false
                    if abs(rotation - 90) <= 1 {
                        options.videoFilters.append("transpose=clock")
                    } else if abs(rotation - 180) <= 1 {
                        options.videoFilters.append("hflip")
                        options.videoFilters.append("vflip")
                    } else if abs(rotation - 270) <= 1 {
                        options.videoFilters.append("transpose=cclock")
                    } else if abs(rotation) > 1 {
                        options.videoFilters.append("rotate=\(rotation)*PI/180")
                    }
                }
                naturalSize = abs(rotation - 90) <= 1 || abs(rotation - 270) <= 1 ? first.naturalSize.reverse : first.naturalSize
                options.process(assetTrack: first)
                options.dynamicRange = first.dynamicRange ?? .sdr
                let frameCapacity = options.videoFrameMaxCount(fps: first.nominalFrameRate, naturalSize: naturalSize, isLive: initDuration == 0)
                let track = options.syncDecodeVideo ? SyncPlayerItemTrack<VideoVTBFrame>(mediaType: .video, frameCapacity: frameCapacity, options: options) : AsyncPlayerItemTrack<VideoVTBFrame>(mediaType: .video, frameCapacity: frameCapacity, options: options)
                track.delegate = self
                allPlayerItemTracks.append(track)
                videoTrack = track
                if !first.isImage {
                    videoAudioTracks.append(track)
                }
                let bitRates = videos.map(\.bitRate).filter {
                    $0 > 0
                }
                if bitRates.count > 1, options.videoAdaptable {
                    let bitRateState = VideoAdaptationState.BitRateState(bitRate: first.bitRate, time: CACurrentMediaTime())
                    videoAdaptation = VideoAdaptationState(bitRates: bitRates.sorted(by: <), duration: duration, fps: first.nominalFrameRate, bitRateStates: [bitRateState])
                }
            }
        }

        let audios = assetTracks.filter { $0.mediaType == .audio }
        let wantedStreamNb: Int32
        if !audios.isEmpty, let track = options.wantedAudio(tracks: audios) {
            wantedStreamNb = track.trackID
        } else {
            wantedStreamNb = -1
        }
        let index = av_find_best_stream(formatCtx, AVMEDIA_TYPE_AUDIO, wantedStreamNb, videoIndex, nil, 0)
        if let first = audios.first(where: {
            index > 0 ? $0.trackID == index : true
        }), first.codecpar.codec_id != AV_CODEC_ID_NONE {
            first.isEnabled = true
            options.process(assetTrack: first)
            // 音频要比较所有的音轨，因为truehd的fps是1200，跟其他的音轨差距太大了
            let fps = audios.map(\.nominalFrameRate).max() ?? 44
            let frameCapacity = options.audioFrameMaxCount(fps: fps, channelCount: Int(first.audioDescriptor?.audioFormat.channelCount ?? 2))
            let track = options.syncDecodeAudio ? SyncPlayerItemTrack<AudioFrame>(mediaType: .audio, frameCapacity: frameCapacity, options: options) : AsyncPlayerItemTrack<AudioFrame>(mediaType: .audio, frameCapacity: frameCapacity, options: options)
            track.delegate = self
            allPlayerItemTracks.append(track)
            audioTrack = track
            videoAudioTracks.append(track)
            isAudioStalled = false
        }
    }

    private func read() {
        readOperation = BlockOperation { [weak self] in
            guard let self else { return }
            Thread.current.name = (self.operationQueue.name ?? "") + "_read"
            Thread.current.stackSize = KSOptions.stackSize
            self.readThread()
        }
        readOperation?.queuePriority = .veryHigh
        readOperation?.qualityOfService = .userInteractive
        if let readOperation {
            operationQueue.addOperation(readOperation)
        }
    }

    private func readThread() {
        if state == .opened {
            /// File has a CUES element, but we defer parsing until it is needed.
            /// 因为mkv只会在第一次seek的时候请求index信息，
            /// 所以为了让预加载不会在第一次seek有缓冲，就手动seek提前请求index。(比较trick，但是没想到更好的方案)
            if options.formatName.contains("matroska"), ioContext as? PreLoadProtocol != nil, options.startPlayTime == 0 {
                options.startPlayTime = 0.0001
//                options.seekFlags |= AVSEEK_FLAG_ANY
            }
            if options.startPlayTime > 0, options.startPlayTime < duration {
                var flags = options.seekFlags
                let timestamp: Int64
                let time = startTime + CMTime(seconds: options.startPlayTime)
                if seekByBytes {
                    if initFileSize > 0, initDuration > 0 {
                        flags |= AVSEEK_FLAG_BYTE
                        timestamp = Int64(Double(initFileSize) * options.startPlayTime / initDuration)
                    } else {
                        timestamp = time.value
                    }
                } else {
                    timestamp = time.value
                }
                let seekStartTime = CACurrentMediaTime()
                let result = avformat_seek_file(formatCtx, -1, Int64.min, timestamp, Int64.max, flags)
                audioClock.time = time
                videoClock.time = time
                KSLog("start seek PlayTime: \(time.seconds) spend Time: \(CACurrentMediaTime() - seekStartTime)")
                if let seekingCompletionHandler {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.seekingCompletionHandler?(result >= 0)
                        self.seekingCompletionHandler = nil
                    }
                }
            }
            state = .reading
        }
        allPlayerItemTracks.forEach { $0.decode() }
        while [MESourceState.paused, .seeking, .reading].contains(state) {
            interrupt = false
            if state == .paused {
                if let preload = ioContext as? PreLoadProtocol {
                    let size = preload.more()
                    // more有可能要等很久才返回,所以这里要判断下状态
                    if size <= 0, state == .paused {
                        condition.wait()
                    }
                } else {
                    condition.wait()
                }
            } else if state == .seeking {
                let seekToTime = seekTime
                let seekSuccess = seekUsePacketCache(seconds: seekToTime)
                if seekSuccess {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.seekingCompletionHandler?(true)
                        self.seekingCompletionHandler = nil
                    }
                    state = .reading
                    continue
                }
                let time = mainClock().time
                var increase = Int64(seekTime + startTime.seconds - time.seconds)
                var seekFlags = options.seekFlags
                let timeStamp: Int64
                /// 因为有的ts走seekByBytes的话，那会seek不会精准，自定义io的直播流和点播也会有有问题，所以先关掉，下次遇到ts seek有问题的话在看下。
                if false, seekByBytes, let formatCtx {
                    seekFlags |= AVSEEK_FLAG_BYTE
                    if fileSize > 0, duration > 0 {
                        timeStamp = Int64(Double(fileSize) * seekToTime / duration)
                    } else {
                        var byteRate = formatCtx.pointee.bit_rate / 8
                        if byteRate == 0 {
                            byteRate = dynamicInfo.byteRate
                        }
                        increase *= byteRate
                        var position = Int64(-1)
                        if position < 0 {
                            position = videoClock.position
                        }
                        if position < 0 {
                            position = audioClock.position
                        }
                        if position < 0 {
                            position = avio_tell(formatCtx.pointee.pb)
                        }
                        timeStamp = position + increase
                    }
                    //                avformat_flush(formatCtx)
                } else {
                    increase *= Int64(AV_TIME_BASE)
                    timeStamp = Int64(time.seconds) * Int64(AV_TIME_BASE) + increase
                }
                /// 有遇到一个mov的视频，如果指定min，那seek之后，就会从0开始播放；
                /// 并且如果seek的值大于结束时间的话，那会返回-1，到时无法加载数据，一直loading。
//                let seekMin = increase > 0 ? timeStamp - increase + 2 : Int64.min
                let seekMin = Int64.min
                let seekMax = increase < 0 ? timeStamp - increase - 2 : Int64.max
//                allPlayerItemTracks.forEach { $0.seek(time: seekToTime) }
                // can not seek to key frame
                let seekStartTime = CACurrentMediaTime()
                var result = avformat_seek_file(formatCtx, -1, seekMin, timeStamp, seekMax, seekFlags)
//                var result = av_seek_frame(formatCtx, -1, timeStamp, seekFlags)
                // When seeking before the beginning of the file, and seeking fails,
                // try again without the backwards flag to make it seek to the
                // beginning.
                if result < 0, seekFlags & AVSEEK_FLAG_BACKWARD == AVSEEK_FLAG_BACKWARD {
                    KSLog("seek to \(seekToTime) failed. seekFlags remove BACKWARD")
                    options.seekFlags &= ~AVSEEK_FLAG_BACKWARD
                    seekFlags &= ~AVSEEK_FLAG_BACKWARD
                    result = avformat_seek_file(formatCtx, -1, seekMin, timeStamp, seekMax, seekFlags)
                }
                KSLog("seek to \(seekToTime) spend Time: \(CACurrentMediaTime() - seekStartTime)")
                if state == .closed {
                    break
                }
                if seekToTime != seekTime {
                    continue
                }
                isSeek = true
                allPlayerItemTracks.forEach { $0.seek(time: seekToTime) }
                audioClock.time = CMTime(seconds: seekToTime, preferredTimescale: time.timescale) + startTime
                videoClock.time = CMTime(seconds: seekToTime, preferredTimescale: time.timescale) + startTime
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.codecDidChangeCapacity()
                    self.seekingCompletionHandler?(result >= 0)
                    self.seekingCompletionHandler = nil
                }
                state = .reading
            } else if state == .reading {
                autoreleasepool {
                    _ = reading()
                }
            }
        }
    }

    private func seekUsePacketCache(seconds: Double) -> Bool {
        guard options.seekUsePacketCache else {
            return false
        }
        var log = "seek use packet cache \(seconds)"
        var seconds = seconds
        var array = [(PlayerItemTrackProtocol, UInt, TimeInterval)]()
        if let track = videoTrack {
            if let (index, time) = track.seekCache(time: seconds, needKeyFrame: true) {
                // 需要更新下seek的时间，不然视频滞后音频的话，那画面会卡住
                seconds = time
                array.append((track, index, time))
            } else {
                return false
            }
        }
        if let track = audioTrack {
            if let (index, time) = track.seekCache(time: seconds, needKeyFrame: false) {
                array.append((track, index, time))
            } else {
                return false
            }
        }
        for (track, index, time) in array {
            track.updateCache(headIndex: index, time: seconds)
            log += " \(track.mediaType.rawValue) \(time)"
        }
        KSLog(log)
        for track in assetTracks {
            if let (index, _) = track.subtitle?.outputRenderQueue.seek(seconds: seconds) {
                track.subtitle?.outputRenderQueue.update(headIndex: index)
            }
        }
        return true
    }

    private func reading() -> Int32 {
        let packet = Packet()
        guard let corePacket = packet.corePacket else {
            return 0
        }
        let readResult = av_read_frame(formatCtx, corePacket)
        if state == .closed {
            return 0
        }
        if readResult == 0 {
            if let outputFormatCtx, let formatCtx {
                let index = Int(corePacket.pointee.stream_index)
                if let outputIndex = streamMapping[index],
                   let inputTb = formatCtx.pointee.streams[index]?.pointee.time_base,
                   let outputTb = outputFormatCtx.pointee.streams[outputIndex]?.pointee.time_base,
                   let outputPacket
                {
                    av_packet_ref(outputPacket, corePacket)
                    outputPacket.pointee.stream_index = Int32(outputIndex)
                    av_packet_rescale_ts(outputPacket, inputTb, outputTb)
                    outputPacket.pointee.pos = -1
                    let ret = av_interleaved_write_frame(outputFormatCtx, outputPacket)
                    if ret < 0 {
                        KSLog("can not av_interleaved_write_frame")
                    }
                }
            }
            if corePacket.pointee.size <= 0 {
                return 0
            }
            let first = assetTracks.first { $0.trackID == corePacket.pointee.stream_index }
            if let first, first.isEnabled {
                packet.assetTrack = first
                if first.mediaType == .video {
                    if options.readVideoTime == 0 {
                        options.readVideoTime = CACurrentMediaTime()
                    }
                    videoTrack?.putPacket(packet: packet)
                } else if first.mediaType == .audio {
                    if options.readAudioTime == 0 {
                        options.readAudioTime = CACurrentMediaTime()
                    }
                    audioTrack?.putPacket(packet: packet)
                } else if first.mediaType == .subtitle {
                    first.subtitle?.putPacket(packet: packet)
                }
            }
        } else if !interrupt {
            if readResult == swift_AVERROR_EOF || avio_feof(formatCtx?.pointee.pb) > 0 {
                if options.isLoopPlay, allPlayerItemTracks.allSatisfy({ !$0.isLoopModel }) {
                    allPlayerItemTracks.forEach { $0.isLoopModel = true }
                    _ = av_seek_frame(formatCtx, -1, startTime.value, AVSEEK_FLAG_BACKWARD)
                } else {
                    allPlayerItemTracks.forEach { $0.isEndOfFile = true }
                    state = .finished
                }
            } else if readResult != AVError.tryAgain.code {
                //                        if IS_AVERROR_INVALIDDATA(readResult)
                error = .init(errorCode: .readFrame, avErrorCode: readResult)
            }
        }
        return readResult
    }

    private func pause() {
        if state == .reading {
            state = .paused
        }
    }

    private func resume() {
        if state == .paused {
            state = .reading
            condition.signal()
        }
    }
}

// MARK: MediaPlayback

extension MEPlayerItem: MediaPlayback {
    var seekable: Bool {
        guard let formatCtx else {
            return false
        }
        var seekable = true
        if let ioContext = formatCtx.pointee.pb {
            seekable = ioContext.pointee.seekable > 0 || initDuration != 0
        }
        return seekable
    }

    public func prepareToPlay() {
        guard [MESourceState.idle, .closed, .failed].contains(state) else {
            return
        }
        state = .opening
        openOperation = BlockOperation { [weak self] in
            guard let self else { return }
            Thread.current.name = (self.operationQueue.name ?? "") + "_open"
            Thread.current.stackSize = KSOptions.stackSize
            self.openThread()
        }
        openOperation?.queuePriority = .veryHigh
        openOperation?.qualityOfService = .userInteractive
        if let openOperation {
            operationQueue.addOperation(openOperation)
        }
    }

    public func stop() {
        guard state != .closed else { return }
        state = .closed
        av_packet_free(&outputPacket)
        stopRecord()
        // 故意循环引用。等结束了。才释放
        let closeOperation = BlockOperation {
            Thread.current.name = (self.operationQueue.name ?? "") + "_close"
            self.allPlayerItemTracks.forEach { $0.shutdown() }
            KSLog("清空formatCtx")
            self.formatCtx?.pointee.interrupt_callback.opaque = nil
            self.formatCtx?.pointee.interrupt_callback.callback = nil
            avformat_close_input(&self.formatCtx)
            if let ioContext = self.ioContext {
                // close之后要马上把ioContext设置为nil。防止下次在进入到close方法
                ioContext.close()
                self.ioContext = nil
                for item in self.pbArray {
                    if var pb = item.pb {
                        if pb.pointee.buffer != nil {
                            av_freep(&pb.pointee.buffer)
                        }
                        if item.pb != nil {
                            avio_context_free(&item.pb)
                        }
                    }
                }
            }
            self.pbArray.removeAll()
            avformat_close_input(&self.outputFormatCtx)
            self.closeOperation = nil
            self.operationQueue.cancelAllOperations()
        }
        closeOperation.queuePriority = .veryHigh
        closeOperation.qualityOfService = .userInteractive
        if let readOperation {
            readOperation.cancel()
            closeOperation.addDependency(readOperation)
        } else if let openOperation {
            openOperation.cancel()
            closeOperation.addDependency(openOperation)
        }
        operationQueue.addOperation(closeOperation)
        condition.signal()
        if options.syncDecodeVideo || options.syncDecodeAudio {
            DispatchQueue.global().async { [weak self] in
                self?.allPlayerItemTracks.forEach { $0.shutdown() }
            }
        }
        self.closeOperation = closeOperation
    }

    public func stopRecord() {
        if let outputFormatCtx {
            av_write_trailer(outputFormatCtx)
            avformat_close_input(&self.outputFormatCtx)
        }
    }

    public func seek(time: TimeInterval, completion: @escaping ((Bool) -> Void)) {
        if state == .reading || state == .paused || state == .seeking {
            let oldState = state
            // 有人反馈进行20s以内的seek，如果设置interrupt为true，容易触发失败。
            if KSOptions.seekInterruptIO, abs(time - currentPlaybackTime) > 20 {
                interrupt = true
            }
            seekTime = time
            seekingCompletionHandler = completion
            state = .seeking
            if oldState == .paused {
                condition.broadcast()
            }
        } else if state == .finished {
            seekTime = time
            state = .seeking
            seekingCompletionHandler = completion
            read()
        } else if state == .failed {
            options.startPlayTime = time
            seekingCompletionHandler = completion
            prepareToPlay()
        }
        isAudioStalled = audioTrack == nil
    }
}

extension MEPlayerItem: CodecCapacityDelegate {
    @MainActor
    func codecDidChangeCapacity() {
        var loadingState = options.playable(capacitys: videoAudioTracks, isFirst: isFirst, isSeek: isSeek)
        if state == .seeking {
            loadingState.loadedTime = 0
        }
        if loadingState.isPlayable {
            isFirst = false
            isSeek = false
            if loadingState.loadedTime > options.maxBufferDuration {
                adaptableVideo(loadingState: loadingState)
                pause()
            } else if loadingState.loadedTime < options.maxBufferDuration / 2 {
                resume()
            }
        } else {
            resume()
            adaptableVideo(loadingState: loadingState)
        }
        // 硬盘缓存要在后面才增加，这样才不会影响到内存缓存。因为只是为了进度条的显示。
        if let preload = ioContext as? PreLoadProtocol, initFileSize > 0, initDuration > 0 {
            if preload.urlPos == initFileSize, preload.loadedSize != 0 {
                loadingState.loadedTime = initDuration - currentPlaybackTime
            } else {
                if preload.loadedSize > 0 {
                    loadingState.loadedTime += Double(preload.loadedSize) * initDuration / Double(initFileSize)
                }
                if preload.urlPos > initFileSize {
                    fileSize = preload.urlPos
                    duration = loadingState.loadedTime + currentPlaybackTime
                } else {
                    loadingState.loadedTime = min(loadingState.loadedTime, duration - currentPlaybackTime)
                }
            }
        }
        delegate?.sourceDidChange(loadingState: loadingState)
    }

    func codecDidFinished(track: some CapacityProtocol) {
        if track.mediaType == .audio {
            isAudioStalled = true
        }
        let allSatisfy = videoAudioTracks.allSatisfy { $0.isEndOfFile && $0.frameCount == 0 && $0.packetCount == 0 }
        if allSatisfy {
            delegate?.sourceDidFinished()
            timer.fireDate = .distantFuture
            if options.isLoopPlay {
                isAudioStalled = audioTrack == nil
                audioTrack?.isLoopModel = false
                videoTrack?.isLoopModel = false
                if state == .finished {
                    runOnMainThread { [weak self] in
                        self?.seek(time: 0) { _ in }
                    }
                }
            }
        }
    }

    @MainActor
    private func adaptableVideo(loadingState: LoadingState) {
        if options.videoDisable || videoAdaptation == nil || loadingState.isEndOfFile || loadingState.isSeek || state == .seeking {
            return
        }
        guard let track = videoTrack else {
            return
        }
        videoAdaptation?.loadedCount = track.packetCount + track.frameCount
        videoAdaptation?.currentPlaybackTime = currentPlaybackTime
        videoAdaptation?.isPlayable = loadingState.isPlayable
        guard let (oldBitRate, newBitrate) = options.adaptable(state: videoAdaptation), oldBitRate != newBitrate,
              let newFFmpegAssetTrack = assetTracks.first(where: { $0.mediaType == .video && $0.bitRate == newBitrate })
        else {
            return
        }
        assetTracks.first { $0.mediaType == .video && $0.bitRate == oldBitRate }?.isEnabled = false
        newFFmpegAssetTrack.isEnabled = true
        findBestAudio(videoTrack: newFFmpegAssetTrack)
        let bitRateState = VideoAdaptationState.BitRateState(bitRate: newBitrate, time: CACurrentMediaTime())
        videoAdaptation?.bitRateStates.append(bitRateState)
        delegate?.sourceDidChange(oldBitRate: oldBitRate, newBitrate: newBitrate)
    }

    private func findBestAudio(videoTrack: FFmpegAssetTrack) {
        guard videoAdaptation != nil, let first = assetTracks.first(where: { $0.mediaType == .audio && $0.isEnabled }) else {
            return
        }
        let index = av_find_best_stream(formatCtx, AVMEDIA_TYPE_AUDIO, -1, videoTrack.trackID, nil, 0)
        if index != first.trackID {
            first.isEnabled = false
            assetTracks.first { $0.mediaType == .audio && $0.trackID == index }?.isEnabled = true
        }
    }
}

extension MEPlayerItem: OutputRenderSourceDelegate {
    func mainClock() -> KSClock {
        isAudioStalled ? videoClock : audioClock
    }

    public func setVideo(time: CMTime, position: Int64) {
//        KSLog("[video] video interval \(CACurrentMediaTime() - videoClock.lastMediaTime) video diff \(time.seconds - videoClock.time.seconds)")
        let oldTime = videoClock.getTime()
        if abs(oldTime - time.seconds) > 1 {
            videoClock.time = time
        } else {
            videoClock.time = CMTime(seconds: oldTime, preferredTimescale: time.timescale)
        }
        videoClock.position = position
        videoDisplayCount += 1
        let diff = videoClock.lastMediaTime - lastVideoClock.lastMediaTime
        if diff > 2 {
            let timeDiff = (videoClock.time - lastVideoClock.time).seconds
            if timeDiff != 0 {
                dynamicInfo.byteRate = Int64(Double(videoClock.position - lastVideoClock.position) / timeDiff)
            }
            dynamicInfo.displayFPS = Double(videoDisplayCount) / diff
            videoDisplayCount = 0
            lastVideoClock = videoClock
        }
    }

    public func setAudio(time: CMTime, position: Int64) {
//        KSLog("[audio] setAudio: \(time.seconds)")
        // 切换到主线程的话，那播放起来会更顺滑
        runOnMainThread {
            self.audioClock.time = time
            self.audioClock.position = position
        }
    }

    @MainActor
    public func getVideoOutputRender(force: Bool) -> VideoVTBFrame? {
        guard let videoTrack else {
            return nil
        }
        var type: ClockProcessType = force ? .next : .remain
        let predicate: ((VideoVTBFrame, Int) -> Bool)? = force ? nil : { [weak self] frame, count -> Bool in
            guard let self else { return true }
            let main: KSClock
            if KSOptions.audioVideoClockSync {
                main = self.mainClock()
            } else {
                if isAudioStalled || abs(audioClock.getTime() - videoClock.getTime()) < 1 {
                    main = videoClock
                } else {
                    main = audioClock
                }
            }
            (self.dynamicInfo.audioVideoSyncDiff, type) = self.options.videoClockSync(main: main, nextVideoTime: frame.seconds, fps: Double(frame.fps), frameCount: count)
            if case .remain = type {
                return false
            } else {
                return true
            }
        }
        let frame = videoTrack.getOutputRender(where: predicate)
        switch type {
        case .remain:
            break
        case .next:
            break
        case let .dropFrame(count: count):
            loop(iterations: count) { _ in
                if videoTrack.getOutputRender(where: nil) != nil {
                    dynamicInfo.droppedVideoFrameCount += 1
                }
            }
        case .flush:
            let count = videoTrack.outputRenderQueue.count
            videoTrack.outputRenderQueue.flush()
            dynamicInfo.droppedVideoFrameCount += UInt32(count)
        case .seek:
            videoTrack.outputRenderQueue.flush()
            videoTrack.seekTime = mainClock().time.seconds
        case .dropNextPacket:
            if let videoTrack = videoTrack as? AsyncPlayerItemTrack {
                let packet = videoTrack.packetQueue.pop { item, _ -> Bool in
                    !item.isKeyFrame
                }
                if packet != nil {
                    dynamicInfo.droppedVideoPacketCount += 1
                }
            }
        case .dropGOPPacket:
            if let videoTrack = videoTrack as? AsyncPlayerItemTrack {
                var packet: Packet? = nil
                repeat {
                    packet = videoTrack.packetQueue.pop { item, _ -> Bool in
                        !item.isKeyFrame
                    }
                    if packet != nil {
                        dynamicInfo.droppedVideoPacketCount += 1
                    }
                } while packet != nil
            }
        }
        return frame
    }

    public func getAudioOutputRender() -> AudioFrame? {
        if let frame = audioTrack?.getOutputRender(where: nil) {
            KSOptions.audioRecognizes.first {
                $0.isEnabled
            }?.append(frame: frame)
            return frame
        } else {
            return nil
        }
    }
}

public extension AbstractAVIOContext {
    func getContext(bufferSize: Int32 = AbstractAVIOContext.bufferSize, writable: Bool = false) -> UnsafeMutablePointer<AVIOContext> {
        avio_alloc_context(av_malloc(Int(bufferSize)), bufferSize, writable ? 1 : 0, Unmanaged.passUnretained(self).toOpaque()) { opaque, buffer, size -> Int32 in
            let value = Unmanaged<AbstractAVIOContext>.fromOpaque(opaque!).takeUnretainedValue()
            let ret = value.read(buffer: buffer, size: size)
            return Int32(ret)
        } _: { opaque, buffer, size -> Int32 in
            let value = Unmanaged<AbstractAVIOContext>.fromOpaque(opaque!).takeUnretainedValue()
            let ret = value.write(buffer: buffer, size: size)
            return Int32(ret)
        } _: { opaque, offset, whence -> Int64 in
            let value = Unmanaged<AbstractAVIOContext>.fromOpaque(opaque!).takeUnretainedValue()
            if whence == AVSEEK_SIZE {
                return value.fileSize()
            }
            return value.seek(offset: offset, whence: whence)
        }
    }
}

private class PBClass {
    fileprivate var pb: UnsafeMutablePointer<AVIOContext>?
    private var _bytesRead: Int64 = 0
    private var add: Int64 = 0
    fileprivate var bytesRead: Int64 {
        if let pb = pb?.pointee {
            // pb有可能会复用，小于就认为进行复用了。
            if _bytesRead > pb.bytes_read {
                add += _bytesRead
            }
            _bytesRead = pb.bytes_read
        }
        // 因为m3u8的pb会被释放，所以要保存之前的已读长度。
        return add + _bytesRead
    }

    init(pb: UnsafeMutablePointer<AVIOContext>?) {
        self.pb = pb
    }

    fileprivate func add(num: Int64) {
        add += num
    }
}
