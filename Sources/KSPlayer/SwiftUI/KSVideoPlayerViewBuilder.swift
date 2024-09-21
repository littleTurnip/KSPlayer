//
//  KSVideoPlayerViewBuilder.swift
//
//
//  Created by Ian Magallan Bosch on 17.03.24.
//

import SwiftUI

@available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
@MainActor
public enum KSVideoPlayerViewBuilder {
    @ViewBuilder
    static func contentModeButton(config: KSVideoPlayer.Coordinator) -> some View {
        Button {
            config.isScaleAspectFill.toggle()
        } label: {
            Image(systemName: config.isScaleAspectFill ? "rectangle.arrowtriangle.2.inward" : "rectangle.arrowtriangle.2.outward")
        }
    }

    @ViewBuilder
    static func subtitleButton(config: KSVideoPlayer.Coordinator) -> some View {
        MenuView(selection: Binding {
            config.playerLayer?.subtitleModel.selectedSubtitleInfo?.subtitleID
        } set: { value in
            let info = config.playerLayer?.subtitleModel.subtitleInfos.first { $0.subtitleID == value }
            // 需要先调用select(track。 因为里面判断了isEnabled
            if let info = info as? MediaPlayerTrack {
                // 因为图片字幕想要实时的显示，那就需要seek。所以需要走select track
                config.playerLayer?.player.select(track: info)
            }
            config.playerLayer?.subtitleModel.selectedSubtitleInfo = info
        }) {
            Text("Off").tag(nil as String?)
            ForEach(config.playerLayer?.subtitleModel.subtitleInfos ?? [], id: \.subtitleID) { track in
                Text(track.name).tag(track.subtitleID as String?)
            }
        } label: {
            Image(systemName: "text.bubble.fill")
        }
    }

    @ViewBuilder
    static func playbackRateButton(playbackRate: Binding<Float>) -> some View {
        MenuView(selection: playbackRate) {
            ForEach([0.5, 1.0, 1.25, 1.5, 2.0] as [Float]) { value in
                // 需要有一个变量text。不然会自动帮忙加很多0
                let text = "\(value) x"
                Text(text).tag(value)
            }
        } label: {
            Image(systemName: "gauge.with.dots.needle.67percent")
        }
    }

    @ViewBuilder
    static func titleView(title: String, config: KSVideoPlayer.Coordinator) -> some View {
        Group {
            Text(title)
                .font(.headline)
            ProgressView()
                .opacity(config.state == .buffering ? 1 : 0)
        }
    }

    @ViewBuilder
    static func muteButton(config: KSVideoPlayer.Coordinator) -> some View {
        Button {
            config.isMuted.toggle()
        } label: {
            Image(systemName: config.isMuted ? speakerDisabledSystemName : speakerSystemName)
        }
    }

    @ViewBuilder
    static func infoButton(showVideoSetting: Binding<Bool>) -> some View {
        Button {
            showVideoSetting.wrappedValue.toggle()
        } label: {
            Image(systemName: "info.circle.fill")
        }
        // iOS 模拟器加keyboardShortcut会导致KSVideoPlayer.Coordinator无法释放。真机不会有这个问题
        #if !os(tvOS)
        .keyboardShortcut("i", modifiers: [.command])
        #endif
    }

    @ViewBuilder
    static func recordButton(config: KSVideoPlayer.Coordinator) -> some View {
        Button {
            config.isRecord.toggle()
        } label: {
            Image(systemName: "video.circle")
                .foregroundColor(config.isRecord ? .red : .white)
        }
    }
}

@available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
public extension KSVideoPlayerViewBuilder {
    static var speakerSystemName: String {
        #if os(xrOS) || os(macOS)
        "speaker.fill"
        #else
        "speaker.wave.2.circle.fill"
        #endif
    }

    static var speakerDisabledSystemName: String {
        #if os(xrOS) || os(macOS)
        "speaker.slash.fill"
        #else
        "speaker.slash.circle.fill"
        #endif
    }

    @ViewBuilder
    static func backwardButton(config: KSVideoPlayer.Coordinator) -> some View {
        if config.playerLayer?.player.seekable ?? false {
            Button {
                config.skip(interval: -15)
            } label: {
                Image(systemName: "gobackward.15")
            }
            #if !os(tvOS)
            .keyboardShortcut(.leftArrow, modifiers: .none)
            #endif
        }
    }

    @ViewBuilder
    static func forwardButton(config: KSVideoPlayer.Coordinator) -> some View {
        if config.playerLayer?.player.seekable ?? false {
            Button {
                config.skip(interval: 15)
            } label: {
                Image(systemName: "goforward.15")
            }
            #if !os(tvOS)
            .keyboardShortcut(.rightArrow, modifiers: .none)
            #endif
        }
    }

    @ViewBuilder
    static func playButton(config: KSVideoPlayer.Coordinator) -> some View {
        Button {
            if config.state.isPlaying {
                config.playerLayer?.pause()
            } else {
                config.playerLayer?.play()
            }
        } label: {
            Image(systemName: config.state.systemName)
        }
        #if os(xrOS)
        .contentTransition(.symbolEffect(.replace))
        #endif
        #if !os(tvOS)
        .keyboardShortcut(.space, modifiers: .none)
        #endif
    }
}

extension KSPlayerState {
    var systemName: String {
        if self == .error {
            return "play.slash.fill"
        } else if self == .playedToTheEnd {
            #if os(xrOS) || os(macOS)
            return "restart.circle"
            #else
            return "restart.circle.fill"
            #endif
        } else if isPlaying {
            #if os(xrOS) || os(macOS)
            return "pause.fill"
            #else
            return "pause.circle.fill"
            #endif
        } else {
            #if os(xrOS) || os(macOS)
            return "play.fill"
            #else
            return "play.circle.fill"
            #endif
        }
    }
}

extension View {
    func onKeyPressLeftArrow(action: @escaping () -> Void) -> some View {
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, *) {
            return onKeyPress(.leftArrow) {
                action()
                return .handled
            }
        } else {
            return self
        }
    }

    func onKeyPressRightArrow(action: @escaping () -> Void) -> some View {
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, *) {
            return onKeyPress(.rightArrow) {
                action()
                return .handled
            }
        } else {
            return self
        }
    }

    func onKeyPressSapce(action: @escaping () -> Void) -> some View {
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, *) {
            return onKeyPress(.space) {
                action()
                return .handled
            }
        } else {
            return self
        }
    }

    func allowedDynamicRange() -> some View {
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, *) {
            return self.allowedDynamicRange(KSOptions.subtitleDynamicRange)
        } else {
            return self
        }
    }

    #if !os(tvOS)
    func textSelection() -> some View {
        if #available(iOS 15.0, macOS 12.0, *) {
            return self.textSelection(.enabled)
        } else {
            return self
        }
    }
    #endif

    func italic(value: Bool) -> some View {
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, *) {
            return self.italic(value)
        } else {
            return self
        }
    }

    func ksIgnoresSafeArea() -> some View {
        if #available(iOS 14.0, macOS 11.0, tvOS 14.0, *) {
            return self.ignoresSafeArea()
        } else {
            return self
        }
    }
}
