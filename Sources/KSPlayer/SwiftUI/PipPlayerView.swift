//
//  PipPlayerView.swift
//  KSPlayer
//
//  Created by kintan on 11/4/24.
//

import Foundation
import SwiftUI

@available(iOS 15.0, macOS 12.0, tvOS 15.0, *)
public struct PipPlayerView: View {
    private let playerLayer: KSPlayerLayer
    @Binding
    private var alignment: Alignment
    private let block: (Bool) -> Void
    @FocusState
    private var focusableView: FocusableView?
    public init(playerLayer: KSPlayerLayer, alignment: Binding<Alignment>, focusableView: FocusState<FocusableView?>, block: @escaping (Bool) -> Void) {
        self.playerLayer = playerLayer
        _alignment = alignment
        _focusableView = focusableView
        self.block = block
    }

    public var body: some View {
        KSVideoPlayer(playerLayer: playerLayer)
            .overlay {
                HStack {
                    Button {
                        block(true)
                    } label: {
                        Image(systemName: "pip.exit")
                    }
                    Button {
                        block(false)
                    } label: {
                        Image(systemName: "x.circle.fill")
                    }
                    Button {
                        if alignment == .topTrailing {
                            alignment = .bottomTrailing
                        } else if alignment == .bottomTrailing {
                            alignment = .bottomLeading
                        } else if alignment == .bottomLeading {
                            alignment = .topLeading
                        } else {
                            alignment = .topTrailing
                        }
                    } label: {
                        switch alignment {
                        case .topTrailing:
                            return Image(systemName: "inset.filled.toptrailing.rectangle")
                        case .bottomLeading:
                            return Image(systemName: "inset.filled.bottomleading.rectangle")
                        case .bottomTrailing:
                            return Image(systemName: "inset.filled.bottomtrailing.rectangle")
                        default:
                            return Image(systemName: "inset.filled.topleading.rectangle")
                        }
                    }
                }
                .focused($focusableView, equals: .pip)
                .opacity(focusableView == .pip ? 1 : 0)
            }
    }

    public enum FocusableView {
        case main, pip
    }
}
