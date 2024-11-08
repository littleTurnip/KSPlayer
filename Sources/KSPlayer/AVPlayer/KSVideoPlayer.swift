//
//  KSVideoPlayer.swift
//  KSPlayer
//
//  Created by kintan on 2023/2/11.
//

import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#else
import AppKit

public typealias UIHostingController = NSHostingController
public typealias UIViewRepresentable = NSViewRepresentable
#endif

public struct KSVideoPlayer {
    @ObservedObject
    public var coordinator: Coordinator
    public let url: URL
    public let options: KSOptions
    public init(coordinator: Coordinator, url: URL, options: KSOptions) {
        _coordinator = .init(wrappedValue: coordinator)
        self.url = url
        self.options = options
    }
}

public extension KSVideoPlayer {
    init(playerLayer: KSPlayerLayer) {
        let coordinator = KSVideoPlayer.Coordinator()
        coordinator.playerLayer = playerLayer
        self.init(coordinator: coordinator, url: playerLayer.url, options: playerLayer.options)
    }
}

#if !os(tvOS)
@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
@MainActor
public struct PlayBackCommands: Commands {
    @FocusedObject
    private var config: KSVideoPlayer.Coordinator?
    public init() {}

    public var body: some Commands {
        CommandMenu("PlayBack") {
            if let config {
                Button(config.state.isPlaying ? "Pause" : "Resume") {
                    if config.state.isPlaying {
                        config.playerLayer?.pause()
                    } else {
                        config.playerLayer?.play()
                    }
                }
                .keyboardShortcut(.space, modifiers: .none)
                Button(config.isMuted ? "Mute" : "Unmute") {
                    config.isMuted.toggle()
                }
            }
        }
    }
}
#endif

extension KSVideoPlayer: UIViewRepresentable {
    public func makeCoordinator() -> Coordinator {
        coordinator
    }

    #if canImport(UIKit)
    public typealias UIViewType = UIView
    public func makeUIView(context: Context) -> UIViewType {
        context.coordinator.makeView(url: url, options: options)
    }

    public func updateUIView(_ view: UIViewType, context: Context) {
        updateView(view, context: context)
    }

    // iOS tvOS真机先调用onDisappear在调用dismantleUIView，但是模拟器就反过来了。
    public static func dismantleUIView(_: UIViewType, coordinator: Coordinator) {
        coordinator.resetPlayer()
    }
    #else
    public typealias NSViewType = UIView
    public func makeNSView(context: Context) -> NSViewType {
        context.coordinator.makeView(url: url, options: options)
    }

    public func updateNSView(_ view: NSViewType, context: Context) {
        updateView(view, context: context)
    }

    // macOS先调用onDisappear在调用dismantleNSView
    public static func dismantleNSView(_ view: NSViewType, coordinator: Coordinator) {
        coordinator.resetPlayer()
        view.window?.aspectRatio = CGSize(width: 16, height: 9)
    }
    #endif

    @MainActor
    private func updateView(_: UIView, context: Context) {
        if context.coordinator.playerLayer?.url != url {
            _ = context.coordinator.makeView(url: url, options: options)
        }
    }

    @MainActor
    public final class Coordinator: ObservableObject {
        public var state: KSPlayerState {
            playerLayer?.state ?? .initialized
        }

        @Published
        public var isMuted: Bool = false {
            didSet {
                playerLayer?.player.isMuted = isMuted
            }
        }

        @Published
        public var playbackVolume: Float = 1.0 {
            didSet {
                playerLayer?.player.playbackVolume = playbackVolume
            }
        }

        @Published
        public var isScaleAspectFill = false {
            didSet {
                playerLayer?.player.contentMode = isScaleAspectFill ? .scaleAspectFill : .scaleAspectFit
            }
        }

        @Published
        public var isRecord = false {
            didSet {
                if isRecord != oldValue {
                    if isRecord {
                        if let url = KSOptions.recordDir {
                            if !FileManager.default.fileExists(atPath: url.path) {
                                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                            }
                            if FileManager.default.fileExists(atPath: url.path) {
                                playerLayer?.player.startRecord(url: url.appendingPathComponent("\(Date().description).mov"))
                            }
                        }
                    } else {
                        playerLayer?.player.stopRecord()
                    }
                }
            }
        }

        @Published
        public var playbackRate: Float = 1.0 {
            didSet {
                playerLayer?.player.playbackRate = playbackRate
            }
        }

        @Published
        @MainActor
        public var isMaskShow = true {
            didSet {
                if isMaskShow != oldValue {
                    mask(show: isMaskShow)
                }
            }
        }

        public var timemodel = ControllerTimeModel()
        // 在SplitView模式下，第二次进入会先调用makeUIView。然后在调用之前的dismantleUIView.所以如果进入的是同一个View的话，就会导致playerLayer被清空了。最准确的方式是在onDisappear清空playerLayer
        public var playerLayer: KSPlayerLayer? {
            didSet {
                oldValue?.delegate = nil
                if oldValue?.player.pipController?.isPictureInPictureActive == true {
                    return
                }
                oldValue?.stop()
            }
        }

        private var delayHide: DispatchWorkItem?
        public var onPlay: ((TimeInterval, TimeInterval) -> Void)?
        public var onFinish: ((KSPlayerLayer, Error?) -> Void)?
        public var onStateChanged: ((KSPlayerLayer, KSPlayerState) -> Void)?
        public var onBufferChanged: ((Int, TimeInterval) -> Void)?

        public init() {}

        public func makeView(url: URL, options: KSOptions) -> UIView {
            if let playerLayer {
                if playerLayer.url == url {
                    return playerLayer.player.view
                }
                playerLayer.delegate = nil
                playerLayer.set(url: url, options: options)
                playerLayer.delegate = self
                return playerLayer.player.view
            } else {
                let playerLayer = KSComplexPlayerLayer(url: url, options: options, delegate: self)
                self.playerLayer = playerLayer
                return playerLayer.player.view
            }
        }

        public func resetPlayer() {
            onStateChanged = nil
            onPlay = nil
            onFinish = nil
            onBufferChanged = nil
            playerLayer = nil
            delayHide?.cancel()
            delayHide = nil
        }

        public func skip(interval: Int) {
            if let playerLayer {
                seek(time: playerLayer.player.currentPlaybackTime + TimeInterval(interval))
            }
        }

        public func seek(time: TimeInterval) {
            playerLayer?.seek(time: TimeInterval(time))
        }

        @MainActor
        public func mask(show: Bool, autoHide: Bool = true) {
            isMaskShow = show
            if show {
                delayHide?.cancel()
                // 播放的时候才自动隐藏
                if state == .bufferFinished, autoHide {
                    delayHide = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        if self.state == .bufferFinished {
                            self.isMaskShow = false
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + KSOptions.animateDelayTimeInterval,
                                                  execute: delayHide!)
                }
            }
            #if os(macOS)
            show ? NSCursor.unhide() : NSCursor.setHiddenUntilMouseMoves(true)
            if let view = playerLayer?.player.view, let window = view.window, !window.styleMask.contains(.fullScreen) {
                if show {
                    window.standardWindowButton(.closeButton)?.superview?.superview?.isHidden = false
                } else {
                    // 因为光标处于状态栏的时候，onHover就会返回false了，所以要自己计算
                    let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
                    if !view.frame.contains(point) {
                        window.standardWindowButton(.closeButton)?.superview?.superview?.isHidden = true
                    }
                }
                //                    window.standardWindowButton(.zoomButton)?.isHidden = !show
                //                    window.standardWindowButton(.closeButton)?.isHidden = !show
                //                    window.standardWindowButton(.miniaturizeButton)?.isHidden = !show
                //                    window.titleVisibility = show ? .visible : .hidden
            }
            #endif
        }
    }
}

extension KSVideoPlayer.Coordinator: KSPlayerLayerDelegate {
    public func player(layer: KSPlayerLayer, state: KSPlayerState) {
        onStateChanged?(layer, state)
        if state == .readyToPlay {
            playbackRate = layer.player.playbackRate
        } else if state == .bufferFinished {
            mask(show: true)
        } else {
//            if state != .preparing, !isMaskShow {
//                mask(show: true)
//            }
        }
    }

    public func player(layer _: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        onPlay?(currentTime, totalTime)
        guard var current = Int(exactly: ceil(currentTime)), var total = Int(exactly: ceil(totalTime)) else {
            return
        }
        current = max(0, current)
        total = max(0, total)
        if timemodel.currentTime != current {
            timemodel.currentTime = current
        }
        if total == 0 {
            timemodel.totalTime = timemodel.currentTime
        } else {
            if timemodel.totalTime != total {
                timemodel.totalTime = total
            }
        }
    }

    public func player(layer: KSPlayerLayer, finish error: Error?) {
        onFinish?(layer, error)
    }

    public func player(layer _: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {
        onBufferChanged?(bufferedCount, consumeTime)
    }
}

extension KSVideoPlayer: Equatable {
    public static func == (lhs: KSVideoPlayer, rhs: KSVideoPlayer) -> Bool {
        lhs.url == rhs.url
    }
}

@MainActor
public extension KSVideoPlayer {
    func onBufferChanged(_ handler: @escaping (Int, TimeInterval) -> Void) -> Self {
        coordinator.onBufferChanged = handler
        return self
    }

    /// Playing to the end.
    func onFinish(_ handler: @escaping (KSPlayerLayer, Error?) -> Void) -> Self {
        coordinator.onFinish = handler
        return self
    }

    func onPlay(_ handler: @escaping (TimeInterval, TimeInterval) -> Void) -> Self {
        coordinator.onPlay = handler
        return self
    }

    /// Playback status changes, such as from play to pause.
    func onStateChanged(_ handler: @escaping (KSPlayerLayer, KSPlayerState) -> Void) -> Self {
        coordinator.onStateChanged = handler
        return self
    }
}

extension View {
    func then(_ body: (inout Self) -> Void) -> Self {
        var result = self
        body(&result)
        return result
    }
}

/// 这是一个频繁变化的model。View要少用这个
public class ControllerTimeModel: ObservableObject {
    // 改成int才不会频繁更新
    @Published
    public var currentTime = 0
    @Published
    public var totalTime = 1
}
