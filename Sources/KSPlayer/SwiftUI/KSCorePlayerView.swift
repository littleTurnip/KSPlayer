//
//  KSCorePlayerView.swift
//  KSPlayer
//
//  Created by kintan on 11/30/24.
//

import Foundation
import SwiftUI

@available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
public struct KSCorePlayerView: View {
    @StateObject
    private var config: KSVideoPlayer.Coordinator
    public let url: URL
    public let options: KSOptions
    @State
    private var title: String
    private let subtitleDataSource: SubtitleDataSource?
    public init(config: KSVideoPlayer.Coordinator, url: URL, options: KSOptions, title: State<String>, subtitleDataSource: SubtitleDataSource?) {
        _config = .init(wrappedValue: config)
        self.url = url
        self.options = options
        _title = title
        self.subtitleDataSource = subtitleDataSource
    }

    public var body: some View {
        KSVideoPlayer(coordinator: config, url: url, options: options)
            .onStateChanged { playerLayer, state in
                if state == .readyToPlay {
                    if let subtitleDataSource {
                        config.playerLayer?.subtitleModel.addSubtitle(dataSource: subtitleDataSource)
                    }
                    if let movieTitle = playerLayer.player.dynamicInfo?.metadata["title"] {
                        title = movieTitle
                    }
                }
            }
            .onBufferChanged { bufferedCount, consumeTime in
                KSLog("bufferedCount \(bufferedCount), consumeTime \(consumeTime)")
            }
        #if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
            .translationView()
        #endif
            .ignoresSafeArea()

        #if os(iOS) || os(xrOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        #if !os(iOS)
        .focusable(!config.isMaskShow)
        #endif
        #if !os(xrOS)
        .onKeyPressLeftArrow {
            config.skip(interval: -15)
        }
        .onKeyPressRightArrow {
            config.skip(interval: 15)
        }
        .onKeyPressSapce {
            if config.state.isPlaying {
                config.playerLayer?.pause()
            } else {
                config.playerLayer?.play()
            }
        }
        #endif
        #if os(macOS)
        .navigationTitle(title)
        .onTapGesture(count: 2) {
            guard let view = config.playerLayer?.player.view else {
                return
            }
            view.window?.toggleFullScreen(nil)
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
        }
        .onExitCommand {
            config.playerLayer?.player.view.exitFullScreenMode()
        }
        .onMoveCommand { direction in
            switch direction {
            case .left:
                config.skip(interval: -15)
            case .right:
                config.skip(interval: 15)
            case .up:
                config.playerLayer?.player.playbackVolume += 0.2
            case .down:
                config.playerLayer?.player.playbackVolume -= 0.2
            @unknown default:
                break
            }
        }
        #endif
    }
}
