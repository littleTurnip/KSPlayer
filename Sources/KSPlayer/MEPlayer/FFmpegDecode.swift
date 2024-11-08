//
//  FFmpegDecode.swift
//  KSPlayer
//
//  Created by kintan on 2018/3/9.
//

import AVFoundation
import FFmpegKit
import Foundation
import Libavcodec

class FFmpegDecode: DecodeProtocol {
    private let options: KSOptions
    private var coreFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var bestEffortTimestamp = Int64(0)
    private let frameChange: FrameChange
    private let filter: MEFilter
    private let seekByBytes: Bool
    private var hasDecodeSuccess = false
    private let isVideo: Bool
    // 因为seek之后，frame可能不会带有doviData，所以需要保存起来，下次使用。
    private var doviData: dovi_metadata? = nil
    required init(assetTrack: FFmpegAssetTrack, options: KSOptions) {
        self.options = options
        seekByBytes = assetTrack.seekByBytes
        do {
            codecContext = try assetTrack.createContext(options: options)
        } catch {
            KSLog(error as CustomStringConvertible)
        }
        codecContext?.pointee.time_base = assetTrack.timebase.rational
        isVideo = assetTrack.mediaType == .video
        filter = MEFilter(timebase: assetTrack.timebase, nominalFrameRate: assetTrack.nominalFrameRate, options: options)
        if isVideo {
            frameChange = VideoSwresample(fps: assetTrack.nominalFrameRate, isDovi: assetTrack.dovi != nil)
        } else {
            frameChange = AudioSwresample(audioDescriptor: assetTrack.audioDescriptor!)
        }
    }

    func decodeFrame(from packet: Packet, completionHandler: @escaping (Result<MEFrame, Error>) -> Void) {
        guard let codecContext else {
            return
        }
        let status = avcodec_send_packet(codecContext, packet.corePacket)
        if status != 0 {
            /**
              有些视频(.m2ts)seek完之后, 就会一直报错，重新createContext，也是会报错一段时间。转为软解就不会报错一段时间了。
              发现在seek的时候不要调用avcodec_flush_buffers就能解决这个问题。
              经过实验还是不能转为软解，因为有的视频软解的话，会发烫严重。
              所以视频卡顿一段还是可以接受的。并且可以用异步硬解，就可以解决这个问题了
              如果在这里createContext的话，会导致内存泄漏，所以先不createContext了
              硬解前后台切换的话，视频会报错-1313558101
              频繁seek的话，音频会报错-1094995529
             如果之前一直都没有成功过的话，那就需要切换成软解
             视频报错AVError.tryAgain.code的话，也不要转为软解。因为dovi解码有可能返回这个错。如果
              **/
            if isVideo, !hasDecodeSuccess {
                avcodec_free_context(&self.codecContext)
                options.hardwareDecode = false
                self.codecContext = try? packet.assetTrack.createContext(options: options)
                avcodec_send_packet(codecContext, packet.corePacket)
            } else {
                avcodec_flush_buffers(codecContext)
                return
            }
        }
        guard let codecContext = self.codecContext else {
            return
        }
        // 需要avcodec_send_packet之后，properties的值才会变成FF_CODEC_PROPERTY_CLOSED_CAPTIONS
        if isVideo {
            if Int32(codecContext.pointee.properties) & FF_CODEC_PROPERTY_CLOSED_CAPTIONS != 0, packet.assetTrack.closedCaptionsTrack == nil {
                var codecpar = AVCodecParameters()
                codecpar.codec_type = AVMEDIA_TYPE_SUBTITLE
                codecpar.codec_id = AV_CODEC_ID_EIA_608
                if let subtitleAssetTrack = FFmpegAssetTrack(codecpar: codecpar) {
                    subtitleAssetTrack.name = "Closed Captions"
                    subtitleAssetTrack.startTime = packet.assetTrack.startTime
                    subtitleAssetTrack.timebase = packet.assetTrack.timebase
                    let subtitle = SyncPlayerItemTrack<SubtitleFrame>(mediaType: .subtitle, frameCapacity: 255, options: options)
                    subtitleAssetTrack.subtitle = subtitle
                    packet.assetTrack.closedCaptionsTrack = subtitleAssetTrack
                    subtitle.decode()
                }
            }
        }
        var success = false
        while true {
            let result = avcodec_receive_frame(codecContext, coreFrame)
            // 有的音频视频可以多次调用avcodec_receive_frame，所以不能第一次成功就直接return
            if result == 0, let inputFrame = coreFrame {
                success = true
                hasDecodeSuccess = true
                decodeFrame(inputFrame: inputFrame, packet: packet, completionHandler: completionHandler)
            } else {
                if result == swift_AVERROR_EOF {
                    avcodec_flush_buffers(codecContext)
                    return
                } else if result == AVError.tryAgain.code {
                    // png封面需要多次调用avcodec_send_packet才能显示封面.其他格式的不要加这个处理。
                    if !hasDecodeSuccess, packet.assetTrack.isImage {
                        let status = avcodec_send_packet(codecContext, packet.corePacket)
                        if status != 0 {
                            return
                        }
                    } else {
                        return
                    }
                } else {
                    // 当前的packet有解决成功过，那就直接返回
                    if success {
                        return
                    }
                    let error = NSError(errorCode: isVideo ? .codecVideoReceiveFrame : .codecAudioReceiveFrame, avErrorCode: result)
                    KSLog(error)
                    if isVideo, options.hardwareDecode {
                        // 在这里做下兜底，转为软解
                        avcodec_free_context(&self.codecContext)
                        options.hardwareDecode = false
                        self.codecContext = try? packet.assetTrack.createContext(options: options)
                    } else {
                        completionHandler(.failure(error))
                    }
                    return
                }
            }
        }
    }

    private func decodeFrame(inputFrame: UnsafeMutablePointer<AVFrame>, packet: Packet, completionHandler: @escaping (Result<MEFrame, Error>) -> Void) {
        var displayData: MasteringDisplayMetadata?
        var contentData: ContentLightMetadata?
        var ambientViewingEnvironment: AmbientViewingEnvironment?
        // filter之后，side_data信息会丢失，所以放在这里
        if inputFrame.pointee.nb_side_data > 0 {
            for i in 0 ..< inputFrame.pointee.nb_side_data {
                if let sideData = inputFrame.pointee.side_data[Int(i)]?.pointee {
                    if sideData.type == AV_FRAME_DATA_A53_CC {
                        if let closedCaptionsTrack = packet.assetTrack.closedCaptionsTrack,
                           let subtitle = closedCaptionsTrack.subtitle
                        {
                            let closedCaptionsPacket = Packet()
                            if let corePacket = packet.corePacket {
                                closedCaptionsPacket.corePacket?.pointee.pts = corePacket.pointee.pts
                                closedCaptionsPacket.corePacket?.pointee.dts = corePacket.pointee.dts
                                closedCaptionsPacket.corePacket?.pointee.pos = corePacket.pointee.pos
                                closedCaptionsPacket.corePacket?.pointee.time_base = corePacket.pointee.time_base
                                closedCaptionsPacket.corePacket?.pointee.stream_index = corePacket.pointee.stream_index
                            }
                            closedCaptionsPacket.corePacket?.pointee.flags |= AV_PKT_FLAG_KEY
                            closedCaptionsPacket.corePacket?.pointee.size = Int32(sideData.size)
                            let buffer = av_buffer_ref(sideData.buf)
                            closedCaptionsPacket.corePacket?.pointee.data = buffer?.pointee.data
                            closedCaptionsPacket.corePacket?.pointee.buf = buffer
                            closedCaptionsPacket.assetTrack = closedCaptionsTrack
                            subtitle.putPacket(packet: closedCaptionsPacket)
                        }
                    } else if sideData.type == AV_FRAME_DATA_SEI_UNREGISTERED {
                        let size = sideData.size
                        if size > AV_UUID_LEN {
                            let str = String(cString: sideData.data.advanced(by: Int(AV_UUID_LEN)))
                            options.sei(string: str)
                        }
                    } else if sideData.type == AV_FRAME_DATA_DYNAMIC_HDR_PLUS { // AVDynamicHDRPlus
                        let data = sideData.data.withMemoryRebound(to: AVDynamicHDRPlus.self, capacity: 1) { $0 }.pointee
                    } else if sideData.type == AV_FRAME_DATA_DYNAMIC_HDR_VIVID { // AVDynamicHDRVivid
                        let data = sideData.data.withMemoryRebound(to: AVDynamicHDRVivid.self, capacity: 1) { $0 }.pointee
                    } else if sideData.type == AV_FRAME_DATA_MASTERING_DISPLAY_METADATA {
                        let data = sideData.data.withMemoryRebound(to: AVMasteringDisplayMetadata.self, capacity: 1) { $0 }.pointee
                        displayData = MasteringDisplayMetadata(
                            display_primaries_r_x: UInt16(truncatingIfNeeded: data.display_primaries.0.0.num),
                            display_primaries_r_y: UInt16(truncatingIfNeeded: data.display_primaries.0.1.num),
                            display_primaries_g_x: UInt16(truncatingIfNeeded: data.display_primaries.1.0.num),
                            display_primaries_g_y: UInt16(truncatingIfNeeded: data.display_primaries.1.1.num),
                            display_primaries_b_x: UInt16(truncatingIfNeeded: data.display_primaries.2.1.num),
                            display_primaries_b_y: UInt16(truncatingIfNeeded: data.display_primaries.2.1.num),
                            white_point_x: UInt16(truncatingIfNeeded: data.white_point.0.num),
                            white_point_y: UInt16(truncatingIfNeeded: data.white_point.1.num),
                            minLuminance: UInt32(truncatingIfNeeded: data.min_luminance.num),
                            maxLuminance: UInt32(truncatingIfNeeded: data.max_luminance.num)
                        )
                    } else if sideData.type == AV_FRAME_DATA_CONTENT_LIGHT_LEVEL {
                        let data = sideData.data.withMemoryRebound(to: AVContentLightMetadata.self, capacity: 1) { $0 }.pointee
                        contentData = ContentLightMetadata(
                            MaxCLL: UInt16(data.MaxCLL),
                            MaxFALL: UInt16(data.MaxFALL)
                        )
                    } else if sideData.type == AV_FRAME_DATA_AMBIENT_VIEWING_ENVIRONMENT {
                        let data = sideData.data.withMemoryRebound(to: AVAmbientViewingEnvironment.self, capacity: 1) { $0 }.pointee
                        ambientViewingEnvironment = AmbientViewingEnvironment(
                            ambient_illuminance: UInt32(truncatingIfNeeded: data.ambient_illuminance.num),
                            ambient_light_x: UInt16(truncatingIfNeeded: data.ambient_light_x.num),
                            ambient_light_y: UInt16(truncatingIfNeeded: data.ambient_light_y.num)
                        )
                    } else if sideData.type == AV_FRAME_DATA_DOVI_RPU_BUFFER {
                        let data = sideData.data.withMemoryRebound(to: [UInt8].self, capacity: 1) { $0 }
                    } else if sideData.type == AV_FRAME_DATA_DOVI_METADATA {
                        let data = sideData.data.withMemoryRebound(to: AVDOVIMetadata.self, capacity: 1) { $0 }
                        doviData = map_dovi_metadata(data).pointee
                    }
                }
            }
        }
        filter.filter(options: options, inputFrame: inputFrame, isVideo: isVideo) { avframe in
            do {
                if isVideo {
                    options.decodeType = avframe.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue ? .hardware : .soft
                }
                var frame = try frameChange.change(avframe: avframe)
                if let videoFrame = frame as? VideoVTBFrame {
                    if displayData != nil || contentData != nil || ambientViewingEnvironment != nil {
                        videoFrame.edrMetaData = EDRMetaData(displayData: displayData, contentData: contentData, ambientViewingEnvironment: ambientViewingEnvironment)
                    }
                    videoFrame.doviData = doviData
                    if let pixelBuffer = videoFrame.pixelBuffer as? PixelBuffer {
                        pixelBuffer.formatDescription = packet.assetTrack.formatDescription
                    }
                }
                frame.timebase = filter.timebase
                //                frame.timebase = Timebase(avframe.pointee.time_base)
                frame.size = packet.size
                frame.position = packet.position
                frame.duration = avframe.pointee.duration
                if frame.duration == 0, avframe.pointee.sample_rate != 0, frame.timebase.num != 0 {
                    frame.duration = Int64(avframe.pointee.nb_samples) * Int64(frame.timebase.den) / (Int64(avframe.pointee.sample_rate) * Int64(frame.timebase.num))
                }
                var timestamp = avframe.pointee.best_effort_timestamp
                // 音频倍速有可能会出现相邻两个帧时间戳一样的情况。所以这里做一下判断。为了不影响正常的播放，所以加下filter的判断
                if !isVideo, filter.filters != nil, timestamp > 0, timestamp + frame.duration == bestEffortTimestamp {
                    timestamp += frame.duration
                }
                if timestamp < 0 {
                    timestamp = avframe.pointee.pts
                }
                if timestamp < 0 {
                    timestamp = avframe.pointee.pkt_dts
                }
                if timestamp < 0 {
                    timestamp = bestEffortTimestamp
                }
                frame.timestamp = timestamp
                bestEffortTimestamp = timestamp &+ frame.duration
                completionHandler(.success(frame))
            } catch {
                completionHandler(.failure(error))
            }
        }
    }

    func doFlushCodec() {
        bestEffortTimestamp = Int64(0)
        // seek之后要清空下，不然解码可能还会有缓存，导致返回的数据是之前seek的。并且ts格式会导致画面花屏一小会儿。
        if codecContext != nil {
            avcodec_flush_buffers(codecContext)
        }
    }

    func shutdown() {
        av_frame_free(&coreFrame)
        avcodec_free_context(&codecContext)
        frameChange.shutdown()
    }

    func decode() {
        bestEffortTimestamp = Int64(0)
        if codecContext != nil {
            avcodec_flush_buffers(codecContext)
        }
    }
}
