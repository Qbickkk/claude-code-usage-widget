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
func render<V: View>(_ view: V, size: CGSize, dark: Bool, name: String, lang: Lang) {
    let framed = view
        .padding(16)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(dark ? Color(white: 0.17) : Color(white: 0.97))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(12)
        .background(dark ? Color.black : Color(white: 0.8))
        .environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.locale, lang.locale)
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
    var old = sample
    old.updated_at = now.timeIntervalSince1970 - 86400  // header shows the weekday: the longest case
    for lang in Lang.allCases {
        let l = lang.rawValue
        render(SmallUsageView(entry: UsageEntry(date: now, usage: sample, lang: lang)), size: small, dark: false, name: "small-\(l)", lang: lang)
        render(MediumUsageView(entry: UsageEntry(date: now, usage: sample, lang: lang)), size: medium, dark: true, name: "medium-\(l)", lang: lang)
        render(SmallUsageView(entry: UsageEntry(date: now, usage: high, lang: lang)), size: small, dark: false, name: "small-high-\(l)", lang: lang)
        render(SmallUsageView(entry: UsageEntry(date: now, usage: old, lang: lang)), size: small, dark: true, name: "small-oldday-\(l)", lang: lang)
        render(MediumUsageView(entry: UsageEntry(date: now, usage: old, lang: lang)), size: medium, dark: false, name: "medium-oldday-\(l)", lang: lang)
        render(SmallUsageView(entry: UsageEntry(date: now, usage: nil, lang: lang)), size: small, dark: false, name: "small-nodata-\(l)", lang: lang)
    }
}
