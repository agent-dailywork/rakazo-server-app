import SwiftUI
import AppKit

// MARK: 共用工具

let installScriptURL = "https://raw.githubusercontent.com/elie222/rakazo/main/infra/compose/install-images.sh"
let manualPath = rakazoDir + "/docs/自架操作手冊.md"

func isInstalled() -> Bool { FileManager.default.fileExists(atPath: envPath) }
func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

/// 在背景執行指令，輸出即時回傳
func runStreaming(_ cmd: String, cwd: String, extraEnv: [String: String] = [:],
                  onOutput: @escaping @Sendable (String) -> Void) async -> Int32 {
    await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", cmd]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = shellPath
        for (k, v) in extraEnv { env[k] = v }
        p.environment = env
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { onOutput(String(decoding: d, as: UTF8.self)) }
        }
        p.terminationHandler = { pr in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            if !rest.isEmpty { onOutput(String(decoding: rest, as: UTF8.self)) }
            cont.resume(returning: pr.terminationStatus)
        }
        do { try p.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            onOutput("無法執行：\(error.localizedDescription)\n")
            cont.resume(returning: -1)
        }
    }
}

/// 只取 HTTP 狀態碼；金鑰經由標準輸入交給 curl，不會出現在指令列
func httpCode(_ url: String, header: String? = nil, timeout: Int = 10) -> Int {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    p.arguments = ["-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "\(timeout)", "-K", "-"]
    let inp = Pipe(), out = Pipe(); p.standardInput = inp; p.standardOutput = out; p.standardError = Pipe()
    func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
    var cfg = "url = \(q(url))\n"
    if let h = header { cfg += "header = \(q(h))\n" }
    do { try p.run() } catch { return -1 }
    inp.fileHandleForWriting.write(Data(cfg.utf8)); try? inp.fileHandleForWriting.close()
    let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return Int(trimmed(String(decoding: d, as: UTF8.self))) ?? 0
}

enum CheckState { case pending, ok, warn, fail, info }

struct CheckItem: Identifiable {
    let id: String
    var title: String
    var state: CheckState = .pending
    var detail: String = ""
    var fix: String = ""
    var linkTitle: String = ""
    var linkURL: String = ""
}

func stateIcon(_ s: CheckState) -> (String, Color) {
    switch s {
    case .ok: return ("checkmark.circle.fill", .green)
    case .warn: return ("exclamationmark.triangle.fill", .orange)
    case .fail: return ("xmark.octagon.fill", .red)
    case .info: return ("info.circle.fill", .blue)
    case .pending: return ("circle.dotted", .secondary)
    }
}

func checkOpenRouter(_ k: String) -> (CheckState, String) {
    if k.isEmpty { return (.info, "沒有填。也可以登入後在網頁的「設定 → 模型」連結模型。") }
    let c = httpCode("https://openrouter.ai/api/v1/key", header: "Authorization: Bearer \(k)")
    switch c {
    case 200: return (.ok, "OpenRouter 接受這把金鑰")
    case 401, 403: return (.fail, "OpenRouter 不接受這把金鑰（\(c)）。請到 openrouter.ai/keys 重新建立一把再貼上。")
    case 0, -1: return (.warn, "連不到 OpenRouter，請確認這台 Mac 有網路。")
    default: return (.warn, "OpenRouter 回應 \(c)，稍後再試一次。")
    }
}

func checkComposio(_ k: String) -> (CheckState, String) {
    if k.isEmpty { return (.info, "沒有填。「連線應用」（Gmail、GitHub…）會不能用，需要時再填。") }
    if k.hasPrefix("ck_") {
        return (.fail, "這是 Composio「Connect」頁的個人金鑰（ck_ 開頭），Rakazo 不能用。請到 dashboard.composio.dev 左側「API Keys」建立 ak_ 開頭的專案金鑰。")
    }
    let c = httpCode("https://backend.composio.dev/api/v3/auth_configs?limit=1", header: "x-api-key: \(k)")
    switch c {
    case 200: return (.ok, "Composio 接受這把金鑰")
    case 401, 403: return (.fail, "Composio 不接受這把金鑰（\(c)）。請到 dashboard.composio.dev → API Keys 建立新的 ak_ 金鑰。")
    case 0, -1: return (.warn, "連不到 Composio，請確認這台 Mac 有網路。")
    default: return (.warn, "Composio 回應 \(c)，稍後再試一次。")
    }
}

/// 讀 tailscale serve 設定：「主機:埠」→ 轉送目標
func serveMap() -> (dns: String, web: [String: String])? {
    let ts = tailscaleBin()
    let (c1, s1) = sh("'\(ts)' status --json")
    guard c1 == 0, let j1 = try? JSONSerialization.jsonObject(with: Data(s1.utf8)) as? [String: Any],
          let me = j1["Self"] as? [String: Any], let raw = me["DNSName"] as? String else { return nil }
    let dns = raw.hasSuffix(".") ? String(raw.dropLast()) : raw
    var web: [String: String] = [:]
    let (c2, s2) = sh("'\(ts)' serve status --json")
    if c2 == 0, let j2 = try? JSONSerialization.jsonObject(with: Data(s2.utf8)) as? [String: Any],
       let w = j2["Web"] as? [String: Any] {
        for (k, v) in w {
            if let h = (v as? [String: Any])?["Handlers"] as? [String: Any],
               let root = h["/"] as? [String: Any], let proxy = root["Proxy"] as? String { web[k] = proxy }
        }
    }
    return (dns, web)
}

// MARK: 健康檢查

func computeHealth(mail: (CheckState, String)) -> [CheckItem] {
    var items: [CheckItem] = []
    guard let e = try? EnvFile.load() else {
        return [CheckItem(id: "env", title: "設定檔", state: .fail, detail: "找不到 \(envPath)", fix: "還沒安裝。請到「安裝」分頁。")]
    }
    let url = e.get("BETTER_AUTH_URL")
    let wp = e.get("RAKAZO_WEB_PORT"); let localPort = wp.isEmpty ? "5173" : wp

    let (dc, dv) = sh("docker info --format '{{.ServerVersion}}'")
    if dc == 0 { items.append(CheckItem(id: "docker", title: "Docker", state: .ok, detail: "正在執行（\(trimmed(dv))）")) }
    else {
        items.append(CheckItem(id: "docker", title: "Docker", state: .fail, detail: "Docker 沒有在執行。",
                               fix: "打開 Docker Desktop，等它顯示 Running 後按「重新檢查」。Docker 停了，Rakazo 也會停。"))
        return items
    }

    let (pc, ps) = sh("cd '\(rakazoDir)' && \(composeBase) ps -a --format '{{.Service}}|{{.State}}|{{.Health}}'")
    var states: [String: (String, String)] = [:]
    if pc == 0 {
        for line in ps.split(separator: "\n") {
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if f.count >= 3 { states[f[0]] = (f[1], f[2]) }
        }
    }
    let need = ["postgres", "supervisor", "api", "worker", "web"]
    let bad = need.filter { s in
        guard let st = states[s] else { return true }
        return st.0 != "running" || st.1 == "unhealthy"
    }
    if bad.isEmpty { items.append(CheckItem(id: "svc", title: "Rakazo 服務", state: .ok, detail: "資料庫、API、背景程式、網頁和 Bot 電腦管理都在執行")) }
    else {
        items.append(CheckItem(id: "svc", title: "Rakazo 服務", state: .fail, detail: "沒在正常執行：\(bad.joined(separator: "、"))",
                               fix: "按下方「啟動／重啟」。還是不行的話，按「最近的錯誤」把結果截圖給 Agent。"))
    }

    let lc = httpCode("http://127.0.0.1:\(localPort)/", timeout: 6)
    if (200..<400).contains(lc) { items.append(CheckItem(id: "local", title: "本機網頁", state: .ok, detail: "http://127.0.0.1:\(localPort) 有回應")) }
    else { items.append(CheckItem(id: "local", title: "本機網頁", state: .fail, detail: "http://127.0.0.1:\(localPort) 沒有回應（\(lc)）", fix: "先按「啟動／重啟」，等 1 分鐘再檢查。")) }

    let host = URLComponents(string: url)?.host ?? ""
    let same = !url.isEmpty && e.get("WEB_ORIGIN") == url && e.get("API_URL") == url && e.get("RAKAZO_HOST") == host
    if same { items.append(CheckItem(id: "urls", title: "網址設定", state: .ok, detail: url)) }
    else { items.append(CheckItem(id: "urls", title: "網址設定", state: .fail, detail: "BETTER_AUTH_URL、WEB_ORIGIN、API_URL、RAKAZO_HOST 不一致",
                                  fix: "到「設定」分頁確認對外網址，按一次「儲存並套用」就會一起改好。")) }

    if let sm = serveMap() {
        let comps = URLComponents(string: url)
        let key = "\(comps?.host ?? ""):\(comps?.port ?? 443)"
        if sm.web[key] == "http://127.0.0.1:\(localPort)" {
            let rc = httpCode(url, timeout: 10)
            if (200..<400).contains(rc) { items.append(CheckItem(id: "ts", title: "Tailscale 網址", state: .ok, detail: "\(url) 打得開，其他裝置可以連")) }
            else { items.append(CheckItem(id: "ts", title: "Tailscale 網址", state: .warn, detail: "轉送已設定，但網址沒有回應（\(rc)）", fix: "確認 Tailscale 有連線；剛重啟的話等 1 分鐘再檢查。")) }
        } else {
            items.append(CheckItem(id: "ts", title: "Tailscale 網址", state: .fail, detail: "沒有任何 Tailscale 網址指向 Rakazo",
                                   fix: "到「設定」分頁的 Tailscale 區塊按「立即同步」。"))
        }
    } else {
        items.append(CheckItem(id: "ts", title: "Tailscale 網址", state: .fail, detail: "讀不到 Tailscale", fix: "打開 Tailscale 並登入。"))
    }

    let or = checkOpenRouter(e.get("OPENROUTER_API_KEY"))
    items.append(CheckItem(id: "or", title: "模型金鑰（OpenRouter）", state: or.0, detail: or.1))
    let co = checkComposio(e.get("COMPOSIO_API_KEY"))
    items.append(CheckItem(id: "co", title: "連線應用金鑰（Composio）", state: co.0, detail: co.1,
                           linkTitle: co.0 == .fail ? "打開 Composio API Keys" : "", linkURL: "https://dashboard.composio.dev"))

    items.append(CheckItem(id: "mail", title: "寄信", state: mail.0, detail: mail.1,
                           fix: mail.0 == .ok ? "" : "到「設定」分頁的「寄信」按「設定精靈…」。"))

    let signups = e.get("SIGNUPS_ENABLED").lowercased() != "false"
    let allow = e.get("SIGNUP_ALLOWLIST")
    if !signups { items.append(CheckItem(id: "signup", title: "註冊保護", state: .ok, detail: "已關閉註冊，別人無法建立帳號")) }
    else if !allow.isEmpty { items.append(CheckItem(id: "signup", title: "註冊保護", state: .ok, detail: "只有 \(allow) 可以註冊")) }
    else { items.append(CheckItem(id: "signup", title: "註冊保護", state: .warn, detail: "任何連得到你 Tailscale 網路的人都能註冊",
                                  fix: "到「設定」分頁填「允許註冊的 Email」。")) }

    let tag = e.get("RAKAZO_IMAGE_TAG")
    items.append(CheckItem(id: "ver", title: "版本", state: .info,
                           detail: tag.isEmpty ? "未指定" : (tag == "edge" ? "edge（官方最新開發版；只有按「更新」才會換版）" : tag)))
    return items
}

@MainActor final class Health: ObservableObject {
    @Published var items: [CheckItem] = []
    @Published var running = false
    @Published var lastRun = ""
    @Published var askUpdate = false
    @Published var askStop = false
    var ran = false

    func run(_ m: Model) {
        guard !running else { return }
        running = true; ran = true
        let st = m.mailStatus
        let mail: (CheckState, String) = m.emailMode == "none" ? (.warn, "沒設定寄信：收不到驗證信和「忘記密碼」信")
            : (st.color == Color.green ? (.ok, st.text) : (.warn, st.text))
        items = ["docker", "svc", "local", "urls", "ts", "or", "co", "mail", "signup"].map { CheckItem(id: $0, title: "檢查中…") }
        Task.detached {
            let r = computeHealth(mail: mail)
            await MainActor.run {
                self.items = r; self.running = false
                let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; self.lastRun = f.string(from: Date())
            }
        }
    }
    var summary: (CheckState, String) {
        if items.isEmpty || running { return (.pending, "檢查中…") }
        let fails = items.filter { $0.state == .fail }.count, warns = items.filter { $0.state == .warn }.count
        if fails > 0 { return (.fail, "有 \(fails) 個問題要處理") }
        if warns > 0 { return (.warn, "可以用，有 \(warns) 個建議") }
        return (.ok, "一切正常")
    }
}

// MARK: 共用 UI

struct CheckRow: View {
    let item: CheckItem
    var body: some View {
        let ic = stateIcon(item.state)
        HStack(alignment: .top, spacing: 10) {
            if item.state == .pending { ProgressView().controlSize(.small).frame(width: 18) }
            else { Image(systemName: ic.0).foregroundStyle(ic.1).frame(width: 18) }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.title).font(.body.weight(.medium))
                    Spacer()
                }
                if !item.detail.isEmpty { Text(item.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                if !item.fix.isEmpty {
                    Text("怎麼處理：" + item.fix).font(.callout).foregroundStyle(item.state == .fail ? Color.red : Color.orange).fixedSize(horizontal: false, vertical: true)
                }
                if !item.linkTitle.isEmpty, let u = URL(string: item.linkURL) {
                    Button(item.linkTitle) { NSWorkspace.shared.open(u) }.buttonStyle(.link).font(.callout)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }
}

struct LogPanel: View {
    @Binding var text: String
    var height: CGFloat = 110
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text.isEmpty ? "（沒有記錄）" : text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(text.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Color.clear.frame(height: 1).id("end")
                }.padding(10)
            }
            .onChange(of: text) { _, _ in proxy.scrollTo("end") }
        }
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
    }
}

func copyToClipboard(_ s: String) {
    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
}

struct ConnectTips: View {
    let url: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("瀏覽器：直接打開上面的網址。", systemImage: "safari")
            Label("Rakazo 桌面 App：按 Cmd+Shift+K → 選「現有執行個體」→ 貼上網址。不要選「這台電腦」，那會另外裝一套獨立的 Rakazo。", systemImage: "desktopcomputer")
            Label("手機 App：登入畫面點「Use a custom server」，填同一個網址。手機也要開著 Tailscale。", systemImage: "iphone")
            Label("要讓 Bot 操作某台 Mac：在那台的桌面 App 連上這個網址並登入，到「設定 → 一般 → 電腦」打開「Let bots use this computer」。", systemImage: "hand.raised")
        }
        .font(.callout).fixedSize(horizontal: false, vertical: true)
        .padding(14)
    }
}

// MARK: 總覽

struct OverviewView: View {
    @ObservedObject var m: Model
    @ObservedObject var h: Health
    @Binding var tab: String

    var body: some View {
        VStack(spacing: 0) {
            if !isInstalled() {
                VStack(spacing: 14) {
                    Image(systemName: "shippingbox").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text("這台 Mac 還沒安裝自架版 Rakazo").font(.title3.weight(.semibold))
                    Button("開始安裝") { tab = "install" }.buttonStyle(.borderedProminent).controlSize(.large)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        Card(title: "健康檢查") {
                            ForEach(Array(h.items.enumerated()), id: \.element.id) { i, it in
                                if i > 0 { Sep() }
                                CheckRow(item: it)
                            }
                        }
                        Card(title: "維護") {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 8) {
                                    Button("啟動／重啟") { m.apply() }
                                    Button("停止…") { h.askStop = true }
                                    Button("更新 Rakazo…") { h.askUpdate = true }
                                    Spacer()
                                }
                                HStack(spacing: 8) {
                                    Button("備份資料庫") { m.run("備份資料庫和設定檔", backupCmd + " && ls -lh backups | tail -4") }
                                    Button("在 Finder 顯示備份") {
                                        try? FileManager.default.createDirectory(atPath: rakazoDir + "/backups", withIntermediateDirectories: true)
                                        NSWorkspace.shared.open(URL(fileURLWithPath: rakazoDir + "/backups"))
                                    }
                                    Button("最近的錯誤") {
                                        m.run("最近的錯誤記錄（api、worker）", "out=$(\(composeBase) logs --tail 300 --no-color api worker 2>&1 | grep -iE 'error|fatal|fail' | tail -25); [ -n \"$out\" ] && echo \"$out\" || echo '最近 300 行記錄裡沒有錯誤'")
                                    }
                                    Button("產生診斷報告") {
                                        m.run("產生診斷報告（不含任何金鑰或內容）", "mkdir -p diagnostics && f=diagnostics/diagnostics-$(date +%Y%m%d-%H%M%S).txt && \(composeBase) exec -T api node dist/cli/diagnostics.js > $f && echo \"已存到 ~/rakazo/$f\" && open -R $f")
                                    }
                                    Spacer()
                                }
                                Text("更新會先自動備份資料庫，再下載新版並重啟，約 2–5 分鐘。備份放在 ~/rakazo/backups（只含資料庫和 .env，不含 Bot 電腦裡的檔案）。")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            .disabled(m.busy)
                            .padding(14)
                        }
                        Card(title: "從其他裝置連線") { ConnectTips(url: m.url) }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("記錄").font(.callout.weight(.semibold))
                                if m.busy { ProgressView().controlSize(.small) }
                                Spacer()
                                if !m.log.isEmpty { Button("清除") { m.log = "" }.buttonStyle(.borderless).font(.caption) }
                            }
                            LogPanel(text: $m.log, height: 140)
                        }
                    }
                    .padding(24).frame(maxWidth: 820).frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear {
            if !m.didLoad && isInstalled() { m.load() }
            if !h.ran && isInstalled() { h.run(m) }
        }
        .onChange(of: m.busy) { _, b in if !b && isInstalled() { h.run(m) } }
        .alert("更新 Rakazo？", isPresented: $h.askUpdate) {
            Button("先備份再更新") {
                m.run("備份 → 下載新版 → 重啟（約 2–5 分鐘）",
                      backupCmd + " && \(composeBase) pull && \(composeBase) up -d --pull never --wait --wait-timeout 600")
            }
            Button("取消", role: .cancel) {}
        } message: { Text("更新期間 Rakazo 會暫時連不上，正在執行的 Bot 工作可能會中斷。") }
        .alert("停止 Rakazo？", isPresented: $h.askStop) {
            Button("停止", role: .destructive) { m.stop() }
            Button("取消", role: .cancel) {}
        } message: { Text("停止後網頁打不開，排程也不會執行，直到再按「啟動／重啟」。資料不會被刪除。") }
    }

    var backupCmd: String {
        "mkdir -p backups && chmod 700 backups && f=backups/rakazo-$(date +%Y%m%d-%H%M%S) && \(composeBase) exec -T postgres sh -c 'pg_dump -Fc -U \"$POSTGRES_USER\" \"$POSTGRES_DB\"' > $f.dump && cp .env $f.env && chmod 600 $f.dump $f.env && echo \"已備份：$f.dump\""
    }

    var header: some View {
        let s = h.summary
        let ic = stateIcon(s.0)
        return HStack(alignment: .center, spacing: 14) {
            if s.0 == .pending { ProgressView() } else { Image(systemName: ic.0).font(.system(size: 34)).foregroundStyle(ic.1) }
            VStack(alignment: .leading, spacing: 4) {
                Text(s.1).font(.title3.weight(.semibold))
                Text(m.url).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                if !h.lastRun.isEmpty { Text("上次檢查：\(h.lastRun)").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Button("重新檢查") { h.run(m) }.disabled(h.running)
            Button("複製網址") { copyToClipboard(m.url) }
            Button("開啟 Rakazo") { if let u = URL(string: m.url) { NSWorkspace.shared.open(u) } }.buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }
}

// MARK: 安裝精靈

@MainActor final class InstallModel: ObservableObject {
    @Published var step = 0
    @Published var env: [CheckItem] = []
    @Published var checking = false
    @Published var dns = ""
    @Published var port = "5173"
    @Published var email = ""
    @Published var portMsg = ""
    @Published var portOK = false
    @Published var openrouter = ""
    @Published var composio = ""
    @Published var orResult: CheckItem? = nil
    @Published var coResult: CheckItem? = nil
    @Published var log = ""
    @Published var stage = ""
    @Published var running = false
    @Published var installOK: Bool? = nil
    @Published var installHint = ""
    @Published var pwd1 = ""
    @Published var pwd2 = ""
    @Published var accountMsg = ""
    @Published var accountOK: Bool? = nil
    @Published var accountMode = "mail"
    @Published var showMail = false

    let steps = ["環境檢查", "網址與帳號", "金鑰", "安裝", "建立帳號", "完成"]

    var publicPort: Int { Int(trimmed(port)) ?? 5173 }
    var localPort: Int { publicPort == 443 ? 5173 : publicPort }
    var url: String { publicPort == 443 ? "https://\(dns)" : "https://\(dns):\(publicPort)" }
    var envBlocking: Bool { env.isEmpty || checking || env.contains { $0.state == .fail } }

    func say(_ s: String) { log += s + "\n" }

    func runEnvChecks() {
        checking = true
        env = ["docker", "compose", "tools", "ts", "https", "disk"].map { CheckItem(id: $0, title: "檢查中…") }
        Task.detached {
            let r = envChecks()
            await MainActor.run {
                self.env = r.0; if !r.1.isEmpty { self.dns = r.1 }
                self.checking = false
                if self.email.isEmpty, let e = try? EnvFile.load() {
                    self.email = e.get("SIGNUP_ALLOWLIST").split(separator: ",").first.map(String.init) ?? ""
                }
            }
        }
    }

    func checkPort() {
        portOK = false
        guard let p = Int(trimmed(port)), (1...65535).contains(p) else { portMsg = "埠號要是 1 到 65535 的數字。"; return }
        if p == 3100 { portMsg = "3100 是 Rakazo 內部 API 用的，請換一個。"; return }
        guard !dns.isEmpty else { portMsg = "還沒讀到這台的 Tailscale 名稱，請先完成環境檢查。"; return }
        if let sm = serveMap(), let used = sm.web["\(dns):\(p)"], used != "http://127.0.0.1:\(localPort)" {
            portMsg = "Tailscale 的 \(p) 埠已經被其他服務使用（\(used)），請換一個，例如 5173、8443。"; return
        }
        if !isInstalled() {
            let (_, lo) = sh("lsof -nP -iTCP:\(localPort) -sTCP:LISTEN 2>/dev/null | tail -n +2 | awk '{print $1}' | sort -u")
            if !trimmed(lo).isEmpty { portMsg = "這台 Mac 的 \(localPort) 埠已經被「\(trimmed(lo))」使用，請換一個。"; return }
        }
        portMsg = p == 443 ? "會使用根網址（沒有埠號）。如果根網址已經給其他服務用，請改用 5173。" : ""
        portOK = true
    }

    var emailOK: Bool {
        let e = trimmed(email)
        return e.contains("@") && e.contains(".") && !e.contains(" ") && !e.contains(",")
    }

    func testKey(_ which: String) {
        let k = trimmed(which == "or" ? openrouter : composio)
        let item = CheckItem(id: which, title: "檢查中…")
        if which == "or" { orResult = item } else { coResult = item }
        Task.detached {
            let r = which == "or" ? checkOpenRouter(k) : checkComposio(k)
            await MainActor.run {
                let it = CheckItem(id: which, title: r.0 == .ok ? "可以用" : (r.0 == .info ? "略過" : "有問題"), state: r.0, detail: r.1)
                if which == "or" { self.orResult = it } else { self.coResult = it }
            }
        }
    }

    private func runStep(_ title: String, _ cmd: String, extraEnv: [String: String] = [:]) async -> Bool {
        stage = title; say("▶ \(title)")
        let code = await runStreaming(cmd, cwd: rakazoDir, extraEnv: extraEnv) { s in
            Task { @MainActor in self.log += s }
        }
        if code != 0 { say("✗ 失敗（代碼 \(code)）") }
        return code == 0
    }

    private func fail(_ hint: String) { installOK = false; installHint = hint; running = false; stage = "" }

    func install() {
        running = true; installOK = nil; installHint = ""; log = ""
        let already = isInstalled()
        let url = self.url, host = dns, pub = publicPort, loc = localPort
        let mail = trimmed(email), or = trimmed(openrouter), co = trimmed(composio)
        Task {
            do { try FileManager.default.createDirectory(atPath: rakazoDir, withIntermediateDirectories: true) }
            catch { fail("無法建立 ~/rakazo 資料夾：\(error.localizedDescription)"); return }

            guard await runStep("1/5 下載官方安裝程式並產生設定檔",
                                "curl -fsSLO \(installScriptURL) && bash install-images.sh --prepare-only") else {
                fail("下載官方安裝程式失敗。請確認網路，再按「重試」。"); return
            }

            stage = "2/5 寫入網址、帳號和金鑰"; say("▶ \(stage)")
            if already {
                say("  已經有 .env，保留現有設定，不覆寫。")
            } else {
                do {
                    var e = try EnvFile.load()
                    let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
                    try? FileManager.default.copyItem(atPath: envPath, toPath: envPath + ".bak-" + f.string(from: Date()))
                    for k in ["BETTER_AUTH_URL", "WEB_ORIGIN", "API_URL"] { e.set(k, url) }
                    e.set("RAKAZO_HOST", host)
                    e.set("SIGNUPS_ENABLED", "true")
                    e.set("SIGNUP_ALLOWLIST", mail)
                    if !or.isEmpty { e.set("OPENROUTER_API_KEY", or) }
                    if !co.isEmpty { e.set("COMPOSIO_API_KEY", co) }
                    if loc != 5173 { e.set("RAKAZO_WEB_PORT", "\(loc)") }
                    try e.text().write(toFile: envPath, atomically: true, encoding: .utf8)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envPath)
                    say("  ✓ 已寫入：網址、主機名稱、允許註冊的 Email" + (or.isEmpty ? "" : "、OpenRouter") + (co.isEmpty ? "" : "、Composio"))
                } catch { fail("寫入 .env 失敗：\(error.localizedDescription)"); return }
            }

            guard await runStep("3/5 下載並啟動 Rakazo（第一次約 5–10 分鐘）", "bash install-images.sh") else {
                fail("下載或啟動失敗。最常見的原因是 Docker 沒在執行或網路中斷。確認後按「重試」，已下載的部分不會重來。"); return
            }

            guard await runStep("4/5 設定 Tailscale HTTPS（只有你的 Tailscale 網路連得到）",
                                "'\(tailscaleBin())' serve --bg --https=\(pub) http://127.0.0.1:\(loc)") else {
                fail("Tailscale 設定失敗。請確認 Tailscale 管理後台已開啟 MagicDNS 和 HTTPS Certificates，再按「重試」。"); return
            }

            stage = "5/5 確認網址打得開"; say("▶ \(stage)")
            var ok = false
            for _ in 0..<12 {
                let c = await Task.detached { httpCode(url, timeout: 10) }.value
                if (200..<400).contains(c) { ok = true; break }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
            if ok { say("✓ \(url) 打得開"); installOK = true; running = false; stage = ""; step = 4 }
            else { fail("Rakazo 已啟動，但 \(url) 還打不開。等 1 分鐘後到「總覽」按「重新檢查」。") }
        }
    }

    func createOwner(_ m: Model) {
        accountOK = nil
        let mail = trimmed(email)
        guard mail.contains("@") else { accountMsg = "請先在「網址與帳號」填你的 Email。"; return }
        guard pwd1.count >= 16 else { accountMsg = "密碼至少要 16 個字元（官方工具的要求）。"; return }
        guard pwd1 == pwd2 else { accountMsg = "兩次輸入的密碼不一樣。"; return }
        let pw = pwd1
        running = true; accountMsg = ""
        Task {
            do {
                var e = try EnvFile.load()
                if e.get("SIGNUPS_ENABLED").lowercased() != "false" {
                    let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
                    try? FileManager.default.copyItem(atPath: envPath, toPath: envPath + ".bak-" + f.string(from: Date()))
                    e.set("SIGNUPS_ENABLED", "false")
                    try e.text().write(toFile: envPath, atomically: true, encoding: .utf8)
                    say("✓ 已關閉公開註冊（SIGNUPS_ENABLED=false）")
                }
            } catch { accountMsg = "寫入 .env 失敗：\(error.localizedDescription)"; running = false; return }
            guard await runStep("套用設定（約 1 分鐘）", "\(composeBase) up -d --pull never --wait --wait-timeout 300") else {
                accountMsg = "重啟失敗，請到「總覽」看健康檢查。"; accountOK = false; running = false; return
            }
            let ok = await runStep("用官方工具建立帳號（\(mail)）",
                                   "\(composeBase) exec -T -e OWNER_EMAIL -e OWNER_PASSWORD api node dist/cli/bootstrap-owner.js",
                                   extraEnv: ["OWNER_EMAIL": mail, "OWNER_PASSWORD": pw])
            pwd1 = ""; pwd2 = ""
            running = false; accountOK = ok
            accountMsg = ok ? "帳號建好了，已經是驗證過的狀態。用 \(mail) 和剛剛的密碼登入。" : "建立失敗，請看下方記錄。"
            m.didLoad = false
        }
    }
}

func envChecks() -> ([CheckItem], String) {
    var items: [CheckItem] = []
    var dns = ""
    let (dc, _) = sh("command -v docker")
    let fm = FileManager.default
    let hasApp = fm.fileExists(atPath: "/Applications/Docker.app") || fm.fileExists(atPath: "/Applications/OrbStack.app")
    if dc != 0 && !hasApp {
        items.append(CheckItem(id: "docker", title: "Docker", state: .fail, detail: "這台 Mac 還沒安裝 Docker。",
                               fix: "安裝 Docker Desktop（或 OrbStack），打開一次完成設定，再按「重新檢查」。",
                               linkTitle: "下載 Docker Desktop", linkURL: "https://www.docker.com/products/docker-desktop/"))
    } else {
        let (vc, v) = sh("docker version --format '{{.Server.Version}}'")
        let ver = trimmed(v)
        let major = Int(ver.split(separator: ".").first ?? "") ?? 0
        if vc != 0 {
            items.append(CheckItem(id: "docker", title: "Docker", state: .fail, detail: "Docker 已安裝，但沒有在執行。",
                                   fix: "打開 Docker Desktop，等它顯示 Running，再按「重新檢查」。建議在 Docker 設定打開「登入時啟動」。"))
        } else if major < 26 {
            items.append(CheckItem(id: "docker", title: "Docker", state: .fail, detail: "Docker \(ver) 太舊，需要 26 以上。", fix: "更新 Docker Desktop。"))
        } else {
            items.append(CheckItem(id: "docker", title: "Docker", state: .ok, detail: "Docker \(ver) 正在執行"))
        }
        let (cc, cv) = sh("docker compose version --short")
        items.append(cc == 0 ? CheckItem(id: "compose", title: "Docker Compose", state: .ok, detail: "版本 \(trimmed(cv))")
                     : CheckItem(id: "compose", title: "Docker Compose", state: .fail, detail: "找不到 Compose 外掛。", fix: "Docker Desktop 內建 Compose；請更新或重裝 Docker Desktop。"))
    }
    let (tc, _) = sh("command -v curl && command -v openssl")
    items.append(tc == 0 ? CheckItem(id: "tools", title: "curl、OpenSSL", state: .ok, detail: "都有")
                 : CheckItem(id: "tools", title: "curl、OpenSSL", state: .fail, detail: "缺少 curl 或 openssl。", fix: "執行 xcode-select --install 安裝命令列工具。"))

    let ts = tailscaleBin()
    let (sc, so) = sh("'\(ts)' status --json")
    if sc != 0 {
        items.append(CheckItem(id: "ts", title: "Tailscale", state: .fail, detail: "讀不到 Tailscale。",
                               fix: "安裝並打開 Tailscale，登入你的帳號，再按「重新檢查」。",
                               linkTitle: "下載 Tailscale", linkURL: "https://tailscale.com/download/mac"))
    } else if let j = try? JSONSerialization.jsonObject(with: Data(so.utf8)) as? [String: Any] {
        let state = j["BackendState"] as? String ?? ""
        if let me = j["Self"] as? [String: Any], let raw = me["DNSName"] as? String { dns = raw.hasSuffix(".") ? String(raw.dropLast()) : raw }
        if state == "Running" && !dns.isEmpty {
            items.append(CheckItem(id: "ts", title: "Tailscale", state: .ok, detail: "已連線，這台的名稱：\(dns)"))
        } else {
            items.append(CheckItem(id: "ts", title: "Tailscale", state: .fail, detail: "Tailscale 沒有連線（\(state)）。", fix: "點選單列的 Tailscale 圖示，登入並連線。"))
        }
        let certs = j["CertDomains"] as? [Any] ?? []
        let magic = (j["CurrentTailnet"] as? [String: Any])?["MagicDNSEnabled"] as? Bool ?? false
        if magic && !certs.isEmpty {
            items.append(CheckItem(id: "https", title: "MagicDNS 與 HTTPS 憑證", state: .ok, detail: "都已開啟，可以提供 https:// 網址"))
        } else {
            items.append(CheckItem(id: "https", title: "MagicDNS 與 HTTPS 憑證", state: .fail, detail: "還沒開啟，沒辦法提供 https:// 網址。",
                                   fix: "到 Tailscale 管理後台的 DNS 頁，打開「MagicDNS」和「HTTPS Certificates」，再按「重新檢查」。",
                                   linkTitle: "打開 Tailscale DNS 設定", linkURL: "https://login.tailscale.com/admin/dns"))
        }
    }
    let (_, df) = sh("df -g \"$HOME\" | tail -1 | awk '{print $4}'")
    let free = Int(trimmed(df)) ?? 0
    items.append(free >= 15 ? CheckItem(id: "disk", title: "磁碟空間", state: .ok, detail: "剩 \(free) GB")
                 : CheckItem(id: "disk", title: "磁碟空間", state: .warn, detail: "只剩 \(free) GB，映像檔約需 5–10 GB。", fix: "先清出一些空間比較保險。"))
    if isInstalled() {
        items.append(CheckItem(id: "exist", title: "既有安裝", state: .warn, detail: "這台已經裝過（~/rakazo/.env 已存在）。",
                               fix: "要改設定請用「設定」分頁。在這裡重跑安裝只會重新下載並啟動，不會覆寫現有設定或資料。"))
    }
    return (items, dns)
}

struct InstallView: View {
    @ObservedObject var w: InstallModel
    @ObservedObject var m: Model
    @Binding var tab: String

    func secure(_ t: Binding<String>, _ p: String) -> some View {
        SecureField("", text: t, prompt: Text(p)).textFieldStyle(.roundedBorder)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(Array(w.steps.enumerated()), id: \.offset) { i, s in
                    HStack(spacing: 5) {
                        ZStack {
                            Circle().fill(i < w.step ? Color.green : (i == w.step ? Color.accentColor : Color.secondary.opacity(0.25))).frame(width: 20, height: 20)
                            if i < w.step { Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white) }
                            else { Text("\(i + 1)").font(.caption2.bold()).foregroundStyle(i == w.step ? .white : .secondary) }
                        }
                        Text(s).font(.callout).foregroundStyle(i == w.step ? .primary : .secondary)
                    }
                    if i < w.steps.count - 1 { Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1).frame(maxWidth: 30) }
                }
            }
            .padding(.vertical, 14).padding(.horizontal, 20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch w.step {
                    case 0: stepEnv
                    case 1: stepURL
                    case 2: stepKeys
                    case 3: stepInstall
                    case 4: stepAccount
                    default: stepDone
                    }
                }
                .padding(24).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
            }
            Divider()
            HStack {
                if w.step > 0 && w.step != 5 { Button("上一步") { w.step -= 1 }.disabled(w.running) }
                Spacer()
                nextButton
            }
            .controlSize(.large).padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
        }
        .onAppear { if w.env.isEmpty { w.runEnvChecks() } }
        .sheet(isPresented: $w.showMail) { MailWizard(m: m) }
    }

    @ViewBuilder var nextButton: some View {
        switch w.step {
        case 0: Button("下一步") { w.checkPort(); w.step = 1 }.buttonStyle(.borderedProminent).disabled(w.envBlocking)
        case 1: Button("下一步") { w.checkPort(); if w.portOK && w.emailOK { w.step = 2 } }.buttonStyle(.borderedProminent).disabled(!w.emailOK)
        case 2: Button("下一步") { w.step = 3 }.buttonStyle(.borderedProminent)
        case 3: Button("下一步") { w.step = 4 }.buttonStyle(.borderedProminent).disabled(w.installOK != true)
        case 4: Button("下一步") { w.step = 5 }.buttonStyle(.borderedProminent).disabled(w.running)
        default: Button("前往總覽") { m.didLoad = false; m.load(); tab = "overview" }.buttonStyle(.borderedProminent)
        }
    }

    var stepEnv: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("第 1 步：檢查這台 Mac").font(.title2.weight(.semibold))
            Text("跟著步驟走，大約 15 分鐘。每一步都會先檢查，有問題會告訴你怎麼處理。").foregroundStyle(.secondary)
            Card(title: "需要的東西") {
                ForEach(Array(w.env.enumerated()), id: \.element.id) { i, it in
                    if i > 0 { Sep() }
                    CheckRow(item: it)
                }
            }
            HStack {
                Button("重新檢查") { w.runEnvChecks() }.disabled(w.checking)
                if w.checking { ProgressView().controlSize(.small) }
                Spacer()
            }
            Text("這台 Mac 會是「伺服器」：要一直開著（可以關螢幕，但不要睡眠），其他裝置才連得上，排程也才會執行。建議到「系統設定 → 能源」關掉自動睡眠。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    var stepURL: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("第 2 步：網址和你的 Email").font(.title2.weight(.semibold))
            Card(title: "網址") {
                Row(label: "這台的 Tailscale 名稱", hint: "自動偵測") { Text(w.dns.isEmpty ? "—" : w.dns).textSelection(.enabled) }
                Sep()
                Row(label: "埠號", hint: "建議 5173", info: "Tailscale 的根網址（沒有埠號）常常已經給其他服務用了。用獨立的埠號比較不會互相影響。這個網址只有登入你 Tailscale 的裝置連得到，不會公開到網路上。") {
                    TextField("", text: $w.port, prompt: Text("5173")).textFieldStyle(.roundedBorder).frame(width: 100)
                        .onChange(of: w.port) { _, _ in w.checkPort() }
                }
                Sep()
                Row(label: "完成後的網址") {
                    Text(w.url).font(.body.monospaced()).textSelection(.enabled)
                }
                if !w.portMsg.isEmpty {
                    Sep()
                    Label(w.portMsg, systemImage: w.portOK ? "info.circle" : "exclamationmark.triangle.fill")
                        .foregroundStyle(w.portOK ? Color.secondary : Color.orange).font(.callout)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                }
            }
            Card(title: "你的帳號") {
                Row(label: "你的 Email", hint: "只有這個 Email 能註冊", info: "會寫進「允許註冊的 Email」，別人就算連得到網址也註冊不了。之後想改可以到「設定」分頁。") {
                    TextField("", text: $w.email, prompt: Text("you@gmail.com")).textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    var stepKeys: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("第 3 步：金鑰（都可以之後再填）").font(.title2.weight(.semibold))
            Text("金鑰只會存在這台 Mac 的 ~/rakazo/.env。不要貼在任何對話裡。").foregroundStyle(.secondary)
            Card(title: "模型：OpenRouter") {
                Row(label: "OpenRouter API Key", hint: "sk-or- 開頭", info: "Bot 要用模型才能回話。沒有的話，也可以登入後在網頁「設定 → 模型」連結其他模型。") {
                    HStack { secure($w.openrouter, "sk-or-…"); Button("檢查") { w.testKey("or") } }
                }
                if let r = w.orResult { Sep(); CheckRow(item: r) }
                Sep()
                HStack { Button("打開 OpenRouter Keys 頁") { NSWorkspace.shared.open(URL(string: "https://openrouter.ai/keys")!) }.buttonStyle(.link); Spacer() }
                    .padding(.horizontal, 14).padding(.vertical, 10)
            }
            Card(title: "連線應用：Composio") {
                Row(label: "Composio API Key", hint: "ak_ 開頭（不是 ck_）", info: "讓 Bot 連 Gmail、GitHub、日曆等 App。要用 Composio「Platform」專案的金鑰（ak_ 開頭），不是「Connect」頁的個人金鑰（ck_ 開頭）。") {
                    HStack { secure($w.composio, "ak_…"); Button("檢查") { w.testKey("co") } }
                }
                if let r = w.coResult { Sep(); CheckRow(item: r) }
                Sep()
                VStack(alignment: .leading, spacing: 6) {
                    Text("怎麼拿：登入 dashboard.composio.dev → 確認左上是「PLATFORM」→ 左側「API Keys」→ 建立。新手引導叫你安裝 skill，可以直接跳過。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("打開 Composio") { NSWorkspace.shared.open(URL(string: "https://dashboard.composio.dev")!) }.buttonStyle(.link)
                }.padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
    }

    var stepInstall: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("第 4 步：安裝").font(.title2.weight(.semibold))
            Card(title: "會做的事") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. 在 ~/rakazo 下載官方安裝程式，產生設定檔和隨機密鑰")
                    Text("2. 寫入網址 \(w.url)、你的 Email 和金鑰")
                    Text("3. 下載並啟動 Rakazo（第一次約 5–10 分鐘）")
                    Text("4. 用 Tailscale 提供 HTTPS 網址（只有你的 Tailscale 網路連得到）")
                    Text("5. 確認網址打得開")
                    if isInstalled() {
                        Text("這台已經裝過：會保留現有 .env，只重新下載並啟動。").foregroundStyle(.orange)
                    }
                }.font(.callout).padding(14)
            }
            HStack(spacing: 10) {
                Button(w.installOK == false ? "重試" : (isInstalled() ? "重新下載並啟動" : "開始安裝")) { w.install() }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(w.running || w.installOK == true)
                if w.running { ProgressView().controlSize(.small); Text(w.stage).font(.callout) }
                if w.installOK == true { Label("安裝完成", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            }
            if w.installOK == false {
                Label(w.installHint, systemImage: "xmark.octagon.fill").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            LogPanel(text: $w.log, height: 260)
        }
    }

    var stepAccount: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("第 5 步：建立你的帳號").font(.title2.weight(.semibold))
            Text("限定 Email 註冊時，Rakazo 一定要能寄驗證信，你才登入得了。所以先選一種做法：")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("", selection: $w.accountMode) {
                Text("A. 先設定寄信，再註冊（推薦）").tag("mail")
                Text("B. 不寄信，直接建立帳號").tag("direct")
            }.pickerStyle(.radioGroup).labelsHidden()

            if w.accountMode == "mail" {
                Card(title: "A. 先設定寄信") {
                    VStack(alignment: .leading, spacing: 10) {
                        let st = m.mailStatus
                        HStack(spacing: 8) {
                            Image(systemName: st.icon).foregroundStyle(st.color)
                            Text(st.text).font(.callout)
                            Spacer()
                            Button("設定精靈…") { if !m.didLoad { m.load() }; w.showMail = true }.buttonStyle(.borderedProminent)
                        }
                        Text("用 Gmail 最簡單：精靈會帶你建立「應用程式密碼」，寄測試信成功才會儲存。這個 Gmail 是「寄件」帳號，可以跟你的登入 Email 相同。")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Divider()
                        Text("寄信設定好後：打開網址 → 用 \(trimmed(w.email).isEmpty ? "你的 Email" : trimmed(w.email)) 註冊 → 到信箱點驗證連結 → 登入。")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                        Button("打開 Rakazo 註冊") { if let u = URL(string: m.url.isEmpty ? w.url : m.url) { NSWorkspace.shared.open(u) } }
                            .disabled(m.mailStatus.color != Color.green)
                    }.padding(14)
                }
            } else {
                Card(title: "B. 不寄信，直接建立帳號") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("會關閉公開註冊，再用官方工具直接建立一個「已驗證」的帳號。缺點：沒設定寄信就不能用「忘記密碼」，之後還是可以在「設定」補設定寄信。")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack { Text("Email").frame(width: 90, alignment: .leading); Text(trimmed(w.email)).textSelection(.enabled) }
                        HStack { Text("密碼").frame(width: 90, alignment: .leading); secure($w.pwd1, "至少 16 個字元") }
                        HStack { Text("再輸入一次").frame(width: 90, alignment: .leading); secure($w.pwd2, "再輸入一次") }
                        HStack {
                            Button("建立帳號") { w.createOwner(m) }.buttonStyle(.borderedProminent).disabled(w.running)
                            if w.running { ProgressView().controlSize(.small); Text(w.stage).font(.callout) }
                        }
                        if !w.accountMsg.isEmpty {
                            Label(w.accountMsg, systemImage: w.accountOK == true ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(w.accountOK == true ? Color.green : Color.orange).fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(14)
                }
                if !w.log.isEmpty { LogPanel(text: $w.log, height: 120) }
            }
        }
        .onAppear { if !m.didLoad { m.load() } }
    }

    var stepDone: some View {
        let u = m.url.isEmpty ? w.url : m.url
        return VStack(alignment: .leading, spacing: 16) {
            Text("完成 🎉").font(.title2.weight(.semibold))
            HStack(spacing: 10) {
                Text(u).font(.title3.monospaced()).textSelection(.enabled)
                Button("複製") { copyToClipboard(u) }
                Button("開啟") { if let x = URL(string: u) { NSWorkspace.shared.open(x) } }.buttonStyle(.borderedProminent)
            }
            Card(title: "從其他裝置連線") { ConnectTips(url: u) }
            Card(title: "之後要做什麼") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("• 要改設定：用這個 App 的「設定」分頁，按「儲存並套用」。")
                    Text("• 覺得怪怪的：到「總覽」按「重新檢查」，照「怎麼處理」做。")
                    Text("• 想升級：到「總覽」按「更新 Rakazo…」，會先自動備份。")
                    Text("• 自架版和 rakazo.com 雲端版的帳號、Bot、對話不互通。")
                }.font(.callout).padding(14)
            }
        }
    }
}

// MARK: App

final class Nav: ObservableObject { @Published var tab: String = isInstalled() ? "overview" : "install" }

struct RootView: View {
    @StateObject var m = Model()
    @StateObject var h = Health()
    @StateObject var w = InstallModel()
    @StateObject var nav = Nav()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Picker("", selection: $nav.tab) {
                    Text("總覽").tag("overview")
                    Text("設定").tag("settings")
                    Text("安裝").tag("install")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
            }
            .overlay(alignment: .trailing) {
                Button { openManual() } label: { Label("操作手冊", systemImage: "book") }
                    .buttonStyle(.borderless).padding(.trailing, 16)
            }
            .padding(.vertical, 10)
            .background(.bar)
            Divider()
            switch nav.tab {
            case "settings":
                if isInstalled() { ContentView(m: m) }
                else { Text("還沒安裝。請先到「安裝」。").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            case "install": InstallView(w: w, m: m, tab: $nav.tab)
            default: OverviewView(m: m, h: h, tab: $nav.tab)
            }
        }
        .frame(minWidth: 820, minHeight: 680)
    }

    func openManual() {
        if FileManager.default.fileExists(atPath: manualPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: manualPath))
        } else if let u = URL(string: "https://rakazo.com/docs/self-host") {
            NSWorkspace.shared.open(u)
        }
    }
}

@main struct RakazoServerApp: App {
    var body: some Scene {
        WindowGroup("Rakazo 自架") { RootView() }
            .defaultSize(width: 920, height: 900)
    }
}
