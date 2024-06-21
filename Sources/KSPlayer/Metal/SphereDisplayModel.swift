//
//  SphereDisplayModel.swift
//
//
//  Created by kintan on 6/21/24.
//

import Foundation
import Metal
import simd
#if canImport(UIKit)
import UIKit
#endif
@MainActor
public class SphereDisplayModel: DisplayEnum {
    private lazy var yuvSphere = MetalRender.makePipelineState(fragmentFunction: "displayYUVTexture", isSphere: true)
    private lazy var yuvp010LESphere = MetalRender.makePipelineState(fragmentFunction: "displayYUVTexture", isSphere: true, bitDepth: 10)
    private lazy var nv12Sphere = MetalRender.makePipelineState(fragmentFunction: "displayNV12Texture", isSphere: true)
    private lazy var p010LESphere = MetalRender.makePipelineState(fragmentFunction: "displayNV12Texture", isSphere: true, bitDepth: 10)
    private lazy var bgraSphere = MetalRender.makePipelineState(fragmentFunction: "displayTexture", isSphere: true)
    public let isSphere: Bool = true
    private var fingerRotationX = Float(0)
    private var fingerRotationY = Float(0)
    fileprivate var modelViewMatrix = matrix_identity_float4x4
    let indexCount: Int
    let indexType = MTLIndexType.uint16
    let primitiveType = MTLPrimitiveType.triangle
    let indexBuffer: MTLBuffer
    let posBuffer: MTLBuffer?
    let uvBuffer: MTLBuffer?
    init() {
        let (indices, positions, uvs) = SphereDisplayModel.genSphere()
        let device = MetalRender.device
        indexCount = indices.count
        indexBuffer = device.makeBuffer(bytes: indices, length: MemoryLayout<UInt16>.size * indexCount)!
        posBuffer = device.makeBuffer(bytes: positions, length: MemoryLayout<simd_float4>.size * positions.count)
        uvBuffer = device.makeBuffer(bytes: uvs, length: MemoryLayout<simd_float2>.size * uvs.count)
        #if canImport(UIKit) && canImport(CoreMotion)
        if KSOptions.enableSensor {
            MotionSensor.shared.start()
        }
        #endif
    }

    public func pipeline(pixelBuffer: PixelBufferProtocol) -> MTLRenderPipelineState {
        let planeCount = pixelBuffer.planeCount
        let bitDepth = pixelBuffer.bitDepth
        switch planeCount {
        case 3:
            if bitDepth == 10 {
                return yuvp010LESphere
            } else {
                return yuvSphere
            }
        case 2:
            if bitDepth == 10 {
                return p010LESphere
            } else {
                return nv12Sphere
            }
        default:
            return bgraSphere
        }
    }

    public func set(frame: VideoVTBFrame, encoder: MTLRenderCommandEncoder) {
        let state = pipeline(pixelBuffer: frame.pixelBuffer)
        encoder.setRenderPipelineState(state)
        MetalRender.setFragmentBuffer(encoder: encoder, pixelBuffer: frame.pixelBuffer)
        encoder.setFrontFacing(.clockwise)
        encoder.setVertexBuffer(posBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(uvBuffer, offset: 0, index: 1)
        #if canImport(UIKit) && canImport(CoreMotion)
        if KSOptions.enableSensor, let matrix = MotionSensor.shared.matrix() {
            modelViewMatrix = matrix
        }
        #endif
    }

    @MainActor
    public func touchesMoved(touch: UITouch) {
        #if canImport(UIKit)
        let view = touch.view
        #else
        let view: UIView? = nil
        #endif
        var distX = Float(touch.location(in: view).x - touch.previousLocation(in: view).x)
        var distY = Float(touch.location(in: view).y - touch.previousLocation(in: view).y)
        distX *= 0.005
        distY *= 0.005
        fingerRotationX -= distY * 60 / 100
        fingerRotationY -= distX * 60 / 100
        modelViewMatrix = matrix_identity_float4x4.rotateX(radians: fingerRotationX).rotateY(radians: fingerRotationY)
    }

    func reset() {
        fingerRotationX = 0
        fingerRotationY = 0
        modelViewMatrix = matrix_identity_float4x4
    }

    private static func genSphere() -> ([UInt16], [simd_float4], [simd_float2]) {
        let slicesCount = UInt16(200)
        let parallelsCount = slicesCount / 2
        let indicesCount = Int(slicesCount) * Int(parallelsCount) * 6
        var indices = [UInt16](repeating: 0, count: indicesCount)
        var positions = [simd_float4]()
        var uvs = [simd_float2]()
        var runCount = 0
        let radius = Float(1.0)
        let step = (2.0 * Float.pi) / Float(slicesCount)
        var i = UInt16(0)
        while i <= parallelsCount {
            var j = UInt16(0)
            while j <= slicesCount {
                let vertex0 = radius * sinf(step * Float(i)) * cosf(step * Float(j))
                let vertex1 = radius * cosf(step * Float(i))
                let vertex2 = radius * sinf(step * Float(i)) * sinf(step * Float(j))
                let vertex3 = Float(1.0)
                let vertex4 = Float(j) / Float(slicesCount)
                let vertex5 = Float(i) / Float(parallelsCount)
                positions.append([vertex0, vertex1, vertex2, vertex3])
                uvs.append([vertex4, vertex5])
                if i < parallelsCount, j < slicesCount {
                    indices[runCount] = i * (slicesCount + 1) + j
                    runCount += 1
                    indices[runCount] = UInt16((i + 1) * (slicesCount + 1) + j)
                    runCount += 1
                    indices[runCount] = UInt16((i + 1) * (slicesCount + 1) + (j + 1))
                    runCount += 1
                    indices[runCount] = UInt16(i * (slicesCount + 1) + j)
                    runCount += 1
                    indices[runCount] = UInt16((i + 1) * (slicesCount + 1) + (j + 1))
                    runCount += 1
                    indices[runCount] = UInt16(i * (slicesCount + 1) + (j + 1))
                    runCount += 1
                }
                j += 1
            }
            i += 1
        }
        return (indices, positions, uvs)
    }
}

public class VRDisplayModel: SphereDisplayModel {
    private let modelViewProjectionMatrix: simd_float4x4

    override required init() {
        let size = KSOptions.sceneSize
        let aspect = Float(size.width / size.height)
        let projectionMatrix = simd_float4x4(perspective: Float.pi / 3, aspect: aspect, nearZ: 0.1, farZ: 400.0)
        let viewMatrix = simd_float4x4(lookAt: SIMD3<Float>.zero, center: [0, 0, -1000], up: [0, 1, 0])
        modelViewProjectionMatrix = projectionMatrix * viewMatrix
        super.init()
    }

    override public func set(frame: VideoVTBFrame, encoder: MTLRenderCommandEncoder) {
        super.set(frame: frame, encoder: encoder)
        var matrix = modelViewProjectionMatrix * modelViewMatrix
        let matrixBuffer = MetalRender.device.makeBuffer(bytes: &matrix, length: MemoryLayout<simd_float4x4>.size)
        encoder.setVertexBuffer(matrixBuffer, offset: 0, index: 2)
        encoder.drawIndexedPrimitives(type: primitiveType, indexCount: indexCount, indexType: indexType, indexBuffer: indexBuffer, indexBufferOffset: 0)
    }
}

public class VRBoxDisplayModel: SphereDisplayModel {
    private let modelViewProjectionMatrixLeft: simd_float4x4
    private let modelViewProjectionMatrixRight: simd_float4x4
    override required init() {
        let size = KSOptions.sceneSize
        let aspect = Float(size.width / size.height) / 2
        let viewMatrixLeft = simd_float4x4(lookAt: [-0.012, 0, 0], center: [0, 0, -1000], up: [0, 1, 0])
        let viewMatrixRight = simd_float4x4(lookAt: [0.012, 0, 0], center: [0, 0, -1000], up: [0, 1, 0])
        let projectionMatrix = simd_float4x4(perspective: Float.pi / 3, aspect: aspect, nearZ: 0.1, farZ: 400.0)
        modelViewProjectionMatrixLeft = projectionMatrix * viewMatrixLeft
        modelViewProjectionMatrixRight = projectionMatrix * viewMatrixRight
        super.init()
    }

    override public func set(frame: VideoVTBFrame, encoder: MTLRenderCommandEncoder) {
        super.set(frame: frame, encoder: encoder)
        let layerSize = KSOptions.sceneSize
        let width = Double(layerSize.width / 2)
        [(modelViewProjectionMatrixLeft, MTLViewport(originX: 0, originY: 0, width: width, height: Double(layerSize.height), znear: 0, zfar: 0)),
         (modelViewProjectionMatrixRight, MTLViewport(originX: width, originY: 0, width: width, height: Double(layerSize.height), znear: 0, zfar: 0))].forEach { modelViewProjectionMatrix, viewport in
            encoder.setViewport(viewport)
            var matrix = modelViewProjectionMatrix * modelViewMatrix
            let matrixBuffer = MetalRender.device.makeBuffer(bytes: &matrix, length: MemoryLayout<simd_float4x4>.size)
            encoder.setVertexBuffer(matrixBuffer, offset: 0, index: 2)
            encoder.drawIndexedPrimitives(type: primitiveType, indexCount: indexCount, indexType: indexType, indexBuffer: indexBuffer, indexBufferOffset: 0)
        }
    }
}
