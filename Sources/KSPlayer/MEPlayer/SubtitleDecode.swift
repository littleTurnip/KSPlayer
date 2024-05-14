//
//  SubtitleDecode.swift
//  KSPlayer
//
//  Created by kintan on 2018/3/11.
//

import CoreGraphics
import Foundation
import Libavformat
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
class SubtitleDecode: DecodeProtocol {
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private let scale = VideoSwresample(dstFormat: AV_PIX_FMT_ARGB, isDovi: false)
    private var subtitle = AVSubtitle()
    private var startTime = TimeInterval(0)
    private var assParse: AssParse? = nil
    private var assImageRenderer: AssImageRenderer? = nil
    required init(assetTrack: FFmpegAssetTrack, options: KSOptions) {
        startTime = assetTrack.startTime.seconds
        do {
            codecContext = try assetTrack.createContext(options: options)
            if let codecContext, let pointer = codecContext.pointee.subtitle_header {
                if #available(iOS 16.0, tvOS 16.0, visionOS 1.0, macOS 13.0, macCatalyst 16.0, *), KSOptions.isASSUseImageRender {
                    assImageRenderer = AssImageRenderer()
                    assetTrack.assImageRenderer = assImageRenderer
                    Task {
                        await assImageRenderer?.subtitle(header: pointer, size: codecContext.pointee.subtitle_header_size)
                    }
                } else {
                    let subtitleHeader = String(cString: pointer)
                    let assParse = AssParse()
                    if assParse.canParse(scanner: Scanner(string: subtitleHeader)) {
                        self.assParse = assParse
                    }
                }
            }
        } catch {
            KSLog(error as CustomStringConvertible)
        }
    }

    func decode() {}

    func decodeFrame(from packet: Packet, completionHandler: @escaping (Result<MEFrame, Error>) -> Void) {
        guard let codecContext else {
            return
        }
        var gotsubtitle = Int32(0)
        _ = avcodec_decode_subtitle2(codecContext, &subtitle, &gotsubtitle, packet.corePacket)
        if gotsubtitle == 0 {
            return
        }
        let timestamp = packet.timestamp
        var start = packet.assetTrack.timebase.cmtime(for: timestamp).seconds + TimeInterval(subtitle.start_display_time) / 1000.0
        if start >= startTime {
            start -= startTime
        }
        var duration = 0.0
        if subtitle.end_display_time != UInt32.max {
            duration = TimeInterval(subtitle.end_display_time - subtitle.start_display_time) / 1000.0
        }
        if duration == 0, packet.duration != 0 {
            duration = packet.assetTrack.timebase.cmtime(for: packet.duration).seconds
        }
        let end: TimeInterval
        if duration == 0 {
            end = .infinity
        } else {
            end = start + duration
        }
        var parts = text(subtitle: subtitle, start: start, end: end)
        /// 不用preSubtitleFrame来进行更新end。而是插入一个空的字幕来更新字幕。
        /// 因为字幕有可能不按顺序解码。这样就会导致end比start小，然后这个字幕就不会被清空了。
        if assImageRenderer == nil, parts.isEmpty {
            parts.append(SubtitlePart(start, end, ""))
        }
        for part in parts {
            let frame = SubtitleFrame(part: part, timebase: packet.assetTrack.timebase)
            frame.timestamp = timestamp
            completionHandler(.success(frame))
        }
        avsubtitle_free(&subtitle)
    }

    func doFlushCodec() {}

    func shutdown() {
        scale.shutdown()
        avsubtitle_free(&subtitle)
        if let codecContext {
            avcodec_close(codecContext)
            avcodec_free_context(&self.codecContext)
        }
    }

    private func text(subtitle: AVSubtitle, start: TimeInterval, end: TimeInterval) -> [any SubtitlePartProtocol] {
        var parts = [any SubtitlePartProtocol]()
        var images = [(CGRect, CGImage)]()
        var origin: CGPoint = .zero
        var attributedString: NSMutableAttributedString?
        for i in 0 ..< Int(subtitle.num_rects) {
            guard let rect = subtitle.rects[i]?.pointee else {
                continue
            }
            if i == 0 {
                origin = CGPoint(x: Int(rect.x), y: Int(rect.y))
            }
            if let text = rect.text {
                if attributedString == nil {
                    attributedString = NSMutableAttributedString()
                }
                attributedString?.append(NSAttributedString(string: String(cString: text)))
            } else if let ass = rect.ass {
                if let assImageRenderer {
                    Task {
                        await assImageRenderer.add(subtitle: ass, size: Int32(strlen(ass)), start: Int64(start * 1000), duration: Int64((end - start) * 1000))
                    }
                } else if let assParse {
                    let scanner = Scanner(string: String(cString: ass))
                    if let group = assParse.parsePart(scanner: scanner) {
                        group.start = start
                        group.end = end
                        parts.append(group)
                    }
                }
            } else if rect.type == SUBTITLE_BITMAP {
                if let image = scale.transfer(format: AV_PIX_FMT_PAL8, width: rect.w, height: rect.h, data: Array(tuple: rect.data), linesize: Array(tuple: rect.linesize))?.cgImage() {
                    images.append((CGRect(x: Int(rect.x), y: Int(rect.y), width: Int(rect.w), height: Int(rect.h)), image))
                }
            }
        }
        if images.count > 0, let image = CGImage.combine(images: images)?.image() {
            if images.count > 1 {
                origin = .zero
            }
            // 因为字幕需要有透明度,所以不能用jpg；tif在iOS支持没有那么好，会有绿色背景； 用heic格式，展示的时候会卡主线程；所以最终用png。
            let part = SubtitlePart(start, end, image: (origin, image))
            parts.append(part)
        }
        if let attributedString {
            parts.append(SubtitlePart(start, end, attributedString: attributedString))
        }
        return parts
    }
}
