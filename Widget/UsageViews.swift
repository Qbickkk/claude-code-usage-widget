import SwiftUI
import WidgetKit

struct UsageEntry: TimelineEntry {
    let date: Date
    let usage: UsageCache?
}

let claudeAccent = Color(red: 0.85, green: 0.47, blue: 0.34)

func levelColor(_ p: Double?) -> Color {
    guard let p else { return .secondary }
    if p >= 90 { return .red }
    if p >= 75 { return .orange }
    return claudeAccent
}

private func shortTime(_ date: Date, now: Date) -> String {
    let f = DateFormatter()
    f.locale = ru
    f.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "EE HH:mm"
    return f.string(from: date)
}

// ("сброс 23:50", "через 48 мин"), or nil when the reset time is unknown.
func resetParts(_ w: UsageWindow?, now: Date) -> (String, String)? {
    guard let r = w?.resets_at else { return nil }
    let date = Date(timeIntervalSince1970: r)
    if date <= now { return ("окно сброшено", "") }
    return ("сброс \(shortTime(date, now: now))", "через \(durationText(date.timeIntervalSince(now)))")
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
        HStack(spacing: 4) {
            Text(compact ? "Claude" : "Claude Code").fontWeight(.semibold)
            Spacer(minLength: 4)
            // The data time must never be cut off; the title gives way first.
            HStack(spacing: 3) {
                if let t = entry.usage?.updated_at {
                    Text("на \(shortTime(Date(timeIntervalSince1970: t), now: entry.date))")
                }
                Image(systemName: "arrow.clockwise")  // the whole widget is a refresh button
            }
            .fixedSize()
            .layoutPriority(1)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

struct NoDataView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Нет данных").font(.headline)
            Text("Открой Claude Code или Claude Usage Bar в строке меню")
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
                SmallWindowBlock(title: "Сессия", window: u.five_hour, now: entry.date)
                Spacer(minLength: 8)
                SmallWindowBlock(title: "Неделя", window: u.seven_day, now: entry.date)
            } else {
                NoDataView()
            }
        }
    }
}

struct SmallWindowBlock: View {
    let title: String
    let window: UsageWindow?
    let now: Date

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
            if let (when, left) = resetParts(window, now: now) {
                Text(left.isEmpty ? when : "\(when) · \(left.replacingOccurrences(of: "через ", with: ""))")
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
                    RingBlock(title: "Сессия · 5 ч", window: u.five_hour, now: entry.date)
                    RingBlock(title: "Неделя · 7 д", window: u.seven_day, now: entry.date)
                }
                .frame(maxHeight: .infinity)
            } else {
                NoDataView()
            }
        }
    }
}

struct RingBlock: View {
    let title: String
    let window: UsageWindow?
    let now: Date

    var body: some View {
        HStack(spacing: 10) {
            UsageRing(value: percent(window, now: now))
                .frame(width: 62, height: 62)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption.weight(.semibold))
                if let (when, left) = resetParts(window, now: now) {
                    Text(when).font(.caption2)
                    if !left.isEmpty {
                        Text(left).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
