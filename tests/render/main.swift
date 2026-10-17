import SwiftUI
import WidgetKit

// Renders the widget views to PNGs for a visual check: swiftc ... && ./render <out-dir>
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let now = Date()
let sample = UsageCache(
    five_hour: UsageWindow(used_percentage: 24, resets_at: now.timeIntervalSince1970 + 48 * 60),
    seven_day: UsageWindow(used_percentage: 28, resets_at: now.timeIntervalSince1970 + 2.5 * 86400),
    updated_at: now.timeIntervalSince1970 - 120)
let high = UsageCache(
    five_hour: UsageWindow(used_percentage: 93, resets_at: now.timeIntervalSince1970 + 20 * 60),
    seven_day: UsageWindow(used_percentage: 78, resets_at: now.timeIntervalSince1970 + 86400),
    updated_at: now.timeIntervalSince1970)

@MainActor
func render<V: View>(_ view: V, size: CGSize, dark: Bool, name: String) {
    let framed = view
        .padding(16)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(dark ? Color(white: 0.17) : Color(white: 0.97))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(12)
        .background(dark ? Color.black : Color(white: 0.8))
        .environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.locale, ru)
    let r = ImageRenderer(content: framed)
    r.scale = 2
    guard let tiff = r.nsImage?.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
        print("render failed: \(name)")
        return
    }
    let url = URL(fileURLWithPath: out).appendingPathComponent("\(name).png")
    try? png.write(to: url)
    print(url.path)
}

MainActor.assumeIsolated {
    // Sizes chronod reports for desktop widgets on macOS 26.
    let small = CGSize(width: 164, height: 164), medium = CGSize(width: 344, height: 164)
    for dark in [false, true] {
        let s = dark ? "dark" : "light"
        render(SmallUsageView(entry: UsageEntry(date: now, usage: sample)), size: small, dark: dark, name: "small-\(s)")
        render(MediumUsageView(entry: UsageEntry(date: now, usage: sample)), size: medium, dark: dark, name: "medium-\(s)")
    }
    render(SmallUsageView(entry: UsageEntry(date: now, usage: high)), size: small, dark: false, name: "small-high")
    render(MediumUsageView(entry: UsageEntry(date: now, usage: high)), size: medium, dark: true, name: "medium-high")
    render(SmallUsageView(entry: UsageEntry(date: now, usage: nil)), size: small, dark: false, name: "small-nodata")
    var old = sample
    old.updated_at = now.timeIntervalSince1970 - 86400  // header shows the weekday: the longest case
    render(SmallUsageView(entry: UsageEntry(date: now, usage: old)), size: small, dark: true, name: "small-oldday")
    render(MediumUsageView(entry: UsageEntry(date: now, usage: old)), size: medium, dark: false, name: "medium-oldday")
}
