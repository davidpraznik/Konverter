import SwiftUI
import Combine
import AppKit
import Compression
import CoreText
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import ServiceManagement
import libwebp

@main
struct KonverterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @ObservedObject private var updates = UpdateChecker.shared

    var body: some Scene {
        MenuBarExtra {
            if let v = updates.available, let url = updates.releaseURL {
                Button("Update available: \(v)…") {
                    NSWorkspace.shared.open(url)
                }
                Divider()
            }
            Button("Settings…") {
                appDelegate.showSettings()
            }
            .keyboardShortcut(",")
            Divider()
            Button("Quit Konverter") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            if updates.available != nil {
                Image(nsImage: UpdateChecker.badgedIcon())
            } else {
                Image("MenuIcon")
            }
        }
    }
}

// MARK: - Oblika: barve, pisava

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

struct Palette {
    let disk: Color
    let wedge: Color
    let wedgeDim: Color
    let text: Color
    let textDim: Color
    let track: Color
    let progress: Color
    let accent = Color(hex: 0x6D4AFF)
    let ink = Color.white

    init(_ scheme: ColorScheme) {
        if scheme == .dark {
            disk = Color(hex: 0x23262D)
            wedge = Color(hex: 0x353A44)
            wedgeDim = Color(hex: 0x2B2F37)
            text = Color(hex: 0xE9ECF1)
            textDim = Color(hex: 0x9AA3AF)
            track = Color(hex: 0x454A55)
            progress = Color(hex: 0xA792FF)
        } else {
            disk = Color(hex: 0xDEE3E7)
            wedge = Color(hex: 0xFFFFFF)
            wedgeDim = Color(hex: 0xF1F3F5)
            text = Color(hex: 0x16202A)
            textDim = Color(hex: 0x55606B)
            track = Color(hex: 0xC3CBD2)
            progress = Color(hex: 0x3C288C)
        }
    }
}

func registerFonts() {
    if let url = Bundle.main.url(forResource: "Inter-SemiBold", withExtension: "ttf") {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

func inter(_ size: CGFloat) -> Font {
    Font.custom("Inter-SemiBold", size: size)
}

// MARK: - Formati

enum ImageFormat: String, CaseIterable, Identifiable {
    case png = "PNG", webp = "WEBP", jpg = "JPG", avif = "AVIF", heic = "HEIC", pdf = "PDF", tiff = "TIFF", bmp = "BMP"
    var id: String { rawValue }

    var ext: String { self == .jpg ? "jpg" : rawValue.lowercased() }

    var typeIdentifier: String? {
        switch self {
        case .png: return "public.png"
        case .jpg: return "public.jpeg"
        case .heic: return "public.heic"
        case .avif: return "public.avif"
        case .pdf: return "com.adobe.pdf"
        case .tiff: return "public.tiff"
        case .bmp: return "com.microsoft.bmp"
        case .webp: return nil
        }
    }
}

enum VideoFormat: String, CaseIterable, Identifiable {
    case mp4 = "MP4", gif = "GIF", m4a = "M4A"
    var id: String { rawValue }
    var ext: String { rawValue.lowercased() }
}

enum Tool: String, CaseIterable {
    case web = "FOR WEB"
    case strip = "STRIP METADATA"

    var formats: String {
        switch self {
        case .web:
            return WebSettings.maxSide == 0 ? "SAME SIZE" : "TO \(WebSettings.maxSide) PX"
        case .strip: return "JPG · PNG\nHEIC · WEBP"
        }
    }

    // Naslov na kolesu, daljši je v dveh vrsticah, da ne uide iz izseka
    var title: String {
        self == .strip ? "STRIP\nMETADATA" : rawValue
    }
}

enum WheelMode {
    case convert, tools
}

enum Target: Hashable {
    case image(ImageFormat)
    case video(VideoFormat)
    case tool(Tool)

    var label: String {
        switch self {
        case .image(let f): return f.rawValue
        case .video(let f): return f.rawValue
        case .tool(let t): return t.rawValue
        }
    }

    // krajša oznaka za sredino kolesa
    var shortLabel: String {
        if case .tool(.strip) = self { return "STRIP" }
        return label
    }
}

enum FileKind {
    case image, video

    var targets: [Target] {
        switch self {
        case .image: return ImageFormat.allCases.map { Target.image($0) }
        case .video: return VideoFormat.allCases.map { Target.video($0) }
        }
    }
}

// MARK: - Pretvorba

enum Converter {
    nonisolated static func kind(of url: URL) -> FileKind? {
        guard let t = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return .video }
        if t.conforms(to: .image) { return .image }
        return nil
    }

    nonisolated static func format(of url: URL) -> Target? {
        switch url.pathExtension.lowercased() {
        case "png": return .image(.png)
        case "webp": return .image(.webp)
        case "jpg", "jpeg": return .image(.jpg)
        case "avif": return .image(.avif)
        case "heic", "heif": return .image(.heic)
        case "pdf": return .image(.pdf)
        case "tiff", "tif": return .image(.tiff)
        case "bmp": return .image(.bmp)
        case "mp4": return .video(.mp4)
        case "gif": return .video(.gif)
        default: return nil
        }
    }

    nonisolated static func uniqueURL(for source: URL, ext: String, suffix: String = "") -> URL {
        let dir = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent + suffix
        var candidate = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var i = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) (\(i))").appendingPathExtension(ext)
            i += 1
        }
        return candidate
    }

    nonisolated static func convert(_ url: URL, to target: Target) -> Bool {
        switch target {
        case .image(let f):
            guard kind(of: url) == .image else { return false }
            return convertImage(url, to: f)
        case .video(let f):
            guard kind(of: url) == .video else { return false }
            return convertVideo(url, to: f)
        case .tool(let t):
            guard kind(of: url) == .image else { return false }
            switch t {
            case .web: return webImage(url)
            case .strip: return stripMetadata(url)
            }
        }
    }

    // MARK: Orodja (kolo Command)

    nonisolated private static func encode(_ source: CGImageSource, to dest: URL, type: String, quality: Double, keepMetadata: Bool, maxSide: Int = 0) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(dest as CFURL, type as CFString, 1, nil) else { return false }
        var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if keepMetadata {
            // Pri pomanjšanju slike ne zasukamo: orientacijska oznaka ostane, da se ujema z gain map
            if let small = downscaled(source, maxSide: maxSide, applyOrientation: false) {
                if var props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                    props.removeValue(forKey: kCGImagePropertyPixelWidth)
                    props.removeValue(forKey: kCGImagePropertyPixelHeight)
                    if var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                        exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
                        exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
                        props[kCGImagePropertyExifDictionary] = exif
                    }
                    for (k, v) in props { options[k] = v }
                    options[kCGImageDestinationLossyCompressionQuality] = quality
                }
                CGImageDestinationAddImage(destination, small, options as CFDictionary)
            } else {
                CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
            }
            // HDR gain map (iPhone fotografije) ImageIO sam ne prenese, brez nje je slika temnejša
            if let gain = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) {
                CGImageDestinationAddAuxiliaryDataInfo(destination, kCGImageAuxiliaryDataTypeHDRGainMap, gain)
            }
        } else {
            guard let image = loadImage(source) else { return false }
            CGImageDestinationAddImage(destination, image, options as CFDictionary)
        }
        return CGImageDestinationFinalize(destination)
    }

    // Pomanjša sliko, če je njena najdaljša stranica večja od maxSide (0 = brez omejitve)
    nonisolated private static func downscaled(_ source: CGImageSource, maxSide: Int, applyOrientation: Bool = true) -> CGImage? {
        guard maxSide > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              max(w, h) > maxSide else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: applyOrientation,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
    }

    // Datoteke, ki jih ni mogoče bolj stisniti (rezultat ni manjši od originala)
    nonisolated private static let skippedLock = NSLock()
    nonisolated(unsafe) private static var skippedValue = 0

    nonisolated static var skippedCount: Int {
        skippedLock.lock()
        defer { skippedLock.unlock() }
        return skippedValue
    }

    nonisolated static func resetSkipped() {
        skippedLock.lock()
        skippedValue = 0
        skippedLock.unlock()
    }

    nonisolated private static func noteSkipped() {
        skippedLock.lock()
        skippedValue += 1
        skippedLock.unlock()
    }

    // Skupni prihranek (v bajtih) zadnjega zagona orodja
    nonisolated private static let savedLock = NSLock()
    nonisolated(unsafe) private static var savedValue = 0

    nonisolated static var savedBytes: Int {
        savedLock.lock()
        defer { savedLock.unlock() }
        return savedValue
    }

    nonisolated static func resetSaved() {
        savedLock.lock()
        savedValue = 0
        savedLock.unlock()
    }

    nonisolated private static func noteSaved(original: Int, result: Int) {
        guard original > result else { return }
        savedLock.lock()
        savedValue += original - result
        savedLock.unlock()
    }

    nonisolated static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    // FOR WEB: v enem koraku spremeni velikost (večjo pomanjša, manjšo poveča na najdaljšo stranico),
    // po želji pretvori v sRGB in odstrani metapodatke, nato shrani s kakovostjo iz nastavitev.
    // Rezultat je ob originalu z oznako "-web".
    nonisolated private static func webImage(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return false }
        let maxSide = WebSettings.maxSide
        let longest = max(w, h)
        let base: CGImage?
        if maxSide == 0 || longest == maxSide {
            base = loadImage(source)
        } else if longest > maxSide {
            base = downscaled(source, maxSide: maxSide)
        } else {
            base = upscaled(source, maxSide: maxSide)
        }
        guard var image = base else { return false }
        if WebSettings.srgb, let converted = convertedToSRGB(image) { image = converted }

        let ext = url.pathExtension.lowercased()
        let dest = uniqueURL(for: url, ext: ext, suffix: "-web")
        let quality = WebSettings.quality
        let keep = !WebSettings.stripMetadata
        var ok = false
        switch ext {
        case "jpg", "jpeg":
            ok = writeScaled(image, from: source, to: dest, type: "public.jpeg", quality: quality.jpg, keepMetadata: keep)
        case "heic", "heif":
            ok = writeScaled(image, from: source, to: dest, type: "public.heic", quality: quality.heic, keepMetadata: keep)
        case "png":
            // PNG ostane brez izgub, brez metapodatkov
            if let data = PNGCompressor.compress(image) {
                ok = (try? data.write(to: dest)) != nil
            } else {
                ok = writeScaled(image, from: source, to: dest, type: "public.png", quality: 1.0, keepMetadata: keep)
            }
        case "webp":
            if let data = encodeWebP(image, quality: quality.webp) { ok = (try? data.write(to: dest)) != nil }
        default:
            return false
        }
        guard ok else { return false }

        // Če velikost ostane ista in datoteka ni manjša, je ne shranimo
        if maxSide == 0 || longest == maxSide {
            let before = fileSize(url)
            if before > 0 && fileSize(dest) >= before {
                try? FileManager.default.removeItem(at: dest)
                noteSkipped()
                return false
            }
        }
        noteSaved(original: fileSize(url), result: fileSize(dest))
        if WebSettings.result == .replace {
            // Original gre v koš, nova datoteka prevzame njegovo ime. Če karkoli spodleti, ostane ob originalu.
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                try FileManager.default.moveItem(at: dest, to: url)
            } catch {
                return true
            }
        }
        return true
    }

    // Pretvori barvni prostor v sRGB (barve se pretvorijo, ne le preimenujejo)
    nonisolated private static func convertedToSRGB(_ image: CGImage) -> CGImage? {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        if let current = image.colorSpace, current.name == srgb.name { return image }
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    // Poveča sliko (z upoštevano orientacijo) na najdaljšo stranico maxSide, visokokakovostna interpolacija
    nonisolated private static func upscaled(_ source: CGImageSource, maxSide: Int) -> CGImage? {
        guard let base = loadImage(source) else { return nil }
        let longest = max(base.width, base.height)
        guard longest > 0 else { return nil }
        let scale = Double(maxSide) / Double(longest)
        let w = max(1, Int((Double(base.width) * scale).rounded()))
        let h = max(1, Int((Double(base.height) * scale).rounded()))
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        var ctx: CGContext? = nil
        if let space = base.colorSpace {
            ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
        }
        if ctx == nil, let srgb = CGColorSpace(name: CGColorSpace.sRGB) {
            ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: info)
        }
        guard let context = ctx else { return nil }
        context.interpolationQuality = .high
        context.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }

    // Zapiše že obrnjeno sliko z metapodatki izvirnika (brez dimenzij in orientacije, da se ne obrne dvakrat)
    nonisolated private static func writeScaled(_ image: CGImage, from source: CGImageSource, to dest: URL, type: String, quality: Double, keepMetadata: Bool = true) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(dest as CFURL, type as CFString, 1, nil) else { return false }
        var options: [CFString: Any] = [:]
        if keepMetadata, var props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            props.removeValue(forKey: kCGImagePropertyPixelWidth)
            props.removeValue(forKey: kCGImagePropertyPixelHeight)
            props.removeValue(forKey: kCGImagePropertyProfileName)
            props[kCGImagePropertyOrientation] = 1
            if var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
                exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
                props[kCGImagePropertyExifDictionary] = exif
            }
            if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff.removeValue(forKey: kCGImagePropertyTIFFOrientation)
                props[kCGImagePropertyTIFFDictionary] = tiff
            }
            for (k, v) in props { options[k] = v }
        }
        options[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    nonisolated private static func stripMetadata(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        let ext = url.pathExtension.lowercased()
        let dest = uniqueURL(for: url, ext: ext, suffix: "-clean")
        switch ext {
        case "jpg", "jpeg":
            return encode(source, to: dest, type: "public.jpeg", quality: 0.95, keepMetadata: false)
        case "png":
            return encode(source, to: dest, type: "public.png", quality: 1.0, keepMetadata: false)
        case "heic", "heif":
            return encode(source, to: dest, type: "public.heic", quality: 0.9, keepMetadata: false)
        case "webp":
            guard let image = loadImage(source), let data = encodeWebP(image, quality: 90) else { return false }
            return (try? data.write(to: dest)) != nil
        default:
            return false
        }
    }

    // MARK: Slike

    nonisolated private static func convertImage(_ url: URL, to format: ImageFormat) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        let dest = uniqueURL(for: url, ext: format.ext)

        if format == .webp {
            guard let image = loadImage(source),
                  let data = encodeWebP(image, quality: 85) else { return false }
            do {
                try data.write(to: dest)
                return true
            } catch {
                return false
            }
        }

        guard let id = format.typeIdentifier,
              let destination = CGImageDestinationCreateWithURL(dest as CFURL, id as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        return CGImageDestinationFinalize(destination)
    }

    nonisolated private static func loadImage(_ source: CGImageSource) -> CGImage? {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let maxDim = max(w, h)
        guard maxDim > 0 else { return CGImageSourceCreateImageAtIndex(source, 0, nil) }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDim
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
    }

    nonisolated private static func encodeWebP(_ image: CGImage, quality: Float) -> Data? {
        let w = image.width
        let h = image.height
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)

        let drawn: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(
                    data: buf.baseAddress,
                    width: w,
                    height: h,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        var i = 0
        while i < pixels.count {
            let a = Int(pixels[i + 3])
            if a > 0 && a < 255 {
                pixels[i] = UInt8(min(255, Int(pixels[i]) * 255 / a))
                pixels[i + 1] = UInt8(min(255, Int(pixels[i + 1]) * 255 / a))
                pixels[i + 2] = UInt8(min(255, Int(pixels[i + 2]) * 255 / a))
            }
            i += 4
        }

        var output: UnsafeMutablePointer<UInt8>? = nil
        let size = pixels.withUnsafeBufferPointer { p in
            WebPEncodeRGBA(p.baseAddress, Int32(w), Int32(h), Int32(bytesPerRow), quality, &output)
        }
        guard size > 0, let out = output else { return nil }
        let data = Data(bytes: out, count: size)
        WebPFree(out)
        return data
    }

    // MARK: Video

    private final class ResultBox: @unchecked Sendable {
        nonisolated(unsafe) var ok = false
    }

    nonisolated private static func convertVideo(_ url: URL, to format: VideoFormat) -> Bool {
        let dest = uniqueURL(for: url, ext: format.ext)
        let box = ResultBox()
        let sem = DispatchSemaphore(value: 0)

        Task.detached(priority: .userInitiated) {
            switch format {
            case .mp4:
                box.ok = await exportVideo(url, to: dest, preset: AVAssetExportPresetHighestQuality, type: .mp4)
            case .m4a:
                box.ok = await exportVideo(url, to: dest, preset: AVAssetExportPresetAppleM4A, type: .m4a)
            case .gif:
                box.ok = await makeGIF(url, to: dest)
            }
            sem.signal()
        }
        sem.wait()
        return box.ok
    }

    nonisolated private static func exportVideo(_ url: URL, to dest: URL, preset: String, type: AVFileType) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { return false }
        do {
            try await session.export(to: dest, as: type)
            return true
        } catch {
            return false
        }
    }

    nonisolated private static func makeGIF(_ url: URL, to dest: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return false }
        let seconds = min(CMTimeGetSeconds(duration), 20)
        guard seconds.isFinite, seconds > 0 else { return false }

        let fps = 10.0
        let count = max(1, Int(seconds * fps))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)

        guard let destination = CGImageDestinationCreateWithURL(dest as CFURL, "com.compuserve.gif" as CFString, count, nil) else { return false }

        let fileProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ]
        CGImageDestinationSetProperties(destination, fileProps as CFDictionary)
        let frameProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / fps]
        ]

        var added = 0
        for i in 0..<count {
            let t = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            if let result = try? await generator.image(at: t) {
                CGImageDestinationAddImage(destination, result.image, frameProps as CFDictionary)
                added += 1
            }
        }
        guard added > 0 else { return false }
        return CGImageDestinationFinalize(destination)
    }
}

// MARK: - PNG: kvantizacija in zapis (kot TinyPNG)

struct PaletteColor {
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var a: UInt8
}

enum PNGCompressor {
    nonisolated static let maxColors = 256
    nonisolated static let ditherStrength: Float = 0.5

    private struct Entry {
        var r: UInt8
        var g: UInt8
        var b: UInt8
        var a: UInt8
        var n: UInt32
    }

    private struct Box {
        var start: Int
        var end: Int
        var channel: Int
        var range: Int
        var score: Double
    }

    nonisolated static func compress(_ image: CGImage) -> Data? {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0, let px = straightRGBA(image) else { return nil }
        let count = w * h

        var palette: [PaletteColor]
        var indices: [UInt8]
        if let exact = exactPalette(px, count: count) {
            palette = exact.palette
            indices = exact.indices
        } else {
            palette = medianCut(px, count: count)
            indices = map(px, width: w, height: h, palette: palette)
        }

        // neprosojni vnosi na konec, da je blok tRNS čim krajši
        let order = palette.indices.sorted { l, r in
            let lt = palette[l].a < 255
            let rt = palette[r].a < 255
            if lt != rt { return lt }
            return l < r
        }
        var remap = [UInt8](repeating: 0, count: palette.count)
        var sorted = [PaletteColor]()
        for (newIndex, oldIndex) in order.enumerated() {
            remap[oldIndex] = UInt8(newIndex)
            sorted.append(palette[oldIndex])
        }
        for i in 0..<indices.count { indices[i] = remap[Int(indices[i])] }

        guard let data = writePNG(width: w, height: h, palette: sorted, indices: indices) else { return nil }

        // preverimo, da je rezultat veljavna slika
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let check = CGImageSourceCreateImageAtIndex(src, 0, nil),
              check.width == w, check.height == h else { return nil }
        return data
    }

    // MARK: Piksli

    nonisolated private static func straightRGBA(_ image: CGImage) -> [UInt8]? {
        let w = image.width
        let h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(
                    data: buf.baseAddress,
                    width: w,
                    height: h,
                    bitsPerComponent: 8,
                    bytesPerRow: w * 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var i = 0
        while i < px.count {
            let a = Int(px[i + 3])
            if a > 0 && a < 255 {
                px[i] = UInt8(min(255, Int(px[i]) * 255 / a))
                px[i + 1] = UInt8(min(255, Int(px[i + 1]) * 255 / a))
                px[i + 2] = UInt8(min(255, Int(px[i + 2]) * 255 / a))
            }
            i += 4
        }
        return px
    }

    // Če ima slika največ 256 barv, ostane popolnoma enaka (brez izgube)
    nonisolated private static func exactPalette(_ px: [UInt8], count: Int) -> (palette: [PaletteColor], indices: [UInt8])? {
        var lookup = [UInt32: UInt8]()
        var palette = [PaletteColor]()
        var indices = [UInt8](repeating: 0, count: count)
        for p in 0..<count {
            let i = p * 4
            let a = px[i + 3]
            let key: UInt32 = a == 0
                ? 0
                : (UInt32(px[i]) << 24) | (UInt32(px[i + 1]) << 16) | (UInt32(px[i + 2]) << 8) | UInt32(a)
            if let idx = lookup[key] {
                indices[p] = idx
                continue
            }
            if palette.count >= maxColors { return nil }
            let idx = UInt8(palette.count)
            lookup[key] = idx
            if a == 0 {
                palette.append(PaletteColor(r: 0, g: 0, b: 0, a: 0))
            } else {
                palette.append(PaletteColor(r: px[i], g: px[i + 1], b: px[i + 2], a: a))
            }
            indices[p] = idx
        }
        return (palette, indices)
    }

    // MARK: Median cut

    nonisolated private static func value(_ e: Entry, _ channel: Int) -> Int {
        switch channel {
        case 0: return Int(e.r)
        case 1: return Int(e.g)
        case 2: return Int(e.b)
        default: return Int(e.a)
        }
    }

    nonisolated private static func makeBox(_ entries: [Entry], _ start: Int, _ end: Int) -> Box {
        var lo = [255, 255, 255, 255]
        var hi = [0, 0, 0, 0]
        var total: UInt64 = 0
        for k in start..<end {
            let e = entries[k]
            total += UInt64(e.n)
            for c in 0..<4 {
                let v = value(e, c)
                if v < lo[c] { lo[c] = v }
                if v > hi[c] { hi[c] = v }
            }
        }
        var channel = 0
        var range = 0
        for c in 0..<4 where hi[c] - lo[c] > range {
            range = hi[c] - lo[c]
            channel = c
        }
        return Box(start: start, end: end, channel: channel, range: range, score: Double(total) * Double(range))
    }

    nonisolated private static func medianCut(_ px: [UInt8], count: Int) -> [PaletteColor] {
        var hist = [UInt32](repeating: 0, count: 1 << 20)
        for p in 0..<count {
            let i = p * 4
            let key = ((Int(px[i]) >> 3) << 15) | ((Int(px[i + 1]) >> 3) << 10) | ((Int(px[i + 2]) >> 3) << 5) | (Int(px[i + 3]) >> 3)
            hist[key] += 1
        }

        var entries = [Entry]()
        for key in 0..<hist.count where hist[key] > 0 {
            let r = ((key >> 15) & 31) * 8 + 4
            let g = ((key >> 10) & 31) * 8 + 4
            let b = ((key >> 5) & 31) * 8 + 4
            let a = (key & 31) * 8 + 4
            entries.append(Entry(r: UInt8(r), g: UInt8(g), b: UInt8(b), a: UInt8(min(255, a)), n: hist[key]))
        }
        guard !entries.isEmpty else { return [PaletteColor(r: 0, g: 0, b: 0, a: 0)] }

        var boxes = [makeBox(entries, 0, entries.count)]
        while boxes.count < maxColors {
            var best = -1
            var bestScore = 0.0
            for (i, b) in boxes.enumerated() where b.end - b.start > 1 && b.range > 0 && b.score > bestScore {
                best = i
                bestScore = b.score
            }
            if best < 0 { break }
            let b = boxes[best]
            let ch = b.channel
            entries[b.start..<b.end].sort { value($0, ch) < value($1, ch) }

            var total: UInt64 = 0
            for k in b.start..<b.end { total += UInt64(entries[k].n) }
            var acc: UInt64 = 0
            var mid = b.start + 1
            for k in b.start..<(b.end - 1) {
                acc += UInt64(entries[k].n)
                mid = k + 1
                if acc * 2 >= total { break }
            }
            boxes[best] = makeBox(entries, b.start, mid)
            boxes.append(makeBox(entries, mid, b.end))
        }

        return boxes.map { b in
            var sr = 0.0, sg = 0.0, sb = 0.0, sa = 0.0, sn = 0.0
            for k in b.start..<b.end {
                let e = entries[k]
                let n = Double(e.n)
                sr += Double(e.r) * n
                sg += Double(e.g) * n
                sb += Double(e.b) * n
                sa += Double(e.a) * n
                sn += n
            }
            let a = UInt8(min(255.0, (sa / sn).rounded()))
            return PaletteColor(
                r: UInt8(min(255.0, (sr / sn).rounded())),
                g: UInt8(min(255.0, (sg / sn).rounded())),
                b: UInt8(min(255.0, (sb / sn).rounded())),
                a: a > 250 ? 255 : a
            )
        }
    }

    // MARK: Preslikava na paleto (Floyd-Steinberg)

    nonisolated private static func map(_ px: [UInt8], width w: Int, height h: Int, palette: [PaletteColor]) -> [UInt8] {
        var lut = [Int16](repeating: -1, count: 1 << 20)
        var indices = [UInt8](repeating: 0, count: w * h)
        var errCur = [Float](repeating: 0, count: (w + 2) * 3)
        var errNext = [Float](repeating: 0, count: (w + 2) * 3)
        let strength = ditherStrength

        func nearest(_ r: Int, _ g: Int, _ b: Int, _ a: Int) -> Int {
            let key = ((r >> 3) << 15) | ((g >> 3) << 10) | ((b >> 3) << 5) | (a >> 3)
            let cached = lut[key]
            if cached >= 0 { return Int(cached) }
            let cr = (r >> 3) * 8 + 4
            let cg = (g >> 3) * 8 + 4
            let cb = (b >> 3) * 8 + 4
            let ca = a
            var bestIndex = 0
            var bestDist = Int.max
            for (i, p) in palette.enumerated() {
                let dr = cr - Int(p.r)
                let dg = cg - Int(p.g)
                let db = cb - Int(p.b)
                let da = ca - Int(p.a)
                let d = dr * dr + dg * dg + db * db + da * da * 3
                if d < bestDist {
                    bestDist = d
                    bestIndex = i
                }
            }
            lut[key] = Int16(bestIndex)
            return bestIndex
        }

        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let e = (x + 1) * 3
                let a = Int(px[i + 3])
                let rf = min(255, max(0, Float(px[i]) + errCur[e]))
                let gf = min(255, max(0, Float(px[i + 1]) + errCur[e + 1]))
                let bf = min(255, max(0, Float(px[i + 2]) + errCur[e + 2]))
                let idx = nearest(Int(rf), Int(gf), Int(bf), a)
                indices[y * w + x] = UInt8(idx)

                if a > 0 {
                    let p = palette[idx]
                    let er = (rf - Float(p.r)) * strength
                    let eg = (gf - Float(p.g)) * strength
                    let eb = (bf - Float(p.b)) * strength
                    errCur[e + 3] += er * 7 / 16
                    errCur[e + 4] += eg * 7 / 16
                    errCur[e + 5] += eb * 7 / 16
                    errNext[e - 3] += er * 3 / 16
                    errNext[e - 2] += eg * 3 / 16
                    errNext[e - 1] += eb * 3 / 16
                    errNext[e] += er * 5 / 16
                    errNext[e + 1] += eg * 5 / 16
                    errNext[e + 2] += eb * 5 / 16
                    errNext[e + 3] += er / 16
                    errNext[e + 4] += eg / 16
                    errNext[e + 5] += eb / 16
                }
            }
            swap(&errCur, &errNext)
            for k in 0..<errNext.count { errNext[k] = 0 }
        }
        return indices
    }

    // MARK: Zapis PNG

    nonisolated private static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    nonisolated private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    nonisolated private static func crcChecksum(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in bytes {
            c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFFFFFF
    }

    nonisolated private static func adlerChecksum(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for v in bytes {
            a = (a + UInt32(v)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }

    nonisolated private static func zlibCompress(_ src: [UInt8]) -> [UInt8]? {
        let capacity = src.count + src.count / 8 + 1024
        var dst = [UInt8](repeating: 0, count: capacity)
        let n = compression_encode_buffer(&dst, capacity, src, src.count, nil, COMPRESSION_ZLIB)
        guard n > 0 else { return nil }
        var out: [UInt8] = [0x78, 0x9C]
        out.append(contentsOf: dst[0..<n])
        out.append(contentsOf: be32(adlerChecksum(src)))
        return out
    }

    nonisolated private static func writePNG(width w: Int, height h: Int, palette: [PaletteColor], indices: [UInt8]) -> Data? {
        var raw = [UInt8]()
        raw.reserveCapacity((w + 1) * h)
        for y in 0..<h {
            raw.append(0)
            raw.append(contentsOf: indices[(y * w)..<((y + 1) * w)])
        }
        guard let z = zlibCompress(raw) else { return nil }

        var out = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        func chunk(_ type: String, _ body: [UInt8]) {
            let t = Array(type.utf8)
            out.append(contentsOf: be32(UInt32(body.count)))
            out.append(contentsOf: t)
            out.append(contentsOf: body)
            out.append(contentsOf: be32(crcChecksum(t + body)))
        }

        chunk("IHDR", be32(UInt32(w)) + be32(UInt32(h)) + [8, 3, 0, 0, 0])
        chunk("PLTE", palette.flatMap { [$0.r, $0.g, $0.b] })
        if let last = palette.lastIndex(where: { $0.a < 255 }) {
            chunk("tRNS", palette[0...last].map { $0.a })
        }
        chunk("IDAT", z)
        chunk("IEND", [])
        return out
    }
}

// MARK: - Kolo

final class WheelModel: ObservableObject {
    @Published var message = ""
    @Published var kind: FileKind = .image
    @Published var busy = false
    @Published var chosen: Target? = nil
    @Published var progress: Double = 0
    @Published var total = 0
    @Published var disabled: Set<Target> = []
    @Published var mode: WheelMode = .convert
    @Published var sizeText = ""
}

struct Wedge: Shape {
    var center: CGFloat
    var slice: CGFloat
    var outer: CGFloat
    var inner: CGFloat
    var gap: CGFloat
    var corner: CGFloat

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let d = gap / 2 + corner
        let R = outer - corner
        let r = inner + corner
        let b0 = center - slice / 2
        let b1 = center + slice / 2

        func pt(_ theta: CGFloat, _ t: CGFloat, _ p: CGFloat) -> CGPoint {
            CGPoint(x: c.x + t * cos(theta) - p * sin(theta),
                    y: c.y + t * sin(theta) + p * cos(theta))
        }
        func ang(_ p: CGPoint) -> CGFloat { atan2(p.y - c.y, p.x - c.x) }

        let tO = (R * R - d * d).squareRoot()
        let tI = (r * r - d * d).squareRoot()
        let so = pt(b0, tO, d)
        let eo = pt(b1, tO, -d)
        let ei = pt(b1, tI, -d)
        let si = pt(b0, tI, d)

        let a0 = ang(so)
        var a1 = ang(eo)
        if a1 < a0 { a1 += 2 * CGFloat.pi }
        let i0 = ang(si)
        var i1 = ang(ei)
        if i1 < i0 { i1 += 2 * CGFloat.pi }

        let steps = 40
        var p = Path()
        for i in 0...steps {
            let a = a0 + (a1 - a0) * CGFloat(i) / CGFloat(steps)
            let q = CGPoint(x: c.x + R * cos(a), y: c.y + R * sin(a))
            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        for i in 0...steps {
            let a = i1 - (i1 - i0) * CGFloat(i) / CGFloat(steps)
            p.addLine(to: CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a)))
        }
        p.closeSubpath()
        return p
    }
}

struct WheelDropDelegate: DropDelegate {
    let size: CGFloat
    let inner: CGFloat
    let gapHalf: CGFloat
    let targets: [Target]
    let disabled: Set<Target>
    @Binding var targeted: Target?
    @Binding var overCenter: Bool
    @Binding var overSame: Bool
    let onDrop: ([URL], Target) -> Void

    func segment(at p: CGPoint) -> Target? {
        let n = targets.count
        guard n > 0 else { return nil }
        let slice = 2 * CGFloat.pi / CGFloat(n)
        let dx = p.x - size / 2
        let dy = p.y - size / 2
        let dist = (dx * dx + dy * dy).squareRoot()
        guard dist >= inner - 4, dist <= size / 2 else { return nil }
        var a = atan2(dy, dx) + CGFloat.pi / 2
        if a < 0 { a += 2 * CGFloat.pi }
        let shifted = a + slice / 2
        let index = Int(shifted / slice) % n
        // razmik med kraki ni veljaven cilj
        let local = shifted.truncatingRemainder(dividingBy: slice)
        let toBoundary = min(local, slice - local)
        if dist * sin(toBoundary) < gapHalf { return nil }
        return targets[index]
    }

    func target(at p: CGPoint) -> Target? {
        guard let t = segment(at: p), !disabled.contains(t) else { return nil }
        return t
    }

    func isSame(at p: CGPoint) -> Bool {
        guard let t = segment(at: p) else { return false }
        return disabled.contains(t)
    }

    func isCenter(at p: CGPoint) -> Bool {
        let dx = p.x - size / 2
        let dy = p.y - size / 2
        return (dx * dx + dy * dy).squareRoot() < inner - 4
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        targeted = target(at: info.location)
        overCenter = isCenter(at: info.location)
        overSame = isSame(at: info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let t = target(at: info.location)
        targeted = t
        overCenter = isCenter(at: info.location)
        overSame = isSame(at: info.location)
        return DropProposal(operation: t == nil ? .forbidden : .copy)
    }

    func dropExited(info: DropInfo) {
        targeted = nil
        overCenter = false
        overSame = false
    }

    func performDrop(info: DropInfo) -> Bool {
        let chosen = target(at: info.location)
        targeted = nil
        overCenter = false
        overSame = false
        guard let chosenTarget = chosen else { return false }

        let providers = info.itemProviders(for: [.fileURL])
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    if let url = url {
                        urls.append(url)
                    }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            onDrop(urls, chosenTarget)
        }
        return true
    }
}

struct VisualEffectDisk: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .behindWindow
        v.material = .popover
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct WheelView: View {
    @ObservedObject var model: WheelModel
    let size: CGFloat
    @Environment(\.colorScheme) private var scheme
    @AppStorage(WheelStyle.storageKey) private var style = WheelStyle.glass.rawValue
    @State private var targeted: Target? = nil
    @State private var overCenter = false
    @State private var overSame = false

    var body: some View {
        let p = Palette(scheme)
        let u = size / 360
        let targets: [Target] = model.mode == .tools ? Tool.allCases.map { Target.tool($0) } : model.kind.targets
        let hint: String? = model.message.isEmpty && targeted == nil
            ? (overSame ? "SAME FORMAT" : (overCenter ? "NOT HERE!" : "DROP ON…"))
            : nil
        let centerText = hint ?? (model.message.isEmpty ? (targeted?.shortLabel ?? "") : model.message)

        ZStack {
            disk(p: p, u: u)

            ForEach(Array(targets.enumerated()), id: \.offset) { index, target in
                segment(index: index, count: targets.count, target: target, p: p, u: u)
            }

            if model.busy && model.total > 1 {
                Circle()
                    .stroke(p.track, lineWidth: 3 * u)
                    .frame(width: 118 * u, height: 118 * u)
                Circle()
                    .trim(from: 0, to: CGFloat(model.progress))
                    .stroke(p.progress, style: StrokeStyle(lineWidth: 3 * u, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 118 * u, height: 118 * u)
            }

            Circle()
                .fill(p.wedge.opacity(style == WheelStyle.glass.rawValue ? 0.88 : 1))
                .frame(width: 112 * u, height: 112 * u)
            VStack(spacing: 3 * u) {
                Text(centerText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(1 * u)
                    .font(inter(hint == nil ? 14 * u : 11 * u))
                    .tracking(hint == nil ? 0 : 0.88 * u)
                    .foregroundStyle(hint == nil ? p.text : p.textDim)
                if !model.sizeText.isEmpty {
                    Text(model.sizeText)
                        .font(inter(10 * u))
                        .tracking(0.6 * u)
                        .foregroundStyle(p.textDim)
                }
            }
            .frame(width: 100 * u)
        }
        .frame(width: size, height: size)

        .onDrop(of: [.fileURL], delegate: WheelDropDelegate(
            size: size,
            inner: 62 * u,
            gapHalf: 3 * u,
            targets: targets,
            disabled: model.disabled,
            targeted: $targeted,
            overCenter: $overCenter,
            overSame: $overSame,
            onDrop: { urls, target in
                run(urls, target)
            }
        ))
    }

    private static let cheers = [
        "LIKE A BOSS!", "NAILED IT!", "SMOOTH!", "DONE!", "BOOM!",
        "EASY!", "CRISP!", "NICE ONE!", "SORTED!", "FLAWLESS!",
        "TOO EASY!", "CLEAN!"
    ]

    // Nosilec kolesa: Solid je polna barva, Glass je zamegljeno ozadje z barvno tinto in svetlim robom
    @ViewBuilder
    private func disk(p: Palette, u: CGFloat) -> some View {
        let shadow = Color.black.opacity(scheme == .dark ? 0.5 : 0.22)
        if style == WheelStyle.glass.rawValue {
            ZStack {
                VisualEffectDisk()
                Circle().fill(p.disk.opacity(0.25))
                Circle().fill(LinearGradient(
                    colors: [Color.white.opacity(scheme == .dark ? 0.10 : 0.45), Color.white.opacity(0.0), Color.white.opacity(scheme == .dark ? 0.06 : 0.25)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(
                Circle().strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(scheme == .dark ? 0.35 : 0.9), Color.white.opacity(0.15), Color.white.opacity(scheme == .dark ? 0.2 : 0.6)],
                        startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1.2 * u)
            )
            .shadow(color: shadow, radius: 16 * u, x: 0, y: 10 * u)
        } else {
            Circle()
                .fill(p.disk)
                .shadow(color: shadow, radius: 16 * u, x: 0, y: 10 * u)
        }
    }

    private func run(_ urls: [URL], _ target: Target) {
        model.chosen = target
        model.sizeText = ""
        Converter.resetSaved()
        model.busy = true
        model.total = urls.count
        model.progress = 0
        model.message = "…"
        Converter.resetSkipped()
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = 0
            for (i, url) in urls.enumerated() {
                if Converter.convert(url, to: target) { ok += 1 }
                let done = i + 1
                DispatchQueue.main.async {
                    model.progress = Double(done) / Double(urls.count)
                    if done < urls.count {
                        model.message = "\(done)/\(urls.count)"
                    }
                }
            }
            let skipped = Converter.skippedCount
            DispatchQueue.main.async {
                if ok == urls.count {
                    model.message = Self.cheers.randomElement() ?? "DONE!"
                } else if ok == 0 && skipped == urls.count {
                    model.message = "ALREADY\nSMALL"
                } else {
                    model.message = "⚠︎ \(ok)/\(urls.count)"
                }
                let saved = Converter.savedBytes
                if saved > 0, case .tool(let t) = target, t != .strip {
                    model.sizeText = "−" + ByteCountFormatter.string(fromByteCount: Int64(saved), countStyle: .file).uppercased()
                }
                model.busy = false
            }
        }
    }

    private func segment(index: Int, count: Int, target: Target, p: Palette, u: CGFloat) -> some View {
        let slice = 2 * CGFloat.pi / CGFloat(count)
        let center = CGFloat(index) * slice - CGFloat.pi / 2
        let outer = 172 * u
        let inner = 62 * u
        let active = targeted == target || model.chosen == target
        let dimmed = (model.busy && model.chosen != target) || model.disabled.contains(target)

        let fill: Color = active ? p.accent : (dimmed ? p.wedgeDim : p.wedge)
        let labelColor: Color = active ? p.ink : (dimmed ? p.textDim : p.text)

        let shape = Wedge(center: center, slice: slice, outer: outer, inner: inner, gap: 6 * u, corner: 6 * u)
        let r = (outer + inner) / 2

        let px = size / 2 + r * cos(center)
        let py = size / 2 + r * sin(center)

        // Pri Glass so neaktivni izseki rahlo prosojni (88 %), aktivni je poln
        let glass = style == WheelStyle.glass.rawValue
        let wedgeOpacity: Double = (glass && !active) ? 0.88 : 1

        return ZStack {
            ZStack {
                shape.fill(fill)
                shape.stroke(fill, style: StrokeStyle(lineWidth: 12 * u, lineJoin: .round))
            }
            .compositingGroup()
            .opacity(wedgeOpacity)
            if case .tool(let tool) = target {
                VStack(spacing: 4 * u) {
                    Text(tool.title)
                        .font(inter(15 * u))
                        .multilineTextAlignment(.center)
                        .lineSpacing(0)
                        .foregroundStyle(labelColor)
                    Text(tool.formats)
                        .font(inter(10 * u))
                        .tracking(0.8 * u)
                        .multilineTextAlignment(.center)
                        .lineSpacing(1 * u)
                        .foregroundStyle(active ? Color.white.opacity(0.8) : p.textDim)
                }
                .position(x: px, y: py)
            } else {
                Text(target.label)
                    .font(inter(15 * u))
                    .foregroundStyle(labelColor)
                    .position(x: px, y: py)
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }
}

// MARK: - Posodobitve

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    let repo = "davidpraznik/Konverter"
    private let defaults = UserDefaults.standard
    private var timer: Timer?

    @Published var autoCheck: Bool {
        didSet {
            defaults.set(autoCheck, forKey: "autoCheckUpdates")
            if autoCheck { checkIfDue() }
        }
    }
    @Published var available: String? = nil
    @Published var releaseURL: URL? = nil
    @Published var status = ""
    @Published var checking = false

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private init() {
        autoCheck = defaults.object(forKey: "autoCheckUpdates") as? Bool ?? true
        // Najdena posodobitev ostane vidna tudi po ponovnem zagonu, dokler ni nameščena
        if let v = defaults.string(forKey: "availableVersion"), UpdateChecker.isNewer(v, than: version) {
            available = v
            if let s = defaults.string(forKey: "availableURL") { releaseURL = URL(string: s) }
            status = "Update \(v) available"
        }
    }

    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // Ob zagonu in nato največ enkrat na dan
    func start() {
        checkIfDue()
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkIfDue() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func checkIfDue() {
        guard autoCheck, !checking else { return }
        let last = defaults.double(forKey: "lastUpdateCheck")
        if Date().timeIntervalSince1970 - last >= 86_400 {
            check(manual: false)
        }
    }

    func check(manual: Bool) {
        guard !checking else { return }
        checking = true
        if manual { status = "" }
        defaults.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
        Task {
            defer { checking = false }
            guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 404 {
                    if manual { status = "No releases published yet." }
                    return
                }
                guard code == 200,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String
                else {
                    if manual { status = "Could not check for updates." }
                    return
                }
                let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                if UpdateChecker.isNewer(latest, than: version) {
                    available = latest
                    let page = json["html_url"] as? String
                    releaseURL = page.flatMap { URL(string: $0) }
                    status = "Update \(latest) available"
                    defaults.set(latest, forKey: "availableVersion")
                    defaults.set(page, forKey: "availableURL")
                } else {
                    available = nil
                    releaseURL = nil
                    defaults.removeObject(forKey: "availableVersion")
                    defaults.removeObject(forKey: "availableURL")
                    if manual { status = "You are up to date (\(version))." }
                }
            } catch {
                if manual { status = "Could not check for updates." }
            }
        }
    }

    // Ikona menijske vrstice z vijolično piko
    static func badgedIcon() -> NSImage {
        guard let base = NSImage(named: "MenuIcon") else { return NSImage() }
        let size = base.size
        let image = NSImage(size: size, flipped: false) { rect in
            let tinted = NSImage(size: size, flipped: false) { r in
                base.draw(in: r)
                NSColor.labelColor.set()
                r.fill(using: .sourceIn)
                return true
            }
            tinted.draw(in: rect)
            NSColor(red: 0.43, green: 0.29, blue: 1.0, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 7, y: rect.maxY - 7, width: 7, height: 7)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

// MARK: - Settings

@MainActor
final class SettingsModel: ObservableObject {
    @Published var launchAtLogin = (SMAppService.mainApp.status == .enabled)

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // stanje se spodaj osveži glede na dejansko stanje
        }
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }
}

// MARK: - Tipka za kolo z orodji

enum ToolsKey: String, CaseIterable, Identifiable {
    case command, shiftCommand

    static let storageKey = "toolsKey"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .command: return "⌘ Command"
        case .shiftCommand: return "⇧⌘ Shift + Command"
        }
    }

    static var current: ToolsKey {
        ToolsKey(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .command
    }
}

// MARK: - Nastavitve kompresije

enum CompressionQuality: String, CaseIterable, Identifiable {
    case smaller, balanced, better

    var id: String { rawValue }

    var label: String {
        switch self {
        case .smaller: return "Smaller"
        case .balanced: return "Balanced"
        case .better: return "Better"
        }
    }

    // Vrednosti Balanced so enake kot pred uvedbo nastavitev
    var jpg: Double {
        switch self {
        case .smaller: return 0.5
        case .balanced: return 0.7
        case .better: return 0.85
        }
    }

    var heic: Double {
        switch self {
        case .smaller: return 0.45
        case .balanced: return 0.6
        case .better: return 0.8
        }
    }

    var webp: Float {
        switch self {
        case .smaller: return 55
        case .balanced: return 70
        case .better: return 85
        }
    }
}

enum CompressionResult: String, CaseIterable, Identifiable {
    case nextToOriginal, replace

    var id: String { rawValue }

    var label: String {
        switch self {
        case .nextToOriginal: return "Save next to original"
        case .replace: return "Replace original"
        }
    }
}

enum WebSettings {
    static let maxSideKey = "webMaxSide"
    static let qualityKey = "webQuality"
    static let srgbKey = "webSRGB"
    static let stripKey = "webStripMetadata"
    static let resultKey = "webResult"
    // 0 = originalna velikost
    static let options = [0, 3840, 2560, 1920, 1600, 1280, 1024, 800]

    static func label(_ v: Int) -> String { v == 0 ? "Original size" : "\(v) px" }

    static var maxSide: Int {
        let v = UserDefaults.standard.object(forKey: maxSideKey) as? Int ?? 1920
        return options.contains(v) ? v : 1920
    }

    static var quality: CompressionQuality {
        CompressionQuality(rawValue: UserDefaults.standard.string(forKey: qualityKey) ?? "") ?? .balanced
    }

    static var result: CompressionResult {
        CompressionResult(rawValue: UserDefaults.standard.string(forKey: resultKey) ?? "") ?? .nextToOriginal
    }

    static var srgb: Bool { UserDefaults.standard.object(forKey: srgbKey) as? Bool ?? true }
    static var stripMetadata: Bool { UserDefaults.standard.object(forKey: stripKey) as? Bool ?? true }
}

enum WheelStyle: String, CaseIterable, Identifiable {
    case glass, solid
    static let storageKey = "wheelStyle"
    var id: String { rawValue }
    var label: String { self == .glass ? "Glass" : "Solid" }
}

struct SettingsView: View {
    @StateObject private var model = SettingsModel()
    @ObservedObject private var updates = UpdateChecker.shared
    @AppStorage(ToolsKey.storageKey) private var toolsKey = ToolsKey.command.rawValue
    @AppStorage(WebSettings.resultKey) private var webResult = CompressionResult.nextToOriginal.rawValue
    @AppStorage(WheelStyle.storageKey) private var wheelStyle = WheelStyle.glass.rawValue
    @AppStorage(WebSettings.maxSideKey) private var webMaxSide = 1920
    @AppStorage(WebSettings.qualityKey) private var webQuality = CompressionQuality.balanced.rawValue
    @AppStorage(WebSettings.srgbKey) private var webSRGB = true
    @AppStorage(WebSettings.stripKey) private var webStrip = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))

            Toggle("Check for updates automatically", isOn: $updates.autoCheck)

            VStack(alignment: .leading, spacing: 6) {
                Picker("Tools key", selection: $toolsKey) {
                    ForEach(ToolsKey.allCases) { key in
                        Text(key.label).tag(key.rawValue)
                    }
                }
                .fixedSize()
                Text("Hold it while dragging images to show the tools wheel. ⇧ Shift alone opens the convert wheel. ⌥ Option and ⌃ Control are used by Archivator.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("APPEARANCE")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline) {
                    Text("Style").frame(width: 72, alignment: .leading)
                    Picker("Style", selection: $wheelStyle) {
                        ForEach(WheelStyle.allCases) { st in
                            Text(st.label).tag(st.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }

            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("FOR WEB")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline) {
                    Text("Max size").frame(width: 72, alignment: .leading)
                    Picker("Max size", selection: $webMaxSide) {
                        ForEach(WebSettings.options, id: \.self) { v in
                            Text(WebSettings.label(v)).tag(v)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Text("Longest side. Larger images are shrunk, smaller ones enlarged. Original size keeps the dimensions.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 80)

                HStack(alignment: .firstTextBaseline) {
                    Text("Quality").frame(width: 72, alignment: .leading)
                    Picker("Quality", selection: $webQuality) {
                        ForEach(CompressionQuality.allCases) { q in
                            Text(q.label).tag(q.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }

                Toggle("Convert to sRGB", isOn: $webSRGB)
                    .padding(.leading, 80)
                Toggle("Remove metadata", isOn: $webStrip)
                    .padding(.leading, 80)

                HStack(alignment: .firstTextBaseline) {
                    Text("Result").frame(width: 72, alignment: .leading)
                    Picker("Result", selection: $webResult) {
                        ForEach(CompressionResult.allCases) { r in
                            Text(r.label).tag(r.rawValue)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Text(webResult == CompressionResult.replace.rawValue
                     ? "The original is moved to the Trash. If the size stays the same and the result is not smaller, nothing changes."
                     : "Adds \"-web\" to the name. If the size stays the same and the result is not smaller, nothing is saved.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 80)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Check for updates") { updates.check(manual: true) }
                        .disabled(updates.checking)
                    if updates.checking { ProgressView().controlSize(.small) }
                }
                if !updates.status.isEmpty {
                    Text(updates.status)
                        .font(.callout)
                        .foregroundStyle(updates.available != nil ? Color(hex: 0x6D4AFF) : Color.secondary)
                }
                if let url = updates.releaseURL {
                    Link("Open download page", destination: url)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Konverter \(updates.version)")
                    .font(.headline)
                Text("© 2026 David Praznik")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Link("github.com/davidpraznik/Konverter",
                     destination: URL(string: "https://github.com/davidpraznik/Konverter")!)
                    .font(.callout)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

// MARK: - Zaznava vlečenja in okno

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var timer: Timer?
    private var mouseMonitor: Any?
    private var alwaysPolling = false
    private var panel: NSPanel?
    private let model = WheelModel()
    private var baselineCount = NSPasteboard(name: .drag).changeCount
    private var wheelVisible = false
    private var hideWork: DispatchWorkItem?
    private let wheelSize: CGFloat = 360
    private let panelSize: CGFloat = 420
    // Shift sam (pri izbiri ⇧⌘) počakamo kratek čas, da se lahko pridruži ⌘
    private var shiftSince: Date?
    private let shiftDelay: TimeInterval = 0.15
    private var settingsWindow: NSWindow?

    @MainActor
    func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Konverter Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerFonts()
        Task { @MainActor in UpdateChecker.shared.start() }
        // Timer teče samo, dokler je levi gumb miške pritisnjen (prej stalno, 33x/s).
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.startPolling()
        }
        // Če monitor ni na voljo, ostane stalno spraševanje kot prej.
        if mouseMonitor == nil {
            alwaysPolling = true
            startPolling()
        }
    }

    private func startPolling() {
        guard timer == nil else { return }
        baselineCount = NSPasteboard(name: .drag).changeCount
        let t = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            self?.tick()
        }
        t.tolerance = 0.01
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let pb = NSPasteboard(name: .drag)
        let pressed = (NSEvent.pressedMouseButtons & 1) != 0

        if !pressed {
            baselineCount = pb.changeCount
            shiftSince = nil
            if wheelVisible {
                scheduleHide()
            } else if !alwaysPolling {
                stopPolling()
            }
            return
        }

        if wheelVisible { return }

        let flags = NSEvent.modifierFlags
        let shift = flags.contains(.shift)
        let command = flags.contains(.command)
        let tools: Bool
        let convert: Bool
        switch ToolsKey.current {
        case .command:
            tools = command && !shift
            convert = shift
        case .shiftCommand:
            tools = command && shift
            if shift && !command {
                if shiftSince == nil { shiftSince = Date() }
                convert = Date().timeIntervalSince(shiftSince ?? Date()) >= shiftDelay
            } else {
                shiftSince = nil
                convert = false
            }
        }
        guard pb.changeCount != baselineCount, convert || tools else { return }

        let urls = (pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []

        guard let first = urls.first, let kind = Converter.kind(of: first) else { return }
        if tools && kind != .image { return }
        showWheel(kind: kind, urls: urls, mode: tools ? .tools : .convert)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelSize, height: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let root = WheelView(model: model, size: wheelSize)
            .frame(width: panelSize, height: panelSize)
        p.contentView = NSHostingView(rootView: root)
        return p
    }

    private func showWheel(kind: FileKind, urls: [URL], mode: WheelMode) {
        hideWork?.cancel()
        hideWork = nil
        model.kind = kind
        model.mode = mode
        let formats = Set(urls.compactMap { Converter.format(of: $0) })
        let allKnown = urls.allSatisfy { Converter.format(of: $0) != nil }
        model.disabled = (mode == .convert && allKnown && formats.count == 1) ? formats : []
        model.message = ""
        model.chosen = nil
        model.progress = 0
        model.total = 0
        let bytes = urls.reduce(0) { $0 + Converter.fileSize($1) }
        let count = urls.count
        model.sizeText = bytes > 0
            ? (count > 1 ? "\(count) FILES · " : "") + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file).uppercased()
            : ""
        if panel == nil { panel = makePanel() }

        let m = NSEvent.mouseLocation
        var origin = NSPoint(x: m.x - panelSize / 2, y: m.y - panelSize / 2)
        if let s = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) {
            let f = s.visibleFrame
            origin.x = min(max(origin.x, f.minX), f.maxX - panelSize)
            origin.y = min(max(origin.y, f.minY), f.maxY - panelSize)
        }
        panel?.setFrameOrigin(origin)
        panel?.orderFrontRegardless()
        wheelVisible = true
    }

    private func scheduleHide() {
        if hideWork != nil { return }
        let work = DispatchWorkItem { [weak self] in
            self?.finishHide()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func finishHide() {
        if model.busy {
            let work = DispatchWorkItem { [weak self] in
                self?.finishHide()
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            return
        }
        if model.message.isEmpty {
            hideWheel()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.hideWheel()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    private func hideWheel() {
        panel?.orderOut(nil)
        wheelVisible = false
        hideWork = nil
    }
}
