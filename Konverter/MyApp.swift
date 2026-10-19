import SwiftUI
import Combine
import AppKit
import CoreText
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import ServiceManagement
import libwebp

@main
struct KonverterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Konverter", image: "MenuIcon") {
            Button("Settings…") {
                appDelegate.showSettings()
            }
            .keyboardShortcut(",")
            Divider()
            Button("Quit Konverter") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
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
    case png = "PNG", webp = "WEBP", jpg = "JPG", avif = "AVIF", heic = "HEIC", pdf = "PDF"
    var id: String { rawValue }

    var ext: String { self == .jpg ? "jpg" : rawValue.lowercased() }

    var typeIdentifier: String? {
        switch self {
        case .png: return "public.png"
        case .jpg: return "public.jpeg"
        case .heic: return "public.heic"
        case .avif: return "public.avif"
        case .pdf: return "com.adobe.pdf"
        case .webp: return nil
        }
    }
}

enum VideoFormat: String, CaseIterable, Identifiable {
    case mp4 = "MP4", gif = "GIF", m4a = "M4A"
    var id: String { rawValue }
    var ext: String { rawValue.lowercased() }
}

enum Target: Hashable {
    case image(ImageFormat)
    case video(VideoFormat)

    var label: String {
        switch self {
        case .image(let f): return f.rawValue
        case .video(let f): return f.rawValue
        }
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
        case "mp4": return .video(.mp4)
        case "gif": return .video(.gif)
        default: return nil
        }
    }

    nonisolated static func uniqueURL(for source: URL, ext: String) -> URL {
        let dir = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
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

// MARK: - Kolo

final class WheelModel: ObservableObject {
    @Published var message = ""
    @Published var kind: FileKind = .image
    @Published var busy = false
    @Published var chosen: Target? = nil
    @Published var progress: Double = 0
    @Published var total = 0
    @Published var disabled: Set<Target> = []
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

struct WheelView: View {
    @ObservedObject var model: WheelModel
    let size: CGFloat
    @Environment(\.colorScheme) private var scheme
    @State private var targeted: Target? = nil
    @State private var overCenter = false
    @State private var overSame = false

    var body: some View {
        let p = Palette(scheme)
        let u = size / 360
        let targets = model.kind.targets
        let hint: String? = model.message.isEmpty && targeted == nil
            ? (overSame ? "SAME FORMAT" : (overCenter ? "NOT HERE!" : "DROP ON…"))
            : nil
        let centerText = hint ?? (model.message.isEmpty ? (targeted?.label ?? "") : model.message)

        ZStack {
            Circle()
                .fill(p.disk)
                .shadow(color: Color.black.opacity(scheme == .dark ? 0.5 : 0.22), radius: 16 * u, x: 0, y: 10 * u)

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
                .fill(p.wedge)
                .frame(width: 112 * u, height: 112 * u)
            Text(centerText)
                .font(inter(hint == nil ? 14 * u : 11 * u))
                .tracking(hint == nil ? 0 : 0.88 * u)
                .foregroundStyle(hint == nil ? p.text : p.textDim)
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

    private func run(_ urls: [URL], _ target: Target) {
        model.chosen = target
        model.busy = true
        model.total = urls.count
        model.progress = 0
        model.message = "…"
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
            DispatchQueue.main.async {
                model.message = ok == urls.count ? "✓ \(ok)" : "⚠︎ \(ok)/\(urls.count)"
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

        return ZStack {
            shape.fill(fill)
            shape.stroke(fill, style: StrokeStyle(lineWidth: 12 * u, lineJoin: .round))
            Text(target.label)
                .font(inter(15 * u))
                .foregroundStyle(labelColor)
                .position(x: size / 2 + r * cos(center), y: size / 2 + r * sin(center))
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }
}

// MARK: - Settings

@MainActor
final class SettingsModel: ObservableObject {
    @Published var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @Published var updateStatus = ""
    @Published var checking = false
    @Published var releaseURL: URL? = nil

    let repo = "davidpraznik/Konverter"

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

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

    func checkForUpdates() {
        checking = true
        updateStatus = ""
        releaseURL = nil
        Task {
            defer { checking = false }
            guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 404 {
                    updateStatus = "No releases published yet."
                    return
                }
                guard code == 200,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String
                else {
                    updateStatus = "Could not check for updates."
                    return
                }
                let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                if SettingsModel.isNewer(latest, than: version) {
                    updateStatus = "Version \(latest) is available."
                    if let page = json["html_url"] as? String { releaseURL = URL(string: page) }
                } else {
                    updateStatus = "You are up to date (\(version))."
                }
            } catch {
                updateStatus = "Could not check for updates."
            }
        }
    }
}

struct SettingsView: View {
    @StateObject private var model = SettingsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Check for updates") { model.checkForUpdates() }
                        .disabled(model.checking)
                    if model.checking { ProgressView().controlSize(.small) }
                }
                if !model.updateStatus.isEmpty {
                    Text(model.updateStatus)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let url = model.releaseURL {
                    Link("Open download page", destination: url)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Konverter \(model.version)")
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
        .frame(width: 340)
    }
}

// MARK: - Zaznava vlečenja in okno

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var timer: Timer?
    private var panel: NSPanel?
    private let model = WheelModel()
    private var baselineCount = NSPasteboard(name: .drag).changeCount
    private var wheelVisible = false
    private var hideWork: DispatchWorkItem?
    private let wheelSize: CGFloat = 360
    private let panelSize: CGFloat = 420
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
        let t = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let pb = NSPasteboard(name: .drag)
        let pressed = (NSEvent.pressedMouseButtons & 1) != 0

        if !pressed {
            baselineCount = pb.changeCount
            if wheelVisible { scheduleHide() }
            return
        }

        if wheelVisible { return }

        let shift = NSEvent.modifierFlags.contains(.shift)
        guard pb.changeCount != baselineCount, shift else { return }

        let urls = (pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []

        guard let first = urls.first, let kind = Converter.kind(of: first) else { return }
        showWheel(kind: kind, urls: urls)
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

    private func showWheel(kind: FileKind, urls: [URL]) {
        hideWork?.cancel()
        hideWork = nil
        model.kind = kind
        let formats = Set(urls.compactMap { Converter.format(of: $0) })
        let allKnown = urls.allSatisfy { Converter.format(of: $0) != nil }
        model.disabled = (allKnown && formats.count == 1) ? formats : []
        model.message = ""
        model.chosen = nil
        model.progress = 0
        model.total = 0
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
