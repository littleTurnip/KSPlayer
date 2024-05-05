import CoreGraphics
import libass

/// Find all the linked images from an `ASS_Image`.
///
/// - Parameters:
///   - image: First image from the list.
///
/// - Returns: A  list of `ASS_Image` that should be combined to produce
/// a final image ready to be drawn on the screen.
public func linkedImages(from image: ASS_Image) -> [ASS_Image] {
    var allImages: [ASS_Image] = []
    var currentImage: ASS_Image? = image
    while let image = currentImage {
        allImages.append(image)
        currentImage = image.next?.pointee
    }

    return allImages
}

/// Find the bounding rect of all linked images.
///
/// - Parameters:
///   - images: Images list to find the bounding rect for.
///
/// - Returns: A `CGRect` containing all image rectangles.
public func imagesBoundingRect(images: [ASS_Image]) -> CGRect {
    let imagesRect = images.map(\.imageRect)
    guard let minX = imagesRect.map(\.minX).min(),
          let minY = imagesRect.map(\.minY).min(),
          let maxX = imagesRect.map(\.maxX).max(),
          let maxY = imagesRect.map(\.maxY).max() else { return .zero }

    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

/// Creates a RGBA bytes buffer from an `ASS_Image`.
///
/// - Parameters:
///   - image: The image to process.
///
/// - Returns: A  new RGBA bytes buffer based on the `ASS_Image` bitmap.
///
/// The `ASS_Image` only contains a monochrome alpha channel bitmap and a color.
/// In order to combine all images and produce a palettized image, first all monochrome bitmaps
/// need to be converted into palettized RGBA bitmaps, and then combined into a
/// final RGBA image by alpha blending the images one by one.
public func palettizedBitmapRGBA(_ image: ASS_Image) -> UnsafeMutableBufferPointer<UInt8>? {
    palettizedBitmap(image) { buffer, position, red, green, blue, alpha in
        buffer[position + 0] = red
        buffer[position + 1] = green
        buffer[position + 2] = blue
        buffer[position + 3] = alpha
    }
}

/// Creates a ARGB bytes buffer from an `ASS_Image`.
///
/// - Parameters:
///   - image: The image to process.
///
/// - Returns: A  new RGBA bytes buffer based on the `ASS_Image` bitmap.
///
/// The `ASS_Image` only contains a monochrome alpha channel bitmap and a color.
/// In order to combine all images and produce a palettized image, first all monochrome bitmaps
/// need to be converted into palettized RGBA bitmaps, and then combined into a
/// final RGBA image by alpha blending the images one by one.
public func palettizedBitmapARGB(_ image: ASS_Image) -> UnsafeMutableBufferPointer<UInt8>? {
    palettizedBitmap(image) { buffer, position, red, green, blue, alpha in
        buffer[position + 0] = alpha
        buffer[position + 1] = red
        buffer[position + 2] = green
        buffer[position + 3] = blue
    }
}

/// Creates a bytes buffer from an `ASS_Image`.
///
/// - Parameters:
///   - image: The image to process.
///   - fillPixel: Closure to set the pixel bytes at the given position.
///
/// - Returns: A  new bytes buffer based on the `ASS_Image` bitmap.
///
/// The `ASS_Image` only contains a monochrome alpha channel bitmap and a color.
/// In order to combine all images and produce a palettized image, first all monochrome bitmaps
/// need to be converted into palettized RGBA bitmaps, and then combined into a
/// final RGBA image by alpha blending the images one by one.
public func palettizedBitmap(
    _ image: ASS_Image,
    fillPixel: (
        _ buffer: UnsafeMutableBufferPointer<UInt8>,
        _ position: Int,
        _ red: UInt8,
        _ green: UInt8,
        _ blue: UInt8,
        _ alpha: UInt8
    ) -> Void
) -> UnsafeMutableBufferPointer<UInt8>? {
    if image.w == 0 || image.h == 0 { return nil }

    let width = Int(image.w)
    let height = Int(image.h)
    let stride = Int(image.stride)

    let red = UInt8((image.color >> 24) & 0xFF)
    let green = UInt8((image.color >> 16) & 0xFF)
    let blue = UInt8((image.color >> 8) & 0xFF)
    let alpha = 255 - UInt8(image.color & 0xFF)

    let bufferCapacity = 4 * width * height
    let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: bufferCapacity)

    var bufferPosition = 0
    var bitmapPosition = 0

    loop(iterations: height) { _ in
        loop(iterations: width) { xPosition in
            let alphaValue = image.bitmap.advanced(by: bitmapPosition + xPosition).pointee
            let normalizedAlpha = Int(alphaValue) * Int(alpha) / 255
            fillPixel(buffer, bufferPosition, red, green, blue, UInt8(normalizedAlpha))
            bufferPosition += 4
        }
        bitmapPosition += stride
    }

    return buffer
}

// This is more performant than for in loop 🤷‍♂️
private func loop(iterations: Int, body: (Int) -> Void) {
    var index = 0
    while index < iterations {
        body(index)
        index += 1
    }
}
