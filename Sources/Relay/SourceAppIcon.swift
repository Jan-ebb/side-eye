import AppKit
import ImageIO
import SwiftUI

@MainActor
struct SourceAppIcon: View {
    let source: Source
    let size: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let icon = Self.icons[source], let image = colorScheme == .dark ? icon.dark ?? icon.light : icon.light {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: source.icon)
                    .font(.system(size: size * 0.8, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private struct Icon {
        var light: NSImage?
        var dark: NSImage? = nil
    }

    private static let icons: [Source: Icon] = {
        let workspace = NSWorkspace.shared
        let codex = workspace.urlForApplication(withBundleIdentifier: "com.openai.codex")
        let claude = workspace.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop")
        let cursor = workspace.urlForApplication(withBundleIdentifier: "com.todesktop.230313mzl4w4u92")
        let grok = workspace.urlForApplication(withBundleIdentifier: "com.anysphere.sand")
        let grokApp = grok?.lastPathComponent == "Grok Bot.app" ? grok : URL(fileURLWithPath: "/Applications/Grok Bot.app")
        return [
            .codex: codexIcon(at: codex),
            .claude: Icon(light: appIcon(at: claude)),
            .cursor: Icon(light: appIcon(at: cursor)),
            .grok: Icon(light: appIcon(at: grokApp)),
        ]
    }()

    private static func codexIcon(at url: URL?) -> Icon {
        guard let url, let bundle = Bundle(url: url) else { return Icon() }
        let light = codexResource("icon-codex-light", in: bundle)
        let dark = codexResource("icon-codex-dark-color", in: bundle)
        if let image = light ?? dark { return Icon(light: image, dark: dark) }
        return bundle.object(forInfoDictionaryKey: "CFBundleName") as? String == "Codex"
            ? Icon(light: appIcon(at: url)) : Icon()
    }

    private static func codexResource(_ name: String, in bundle: Bundle) -> NSImage? {
        guard let url = bundle.url(forResource: name, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 64,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }

    private static func appIcon(at url: URL?) -> NSImage? {
        guard let url, Bundle(url: url) != nil else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
