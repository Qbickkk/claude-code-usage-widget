import Foundation

enum Lang: String, CaseIterable {
    case uk, en, ru

    var locale: Locale {
        switch self {
        case .uk: return Locale(identifier: "uk_UA")
        case .en: return Locale(identifier: "en_US")
        case .ru: return Locale(identifier: "ru_RU")
        }
    }

    var nativeName: String {
        switch self {
        case .uk: return "Українська"
        case .en: return "English"
        case .ru: return "Русский"
        }
    }

    // The first of the user's preferred languages that the app has; English otherwise.
    static func preferred(_ languages: [String] = Locale.preferredLanguages) -> Lang {
        for id in languages {
            if let lang = Lang(rawValue: Locale(identifier: id).language.languageCode?.identifier ?? "") {
                return lang
            }
        }
        return .en
    }

    // setting: the language picked in the menu ("uk", "en", "ru"); nil or anything else means system.
    static func resolve(setting: String?, preferred languages: [String] = Locale.preferredLanguages) -> Lang {
        setting.flatMap(Lang.init(rawValue:)) ?? preferred(languages)
    }
}

// UI strings. Every case lists (uk, en, ru), so a missing translation doesn't compile.
// %1, %2 are replaced by the arguments: S.resetLine(lang, time, duration).
enum S: CaseIterable {
    case session, week, sessionLong, weekLong
    case noData, noDataMenu, noDataHint
    case asOf, reset, inDuration, resetLine, resetUnknown, windowAlreadyReset, windowReset
    case minutes, hours, days
    case apiRetry, apiNotNeeded
    case refreshNow, openUsage, launchAtLogin, language, languageSystem, quit
    case tokenExpired, notLoggedIn, badResponse, rateLimited, denied, offline, httpError
    case widgetName, widgetDescription

    private var text: (uk: String, en: String, ru: String) {
        switch self {
        case .session: return ("Сесія", "Session", "Сессия")
        case .week: return ("Тиждень", "Week", "Неделя")
        case .sessionLong: return ("Сесія · 5 год", "Session · 5 h", "Сессия · 5 ч")
        case .weekLong: return ("Тиждень · 7 дн", "Week · 7 d", "Неделя · 7 д")
        case .noData: return ("Немає даних", "No data", "Нет данных")
        case .noDataMenu: return ("Немає даних — відкрийте Claude Code", "No data — open Claude Code",
                                  "Нет данных — откройте Claude Code")
        case .noDataHint: return ("Відкрийте Claude Code або Claude Usage Bar на смузі меню",
                                  "Open Claude Code or Claude Usage Bar in the menu bar",
                                  "Откройте Claude Code или Claude Usage Bar в строке меню")
        case .asOf: return ("на %1", "as of %1", "на %1")
        // Short "until" form in uk/ru keeps the small widget's reset line from overflowing.
        case .reset: return ("до %1", "resets %1", "до %1")
        case .inDuration: return ("через %1", "in %1", "через %1")
        case .resetLine: return ("скидання %1, через %2", "resets %1, in %2", "сброс %1, через %2")
        case .resetUnknown: return ("час скидання невідомий", "reset time unknown", "время сброса неизвестно")
        case .windowAlreadyReset: return ("ліміт уже скинуто", "limit already reset", "лимит уже сброшен")
        case .windowReset: return ("ліміт скинуто", "limit reset", "лимит сброшен")
        case .minutes: return ("хв", "min", "мин")
        case .hours: return ("год", "h", "ч")
        case .days: return ("дн", "d", "д")
        case .apiRetry: return (", повтор %1", ", retrying %1", ", повтор %1")
        case .apiNotNeeded: return ("API: не потрібен, поки Claude Code активний",
                                    "API: not needed while Claude Code is active",
                                    "API: не нужен, пока Claude Code активен")
        case .refreshNow: return ("Оновити зараз", "Refresh Now", "Обновить сейчас")
        case .openUsage: return ("Відкрити claude.ai → Usage", "Open claude.ai → Usage", "Открыть claude.ai → Usage")
        case .launchAtLogin: return ("Відкривати під час входу в систему", "Open at Login", "Открывать при входе")
        case .language: return ("Мова", "Language", "Язык")
        case .languageSystem: return ("Як у системі", "System", "Как в системе")
        case .quit: return ("Завершити", "Quit", "Завершить")
        case .tokenExpired: return ("токен прострочено — відкрийте Claude Code", "token expired — open Claude Code",
                                    "токен истёк — откройте Claude Code")
        // Shown after "API: " in the menu, so these don't repeat "API".
        case .notLoggedIn: return ("немає даних входу Claude Code у Keychain", "no Claude Code login in Keychain",
                                   "нет учётных данных Claude Code в Keychain")
        case .badResponse: return ("неочікувана відповідь", "unexpected response", "неожиданный ответ")
        case .rateLimited: return ("перевищено ліміт запитів", "rate limited", "превышен лимит запросов")
        case .denied: return ("доступ заборонено", "access denied", "доступ запрещён")
        case .offline: return ("немає звʼязку", "can't connect", "нет связи")
        case .httpError: return ("помилка HTTP %1", "HTTP error %1", "ошибка HTTP %1")
        case .widgetName: return ("Claude Code — ліміти", "Claude Code Limits", "Claude Code — лимиты")
        case .widgetDescription: return ("Сесія (5 год) і тиждень: відсотки та час скидання.",
                                         "Session (5 h) and weekly usage with reset times.",
                                         "Сессия (5 ч) и неделя: проценты и время сброса.")
        }
    }

    func callAsFunction(_ lang: Lang, _ args: String...) -> String {
        var s: String
        switch lang {
        case .uk: s = text.uk
        case .en: s = text.en
        case .ru: s = text.ru
        }
        for (i, arg) in args.enumerated() { s = s.replacingOccurrences(of: "%\(i + 1)", with: arg) }
        return s
    }
}

// Why the last API request gave no numbers. Stored by raw value so it survives relaunches and is
// shown in whatever language is current.
enum APIProblem: Equatable {
    case tokenExpired, notLoggedIn, badResponse, rateLimited, denied, offline
    case http(Int)

    private static let simple: [APIProblem] = [.tokenExpired, .notLoggedIn, .badResponse, .rateLimited, .denied, .offline]

    var raw: String {
        if case .http(let code) = self { return "http:\(code)" }
        return "\(self)"
    }

    init?(raw: String) {
        if raw.hasPrefix("http:"), let code = Int(raw.dropFirst(5)) {
            self = .http(code)
        } else if let p = Self.simple.first(where: { $0.raw == raw }) {
            self = p
        } else {
            return nil
        }
    }

    func text(_ lang: Lang) -> String {
        switch self {
        case .tokenExpired: return S.tokenExpired(lang)
        case .notLoggedIn: return S.notLoggedIn(lang)
        case .badResponse: return S.badResponse(lang)
        case .rateLimited: return S.rateLimited(lang)
        case .denied: return S.denied(lang)
        case .offline: return S.offline(lang)
        case .http(let code): return S.httpError(lang, String(code))
        }
    }
}
