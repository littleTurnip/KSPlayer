//
//  Slider.swift
//  KSPlayer
//
//  Created by kintan on 2023/5/4.
//

import SwiftUI

#if os(tvOS)
import Combine

@available(tvOS 15.0, *)
public struct Slider: View {
    private let value: Binding<Float>
    private let bounds: ClosedRange<Float>
    private let onEditingChanged: (Bool) -> Void
    @FocusState
    private var isFocused: Bool
    public init(value: Binding<Float>, in bounds: ClosedRange<Float> = 0 ... 1, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.value = value
        self.bounds = bounds
        self.onEditingChanged = onEditingChanged
    }

    public var body: some View {
        TVOSSlide(value: value, bounds: bounds, isFocused: _isFocused, onEditingChanged: onEditingChanged)
            .focused($isFocused)
    }
}

@available(tvOS 15.0, *)
public struct TVOSSlide: UIViewRepresentable {
    fileprivate let value: Binding<Float>
    fileprivate let bounds: ClosedRange<Float>
    @FocusState
    public var isFocused: Bool
    public let onEditingChanged: (Bool) -> Void
    public typealias UIViewType = TVSlide
    public func makeUIView(context _: Context) -> UIViewType {
        TVSlide(value: value, bounds: bounds, onEditingChanged: onEditingChanged)
    }

    public func updateUIView(_ view: UIViewType, context _: Context) {
        if isFocused {
            if view.processView.tintColor == .white {
                view.processView.tintColor = .red
            }
        } else {
            view.processView.tintColor = .white
            view.cancle()
        }
        // 要加这个才会触发进度条更新
        let process = (value.wrappedValue - bounds.lowerBound) / (bounds.upperBound - bounds.lowerBound)
        if process != view.processView.progress {
            view.processView.progress = process
        }
    }
}

public class TVSlide: UIControl {
    fileprivate let processView = UIProgressView()
    private var beganValue: Float
    private let onEditingChanged: (Bool) -> Void
    fileprivate var value: Binding<Float>
    fileprivate let ranges: ClosedRange<Float>
    private var moveDirection: UISwipeGestureRecognizer.Direction?
    private var pressTime = CACurrentMediaTime()

    private lazy var timer: Timer = .scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
        guard let self, let moveDirection = self.moveDirection else {
            return
        }
        let rate = min(10, Int((CACurrentMediaTime() - self.pressTime) / 2) + 1)
        let wrappedValue = self.value.wrappedValue + Float((moveDirection == .right ? 10 : -10) * rate)
        if wrappedValue >= self.ranges.lowerBound, wrappedValue <= self.ranges.upperBound {
            self.value.wrappedValue = wrappedValue
        }
    }

    public init(value: Binding<Float>, bounds: ClosedRange<Float>, onEditingChanged: @escaping (Bool) -> Void) {
        self.value = value
        beganValue = value.wrappedValue
        ranges = bounds
        self.onEditingChanged = onEditingChanged
        super.init(frame: .zero)
        processView.translatesAutoresizingMaskIntoConstraints = false
        processView.tintColor = .white
        addSubview(processView)
        NSLayoutConstraint.activate([
            processView.topAnchor.constraint(equalTo: topAnchor),
            processView.leadingAnchor.constraint(equalTo: leadingAnchor),
            processView.trailingAnchor.constraint(equalTo: trailingAnchor),
            processView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let panGestureRecognizer = UIPanGestureRecognizer(target: self, action: #selector(actionPanGesture(sender:)))
        addGestureRecognizer(panGestureRecognizer)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func cancle() {
        timer.fireDate = Date.distantFuture
    }

    override open func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let presse = presses.first else {
            return
        }
        switch presse.type {
        case .leftArrow:
            moveDirection = .left
            pressTime = CACurrentMediaTime()
            onEditingChanged(true)
            timer.fireDate = Date.distantPast
        case .rightArrow:
            moveDirection = .right
            pressTime = CACurrentMediaTime()
            onEditingChanged(true)
            timer.fireDate = Date.distantPast
        case .select:
            timer.fireDate = Date.distantFuture
            onEditingChanged(false)
        default:
            timer.fireDate = Date.distantFuture
            onEditingChanged(false)
            super.pressesBegan(presses, with: event)
        }
    }

    @objc private func actionPanGesture(sender: UIPanGestureRecognizer) {
        let translation = sender.translation(in: self)
        if abs(translation.y) > abs(translation.x) {
            return
        }
        switch sender.state {
        case .began, .possible:
            timer.fireDate = Date.distantFuture
            beganValue = value.wrappedValue
            onEditingChanged(true)
        case .changed:
            let wrappedValue = beganValue + Float(translation.x) / Float(frame.size.width) * (ranges.upperBound - ranges.lowerBound) / 5
            if wrappedValue <= ranges.upperBound, wrappedValue >= ranges.lowerBound {
                value.wrappedValue = wrappedValue
            }
        case .ended:
            beganValue = value.wrappedValue
            onEditingChanged(false)
        case .cancelled, .failed:
//            value.wrappedValue = beganValue
            break
        @unknown default:
            break
        }
    }
}
#endif
