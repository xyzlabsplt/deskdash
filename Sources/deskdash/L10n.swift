import Foundation

/// deskdash's words, on the pages and in the menus, alerts and Settings, in English or Traditional Chinese, by the
/// `language` setting: "" follows macOS's first preferred language, or "en" or "zh-Hant". Dates and durations follow
/// it too (`Fmt`).
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

    /// Between two sentences: Chinese runs them together.
    static var space: String { chinese ? "" : " " }

    /// `t` for a sentence with values in it: the English is a format with %@ for each, as is its translation.
    static func f(_ english: String, _ values: String...) -> String {
        String(format: t(english), arguments: values)
    }

    // MARK: alerts

    static func needsYou(_ who: String) -> String { chinese ? "\(t(who)) 需要你" : "\(who) needs you" }
    static func finished(_ who: String) -> String { chinese ? "\(t(who)) 完成了" : "\(who) finished" }

    /// "Claude Code 5-hour limit: 15% left"
    static func limitLow(_ who: String, week: Bool, left: Int) -> String {
        chinese ? "\(who) \(week ? "本週" : "5 小時")用量剩 \(left)%" : "\(who) \(week ? "weekly" : "5-hour") limit: \(left)% left"
    }

    static func resetsIn(_ duration: String) -> String { chinese ? "\(duration) 後重置" : "Resets in \(duration)" }

    // MARK: pages

    static func ago(_ duration: String) -> String { chinese ? "\(duration)前" : duration.uppercased() + " AGO" }
    static func more(_ count: Int) -> String { chinese ? "還有 \(count) 個" : "+\(count) more" }
    static func days(_ count: Int) -> String { chinese ? "\(count) 天" : count == 1 ? "1 day" : "\(count) days" }

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
        // pages
        "NEEDS YOU": "需要你", "WORKING": "工作中", "DONE": "完成", "IDLE": "閒置",
        "LEFT  5H": "5 小時內剩餘", "LEFT  WEEK": "本週剩餘",
        "NO 5-HOUR LIMIT": "沒有 5 小時限制", "NO WEEKLY LIMIT": "沒有每週限制",
        "TODAY": "今天", "7 DAYS": "7 天", "30 DAYS": "30 天", "ALL TIME": "累計", "STREAK": "連續",
        "TEMP": "溫度", "OUTSIDE": "戶外",
        "Sensors are off: turn on Continuous Monitoring in the Dyson app": "感測器已關閉：請在 Dyson App 開啟「持續監測」",
        // Settings
        "Turn the dock screen off when the Mac is unused for": "Mac 閒置多久後關閉擴充座螢幕",
        "Sleep hours": "休眠時間",
        "The dock screen goes black when no one has used the keyboard or mouse for that long, and comes back with any input or alert. In sleep hours it stays black, alerts or not, and the displays may sleep.": "鍵盤滑鼠閒置超過設定時間，擴充座螢幕就會變全黑；一有操作或 AI 提醒就會亮起。休眠時間內螢幕固定全黑，有提醒也不亮，螢幕也可以進入睡眠。",
        "Sources": "資料來源",
        "Claude Code sessions": "Claude Code 工作階段",
        "Codex sessions": "Codex 工作階段",
        "Claude plan limits": "Claude 方案額度",
        "Codex plan limits": "Codex 方案額度",
        "Reading · %@ open now": "讀取中 · 目前 %@ 個",
        "Hook installed": "已安裝 hook",
        "Not installed": "尚未安裝",
        "Install the hook": "安裝 hook",
        "No report yet": "還沒有資料",
        "%@ · updated %@ ago": "%@ · %@前更新",
        "Updated %@ ago": "%@前更新",
        "Claude's limits update while you talk with Claude in the desktop app, and from the status line when you use Claude Code in a terminal. Codex reports its limits after each reply, in its own logs.": "Claude 的額度在你用桌面版和 Claude 對話時更新，在終端機用 Claude Code 時則由狀態列更新。Codex 每次回覆後會在自己的 log 記錄額度。",
        "After installing, type /hooks in Codex once to trust it.": "安裝後，請在 Codex 輸入一次 /hooks 信任它。",
        "Sound": "提醒音",
        "Card": "提醒卡片",
        "Jumping to a page": "跳頁",
        "The sound stops when someone uses this Mac's keyboard or mouse.": "有人動了這台 Mac 的鍵盤或滑鼠，提醒音就會停止。",
        "Click the dashboard to close the card.": "點一下儀表板可以關閉卡片。",
        "Installing…": "安裝中…",
        "Could not run %@.": "無法執行 %@。",
        "Reading the Photos app's albums…": "正在讀取「照片」App 的相簿…",
        "deskdash may not read the Photos library: allow it in System Settings → Privacy & Security → Photos.": "deskdash 沒有讀取照片圖庫的權限：請到「系統設定 → 隱私權與安全性 → 照片」允許。",
        "The Photos app has no albums with pictures.": "「照片」App 裡沒有含照片的相簿。",
        "General": "一般",
        "Weather & Time": "天氣與時間",
        "Purifier": "空氣清淨機",
        "Now Playing (while Music or Spotify plays)": "正在播放（Apple Music 或 Spotify 播放時）",
        "Photos (an album or a folder, under Photos)": "相簿（在「相簿」分頁選相簿或資料夾）",
        "Climate (from the purifier)": "空氣品質（來自空氣清淨機）",
        "Limits (what is left of the Claude and Codex plans)": "用量（Claude 與 Codex 方案還剩多少）",
        "Tokens (what the coding agents used)": "Token 用量（AI 程式助理用了多少）",
        "Language": "語言",
        "Pages, menus, alerts and Settings": "頁面、選單、提醒與設定",
        "Follow macOS": "跟隨 macOS",
        "Dock screen": "擴充座螢幕",
        "Show the dashboard on": "儀表板顯示在",
        "Make a connected monitor or iPad the main display": "接上螢幕或 iPad 時，讓它成為主螢幕",
        "Add a virtual main display when the dock screen is the only one": "只剩擴充座螢幕時，加入虛擬主螢幕",
        "macOS opens windows on the main display, and the dashboard stays behind them there. The virtual display is for using this Mac remotely (Parsec, Screen Sharing) with no monitor; it uses a private macOS API. Right-click the dashboard to turn it off.": "macOS 會把視窗開在主螢幕上，儀表板在主螢幕上只能待在視窗後面。虛擬螢幕適合沒接螢幕、用 Parsec 或螢幕共享遠端操作時使用，它用的是 macOS 的非公開 API。在儀表板上按右鍵可以關掉。",
        "Pages": "頁面",
        "Each page stays": "每頁停留",
        "The clock stays": "時鐘停留",
        "24-hour clock": "24 小時制",
        "CPU, temperature, memory, SSD and network along the bottom": "底部顯示 CPU、溫度、記憶體、SSD 與網路",
        "What's playing in Music or Spotify": "Apple Music 或 Spotify 正在播放的歌曲",
        "Time zone": "時區",
        "This Mac's (%@)": "這台 Mac 的（%@）",
        "Use this Mac's": "改用這台 Mac 的",
        "To show another place's time, choose the place under Weather & Time.": "要顯示其他地方的時間，請在「天氣與時間」選擇地點。",
        "Now playing": "正在播放",
        "Show each new track full screen": "每首新歌全螢幕顯示",
        "Shows for": "顯示",
        "Look up covers (Spotify, Apple's iTunes Search)": "查詢專輯封面（Spotify、Apple 的 iTunes 搜尋）",
        "Music and Spotify on this Mac announce each track themselves; nothing needs a permission.": "這台 Mac 上的 Apple Music 和 Spotify 會自己通知播放的歌曲，不需要任何權限。",
        "Schedule": "排程",
        "Keep the displays awake": "讓螢幕保持喚醒",
        "Brightness": "亮度",
        "All day": "全天",
        "Daytime": "白天",
        "Dim the dashboard at night": "夜間調暗儀表板",
        "At night": "夜間",
        "While you drag a slider, the dock screen shows that level.": "拖動滑桿時，擴充座螢幕會即時顯示該亮度。",
        "From": "從",
        "to": "到",
        "Pictures from": "照片來源",
        "Source": "來源",
        "An album in the Photos app": "「照片」App 的相簿",
        "A folder": "資料夾",
        "Album": "相簿",
        "Choose an album": "選擇相簿",
        "Folder": "資料夾",
        "None yet": "尚未選擇",
        "Choose…": "選擇…",
        "Showing": "顯示",
        "Shuffle": "隨機播放",
        "Crop each picture to fill the screen": "裁切照片填滿螢幕",
        "The time and date in the corner": "角落顯示時間與日期",
        "Each picture stays": "每張照片停留",
        "A different picture each time the page comes round. deskdash only reads the pictures, and keeps no copies; pictures kept only in iCloud are downloaded at the size the dock screen needs.": "每次輪到這頁會換一張照片。deskdash 只讀取照片，不會另存副本；只存在 iCloud 的照片會以擴充座螢幕需要的大小下載。",
        "Choose": "選擇",
        "Location": "地點",
        "A place without a name": "未命名的地點",
        "Coordinates": "座標",
        "No place yet: find your city below": "尚未設定：請在下方搜尋你的城市",
        "Find a city": "搜尋城市",
        "City name, like Lisbon": "城市名稱，例如 Taipei",
        "Search": "搜尋",
        "The clock shows this place's time": "時鐘顯示這個地點的時間",
        "Weather": "天氣",
        "Show outdoor weather": "顯示戶外天氣",
        "Fahrenheit": "華氏",
        "Searching…": "搜尋中…",
        "Could not reach Open-Meteo's place search.": "無法連線到 Open-Meteo 的地點搜尋。",
        "No place called “%@”.": "找不到「%@」這個地點。",
        "Now showing %@.": "現在顯示 %@。",
        "Hyperliquid perps, in order": "Hyperliquid 永續合約（依順序）",
        "Add a symbol": "新增代號",
        "Its Hyperliquid name, like SOL": "Hyperliquid 上的名稱，例如 SOL",
        "Add": "新增",
        "Tickers per page": "每頁幾檔",
        "Up to five fit on the dock screen, sized to fill it. More symbols make more pages.": "擴充座螢幕一頁最多放五檔，會自動放大填滿。代號更多就會分成多頁。",
        "Checking %@ on Hyperliquid…": "正在 Hyperliquid 查詢 %@…",
        "Could not reach Hyperliquid.": "無法連線到 Hyperliquid。",
        "Hyperliquid has no perp called %@.": "Hyperliquid 沒有叫 %@ 的永續合約。",
        "Added %@.": "已新增 %@。",
        "Public channels": "公開頻道",
        "Preview": "預覽",
        "Add a channel": "新增頻道",
        "t.me link or @name": "t.me 連結或 @名稱",
        "New posts": "新貼文",
        "Each one shows for": "每則顯示",
        "Check for them every": "檢查間隔",
        "Public channels only: deskdash reads Telegram's public preview page, without an account. Preview shows a channel's newest post on the dock screen.": "僅限公開頻道：deskdash 讀取 Telegram 的公開預覽頁，不需要帳號。按「預覽」會在擴充座螢幕顯示頻道的最新貼文。",
        "That is not a channel link or name.": "這不是頻道連結或名稱。",
        "Already watching t.me/%@.": "已經在追蹤 t.me/%@。",
        "Checking t.me/%@…": "正在檢查 t.me/%@…",
        "t.me/%@ has no public preview. Only public channels work.": "t.me/%@ 沒有公開預覽，只支援公開頻道。",
        "Sessions": "工作階段",
        "Show Claude Code sessions": "顯示 Claude Code 的工作階段",
        "A finished session shows DONE for": "完成的工作階段顯示「完成」",
        "min": "分鐘",
        "Hide idle sessions after": "閒置多久後隱藏",
        "h": "小時",
        "Alerts": "提醒",
        "Jump to the agents page when a session needs you": "有工作階段需要你時，跳到 AI 代理頁",
        "…and briefly when one finishes": "…完成時也短暫跳過去",
        "Hold the agents page for": "AI 代理頁停留",
        "Sound and card": "提醒音與卡片",
        "Play a sound until you are back": "播放提醒音，直到你回到電腦前",
        "When a session needs you": "需要你時",
        "When a session finishes": "完成時",
        "When a plan limit runs low": "方案用量快用完時",
        "Ring again after": "第一次重響",
        "Once": "只響一次",
        "Then at most every": "之後最長間隔",
        "Through Notification Center, so a Focus or Sleep keeps it quiet": "透過通知中心播放（專注模式、睡眠時會自動靜音）",
        "No sound at night": "夜間不響",
        "Show a card on the dock screen until it is over": "在擴充座螢幕顯示提醒卡片，直到處理完",
        "The sound stops when someone uses this Mac's keyboard or mouse. Click the dashboard to close the card.": "有人動了這台 Mac 的鍵盤或滑鼠，提醒音就會停止。點一下儀表板可以關閉卡片。",
        "Plan limits": "方案用量",
        "Alert when less than this is left": "剩餘低於此值時提醒",
        "Never": "不提醒",
        "…and jump to the limits page": "…並跳到用量頁",
        "Codex reports its limits in its own logs. Claude Code reports them to its status line, in a terminal; run this in Terminal to pass them on:": "Codex 的用量記錄在它自己的 log 裡。Claude Code 只在終端機版的狀態列提供用量；在「終端機」執行以下指令即可轉給 deskdash：",
        "Token usage": "Token 用量",
        "Weeks in the heatmap": "熱度圖週數",
        "Counted from the logs Claude Code, Codex, Gemini CLI and Muse Code keep on this Mac, reading only their token counts.": "從這台 Mac 上 Claude Code、Codex、Gemini CLI 和 Muse Code 的 log 計算，只讀取 token 數量。",
        "Each day's totals are also kept in %@, since Claude Code deletes transcripts after 30 days.": "因為 Claude Code 會在 30 天後刪除對話紀錄，每日總數另外保存在 %@。",
        "The Tokens page is under General → Pages.": "Token 用量頁的開關在「一般 → 頁面」。",
        "Codex sessions appear once deskdash's hook is installed. Run this in Terminal:": "安裝 deskdash 的 hook 後，Codex 的工作階段才會出現。請在「終端機」執行：",
        "Then type /hooks in Codex to trust it.": "然後在 Codex 輸入 /hooks 信任它。",
        "That is not a Dyson Wi-Fi name. It looks like DYSON-XXX-XX-XXXXXXXX-664.": "這不是 Dyson 的 Wi-Fi 名稱。它長得像 DYSON-XXX-XX-XXXXXXXX-664。",
        "Type the whole email address you sign in to the Dyson app with.": "請輸入你登入 Dyson App 的完整電子郵件。",
        "Asking Dyson to email a code…": "正在請 Dyson 寄送驗證碼…",
        "Dyson has emailed a one-time code to %@.": "Dyson 已將一次性驗證碼寄到 %@。",
        "Signing in to Dyson…": "正在登入 Dyson…",
        "None of the account's %@ devices answered on this network. Choose the purifier.": "帳號裡的 %@ 台裝置都沒有在這個網路上回應，請選擇空氣清淨機。",
        "Forgot the purifier. Its password is deleted from this Mac.": "已移除空氣清淨機，它的密碼已從這台 Mac 刪除。",
        "Trying the password with %@. This can take up to 30 s…": "正在用密碼連線 %@，最多需要 30 秒…",
        "Dyson purifier": "Dyson 空氣清淨機",
        "Read the purifier's sensors": "讀取空氣清淨機的感測器",
        "Status": "狀態",
        "Cancel": "取消",
        "Forget": "移除",
        "Change…": "更換…",
        "Forget…": "移除…",
        "Forgetting deletes the purifier's password from this Mac. Connecting it again takes the sticker or your Dyson account.": "移除會把空氣清淨機的密碼從這台 Mac 刪除。之後要重新連線，需要機身貼紙或你的 Dyson 帳號。",
        "Connect the purifier": "連線空氣清淨機",
        "Connect another purifier": "連線另一台空氣清淨機",
        "Its password from": "密碼來源",
        "The Wi-Fi sticker": "Wi-Fi 貼紙",
        "Your Dyson account": "你的 Dyson 帳號",
        "Network": "網路",
        "Address": "位址",
        "Found automatically": "自動尋找",
        "Apply": "套用",
        "Leave the address blank unless the purifier cannot be found: then type its IP address or host[:port].": "除非找不到空氣清淨機，否則請留空；找不到時再輸入它的 IP 位址或 host[:port]。",
        "Another: type its Wi-Fi name": "其他：輸入 Wi-Fi 名稱",
        "Wi-Fi name": "Wi-Fi 名稱",
        "Wi-Fi password": "Wi-Fi 密碼",
        "As printed on the sticker": "貼紙上印的密碼",
        "Connect": "連線",
        "The sticker is on the purifier, and on the back of its manual. No Dyson account involved.": "貼紙在空氣清淨機機身上，說明書背面也有。不需要 Dyson 帳號。",
        "Start Over": "重新開始",
        "Country": "國家",
        "Two letters, like US": "兩個字母，例如 TW",
        "Email": "電子郵件",
        "Send Code": "寄送驗證碼",
        "The email you sign in to the Dyson app with. Dyson emails it a one-time code; your account password is then used once, to sign in, and never saved.": "你登入 Dyson App 的電子郵件。Dyson 會寄一次性驗證碼過去；你的帳號密碼只會用來登入一次，不會儲存。",
        "Code": "驗證碼",
        "From Dyson's email": "Dyson 寄來的信裡",
        "Password": "密碼",
        "Your Dyson account's": "你的 Dyson 帳號密碼",
        "Sign In": "登入",
        "Used once, to sign in, and never saved.": "只用來登入一次，不會儲存。",
        "Off": "關閉",
        "Not connected yet": "尚未連線",
        "No readings yet": "還沒有讀數",
        "Reporting (last reading %@ s ago)": "回報中（上次讀數 %@ 秒前）",
        "Last reading %@ min ago": "上次讀數 %@ 分鐘前",
        "s": "秒",
        "None": "無",
        "Play": "播放",
        "Copy": "拷貝",
    ]
}
