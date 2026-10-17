import SwiftUI
import WidgetKit

struct UsageEntry: TimelineEntry {
    let date: Date
    let usage: UsageCache?
    let lang: Lang
}

let claudeAccent = Color(red: 0.85, green: 0.47, blue: 0.34)

func levelColor(_ p: Double?) -> Color {
    guard let p else { return .secondary }
    if p >= 90 { return .red }
    if p >= 75 { return .orange }
    return claudeAccent
}

// ("resets 23:50", "48 min"), ("window reset", nil) after the reset, or nil when the time is unknown.
func resetParts(_ w: UsageWindow?, now: Date, _ lang: Lang) -> (when: String, left: String?)? {
    guard let r = w?.resets_at else { return nil }
    let date = Date(timeIntervalSince1970: r)
    if date <= now { return (S.windowReset(lang), nil) }
    return (S.reset(lang, shortTime(date, now: now, lang)), durationText(date.timeIntervalSince(now), lang))
}

private func clamped(_ p: Double?) -> Double { min(max(p ?? 0, 0), 100) / 100 }

struct UsageBar: View {
    let value: Double?

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(levelColor(value))
                    .frame(width: max(g.size.width * clamped(value), (value ?? 0) > 0 ? 6 : 0))
                    .widgetAccentable()
            }
        }
        .frame(height: 6)
    }
}

struct UsageRing: View {
    let value: Double?

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 7)
            Circle().trim(from: 0, to: clamped(value))
                .stroke(levelColor(value), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .widgetAccentable()
            Text(pctText(value))
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
        }
    }
}

struct WidgetHeader: View {
    let entry: UsageEntry
    var compact = false

    var body: some View {
        // The data time must never be cut off; when it and the title don't both fit, drop the title.
        ViewThatFits(in: .horizontal) {
            row(withTitle: true)
            row(withTitle: false)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func row(withTitle: Bool) -> some View {
        HStack(spacing: 4) {
            if withTitle {
                Text(compact ? "Claude" : "Claude Code").fontWeight(.semibold).fixedSize()
            }
            Spacer(minLength: 4)
            HStack(spacing: 3) {
                if let t = entry.usage?.updated_at {
                    Text(S.asOf(entry.lang, shortTime(Date(timeIntervalSince1970: t), now: entry.date, entry.lang)))
                }
                Image(systemName: "arrow.clockwise")  // the whole widget is a refresh button
            }
            .fixedSize()
        }
    }
}

struct NoDataView: View {
    let lang: Lang

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(S.noData(lang)).font(.headline)
            Text(S.noDataHint(lang))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct SmallUsageView: View {
    let entry: UsageEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(entry: entry, compact: true)
            if let u = entry.usage {
                Spacer(minLength: 6)
                SmallWindowBlock(title: S.session(entry.lang), window: u.five_hour, now: entry.date, lang: entry.lang)
                Spacer(minLength: 8)
                SmallWindowBlock(title: S.week(entry.lang), window: u.seven_day, now: entry.date, lang: entry.lang)
            } else {
                NoDataView(lang: entry.lang)
            }
        }
    }
}

struct SmallWindowBlock: View {
    let title: String
    let window: UsageWindow?
    let now: Date
    let lang: Lang

    var body: some View {
        let p = percent(window, now: now)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.caption.weight(.medium))
                Spacer()
                Text(pctText(p))
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            UsageBar(value: p)
            if let (when, left) = resetParts(window, now: now, lang) {
                Text(left.map { "\(when) · \($0)" } ?? when)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }
}

struct MediumUsageView: View {
    let entry: UsageEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WidgetHeader(entry: entry)
            if let u = entry.usage {
                HStack(spacing: 12) {
                    RingBlock(title: S.sessionLong(entry.lang), window: u.five_hour, now: entry.date, lang: entry.lang)
                    RingBlock(title: S.weekLong(entry.lang), window: u.seven_day, now: entry.date, lang: entry.lang)
                }
                .frame(maxHeight: .infinity)
            } else {
                NoDataView(lang: entry.lang)
            }
        }
    }
}

struct RingBlock: View {
    let title: String
    let window: UsageWindow?
    let now: Date
    let lang: Lang

    var body: some View {
        HStack(spacing: 10) {
            UsageRing(value: percent(window, now: now))
                .frame(width: 62, height: 62)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption.weight(.semibold))
                if let (when, left) = resetParts(window, now: now, lang) {
                    Text(when).font(.caption2)
                    if let left {
                        Text(S.inDuration(lang, left)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
