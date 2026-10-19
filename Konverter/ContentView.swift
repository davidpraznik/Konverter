import SwiftUI
import UniformTypeIdentifiers
import ImageIO

enum OutputFormat: String, CaseIterable, Identifiable {
    case png = "PNG", jpg = "JPG", heic = "HEIC", tiff = "TIFF"
    var id: String { rawValue }
    var type: UTType {
        switch self {
        case .png: return .png
        case .jpg: return .jpeg
        case .heic: return .heic
        case .tiff: return .tiff
        }
    }
    var ext: String { self == .jpg ? "jpg" : rawValue.lowercased() }
}

struct ContentView: View {
    @State private var format: OutputFormat = .png
    @State private var status = "Spusti slike sem"
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 16) {
            Picker("Pretvori v", selection: $format) {
                ForEach(OutputFormat.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
                Text(status)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
            .frame(minHeight: 160)
            .dropDestination(for: URL.self) { urls, _ in
                guard !urls.isEmpty else { return false }
                convertAll(urls)
                return true
            } isTargeted: { isTargeted = $0 }
        }
        .padding(20)
        .frame(minWidth: 360, minHeight: 280)
    }

    private func convertAll(_ urls: [URL]) {
        var ok = 0
        var failed = 0
        for url in urls {
            if convert(url) { ok += 1 } else { failed += 1 }
        }
        status = failed == 0
            ? "Pretvorjeno: \(ok)"
            : "Pretvorjeno: \(ok), neuspešno: \(failed)"
    }

    private func uniqueURL(for source: URL) -> URL {
        let dir = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        var candidate = dir.appendingPathComponent(base).appendingPathExtension(format.ext)
        var i = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) (\(i))").appendingPathExtension(format.ext)
            i += 1
        }
        return candidate
    }

    private func convert(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        let dest = uniqueURL(for: url)
        guard let destination = CGImageDestinationCreateWithURL(dest as CFURL, format.type.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        return CGImageDestinationFinalize(destination)
    }
}
