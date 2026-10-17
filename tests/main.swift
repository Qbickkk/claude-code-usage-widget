import Foundation

// Test runner for Usage.swift: swiftc ../Usage.swift main.swift && ./a.out
var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "ok   \(name)" : "FAIL \(name)")
    if !ok { failures += 1 }
}

let r5 = 1_792_270_200.0
let w = { (p: Double, r: Double?) in UsageWindow(used_percentage: p, resets_at: r) }

// mergeWindow
check("nil + b = b", mergeWindow(nil, w(5, r5)) == w(5, r5))
check("a + nil = a", mergeWindow(w(5, r5), nil) == w(5, r5))
check("same window: higher wins", mergeWindow(w(20, r5), w(15, r5)) == w(20, r5))
check("same window: higher wins (other order)", mergeWindow(w(15, r5), w(20, r5)) == w(20, r5))
check("same window within a minute", mergeWindow(w(20, r5), w(21, r5 + 30)) == w(21, r5 + 30))
check("newer window wins even if lower", mergeWindow(w(90, r5), w(2, r5 + 18000)) == w(2, r5 + 18000))
check("older window loses", mergeWindow(w(2, r5 + 18000), w(90, r5)) == w(2, r5 + 18000))
check("missing percentage ignored", mergeWindow(w(7, r5), UsageWindow(used_percentage: nil, resets_at: r5)) == w(7, r5))

// merge of whole snapshots keeps the newest timestamp
let a = UsageCache(five_hour: w(20, r5), seven_day: w(30, r5 + 200_000), updated_at: 100)
let b = UsageCache(five_hour: w(22, r5), seven_day: nil, updated_at: 200)
let m = merge(a, b)
check("merge five", m?.five_hour == w(22, r5))
check("merge keeps week from a", m?.seven_day == w(30, r5 + 200_000))
check("merge updated_at is newest", m?.updated_at == 200)
check("merge nil nil", merge(nil, nil) == nil)

// percent
check("passed reset counts as 0", percent(w(80, 1000), now: Date(timeIntervalSince1970: 2000)) == 0)
check("future reset keeps value", percent(w(80, 3000), now: Date(timeIntervalSince1970: 2000)) == 80)

// API response, shape as returned by /api/oauth/usage on 2026-10-17
let apiJSON = """
{"five_hour":{"utilization":21.0,"resets_at":"2026-10-17T20:50:00.127573+00:00","limit_dollars":null},
 "seven_day":{"utilization":27,"resets_at":"2026-10-20T08:00:00.127591+00:00"},
 "seven_day_opus":null,"limits":[{"kind":"session","percent":21}],"extra_usage":{"is_enabled":false}}
""".data(using: .utf8)!
let api = decodeAPIUsage(apiJSON, fetchedAt: Date(timeIntervalSince1970: 500))
check("api five utilization", api?.five_hour?.used_percentage == 21)
check("api five resets_at (microseconds dropped)", api?.five_hour?.resets_at == 1_792_270_200)
check("api week int utilization", api?.seven_day?.used_percentage == 27)
check("api fetchedAt", api?.updated_at == 500)
let idle = decodeAPIUsage(#"{"five_hour":{"utilization":0,"resets_at":null},"seven_day":null}"#.data(using: .utf8)!,
                          fetchedAt: Date())
check("api idle window", idle?.five_hour == UsageWindow(used_percentage: 0, resets_at: nil) && idle?.seven_day == nil)
check("api garbage", decodeAPIUsage("<html>".data(using: .utf8)!, fetchedAt: Date()) == nil)
check("iso without fraction", parseISODate("2026-10-17T20:50:00+00:00") == 1_792_270_200)

// Keychain credentials (security -w prints the JSON plus a newline)
let now = Date(timeIntervalSince1970: 1_792_266_000)
let creds = { (exp: Double) in
    "{\"claudeAiOauth\":{\"accessToken\":\"tok\",\"refreshToken\":\"r\",\"expiresAt\":\(exp)}}\n".data(using: .utf8)!
}
check("valid token", tokenState(from: creds(1_792_270_000_000), now: now) == .ok("tok"))
check("expired token", tokenState(from: creds(1_792_265_000_000), now: now) == .expired)
check("only mcp creds", tokenState(from: #"{"mcpOAuth":{}}"#.data(using: .utf8)!, now: now) == .missing)
check("empty keychain output", tokenState(from: Data(), now: now) == .missing)

// Backoff
check("success -> 5 min", nextDelay(status: 200, retryAfter: nil, previous: 1800) == 300)
check("429 doubles", nextDelay(status: 429, retryAfter: nil, previous: 300) == 600)
check("429 honours Retry-After", nextDelay(status: 429, retryAfter: 1362, previous: 300) == 1362)
check("429 doubling capped at 30 min", nextDelay(status: 429, retryAfter: nil, previous: 1800) == 1800)
check("429 long Retry-After capped at 6 h", nextDelay(status: 429, retryAfter: 99999, previous: 300) == 21600)
check("auth error -> 30 min", nextDelay(status: 401, retryAfter: nil, previous: 300) == 1800)
check("network error doubles", nextDelay(status: nil, retryAfter: nil, previous: 300) == 600)

// When to poll the API
let t0 = Date(timeIntervalSince1970: 10_000)
check("fresh statusline: no poll", !shouldPoll(statuslineUpdatedAt: 9_950, now: t0, nextAttempt: .distantPast))
check("stale statusline: poll", shouldPoll(statuslineUpdatedAt: 9_000, now: t0, nextAttempt: .distantPast))
check("no statusline data: poll", shouldPoll(statuslineUpdatedAt: nil, now: t0, nextAttempt: .distantPast))
check("stale but backing off: no poll",
      !shouldPoll(statuslineUpdatedAt: 9_000, now: t0, nextAttempt: t0.addingTimeInterval(60)))

// Widget timeline: every 5 min for an hour, plus right after a reset inside that hour
let start = Date(timeIntervalSince1970: 1_000_000)
let resetSoon = UsageCache(five_hour: w(50, 1_000_000 + 1000), seven_day: w(10, 1_000_000 + 900_000), updated_at: nil)
let dates = timelineDates(from: start, usage: resetSoon)
check("timeline starts now", dates.first == start)
check("timeline spans two hours", dates.last == start.addingTimeInterval(7200))
check("timeline has reset entry", dates.contains(Date(timeIntervalSince1970: 1_000_000 + 1001)))
check("timeline sorted and unique", dates == Array(Set(dates)).sorted())
check("timeline count", dates.count == 26)
check("timeline without data", timelineDates(from: start, usage: nil).count == 25)

// Widget reload key changes on visible changes only
let k1 = widgetKey(UsageCache(five_hour: w(24.2, r5), seven_day: w(28, r5 + 200_000), updated_at: 1_792_266_000))
let k2 = widgetKey(UsageCache(five_hour: w(24.4, r5), seven_day: w(28, r5 + 200_000), updated_at: 1_792_266_100))
let k3 = widgetKey(UsageCache(five_hour: w(25, r5), seven_day: w(28, r5 + 200_000), updated_at: 1_792_266_100))
let k4 = widgetKey(UsageCache(five_hour: w(24.2, r5), seven_day: w(28, r5 + 200_000), updated_at: 1_792_270_000))
let k5 = widgetKey(UsageCache(five_hour: w(24.2, r5), seven_day: w(28, r5 + 200_000), updated_at: 1_792_267_000))
check("key ignores sub-percent and seconds", k1 == k2)
check("key changes with percent", k1 != k3)
check("key changes with hourly data age bucket", k1 != k4)
check("key ignores data age within the hour", k1 == k5)
check("key ignores refresh ack", widgetKey(UsageCache(five_hour: w(24.2, r5), seven_day: w(28, r5 + 200_000),
                                                      updated_at: 1_792_266_000, refreshed_at: 5)) == k1)

// Reload budget: bursts of one per minute, about one per 15 minutes sustained
var budget = ReloadBudget()
let b0 = Date(timeIntervalSince1970: 0)
check("budget: first reload", budget.take(now: b0))
check("budget: min gap 60 s", !budget.take(now: b0.addingTimeInterval(30)))
check("budget: second after a minute", budget.take(now: b0.addingTimeInterval(60)))
check("budget: third after two minutes", budget.take(now: b0.addingTimeInterval(120)))
check("budget: burst exhausted", !budget.take(now: b0.addingTimeInterval(180)))
check("budget: still empty at 10 min", !budget.take(now: b0.addingTimeInterval(600)))
check("budget: refilled by 15 min", budget.take(now: b0.addingTimeInterval(900)))
check("budget: empty again right after", !budget.take(now: b0.addingTimeInterval(960)))
var idleBudget = ReloadBudget()
_ = idleBudget.take(now: b0)
check("budget: long idle refills only to capacity", idleBudget.take(now: b0.addingTimeInterval(86400))
      && idleBudget.take(now: b0.addingTimeInterval(86460)) && idleBudget.take(now: b0.addingTimeInterval(86520))
      && !idleBudget.take(now: b0.addingTimeInterval(86580)))

// A refresh answer counts as seen by the widget only while its intent is still waiting
let asked = Date(timeIntervalSince1970: 0)
check("ack in time", ackReachesWidget(askedAt: asked, now: asked.addingTimeInterval(0.4)))
check("ack too late", !ackReachesWidget(askedAt: asked, now: asked.addingTimeInterval(widgetRefreshWait)))

// Durations
check("duration < 1 min", durationText(30) == "1 мин")
check("duration minutes", durationText(48 * 60) == "48 мин")
check("duration whole hours", durationText(2 * 3600) == "2 ч")
check("duration hours+min", durationText(2 * 3600 + 600) == "2 ч 10 мин")
check("duration whole day", durationText(86400 + 120) == "1 д")
check("duration days+hours", durationText(2.5 * 86400) == "2 д 12 ч")

// Paths resolve to the real home even inside the widget sandbox
check("cache path", usageCacheURL.path.hasSuffix("/.claude/usage-cache.json") && !usageCacheURL.path.contains("/Containers/"))

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
