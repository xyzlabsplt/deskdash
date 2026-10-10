import Foundation

/// The words of deskdash's menus and alerts, in English or Traditional Chinese, by the `language` setting: "" follows
/// macOS's first preferred language, or "en" or "zh-Hant". The dashboard's pages stay in English, sized as they are.
/// A dictionary rather than .strings files: deskdash.app is assembled by hand and carries no resource bundle.
enum L10n {
    nonisolated(unsafe) static var chinese = false

    static func apply(_ language: String) {
        let code = language.isEmpty ? Locale.preferredLanguages.first ?? "en" : language
        chinese = ["zh-Hant", "zh-TW", "zh-HK", "zh-MO"].contains { code.hasPrefix($0) }
    }

    static func t(_ english: String) -> String {
        chinese ? zhHant[english] ?? english : english
    }

    // MARK: alerts

    static func needsYou(_ who: String) -> String { chinese ? "\(t(who)) 需要你" : "\(who) needs you" }
    static func finished(_ who: String) -> String { chinese ? "\(t(who)) 完成了" : "\(who) finished" }

    /// "Claude Code 5-hour limit: 15% left"
    static func limitLow(_ who: String, week: Bool, left: Int) -> String {
        chinese ? "\(who) \(week ? "本週" : "5 小時")用量剩 \(left)%" : "\(who) \(week ? "weekly" : "5-hour") limit: \(left)% left"
    }

    static func resetsIn(_ duration: String) -> String { chinese ? "\(duration) 後重置" : "Resets in \(duration)" }

    static func menuHeader(page: String, screen: String) -> String {
        chinese ? "deskdash：\(t(page))（\(screen)）" : "deskdash: \(page) on \(screen)"
    }

    private static let zhHant: [String: String] = [
        // pages
        "Clock": "時鐘", "Now Playing": "正在播放", "Photos": "相簿", "Climate": "空氣品質", "Markets": "行情",
        "Agents": "AI 代理", "Limits": "用量", "Tokens": "Token 用量",
        // menus
        "Show Page": "顯示頁面", "Next Page": "下一頁", "Previous Page": "上一頁", "Pause Rotation": "暫停輪播",
        "Virtual Main Display When Alone": "只剩這個螢幕時加入虛擬主螢幕",
        "Hide for 10 Minutes": "隱藏 10 分鐘", "Show Dashboard": "顯示儀表板", "Settings…": "設定…",
        "Quit deskdash": "結束 deskdash", "Quit deskdash (until next login)": "結束 deskdash（直到下次登入）",
        // alerts
        "An agent": "有個 AI 代理", "A plan limit is running low": "方案用量快用完了",
        "A preview of deskdash's alert": "deskdash 提醒預覽", "CLICK TO DISMISS": "點一下關閉", "Close": "關閉",
        "permission prompt": "等你允許權限", "input needed": "等你回覆",
    ]
}
