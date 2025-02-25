//
//  KSMEPlayer.swift
//  KSPlayer
//
//  Created by kintan on 2018/3/9.
//

import AVFoundation
import AVKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

public class KSMEPlayer: NSObject {
    private var loopCount = 1
    private var playerItem: MEPlayerItem
    public let audioOutput: AudioOutput
    private var options: KSOptions
    private var bufferingCountDownTimer: Timer?
    public let videoOutput: VideoOutput & UIView

    public private(set) var bufferingProgress = 0 {
        willSet {
            runOnMainThread { [weak self] in
                guard let self else { return }
                delegate?.changeBuffering(player: self, progress: newValue)
            }
        }
    }

    @MainActor
    public var pipController: KSPictureInPictureProtocol? = nil

    private lazy var _playbackCoordinator: Any? = {
        if #available(macOS 12.0, iOS 15.0, tvOS 15.0, *) {
            let coordinator = AVDelegatingPlaybackCoordinator(playbackControlDelegate: self)
            coordinator.suspensionReasonsThatTriggerWaiting = [.stallRecovery]
            return coordinator
        } else {
            return nil
        }
    }()

    @available(macOS 12.0, iOS 15.0, tvOS 15.0, *)
    public var playbackCoordinator: AVPlaybackCoordinator {
        // swiftlint:disable force_cast
        _playbackCoordinator as! AVPlaybackCoordinator
        // swiftlint:enable force_cast
    }

    public private(set) var playableTime = TimeInterval(0)
    public weak var delegate: MediaPlayerDelegate?
    public private(set) var isReadyToPlay = false
    public var allowsExternalPlayback: Bool = false
    public var usesExternalPlaybackWhileExternalScreenIsActive: Bool = false
    @MainActor
    public var playbackRate: Float = 1 {
        didSet {
            if playbackRate != audioOutput.playbackRate {
                audioOutput.playbackRate = playbackRate
                playerItem.playbackRate = playbackRate
                if let controlTimebase = videoOutput.displayLayer.controlTimebase {
                    CMTimebaseSetRate(controlTimebase, rate: Float64(playbackRate))
                }
                if audioOutput is AudioUnitPlayer {
                    var audioFilters = options.audioFilters.filter {
                        !$0.hasPrefix("atempo=")
                    }
                    if playbackRate != 1 {
                        audioFilters.append("atempo=\(playbackRate)")
                    }
                    options.audioFilters = audioFilters
                }
            }
        }
    }

    public private(set) var loadState = MediaLoadState.idle {
        didSet {
            if loadState != oldValue {
                playOrPause()
            }
        }
    }

    public private(set) var playbackState = MediaPlaybackState.idle {
        didSet {
            if playbackState != oldValue {
                playOrPause()
                if playbackState == .finished {
                    runOnMainThread { [weak self] in
                        guard let self else { return }
                        delegate?.finish(player: self, error: nil)
                    }
                }
            }
        }
    }

    @MainActor
    public required init(url: URL, options: KSOptions) {
        KSOptions.setAudioSession()
        audioOutput = KSOptions.audioPlayerType.init()
        playerItem = MEPlayerItem(url: url, options: options)
        videoOutput = KSOptions.videoPlayerType.init(options: options)
        self.options = options
        super.init()
        playerItem.delegate = self
        audioOutput.renderSource = playerItem
        videoOutput.renderSource = playerItem
        #if os(macOS)
        let audioId = AudioObjectID(bitPattern: kAudioObjectSystemObject)
        var forPropertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster
        )
        AudioObjectAddPropertyListenerBlock(audioId, &forPropertyAddress, DispatchQueue.main) { [weak self] _, _ in
            guard let self else { return }
            self.audioOutput.flush()
            // 切换成蓝牙音箱的话，需要异步暂停播放下，不然会没有声音。并且要延迟1s之后处理，不然不行
            if self.playbackState == .playing, self.loadState == .playable {
                DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 1) { [weak self] in
                    guard let self else { return }
                    self.audioOutput.pause()
                    self.videoOutput.pause()
                    self.audioOutput.play()
                    self.videoOutput.play()
                }
            }
        }
        #else
        NotificationCenter.default.addObserver(self, selector: #selector(audioRouteChange), name: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance())
        if #available(tvOS 15.0, iOS 15.0, *) {
            NotificationCenter.default.addObserver(self, selector: #selector(spatialCapabilityChange), name: AVAudioSession.spatialPlaybackCapabilitiesChangedNotification, object: nil)
        }
        #endif
    }

    deinit {}
}

// MARK: - private functions

private extension KSMEPlayer {
    func playOrPause() {
        runOnMainThread { [weak self] in
            guard let self else { return }
            let isPaused = !(self.playbackState == .playing && self.loadState == .playable)
            if isPaused {
                self.videoOutput.pause()
                self.audioOutput.pause()
            } else {
                // 要先调用video的play。这样才能减少seek之后，声音出来了，但是画面还卡住的概率。
                self.videoOutput.play()
                /// audioOutput 要手动的调用setAudio(time下，这样才能及时的更新音频的时间
                /// 不然如果音频没有先渲染的话，那音视频同步算法就无法取到正确的时间戳。导致误丢数据
                /// 暂停会导致getTime变大，所以要用time更新下时间戳
                /// seek之后返回的音频和视频的时间戳跟seek的时间戳有可能会差了10s，
                /// 有时候加载很快，视频帧无法优先展示一帧。所以要取最新的音频时间来更新time
                self.audioOutput.play()
            }
            self.delegate?.changeLoadState(player: self)
        }
    }

    @MainActor
    @objc private func spatialCapabilityChange(notification _: Notification) {
        KSLog("[audio] spatialCapabilityChange")
        for track in tracks(mediaType: .audio) {
            (track as? FFmpegAssetTrack)?.audioDescriptor?.updateAudioFormat()
        }
    }

    #if !os(macOS)
    @MainActor
    @objc private func audioRouteChange(notification: Notification) {
        guard let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt, let routeChangeReason = AVAudioSession.RouteChangeReason(rawValue: reason) else {
            return
        }

        KSLog("[audio] audioRouteChange \(routeChangeReason)")
        // 有电话进来会上报categoryChange
        guard [AVAudioSession.RouteChangeReason.newDeviceAvailable, .oldDeviceUnavailable, .routeConfigurationChange].contains(routeChangeReason) else {
            return
        }
        for track in tracks(mediaType: .audio) {
            (track as? FFmpegAssetTrack)?.audioDescriptor?.updateAudioFormat()
        }
        audioOutput.flush()
        // oldDeviceUnavailable的话，就不进行恢复了。因为有可能先调用这个通知，在调pause的通知。导致暂停之后还会继续播放
        if routeChangeReason != .oldDeviceUnavailable, playbackState == .playing, loadState == .playable {
            // 切换成蓝牙音箱的话，需要异步暂停播放下，不然会没有声音
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.audioOutput.pause()
                self.videoOutput.pause()
                self.audioOutput.play()
                self.videoOutput.play()
            }
        }
    }
    #endif
}

extension KSMEPlayer: MEPlayerDelegate {
    func sourceDidOpened() {
        isReadyToPlay = true
        options.readyTime = CACurrentMediaTime()
        runOnMainThread { [weak self] in
            guard let self else { return }
            let audioDescriptor = tracks(mediaType: .audio).first { $0.isEnabled }.flatMap {
                $0 as? FFmpegAssetTrack
            }?.audioDescriptor
            if let outputURL = options.outputURL {
                startRecord(url: outputURL)
            }
            if let audioDescriptor {
                KSLog("[audio] audio type: \(audioOutput) prepare audioFormat )")
                audioOutput.prepare(audioFormat: audioDescriptor.audioFormat)
            }
            if let controlTimebase = videoOutput.displayLayer.controlTimebase, options.startPlayTime > 1 {
                CMTimebaseSetTime(controlTimebase, time: CMTimeMake(value: Int64(options.startPlayTime), timescale: 1))
            }
            delegate?.readyToPlay(player: self)
        }
    }

    func sourceDidFailed(error: NSError?) {
        runOnMainThread { [weak self] in
            guard let self else { return }
            self.delegate?.finish(player: self, error: error)
        }
    }

    func sourceDidFinished() {
        runOnMainThread { [weak self] in
            guard let self else { return }
            if self.options.isLoopPlay {
                self.loopCount += 1
                self.delegate?.playBack(player: self, loopCount: self.loopCount)
                self.audioOutput.play()
                self.videoOutput.play()
            } else {
                self.playbackState = .finished
            }
        }
    }

    @MainActor
    func sourceDidChange(loadingState: LoadingState) {
        if loadingState.isEndOfFile {
            playableTime = duration
        } else {
            playableTime = currentPlaybackTime + loadingState.loadedTime
        }
        if loadState == .playable {
            if !loadingState.isEndOfFile, loadingState.frameCount == 0, loadingState.packetCount == 0, options.preferredForwardBufferDuration != 0 {
                loadState = .loading
                if playbackState == .playing {
                    runOnMainThread { [weak self] in
                        // 在主线程更新进度
                        self?.bufferingProgress = 0
                    }
                }
            }
        } else {
            if loadingState.isFirst || loadingState.isSeek {
                runOnMainThread { [weak self] in
                    // 在主线程更新进度
                    if let videoOutput = self?.videoOutput, videoOutput.pixelBuffer == nil {
                        videoOutput.readNextFrame()
                    }
                }
            }
            var progress = 100
            if loadingState.isPlayable {
                loadState = .playable
            } else {
                if loadingState.progress.isInfinite {
                    progress = 100
                } else if loadingState.progress.isNaN {
                    progress = 0
                } else {
                    progress = min(100, Int(loadingState.progress))
                }
            }
            if playbackState == .playing {
                runOnMainThread { [weak self] in
                    // 在主线程更新进度
                    self?.bufferingProgress = progress
                }
            }
        }
        if duration == 0, playbackState == .playing, loadState == .playable {
            if let rate = options.liveAdaptivePlaybackRate(loadingState: loadingState) {
                playbackRate = rate
            }
        }
    }

    func sourceDidChange(oldBitRate: Int64, newBitrate: Int64) {
        KSLog("oldBitRate \(oldBitRate) change to newBitrate \(newBitrate)")
    }
}

extension KSMEPlayer: MediaPlayerProtocol {
    public var chapters: [Chapter] {
        playerItem.chapters
    }

    public var subtitleDataSource: (any ConstantSubtitleDataSource)? { self }
    public var playbackVolume: Float {
        get {
            audioOutput.volume
        }
        set {
            audioOutput.volume = newValue
        }
    }

    @MainActor
    public var naturalSize: CGSize {
        options.display.isSphere ? KSOptions.sceneSize : playerItem.naturalSize
    }

    public var view: UIView { videoOutput }

    public func replace(url: URL, options: KSOptions) {
        replace(item: MEPlayerItem(url: url, options: options))
    }

    @MainActor
    public func replace(item: MEPlayerItem) {
        KSLog("replace item \(item)")
        reset()
        playerItem.delegate = nil
        let options = item.options
        playerItem = item
        self.options = options
        playerItem.delegate = self
        audioOutput.flush()
        audioOutput.renderSource = playerItem
        videoOutput.renderSource = playerItem
        videoOutput.options = options
    }

    public var currentPlaybackTime: TimeInterval {
        get {
            playerItem.currentPlaybackTime
        }
        set {
            seek(time: newValue) { _ in }
        }
    }

    public var duration: TimeInterval { playerItem.duration }

    public var fileSize: Int64 { playerItem.fileSize }

    public var seekable: Bool { playerItem.seekable }

    public var dynamicInfo: DynamicInfo? {
        playerItem.dynamicInfo
    }

    public func seek(time: TimeInterval, completion: @escaping ((Bool) -> Void)) {
        let time = max(time, 0)
        playbackState = .seeking
        runOnMainThread { [weak self] in
            self?.bufferingProgress = 0
        }
        let seekTime: TimeInterval
        if time >= duration, options.isLoopPlay {
            seekTime = 0
        } else {
            seekTime = time
        }
        playerItem.seek(time: seekTime) { [weak self] result in
            guard let self else { return }
            if result {
                self.videoOutput.pixelBuffer = nil
                self.audioOutput.flush()
                runOnMainThread { [weak self] in
                    guard let self else { return }
                    if let controlTimebase = self.videoOutput.displayLayer.controlTimebase {
                        CMTimebaseSetTime(controlTimebase, time: CMTimeMake(value: Int64(self.currentPlaybackTime), timescale: 1))
                    }
                }
            }
            completion(result)
        }
    }

    public func prepareToPlay() {
        KSLog("prepareToPlay \(self)")
        options.prepareTime = CACurrentMediaTime()
        playerItem.prepareToPlay()
        bufferingProgress = 0
    }

    public func play() {
        KSLog("play \(self)")
        playbackState = .playing
        if #available(iOS 15.0, tvOS 15.0, macOS 12.0, *) {
            pipController?.invalidatePlaybackState()
        }
    }

    public func pause() {
        KSLog("pause \(self)")
        playbackState = .paused
        if #available(iOS 15.0, tvOS 15.0, macOS 12.0, *) {
            pipController?.invalidatePlaybackState()
        }
    }

    public func reset() {
        loadState = .idle
        playbackState = .idle
        isReadyToPlay = false
        loopCount = 0
        playerItem.stop()
        options.prepareTime = 0
        options.dnsStartTime = 0
        options.tcpStartTime = 0
        options.tcpConnectedTime = 0
        options.openTime = 0
        options.findTime = 0
        options.readyTime = 0
        options.readAudioTime = 0
        options.readVideoTime = 0
        options.decodeAudioTime = 0
        options.decodeVideoTime = 0
        if KSOptions.isClearVideoWhereReplace {
            videoOutput.flush()
        }
    }

    public func stop() {
        KSLog("stop \(self)")
        playbackState = .stopped
        reset()
        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setPreferredOutputNumberOfChannels(2)
        #endif
        NotificationCenter.default.removeObserver(self)
        audioOutput.invalidate()
        videoOutput.invalidate()
    }

    public func thumbnailImageAtCurrentTime() async -> CGImage? {
        videoOutput.pixelBuffer?.cgImage(isHDR: false)
    }

    public func enterBackground() {}

    public func enterForeground() {
        videoOutput.enterForeground()
        /// 因为硬解进入前台会失败。如果视频 i 帧间隔比较长，那画面会卡比较久。所以要seek让页面不会卡住。
        /// 过滤掉直播流或是不能seek的视频
        if playerItem.seekable, duration > 0, options.hardwareDecode {
            seek(time: currentPlaybackTime) { [weak self] _ in
                guard let self else { return }
                self.playbackState = .paused
            }
        }
    }

    public var isMuted: Bool {
        get {
            audioOutput.isMuted
        }
        set {
            audioOutput.isMuted = newValue
        }
    }

    public func tracks(mediaType: AVFoundation.AVMediaType) -> [MediaPlayerTrack] {
        playerItem.assetTracks.compactMap { track -> MediaPlayerTrack? in
            if track.mediaType == mediaType {
                return track
            } else if mediaType == .subtitle {
                return track.closedCaptionsTrack
            }
            return nil
        }
    }

    public func select(track: some MediaPlayerTrack) {
        let isSeek = playerItem.select(track: track)
        if isSeek {
            audioOutput.flush()
        }
    }

    public func startRecord(url: URL) {
        playerItem.startRecord(url: url)
    }

    public func stopRecord() {
        playerItem.stopRecord()
    }

    public func configPIP() {
        if #available(iOS 15.0, tvOS 15.0, macOS 12.0, *) {
            let contentSource = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: videoOutput.displayLayer, playbackDelegate: self)
            let pip = KSOptions.pictureInPictureType.init(contentSource: contentSource)
            pipController = pip
        }
    }
}

@available(tvOS 14.0, *)
@MainActor
extension KSMEPlayer: AVPictureInPictureSampleBufferPlaybackDelegate {
    public func pictureInPictureController(_: AVPictureInPictureController, setPlaying playing: Bool) {
        playing ? play() : pause()
    }

    public func pictureInPictureControllerTimeRangeForPlayback(_: AVPictureInPictureController) -> CMTimeRange {
        // Handle live streams.
        if duration == 0 {
            return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
        }
        return CMTimeRange(start: 0, end: duration)
    }

    public func pictureInPictureControllerIsPlaybackPaused(_: AVPictureInPictureController) -> Bool {
        !isPlaying
    }

    public func pictureInPictureController(_: AVPictureInPictureController, didTransitionToRenderSize _: CMVideoDimensions) {}
    public func pictureInPictureController(_: AVPictureInPictureController, skipByInterval skipInterval: CMTime) async {
        seek(time: currentPlaybackTime + skipInterval.seconds) { _ in }
    }

    public func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_: AVPictureInPictureController) -> Bool {
        false
    }
}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, *)
extension KSMEPlayer: AVPlaybackCoordinatorPlaybackControlDelegate {
    public func playbackCoordinator(_: AVDelegatingPlaybackCoordinator, didIssue playCommand: AVDelegatingPlaybackCoordinatorPlayCommand, completionHandler: @escaping () -> Void) {
        guard playCommand.expectedCurrentItemIdentifier == (playbackCoordinator as? AVDelegatingPlaybackCoordinator)?.currentItemIdentifier else {
            completionHandler()
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            if self.playbackState != .playing {
                self.play()
            }
            completionHandler()
        }
    }

    public func playbackCoordinator(_: AVDelegatingPlaybackCoordinator, didIssue pauseCommand: AVDelegatingPlaybackCoordinatorPauseCommand, completionHandler: @escaping () -> Void) {
        guard pauseCommand.expectedCurrentItemIdentifier == (playbackCoordinator as? AVDelegatingPlaybackCoordinator)?.currentItemIdentifier else {
            completionHandler()
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            if self.playbackState != .paused {
                self.pause()
            }
            completionHandler()
        }
    }

    @MainActor
    public func playbackCoordinator(_: AVDelegatingPlaybackCoordinator, didIssue seekCommand: AVDelegatingPlaybackCoordinatorSeekCommand) async {
        guard seekCommand.expectedCurrentItemIdentifier == (playbackCoordinator as? AVDelegatingPlaybackCoordinator)?.currentItemIdentifier else {
            return
        }
        let seekTime = fmod(seekCommand.itemTime.seconds, duration)
        if abs(currentPlaybackTime - seekTime) < CGFLOAT_EPSILON {
            return
        }
        seek(time: seekTime) { _ in }
    }

    public func playbackCoordinator(_: AVDelegatingPlaybackCoordinator, didIssue bufferingCommand: AVDelegatingPlaybackCoordinatorBufferingCommand, completionHandler: @escaping () -> Void) {
        guard bufferingCommand.expectedCurrentItemIdentifier == (playbackCoordinator as? AVDelegatingPlaybackCoordinator)?.currentItemIdentifier else {
            completionHandler()
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            guard self.loadState != .playable, let countDown = bufferingCommand.completionDueDate?.timeIntervalSinceNow else {
                completionHandler()
                return
            }
            self.bufferingCountDownTimer?.invalidate()
            self.bufferingCountDownTimer = nil
            self.bufferingCountDownTimer = Timer(timeInterval: countDown, repeats: false) { _ in
                completionHandler()
            }
        }
    }
}
