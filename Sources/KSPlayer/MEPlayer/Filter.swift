//
//  Filter.swift
//  KSPlayer
//
//  Created by kintan on 2021/8/7.
//

import Foundation
import Libavfilter
import Libavutil

class MEFilter {
    private var graph: UnsafeMutablePointer<AVFilterGraph>?
    private var bufferSrcContext: UnsafeMutablePointer<AVFilterContext>?
    private var bufferSinkContext: UnsafeMutablePointer<AVFilterContext>?
    var filters: String?
    let timebase: Timebase
    private var format = Int32(0)
    private var height = Int32(0)
    private var width = Int32(0)
    private let nominalFrameRate: Float
    deinit {
        graph?.pointee.opaque = nil
        avfilter_graph_free(&graph)
    }

    public init(timebase: Timebase, nominalFrameRate: Float, options: KSOptions) {
        graph = avfilter_graph_alloc()
        graph?.pointee.opaque = Unmanaged.passUnretained(options).toOpaque()
        self.timebase = timebase
        self.nominalFrameRate = nominalFrameRate
    }

    private func setup(filters: String, params: UnsafeMutablePointer<AVBufferSrcParameters>?, isVideo: Bool) -> Bool {
        var inputs = avfilter_inout_alloc()
        var outputs = avfilter_inout_alloc()
        var ret = avfilter_graph_parse2(graph, filters, &inputs, &outputs)
        guard ret >= 0, let graph, let inputs, let outputs else {
            avfilter_inout_free(&inputs)
            avfilter_inout_free(&outputs)
            return false
        }
        let bufferSink = avfilter_get_by_name(isVideo ? "buffersink" : "abuffersink")
        ret = avfilter_graph_create_filter(&bufferSinkContext, bufferSink, "out", nil, nil, graph)
        guard ret >= 0 else { return false }
        ret = avfilter_link(outputs.pointee.filter_ctx, UInt32(outputs.pointee.pad_idx), bufferSinkContext, 0)
        guard ret >= 0 else { return false }
        let buffer = avfilter_get_by_name(isVideo ? "buffer" : "abuffer")
        bufferSrcContext = avfilter_graph_alloc_filter(graph, buffer, "in")
        guard bufferSrcContext != nil else { return false }
        av_buffersrc_parameters_set(bufferSrcContext, params)
        ret = avfilter_init_str(bufferSrcContext, nil)
        guard ret >= 0 else { return false }
        ret = avfilter_link(bufferSrcContext, 0, inputs.pointee.filter_ctx, UInt32(inputs.pointee.pad_idx))
        guard ret >= 0 else { return false }
//        if let ctx = params?.pointee.hw_frames_ctx {
//            let framesCtxData = UnsafeMutableRawPointer(ctx.pointee.data).bindMemory(to: AVHWFramesContext.self, capacity: 1)
//            inputs.pointee.filter_ctx.pointee.hw_device_ctx = framesCtxData.pointee.device_ref
//                    outputs.pointee.filter_ctx.pointee.hw_device_ctx = framesCtxData.pointee.device_ref
//                    bufferSrcContext?.pointee.hw_device_ctx = framesCtxData.pointee.device_ref
//                    bufferSinkContext?.pointee.hw_device_ctx = framesCtxData.pointee.device_ref
//        }
        ret = avfilter_graph_config(graph, nil)
        guard ret >= 0 else { return false }
        return true
    }

    private func setup2(filters: String, params: UnsafeMutablePointer<AVBufferSrcParameters>?, isVideo: Bool) -> Bool {
        guard let graph else {
            return false
        }
        let bufferName = isVideo ? "buffer" : "abuffer"
        let bufferSrc = avfilter_get_by_name(bufferName)
        var ret = avfilter_graph_create_filter(&bufferSrcContext, bufferSrc, "ksplayer_\(bufferName)", params?.pointee.arg, nil, graph)
        av_buffersrc_parameters_set(bufferSrcContext, params)
        let bufferSink = avfilter_get_by_name(bufferName + "sink")
        ret = avfilter_graph_create_filter(&bufferSinkContext, bufferSink, "ksplayer_\(bufferName)sink", nil, nil, graph)
        guard ret >= 0 else { return false }
        //        av_opt_set_int_list(bufferSinkContext, "pix_fmts", [AV_PIX_FMT_GRAY8, AV_PIX_FMT_NONE] AV_PIX_FMT_NONE,AV_OPT_SEARCH_CHILDREN)
        var inputs = avfilter_inout_alloc()
        var outputs = avfilter_inout_alloc()
        outputs?.pointee.name = strdup("in")
        outputs?.pointee.filter_ctx = bufferSrcContext
        outputs?.pointee.pad_idx = 0
        outputs?.pointee.next = nil
        inputs?.pointee.name = strdup("out")
        inputs?.pointee.filter_ctx = bufferSinkContext
        inputs?.pointee.pad_idx = 0
        inputs?.pointee.next = nil
        let filterNb = Int(graph.pointee.nb_filters)
        ret = avfilter_graph_parse_ptr(graph, filters, &inputs, &outputs, nil)
        guard ret >= 0 else {
            avfilter_inout_free(&inputs)
            avfilter_inout_free(&outputs)
            return false
        }
        for i in 0 ..< Int(graph.pointee.nb_filters) - filterNb {
            swap(&graph.pointee.filters[i], &graph.pointee.filters[i + filterNb])
        }
        ret = avfilter_graph_config(graph, nil)
        guard ret >= 0 else { return false }
        return true
    }

    public func filter(options: KSOptions, inputFrame: UnsafeMutablePointer<AVFrame>, isVideo: Bool, completionHandler: (UnsafeMutablePointer<AVFrame>) -> Void) {
        let filters: String
        if isVideo {
            filters = options.videoFilters.joined(separator: ",")
        } else {
            filters = options.audioFilters.joined(separator: ",")
        }
        guard !filters.isEmpty else {
            completionHandler(inputFrame)
            return
        }
        if format != inputFrame.pointee.format || height != inputFrame.pointee.height || width != inputFrame.pointee.width || self.filters != filters {
            format = inputFrame.pointee.format
            width = inputFrame.pointee.width
            height = inputFrame.pointee.height
            self.filters = filters
            var params = av_buffersrc_parameters_alloc()
            params?.pointee.format = inputFrame.pointee.format
            params?.pointee.time_base = timebase.rational
            params?.pointee.width = inputFrame.pointee.width
            params?.pointee.height = inputFrame.pointee.height
            params?.pointee.sample_aspect_ratio = inputFrame.pointee.sample_aspect_ratio
            params?.pointee.frame_rate = AVRational(num: 1, den: Int32(nominalFrameRate))
            params?.pointee.sample_rate = inputFrame.pointee.sample_rate
            params?.pointee.ch_layout = inputFrame.pointee.ch_layout
            if let ctx = inputFrame.pointee.hw_frames_ctx {
                params?.pointee.hw_frames_ctx = ctx
            }
            let result = setup(filters: filters, params: params, isVideo: isVideo)
            av_freep(&params)
            if !result {
                completionHandler(inputFrame)
                return
            }
        }
        let duration = inputFrame.pointee.duration
        let ret = av_buffersrc_add_frame_flags(bufferSrcContext, inputFrame, 0)
        if ret < 0 {
            return
        }
        while av_buffersink_get_frame_flags(bufferSinkContext, inputFrame, 0) >= 0 {
            if !isVideo {
                inputFrame.pointee.duration = duration
            }
            completionHandler(inputFrame)
            // 一定要加av_frame_unref，不然会内存泄漏。
            av_frame_unref(inputFrame)
        }
    }
}
