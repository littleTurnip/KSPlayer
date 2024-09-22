//
//  EmbedDataSource.swift
//  KSPlayer-7de52535
//
//  Created by kintan on 2018/8/7.
//
import Foundation
import Libavcodec
import Libavutil

extension FFmpegAssetTrack: SubtitleInfo {
    public var subtitleID: String {
        String(trackID)
    }
}

extension FFmpegAssetTrack: KSSubtitleProtocol {
    public func search(for time: TimeInterval, size: CGSize, isHDR: Bool) async -> [SubtitlePart] {
        if let subtitleRender {
            return await subtitleRender.search(for: time, size: size, isHDR: isHDR)
        }
        let parts = subtitle?.outputRenderQueue.search { item -> Bool in
            item.part.isEqual(time: time)
        }.map(\.part)
        if let parts {
            /// pgssub字幕会没有结束时间，所以会插入空的字幕，但是空的字幕有可能跟非空的字幕在同一个数组里面
            /// 这样非空字幕就无法清除了。所以这边需要更新下字幕的结束时间。（字幕有进行了排序了）
            var prePart: SubtitlePart?
            for part in parts {
                if let prePart, prePart.end == .infinity {
                    prePart.end = part.start
                }
                prePart = part
                if let left = part.render.left {
                    // 图片字幕的比例可能跟视频的比例不一致，所以需要对图片的大小进行伸缩下
                    var hZoom = size.width / left.displaySize.width
                    var vZoom = size.height / left.displaySize.height
                    var newRect = left.rect * (hZoom, vZoom)
                    part.render = .left(SubtitleImageInfo(rect: newRect, image: left.image, displaySize: size))
                }
            }
            return parts
        }
        return []
    }
}

extension KSMEPlayer: EmbedSubtitleDataSource {
    public var infos: [FFmpegAssetTrack] {
        tracks(mediaType: .subtitle).compactMap { $0 as? FFmpegAssetTrack }
    }
}
