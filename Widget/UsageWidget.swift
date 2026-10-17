import AppIntents
import SwiftUI
import WidgetKit

// The widget is sandboxed: it only reads the statusline cache and the menu bar app's snapshot
// (see the temporary-exception entitlement in project.yml). The app reloads it on changes.
func currentUsage() -> UsageCache? {
    merge(loadUsage(usageCacheURL), loadUsage(widgetSnapshotURL))
}

// The menu bar app's language (from its snapshot), so both match; the system language otherwise.
func widgetLang() -> Lang {
    Lang.resolve(setting: loadUsage(widgetSnapshotURL)?.lang)
}

func sampleUsage(_ now: Date) -> UsageCache {
    UsageCache(five_hour: UsageWindow(used_percentage: 42, resets_at: now.timeIntervalSince1970 + 2 * 3600),
               seven_day: UsageWindow(used_percentage: 18, resets_at: now.timeIntervalSince1970 + 3 * 86400),
               updated_at: now.timeIntervalSince1970)
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), usage: sampleUsage(Date()), lang: widgetLang())
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        let now = Date()
        completion(UsageEntry(date: now, usage: currentUsage() ?? (context.isPreview ? sampleUsage(now) : nil),
                              lang: widgetLang()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let now = Date()
        let usage = currentUsage(), lang = widgetLang()
        let entries = timelineDates(from: now, usage: usage).map { UsageEntry(date: $0, usage: usage, lang: lang) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

// Clicking the widget runs this; WidgetKit reloads the widget after perform() without spending
// the reload budget. The menu bar app fetches fresh numbers if needed and stamps refreshed_at.
struct RefreshUsageIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Claude Code usage"
    static var isDiscoverable = false

    func perform() async throws -> some IntentResult {
        let asked = Date().timeIntervalSince1970
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(refreshNotification as CFString), nil, nil, true)
        // Wait for the app's answer; if it isn't running, show what the files have.
        for _ in 0..<Int(widgetRefreshWait * 4) {
            if (loadUsage(widgetSnapshotURL)?.refreshed_at ?? 0) >= asked - 1 { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        return .result()
    }
}

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        Button(intent: RefreshUsageIntent()) {
            Group {
                switch family {
                case .systemMedium: MediumUsageView(entry: entry)
                default: SmallUsageView(entry: entry)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .environment(\.locale, entry.lang.locale)
        .containerBackground(.background, for: .widget)
    }
}

struct ClaudeUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClaudeUsage", provider: Provider()) { entry in
            UsageWidgetView(entry: entry)
        }
        .configurationDisplayName(S.widgetName(widgetLang()))
        .description(S.widgetDescription(widgetLang()))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct ClaudeUsageWidgets: WidgetBundle {
    var body: some Widget {
        ClaudeUsageWidget()
    }
}
