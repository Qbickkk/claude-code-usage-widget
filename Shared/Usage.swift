import Foundation

// One rate-limit window: the 5-hour session or the 7-day week.
struct UsageWindow: Codable, Equatable {
    var used_percentage: Double?
    var resets_at: Double?
}

// ~/.claude/usage-cache.json (written by statusline-usage.sh); API snapshots use the same shape.
struct UsageCache: Codable, Equatable {
    var five_hour: UsageWindow?
    var seven_day: UsageWindow?
    var updated_at: Double?
    // Set by the menu bar app when it has answered a refresh request from the widget.
    var refreshed_at: Double?
}

// Posted by the widget's refresh button (Darwin notification); the menu bar app answers it.
let refreshNotification = "local.shulika-illia.claude-usage-bar.refresh"
// How long the widget's refresh button waits for the app's answer before reloading anyway.
let widgetRefreshWait: TimeInterval = 4

// After this the widget has already reloaded with the old files, so the answer doesn't reach it.
func ackReachesWidget(askedAt: Date, now: Date) -> Bool {
    now.timeIntervalSince(askedAt) < widgetRefreshWait - 0.5
}

let ru = Locale(identifier: "ru_RU")

// FileManager's home points into the container when sandboxed (the widget); passwd has the real one.
func realHomeDirectory() -> URL {
    // Lets tests run the app against a scratch ~/.claude without the live statusline writing to it.
    if let home = ProcessInfo.processInfo.environment["CLAUDE_USAGE_HOME"] {
        return URL(fileURLWithPath: home, isDirectory: true)
    }
    if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
        return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
}

// Written by statusline-usage.sh.
let usageCacheURL = realHomeDirectory().appendingPathComponent(".claude/usage-cache.json")
// Written by the menu bar app: statusline data merged with the latest API snapshot, for the widget.
let widgetSnapshotURL = realHomeDirectory().appendingPathComponent(".claude/usage-widget.json")

func loadUsage(_ url: URL) -> UsageCache? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(UsageCache.self, from: data)
}

// Usage only grows inside a window, so for the same window the larger value is the fresher one.
// A later resets_at (by more than a minute) means a newer window.
func mergeWindow(_ a: UsageWindow?, _ b: UsageWindow?) -> UsageWindow? {
    guard let a, let pa = a.used_percentage else { return b }
    guard let b, let pb = b.used_percentage else { return a }
    let ra = a.resets_at ?? 0, rb = b.resets_at ?? 0
    if rb > ra + 60 { return b }
    if ra > rb + 60 { return a }
    return pb > pa ? b : a
}

func merge(_ a: UsageCache?, _ b: UsageCache?) -> UsageCache? {
    guard a != nil || b != nil else { return nil }
    return UsageCache(five_hour: mergeWindow(a?.five_hour, b?.five_hour),
                      seven_day: mergeWindow(a?.seven_day, b?.seven_day),
                      updated_at: max(a?.updated_at ?? 0, b?.updated_at ?? 0))
}

// A window whose reset time has passed counts as 0% until a source reports again.
func percent(_ w: UsageWindow?, now: Date) -> Double? {
    guard let w, let p = w.used_percentage else { return nil }
    if let r = w.resets_at, r <= now.timeIntervalSince1970 { return 0 }
    return p
}

// MARK: - /api/oauth/usage (the endpoint behind Claude Code's /usage)

private struct APIUsage: Decodable {
    struct Window: Decodable {
        let utilization: Double?
        let resets_at: String?
    }
    let five_hour: Window?
    let seven_day: Window?
}

// resets_at comes with microseconds ("…00.127573+00:00"), which ISO8601DateFormatter can't parse.
func parseISODate(_ s: String?) -> Double? {
    guard var s else { return nil }
    if let r = s.range(of: #"\.\d+"#, options: .regularExpression) { s.removeSubrange(r) }
    return ISO8601DateFormatter().date(from: s)?.timeIntervalSince1970
}

func decodeAPIUsage(_ data: Data, fetchedAt: Date) -> UsageCache? {
    guard let u = try? JSONDecoder().decode(APIUsage.self, from: data) else { return nil }
    func window(_ x: APIUsage.Window?) -> UsageWindow? {
        guard let x, let p = x.utilization else { return nil }
        return UsageWindow(used_percentage: p, resets_at: parseISODate(x.resets_at))
    }
    return UsageCache(five_hour: window(u.five_hour), seven_day: window(u.seven_day),
                      updated_at: fetchedAt.timeIntervalSince1970)
}

// MARK: - Claude Code's OAuth token (Keychain item "Claude Code-credentials"), read-only

private struct OAuthCredentials: Decodable {
    struct Account: Decodable {
        let accessToken: String?
        let expiresAt: Double?  // epoch milliseconds
    }
    let claudeAiOauth: Account?
}

enum TokenState: Equatable {
    case ok(String)
    case expired
    case missing
}

// The token is never refreshed here: refresh tokens rotate, and refreshing would log Claude Code out.
func tokenState(from data: Data, now: Date) -> TokenState {
    guard let c = try? JSONDecoder().decode(OAuthCredentials.self, from: data),
          let token = c.claudeAiOauth?.accessToken, !token.isEmpty else { return .missing }
    if let e = c.claudeAiOauth?.expiresAt, e / 1000 <= now.timeIntervalSince1970 + 30 { return .expired }
    return .ok(token)
}

// Poll the API only when Claude Code hasn't reported for this long.
let statuslineFreshness: TimeInterval = 120

func shouldPoll(statuslineUpdatedAt: Double?, now: Date, nextAttempt: Date) -> Bool {
    now.timeIntervalSince1970 - (statuslineUpdatedAt ?? 0) > statuslineFreshness && now >= nextAttempt
}

// Seconds until the next API request after a response with this HTTP status (nil: no response).
func nextDelay(status: Int?, retryAfter: Double?, previous: TimeInterval) -> TimeInterval {
    switch status {
    case 200: return 300
    case 429: return max(min(retryAfter ?? 0, 21600), min(1800, max(previous * 2, 300)))
    case 401, 403: return 1800
    default: return min(1800, max(previous * 2, 300))
    }
}

// MARK: - Widget

// Entries every 5 minutes for two hours (countdowns stay current without reloads), plus one right
// after each reset inside that span so the widget drops to 0% on time.
func timelineDates(from now: Date, usage: UsageCache?) -> [Date] {
    var dates = (0...24).map { now.addingTimeInterval(Double($0) * 300) }
    let end = now.addingTimeInterval(7200)
    for r in [usage?.five_hour?.resets_at, usage?.seven_day?.resets_at].compactMap({ $0 }) {
        let d = Date(timeIntervalSince1970: r + 1)
        if d > now, d < end { dates.append(d) }
    }
    return Array(Set(dates)).sorted()
}

// What the widget shows: rounded percents, reset minutes and the hour of the data time.
// The app reloads the widget only when this changes, to stay within WidgetKit's reload budget.
func widgetKey(_ u: UsageCache?) -> String {
    guard let u else { return "none" }
    func part(_ w: UsageWindow?) -> String {
        "\(w?.used_percentage.map { Int($0.rounded()) } ?? -1)@\(w?.resets_at.map { Int($0 / 60) } ?? -1)"
    }
    return "\(part(u.five_hour))|\(part(u.seven_day))|\(u.updated_at.map { Int($0 / 3600) } ?? -1)"
}

// WidgetKit gives a widget roughly 40–70 budgeted reloads a day (reloads requested by a background
// app count; refresh-button taps don't). Allow bursts of one a minute, about one per 15 minutes
// sustained, so a long working session can't use up the day's budget and freeze the widget.
struct ReloadBudget {
    static let capacity = 3.0
    static let refillInterval: TimeInterval = 900
    static let minGap: TimeInterval = 60

    private(set) var tokens = capacity
    private var refilledAt: Date?
    private var lastReload: Date?

    mutating func take(now: Date) -> Bool {
        if let r = refilledAt { tokens = min(Self.capacity, tokens + now.timeIntervalSince(r) / Self.refillInterval) }
        refilledAt = now
        if let l = lastReload, now.timeIntervalSince(l) < Self.minGap { return false }
        guard tokens >= 1 - 1e-9 else { return false }  // partial refills accumulate rounding error
        tokens -= 1
        lastReload = now
        return true
    }
}

// MARK: - Formatting

func pctText(_ p: Double?) -> String {
    guard let p else { return "–" }
    return "\(Int(p.rounded()))%"
}

func bar(_ p: Double?) -> String {
    let filled = min(10, max(0, Int(((p ?? 0) / 10).rounded())))
    return String(repeating: "▰", count: filled) + String(repeating: "▱", count: 10 - filled)
}

func durationText(_ seconds: Double) -> String {
    let m = Int(seconds / 60)
    if m < 60 { return "\(max(m, 1)) мин" }
    let h = m / 60
    if h < 24 { return m % 60 == 0 ? "\(h) ч" : "\(h) ч \(m % 60) мин" }
    return h % 24 == 0 ? "\(h / 24) д" : "\(h / 24) д \(h % 24) ч"
}

func resetText(_ w: UsageWindow?, now: Date) -> String {
    guard let r = w?.resets_at else { return "время сброса неизвестно" }
    let date = Date(timeIntervalSince1970: r)
    if date <= now { return "окно уже сброшено" }
    let f = DateFormatter()
    f.locale = ru
    f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EE HH:mm"
    return "сброс \(f.string(from: date)), через \(durationText(date.timeIntervalSince(now)))"
}

func agoText(_ t: Double, now: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.locale = ru
    return f.localizedString(for: Date(timeIntervalSince1970: t), relativeTo: now)
}
