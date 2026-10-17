import AppKit
import os
import ServiceManagement
import WidgetKit

// NSLog text shows up as <private> in the unified log; these messages hold no secrets.
let logger = Logger(subsystem: "local.shulika-illia.claude-usage-bar", category: "usage")

let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

func loadCache() -> UsageCache? { loadUsage(usageCacheURL) }

// Picked in the menu (UserDefaults "language"); the system language when unset.
func currentLang() -> Lang { Lang.resolve(setting: UserDefaults.standard.string(forKey: "language")) }

// Same access path Claude Code uses (/usr/bin/security), so macOS doesn't prompt.
func readKeychainCredentials() -> Data {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return Data() }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return p.terminationStatus == 0 ? data : Data()
}

struct FetchResult {
    var snapshot: UsageCache?
    var status: Int?
    var retryAfter: Double?
    var problem: APIProblem?
}

// No URLCache: URLSession.shared stores cacheable requests, Authorization header included,
// in ~/Library/Caches/<bundle id>/Cache.db — that would copy the token out of the Keychain.
let apiSession: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.urlCache = nil
    c.httpCookieStorage = nil
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: c)
}()

func fetchUsage(_ done: @escaping (FetchResult) -> Void) {
    let token: String
    switch tokenState(from: readKeychainCredentials(), now: Date()) {
    case .ok(let t): token = t
    case .expired: return done(FetchResult(problem: .tokenExpired))
    case .missing: return done(FetchResult(problem: .notLoggedIn))
    }
    var req = URLRequest(url: usageURL, timeoutInterval: 15)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.setValue("ClaudeUsageBar/1.0 (personal)", forHTTPHeaderField: "User-Agent")
    apiSession.dataTask(with: req) { data, response, _ in
        let http = response as? HTTPURLResponse
        var r = FetchResult(status: http?.statusCode,
                            retryAfter: http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
        switch http?.statusCode {
        case 200:
            r.snapshot = data.flatMap { decodeAPIUsage($0, fetchedAt: Date()) }
            if r.snapshot == nil { r.problem = .badResponse }
        case 429: r.problem = .rateLimited
        case 401, 403: r.problem = .denied
        case nil: r.problem = .offline
        case let code?: r.problem = .http(code)
        }
        done(r)
    }.resume()
}

func tint(_ p: Double) -> NSColor? {
    if p >= 90 { return .systemRed }
    if p >= 75 { return .systemOrange }
    return nil
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var api: UsageCache?
    private var apiProblem: APIProblem?
    private var apiDelay: TimeInterval = 300
    private var nextAPIAttempt = Date.distantPast
    private var rateLimited = false
    private var fetching = false
    private var lastAPIStart = Date.distantPast
    private var published: UsageCache?
    private var widgetShows: String?  // widgetKey of what the widget last loaded
    private var reloadBudget = ReloadBudget()
    private var lastAck: Double?
    private var ackAfterFetch = false
    private var refreshAskedAt = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent",
                                           accessibilityDescription: "Claude usage")
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let app = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { app.widgetAskedForRefresh() }
            },
            refreshNotification as CFString, nil, .deliverImmediately)
        // App Intents (the widget's refresh button) are indexed by bundle id, so unregistering any other
        // copy of the app (an Xcode build product) drops them for this one too. Re-registering on launch
        // restores them ("There is no metadata for RefreshUsageIntent").
        LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        restoreAPIState()
        tick()
        timer = Timer.scheduledTimer(timeInterval: 15, target: self, selector: #selector(tick),
                                     userInfo: nil, repeats: true)
    }

    @objc private func tick() {
        if shouldPoll(statuslineUpdatedAt: loadCache()?.updated_at, now: Date(), nextAttempt: nextAPIAttempt) {
            refreshFromAPI()
        }
        render()
    }

    private func refreshFromAPI() {
        guard !fetching else { return }
        fetching = true
        lastAPIStart = Date()
        DispatchQueue.global(qos: .utility).async {
            fetchUsage { r in DispatchQueue.main.async { self.finish(r) } }
        }
    }

    private func finish(_ r: FetchResult) {
        fetching = false
        if let s = r.snapshot { api = s }
        apiProblem = r.problem
        rateLimited = r.status == 429
        apiDelay = nextDelay(status: r.snapshot != nil ? 200 : r.status, retryAfter: r.retryAfter, previous: apiDelay)
        nextAPIAttempt = Date().addingTimeInterval(apiDelay)
        let status = r.status.map(String.init) ?? "-", note = r.problem.map { " (\($0.text(.en)))" } ?? ""
        logger.notice("usage api: HTTP \(status, privacy: .public)\(note, privacy: .public), next attempt in \(Int(self.apiDelay)) s")
        saveAPIState()
        if ackAfterFetch {
            ackAfterFetch = false
            acknowledgeWidget()
        } else {
            render()
        }
    }

    // The widget's refresh button: fetch fresh numbers if Claude Code hasn't reported for a minute,
    // then answer by stamping the snapshot; the widget reloads itself (unbudgeted) right after.
    private func widgetAskedForRefresh() {
        logger.notice("usage widget: refresh requested")
        refreshAskedAt = Date()
        let age = Date().timeIntervalSince1970 - (loadCache()?.updated_at ?? 0)
        if fetching {
            ackAfterFetch = true
        } else if age > 60, !rateLimited, Date().timeIntervalSince(lastAPIStart) >= 60 {
            ackAfterFetch = true
            refreshFromAPI()
        } else {
            acknowledgeWidget()
        }
    }

    private func acknowledgeWidget() {
        lastAck = Date().timeIntervalSince1970
        // A late answer (slow API) arrives after the widget has reloaded with the old files; then
        // leave widgetShows alone so the regular reload delivers the new numbers.
        if ackReachesWidget(askedAt: refreshAskedAt, now: Date()) {
            widgetShows = widgetKey(merge(loadCache(), api))
        }
        render()
    }

    // The last API numbers and the backoff survive relaunches (rebuilds, login), so a relaunch
    // neither drops them from the widget snapshot nor ignores the server's Retry-After.
    private func saveAPIState() {
        let d = UserDefaults.standard
        d.set(try? JSONEncoder().encode(api), forKey: "api")
        d.set(nextAPIAttempt.timeIntervalSince1970, forKey: "nextAPIAttempt")
        d.set(apiDelay, forKey: "apiDelay")
        d.set(rateLimited, forKey: "rateLimited")
        d.set(apiProblem?.raw, forKey: "apiProblem")
    }

    private func restoreAPIState() {
        let d = UserDefaults.standard
        api = d.data(forKey: "api").flatMap { try? JSONDecoder().decode(UsageCache.self, from: $0) }
        let next = Date(timeIntervalSince1970: d.double(forKey: "nextAPIAttempt"))
        guard next > Date() else { return }
        nextAPIAttempt = next
        apiDelay = max(d.double(forKey: "apiDelay"), 300)
        rateLimited = d.bool(forKey: "rateLimited")
        apiProblem = d.string(forKey: "apiProblem").flatMap(APIProblem.init(raw:))
    }

    private func render() {
        let now = Date()
        let usage = merge(loadCache(), api)
        let five = percent(usage?.five_hour, now: now)
        let week = percent(usage?.seven_day, now: now)
        let text = usage == nil ? " —" : " \(pctText(five)) · \(pctText(week))"
        var attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
        ]
        if let c = tint(max(five ?? 0, week ?? 0)) { attrs[.foregroundColor] = c }
        statusItem.button?.attributedTitle = NSAttributedString(string: text, attributes: attrs)
        publishForWidget(usage)
    }

    // The widget can't reach the API or Keychain, so it reads this snapshot.
    private func publishForWidget(_ usage: UsageCache?) {
        guard var snapshot = usage else { return }
        snapshot.refreshed_at = lastAck
        snapshot.lang = currentLang().rawValue
        if snapshot != published {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: widgetSnapshotURL, options: .atomic)
            }
            published = snapshot
        }
        let key = widgetKey(snapshot)
        if key != widgetShows, reloadBudget.take(now: Date()) {
            WidgetCenter.shared.reloadAllTimelines()
            widgetShows = key
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let now = Date()
        let lang = currentLang()
        let cache = loadCache()
        if let usage = merge(cache, api) {
            for (title, w) in [(S.sessionLong(lang), usage.five_hour), (S.weekLong(lang), usage.seven_day)] {
                let p = percent(w, now: now)
                addInfo(menu, "\(title)   \(bar(p))  \(pctText(p))")
                addInfo(menu, resetText(w, now: now, lang: lang), secondary: true)
            }
        } else {
            addInfo(menu, S.noDataMenu(lang))
        }
        menu.addItem(.separator())
        if let u = cache?.updated_at {
            addInfo(menu, "Claude Code: \(agoText(u, now: now, lang: lang))", secondary: true)
        }
        if let problem = apiProblem {
            let retry = rateLimited ? S.apiRetry(lang, agoText(nextAPIAttempt.timeIntervalSince1970, now: now, lang: lang)) : ""
            addInfo(menu, "API: \(problem.text(lang))\(retry)", secondary: true)
        } else if let u = api?.updated_at {
            addInfo(menu, "API: \(agoText(u, now: now, lang: lang))", secondary: true)
        } else {
            addInfo(menu, S.apiNotNeeded(lang), secondary: true)
        }
        menu.addItem(.separator())
        let refresh = menu.addItem(withTitle: S.refreshNow(lang), action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        refresh.isEnabled = !fetching && !rateLimited
        let open = menu.addItem(withTitle: S.openUsage(lang), action: #selector(openUsage), keyEquivalent: "")
        open.target = self
        let login = menu.addItem(withTitle: S.launchAtLogin(lang), action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(languageMenuItem(lang))
        menu.addItem(.separator())
        menu.addItem(withTitle: S.quit(lang), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    // "System" plus each language under its own name; the choice is stored in UserDefaults "language".
    private func languageMenuItem(_ lang: Lang) -> NSMenuItem {
        let item = NSMenuItem(title: S.language(lang), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let chosen = UserDefaults.standard.string(forKey: "language").flatMap(Lang.init(rawValue:))?.rawValue
        let choices: [(String, String?)] = [(S.languageSystem(lang), nil)] + Lang.allCases.map { ($0.nativeName, $0.rawValue) }
        for (title, value) in choices {
            let choice = submenu.addItem(withTitle: title, action: #selector(chooseLanguage(_:)), keyEquivalent: "")
            choice.target = self
            choice.representedObject = value
            choice.state = chosen == value ? .on : .off
        }
        item.submenu = submenu
        return item
    }

    @objc private func chooseLanguage(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.representedObject as? String, forKey: "language")
        render()  // writes the widget snapshot with the new language
        WidgetCenter.shared.reloadAllTimelines()  // rare and user-initiated, worth a budgeted reload
    }

    private func addInfo(_ menu: NSMenu, _ text: String, secondary: Bool = false) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: secondary ? NSFont.systemFont(ofSize: 11)
                             : NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: secondary ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ])
        menu.addItem(item)
    }

    @objc private func refreshNow() {
        refreshFromAPI()
    }

    @objc private func openUsage() {
        NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

func printUsage(_ label: String, _ u: UsageCache?) {
    let now = Date(), lang = currentLang()
    guard let u else { return print("\(label): no data") }
    print("\(label): 5h \(pctText(percent(u.five_hour, now: now))) (\(resetText(u.five_hour, now: now, lang: lang))); "
        + "7d \(pctText(percent(u.seven_day, now: now))) (\(resetText(u.seven_day, now: now, lang: lang)))")
}

let args = CommandLine.arguments
if args.contains("--print") {
    printUsage("statusline", loadCache())
    exit(0)
}
if args.contains("--fetch") {
    let done = DispatchSemaphore(value: 0)
    fetchUsage { r in
        print("HTTP \(r.status.map(String.init) ?? "-")\(r.problem.map { " · \($0.text(currentLang()))" } ?? "")")
        printUsage("api", r.snapshot)
        printUsage("merged", merge(loadCache(), r.snapshot))
        done.signal()
    }
    done.wait()
    exit(0)
}
if let i = args.firstIndex(of: "--login"), i + 1 < args.count {
    do {
        if args[i + 1] == "on" { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        print("login item status: \(SMAppService.mainApp.status.rawValue)")
        exit(0)
    } catch {
        print("error: \(error)")
        exit(1)
    }
}
if let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
