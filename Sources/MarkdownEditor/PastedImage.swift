import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Helpers for image blobs arriving through `EditorBridge.onPasteImage`.
public enum PastedImage {

    /// Default cap applied by the app to pasted / dropped images.
    public static let defaultMaxWidth = 512

    /// Shrink `data` so its pixel width is at most `maxWidth`, preserving
    /// aspect ratio and EXIF orientation. Images already narrow enough —
    /// and formats we won't re-encode (animated GIF, SVG) — come back
    /// untouched. JPEG stays JPEG; everything else is re-encoded as PNG,
    /// and the returned `mime` reflects that so the caller picks the
    /// right extension.
    public static func downscaled(_ data: Data, mime: String, maxWidth: Int)
        -> (data: Data, mime: String)
    {
        let lower = mime.lowercased()
        guard maxWidth > 0, !data.isEmpty,
              lower != "image/gif", lower != "image/svg+xml" else {
            return (data, mime)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawW = props[kCGImagePropertyPixelWidth] as? Int,
              let rawH = props[kCGImagePropertyPixelHeight] as? Int,
              rawW > 0, rawH > 0 else {
            return (data, mime)
        }
        // EXIF orientation 5–8 swap width and height on display; we scale
        // the displayed width, which is what the user sees as "too wide".
        let orientation = (props[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let rotated = orientation >= 5
        let width = rotated ? rawH : rawW
        let height = rotated ? rawW : rawH
        guard width > maxWidth else { return (data, mime) }

        // ImageIO caps the *larger* dimension; derive the cap that lands
        // the width at `maxWidth` (floor keeps it ≤ maxWidth for tall images).
        let maxPixel = max(1, Int(Double(max(width, height)) * Double(maxWidth) / Double(width)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return (data, mime)
        }

        let isJPEG = lower == "image/jpeg" || lower == "image/jpg"
        let outType: UTType = isJPEG ? .jpeg : .png
        let outMime = isJPEG ? "image/jpeg" : "image/png"
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, outType.identifier as CFString, 1, nil) else {
            return (data, mime)
        }
        var destProps: [CFString: Any] = [:]
        if isJPEG { destProps[kCGImageDestinationLossyCompressionQuality] = 0.85 }
        CGImageDestinationAddImage(dest, scaled, destProps as CFDictionary)
        guard CGImageDestinationFinalize(dest), out.length > 0 else {
            return (data, mime)
        }
        return (out as Data, outMime)
    }
}
