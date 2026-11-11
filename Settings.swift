import SwiftUI
import AppKit
import CryptoKit

let home = FileManager.default.homeDirectoryForCurrentUser.path
let rakazoDir = home + "/rakazo"
let envPath = rakazoDir + "/.env"
let composeBase = "docker compose --env-file .env -f docker-compose.images.yml -p rakazo"
let shellPath = "\(home)/.docker/bin:/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:/Applications/Tailscale.app/Contents/MacOS:/usr/bin:/bin:/usr/sbin:/sbin"

func tailscaleBin() -> String {
    for p in ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
    where FileManager.default.isExecutableFile(atPath: p) { return p }
    return "tailscale"
}

/// 同步執行指令（只用於很快的查詢）
func sh(_ cmd: String) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-c", cmd]
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = shellPath
    p.environment = env
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, error.localizedDescription) }
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: d, as: UTF8.self))
}

func unquote(_ s: String) -> String {
    if s.count >= 2, (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
        return String(s.dropFirst().dropLast())
    }
    return s
}

struct EnvFile {
    var lines: [String] = []
    static func load() throws -> EnvFile {
        let s = try String(contentsOfFile: envPath, encoding: .utf8)
        var f = EnvFile(); f.lines = s.components(separatedBy: "\n"); return f
    }
    func has(_ k: String) -> Bool { lines.contains { $0.hasPrefix(k + "=") } }
    func get(_ k: String) -> String {
        for l in lines where l.hasPrefix(k + "=") { return unquote(String(l.dropFirst(k.count + 1))) }
        return ""
    }
    mutating func set(_ k: String, _ v: String) {
        let line = "\(k)=\(v)"
        if let i = lines.firstIndex(where: { $0.hasPrefix(k + "=") }) { lines[i] = line }
        else if let last = lines.last, last.isEmpty { lines.insert(line, at: lines.count - 1) }
        else { lines.append(line) }
    }
    func text() -> String { lines.joined(separator: "\n") }
}

struct ServeInfo {
    var dns = ""                       // 這台的 Tailscale 名稱
    var web: [String: String] = [:]    // "host:port" -> proxy
}

@MainActor final class Model: ObservableObject {
    @Published var url = ""
    @Published var allowedHosts = ""
    @Published var signupsEnabled = true
    @Published var allowlist = ""
    @Published var openrouter = ""
    @Published var composio = ""
    @Published var emailMode = "none"      // none / resend / smtp
    @Published var resendKey = ""
    @Published var smtpUrl = ""
    @Published var emailFrom = ""
    @Published var emailReplyTo = ""
    @Published var testTo = ""
    @Published var testing = false
    @Published var idleMs = ""
    @Published var maxUpload = ""
    @Published var logLevel = "info"
    @Published var showKeys = false
    @Published var syncTailscale = true
    @Published var tsStatus = "尚未檢查"
    @Published var tsOK = false
    @Published var log = ""
    @Published var busy = false
    @Published var showLog = true
    @Published var clearedLog: String? = nil
    @Published var showWizard = false
    @Published var showMailAdvanced = false
    @Published var testStamp = 0
    var webPort = "5173"
    var didLoad = false

    var localTarget: String { "http://127.0.0.1:\(webPort)" }
    var hostFromURL: String { URLComponents(string: url.trimmingCharacters(in: .whitespaces))?.host ?? "" }

    func say(_ s: String) { log += s + "\n" }

    func load() {
        didLoad = true
        do {
            let e = try EnvFile.load()
            url = e.get("BETTER_AUTH_URL")
            allowedHosts = e.get("RAKAZO_ALLOWED_HOSTS")
            signupsEnabled = e.get("SIGNUPS_ENABLED").lowercased() != "false"
            allowlist = e.get("SIGNUP_ALLOWLIST")
            openrouter = e.get("OPENROUTER_API_KEY"); composio = e.get("COMPOSIO_API_KEY")
            resendKey = e.get("EMAIL_API_KEY"); smtpUrl = e.get("SMTP_URL")
            emailFrom = e.get("EMAIL_FROM"); emailReplyTo = e.get("EMAIL_REPLY_TO")
            let prov = e.get("EMAIL_PROVIDER").lowercased()
            emailMode = ["none", "resend", "smtp"].contains(prov) ? prov : (smtpUrl.isEmpty ? "none" : "smtp")
            if testTo.isEmpty { testTo = allowlist.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "" }
            idleMs = e.get("SANDBOX_IDLE_MS"); maxUpload = e.get("MAX_UPLOAD_SIZE_MB")
            let lv = e.get("LOG_LEVEL"); logLevel = lv.isEmpty ? "info" : lv
            let wp = e.get("RAKAZO_WEB_PORT"); webPort = wp.isEmpty ? "5173" : wp
            say("已讀取 \(envPath)")
        } catch { say("讀取失敗：\(error.localizedDescription)") }
        refreshTailscale()
    }

    // MARK: Tailscale

    func serveInfo() -> ServeInfo? {
        let ts = tailscaleBin()
        let (c1, s1) = sh("'\(ts)' status --json")
        let (c2, s2) = sh("'\(ts)' serve status --json")
        guard c1 == 0, c2 == 0,
              let j1 = try? JSONSerialization.jsonObject(with: Data(s1.utf8)) as? [String: Any],
              let me = j1["Self"] as? [String: Any], let dnsRaw = me["DNSName"] as? String
        else { return nil }
        var info = ServeInfo(); info.dns = dnsRaw.hasSuffix(".") ? String(dnsRaw.dropLast()) : dnsRaw
        if let j2 = try? JSONSerialization.jsonObject(with: Data(s2.utf8)) as? [String: Any],
           let web = j2["Web"] as? [String: Any] {
            for (k, v) in web {
                if let h = (v as? [String: Any])?["Handlers"] as? [String: Any],
                   let root = h["/"] as? [String: Any], let proxy = root["Proxy"] as? String {
                    info.web[k] = proxy
                }
            }
        }
        return info
    }

    func refreshTailscale() {
        guard let info = serveInfo() else { tsOK = false; tsStatus = "讀不到 Tailscale（沒有安裝、沒有登入或沒有開啟）"; return }
        let mine = info.web.filter { $0.value == localTarget }.keys.sorted()
        if mine.isEmpty { tsOK = false; tsStatus = "目前沒有任何 Tailscale 網址指向 Rakazo" }
        else {
            let urls = mine.map { k -> String in k.hasSuffix(":443") ? "https://" + k.dropLast(4) : "https://" + k }
            let want = url.trimmingCharacters(in: .whitespaces)
            tsOK = urls.contains(want)
            tsStatus = urls.joined(separator: "、") + " → \(localTarget)" + (tsOK ? "" : "（和對外網址不一致）")
        }
    }

    /// 產生要執行的 tailscale 指令；有問題時回傳錯誤訊息
    func planTailscale() -> (cmds: [String], error: String?) {
        let u = url.trimmingCharacters(in: .whitespaces)
        guard let c = URLComponents(string: u), let host = c.host, c.scheme == "https" else {
            return ([], "同步 Tailscale 時，對外網址必須是 https://")
        }
        guard let info = serveInfo() else { return ([], "讀不到 Tailscale，請確認已開啟並登入") }
        guard host == info.dns else {
            return ([], "對外網址的主機名稱必須是這台的 Tailscale 名稱：\(info.dns)")
        }
        let port = c.port ?? 443
        if [3100].contains(port) { return ([], "埠號 \(port) 是 Rakazo API 內部使用的，請換一個") }
        let key = "\(host):\(port)"
        if let p = info.web[key], p != localTarget {
            return ([], "埠號 \(port) 已經被其他服務使用（\(p)），為了不影響它，請換一個埠號")
        }
        let ts = tailscaleBin()
        var cmds: [String] = []
        if info.web[key] != localTarget { cmds.append("'\(ts)' serve --bg --https=\(port) \(localTarget)") }
        for (k, p) in info.web where p == localTarget && k != key {
            if let old = k.split(separator: ":").last { cmds.append("'\(ts)' serve --https=\(old) off") }
        }
        return (cmds, nil)
    }

    func syncTailscaleOnly() {
        let plan = planTailscale()
        if let e = plan.error { say("✗ \(e)"); return }
        if plan.cmds.isEmpty { say("Tailscale 已是最新，不用改"); refreshTailscale(); return }
        run("同步 Tailscale", plan.cmds.joined(separator: " && "))
    }

    // MARK: .env

    func save() -> Bool {
        let u = url.trimmingCharacters(in: .whitespaces)
        guard u.hasPrefix("https://") || u.hasPrefix("http://"), !hostFromURL.isEmpty else { say("✗ 對外網址格式不正確，要以 https:// 開頭"); return false }
        for (name, v) in [("閒置休眠毫秒", idleMs), ("上傳上限", maxUpload)] {
            let t = v.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty && Int(t) == nil { say("✗ \(name) 只能填數字"); return false }
        }
        let from = emailFrom.trimmingCharacters(in: .whitespaces)
        if emailMode != "none" {
            if from.isEmpty { say("✗ 要寄信的話，「寄件人」不能空白"); return false }
            if emailMode == "resend" && resendKey.trimmingCharacters(in: .whitespaces).isEmpty { say("✗ 選了 Resend，要填 Resend API Key"); return false }
            let su = smtpUrl.trimmingCharacters(in: .whitespaces)
            if emailMode == "smtp" && !(su.hasPrefix("smtp://") || su.hasPrefix("smtps://")) { say("✗ SMTP 網址要以 smtp:// 或 smtps:// 開頭"); return false }
        } else if signupsEnabled && !allowlist.trimmingCharacters(in: .whitespaces).isEmpty {
            say("⚠︎ 有限定註冊 Email 但沒設定寄信：新帳號會無法註冊，也收不到忘記密碼的信")
        }
        if composio.trimmingCharacters(in: .whitespaces).hasPrefix("ck_") {
            say("✗ Composio 金鑰是 ck_ 開頭（Connect 頁的個人金鑰），Rakazo 不能用。請到 dashboard.composio.dev → API Keys 建立 ak_ 開頭的專案金鑰。"); return false
        }
        let provider = emailMode == "none" ? ((smtpUrl.isEmpty && resendKey.isEmpty) ? "" : "none") : emailMode
        let pairs: [(String, String)] = [
            ("BETTER_AUTH_URL", u), ("WEB_ORIGIN", u), ("API_URL", u),
            ("RAKAZO_HOST", hostFromURL), ("RAKAZO_ALLOWED_HOSTS", allowedHosts.replacingOccurrences(of: " ", with: "")),
            ("SIGNUPS_ENABLED", signupsEnabled ? "true" : "false"),
            ("SIGNUP_ALLOWLIST", allowlist.replacingOccurrences(of: " ", with: "")),
            ("OPENROUTER_API_KEY", openrouter), ("COMPOSIO_API_KEY", composio),
            ("EMAIL_PROVIDER", provider), ("EMAIL_API_KEY", resendKey), ("SMTP_URL", smtpUrl),
            ("EMAIL_FROM", from), ("EMAIL_REPLY_TO", emailReplyTo),
            ("SANDBOX_IDLE_MS", idleMs), ("MAX_UPLOAD_SIZE_MB", maxUpload), ("LOG_LEVEL", logLevel)]
        do {
            var e = try EnvFile.load()
            var changed: [String] = []
            for (k, raw) in pairs {
                let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let spaceOK = (k == "EMAIL_FROM" || k == "EMAIL_REPLY_TO")
                if (!spaceOK && v.contains(" ")) || v.contains("#") || v.contains("'") || v.contains("\"") || v.contains("$") {
                    say(spaceOK ? "✗ \(k) 不能含 #、$ 或引號" : "✗ \(k) 不能含空白、#、$ 或引號（密碼有特殊字元請先做網址編碼）"); return false
                }
                if e.get(k) == v { continue }
                if v.isEmpty && !e.has(k) { continue }
                e.set(k, v.contains(" ") ? "\"\(v)\"" : v); changed.append(k)
            }
            if changed.isEmpty { say(".env 沒有變更"); return true }
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
            let bak = envPath + ".bak-" + f.string(from: Date())
            try FileManager.default.copyItem(atPath: envPath, toPath: bak)
            try e.text().write(toFile: envPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envPath)
            say("✓ 已儲存，變更：\(changed.joined(separator: ", "))")
            say("  備份：\((bak as NSString).lastPathComponent)")
            return true
        } catch { say("✗ 儲存失敗：\(error.localizedDescription)"); return false }
    }

    func saveAndApply() {
        var tsCmds: [String] = []
        if syncTailscale {
            let plan = planTailscale()
            if let e = plan.error { say("✗ \(e)"); say("  沒有儲存任何變更。可以修正網址，或關掉「同步 Tailscale」。"); return }
            tsCmds = plan.cmds
        }
        guard save() else { return }
        let docker = "\(composeBase) up -d --pull never --wait --wait-timeout 300"
        let all = (tsCmds + [docker]).joined(separator: " && ")
        run(tsCmds.isEmpty ? "重啟 Rakazo 套用設定（約 1 分鐘）" : "更新 Tailscale 並重啟 Rakazo（約 1 分鐘）", all)
    }

    func run(_ title: String, _ cmd: String) {
        busy = true; say("▶ \(title)")
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-c", cmd]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = shellPath
            p.environment = env
            p.currentDirectoryURL = URL(fileURLWithPath: rakazoDir)
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { return }
                let s = String(decoding: d, as: UTF8.self)
                Task { @MainActor in self.log += s }
            }
            var code: Int32 = -1
            do { try p.run(); p.waitUntilExit(); code = p.terminationStatus } catch {}
            pipe.fileHandleForReading.readabilityHandler = nil
            let c = code
            await MainActor.run {
                self.say(c == 0 ? "✓ 完成" : "✗ 失敗（代碼 \(c)）")
                self.busy = false
                self.refreshTailscale()
            }
        }
    }

    /// 用畫面上目前的寄信設定寄一封測試信（不需先儲存）
    func sendTest(done: ((Bool, String) -> Void)? = nil) {
        func fail(_ s: String) { say("✗ " + s); done?(false, s) }
        let to = testTo.trimmingCharacters(in: .whitespaces)
        let from = emailFrom.trimmingCharacters(in: .whitespaces)
        guard to.contains("@") else { fail("請填測試收件人"); return }
        guard !from.isEmpty else { fail("請先填寄件人"); return }
        let mode = emailMode, key = resendKey.trimmingCharacters(in: .whitespaces), surl = smtpUrl.trimmingCharacters(in: .whitespaces)
        let replyTo = emailReplyTo.trimmingCharacters(in: .whitespaces)
        if mode == "none" { fail("目前選的是「不寄信」"); return }
        if mode == "resend" && key.isEmpty { fail("請先填 Resend API Key"); return }
        if mode == "smtp" && !(surl.hasPrefix("smtp://") || surl.hasPrefix("smtps://")) { fail("SMTP 網址要以 smtp:// 或 smtps:// 開頭"); return }
        let sig = mailSig
        testing = true; say("▶ 寄測試信到 \(to)（\(mode == "resend" ? "Resend" : "SMTP")）")
        Task.detached {
            func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
            let tmp = NSTemporaryDirectory() + "rakazo-mailtest-\(UUID().uuidString)"
            var cfg = ""; var args = ["-sS", "--max-time", "30", "-K", "-"]
            let subject = "Rakazo 設定：測試信"
            let bodyText = "這是「Rakazo 設定」寄出的測試信。收到代表寄信設定正確，Rakazo 可以寄驗證信和重設密碼信。"
            if mode == "resend" {
                var obj: [String: Any] = ["from": from, "to": [to], "subject": subject, "text": bodyText]
                if !replyTo.isEmpty { obj["reply_to"] = replyTo }
                let d = try? JSONSerialization.data(withJSONObject: obj)
                FileManager.default.createFile(atPath: tmp, contents: d, attributes: [.posixPermissions: 0o600])
                cfg = "url = \"https://api.resend.com/emails\"\nheader = " + q("Authorization: Bearer " + key) + "\nheader = \"Content-Type: application/json\"\n"
                args += ["--data-binary", "@" + tmp, "-w", "\nHTTP %{http_code}"]
            } else {
                let addr: String = {
                    if let a = from.firstIndex(of: "<"), let b = from.firstIndex(of: ">"), a < b { return String(from[from.index(after: a)..<b]) }
                    return from
                }()
                let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
                let b64Subject = "=?UTF-8?B?" + Data(subject.utf8).base64EncodedString() + "?="
                var msg = "From: \(from)\r\nTo: \(to)\r\nSubject: \(b64Subject)\r\nDate: \(df.string(from: Date()))\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n"
                if !replyTo.isEmpty { msg += "Reply-To: \(replyTo)\r\n" }
                msg += "\r\n" + Data(bodyText.utf8).base64EncodedString(options: .lineLength76Characters) + "\r\n"
                FileManager.default.createFile(atPath: tmp, contents: Data(msg.utf8), attributes: [.posixPermissions: 0o600])
                cfg = "url = " + q(surl) + "\nmail-from = " + q(addr) + "\nmail-rcpt = " + q(to) + "\n"
                if surl.hasPrefix("smtp://") { cfg += "ssl-reqd\n" }
                args += ["--upload-file", tmp]
            }
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/curl"); p.arguments = args
            let inp = Pipe(), out = Pipe(); p.standardInput = inp; p.standardOutput = out; p.standardError = out
            var code: Int32 = -1; var text = ""
            do {
                try p.run()
                inp.fileHandleForWriting.write(Data(cfg.utf8)); try? inp.fileHandleForWriting.close()
                let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
                code = p.terminationStatus; text = String(decoding: d, as: UTF8.self)
            } catch { text = error.localizedDescription }
            try? FileManager.default.removeItem(atPath: tmp)
            for secret in [key, surl] where !secret.isEmpty { text = text.replacingOccurrences(of: secret, with: "•••") }
            let ok: Bool = mode == "resend" ? (code == 0 && (text.contains("HTTP 200") || text.contains("HTTP 201"))) : code == 0
            let shown = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let fc = code
            await MainActor.run {
                let msg = ok ? "測試信已送出，請到 \(to) 收信（也看一下垃圾信匣）。" : Model.explain(mode: mode, code: fc, text: shown)
                if ok { self.say("✓ " + msg) }
                else {
                    self.say("✗ 寄送失敗：" + msg)
                    if !shown.isEmpty { self.say("  原始訊息：" + String(shown.prefix(300))) }
                }
                self.recordTest(sig: sig, ok: ok, msg: msg)
                self.testing = false
                done?(ok, msg)
            }
        }
    }

    // MARK: 寄信狀態

    var mailSig: String {
        let raw = [emailMode, emailFrom, resendKey, smtpUrl].map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "|")
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var mailKind: String {
        if emailMode == "resend" { return "Resend" }
        return smtpUrl.contains("smtp.gmail.com") ? "Gmail" : "SMTP"
    }

    var mailStatus: (icon: String, color: Color, text: String) {
        _ = testStamp
        if emailMode == "none" { return ("minus.circle.fill", Color.secondary, "未設定：Rakazo 目前不會寄信") }
        let d = UserDefaults.standard
        if d.string(forKey: "mailTestSig") == mailSig {
            let at = d.string(forKey: "mailTestAt") ?? ""
            if d.bool(forKey: "mailTestOK") { return ("checkmark.circle.fill", Color.green, "已設定（\(mailKind)），\(at) 測試成功") }
            return ("xmark.octagon.fill", Color.red, "已設定（\(mailKind)），但 \(at) 測試失敗：\(d.string(forKey: "mailTestMsg") ?? "")")
        }
        return ("exclamationmark.triangle.fill", Color.orange, "已設定（\(mailKind)），還沒寄過測試信")
    }

    func recordTest(sig: String, ok: Bool, msg: String) {
        let d = UserDefaults.standard
        let f = DateFormatter(); f.dateFormat = "M/d HH:mm"
        d.set(sig, forKey: "mailTestSig"); d.set(ok, forKey: "mailTestOK")
        d.set(f.string(from: Date()), forKey: "mailTestAt"); d.set(msg, forKey: "mailTestMsg")
        testStamp += 1
    }

    /// 把寄信失敗的原因翻成白話
    static func explain(mode: String, code: Int32, text: String) -> String {
        let t = text.lowercased()
        switch code {
        case 6: return "找不到郵件伺服器，請確認這台 Mac 有連上網路。"
        case 7: return "連不上郵件伺服器，可能是網路或防火牆擋住了。"
        case 28: return "連線逾時，請稍後再試，或檢查網路。"
        default: break
        }
        if mode == "resend" {
            if t.contains("api key is invalid") || t.contains("http 401") { return "Resend API Key 不正確。請到 Resend 的 API Keys 頁重新建立一把，再貼上。" }
            if t.contains("only send testing emails") { return "Resend 只允許寄給你自己的註冊信箱，代表網域還沒驗證完成。請到 Resend 的 Domains 頁確認狀態是 Verified。" }
            if t.contains("not verified") || t.contains("verify a domain") || t.contains("domain is not") { return "寄件人的網域還沒在 Resend 驗證完成。請到 Resend 的 Domains 頁確認狀態是 Verified（DNS 生效可能要等幾分鐘到幾小時）。" }
            if t.contains("from") && (t.contains("http 422") || t.contains("invalid")) { return "寄件人格式不正確，應該像「Rakazo <noreply@你的網域>」，而且網域要跟 Resend 驗證過的一樣。" }
            if t.contains("http 429") { return "寄太頻繁了，等一分鐘再試。" }
            if t.contains("http 403") { return "Resend 拒絕寄送，通常是網域還沒驗證，或 API Key 權限不夠。" }
            return "Resend 回報錯誤，詳細訊息在下方「記錄」。"
        }
        switch code {
        case 67: return "登入郵件伺服器失敗：帳號或密碼錯誤。Gmail 要用 16 碼「應用程式密碼」，不是平常登入用的密碼。"
        case 35, 60: return "加密連線失敗。465 埠要用 smtps://，587 埠要用 smtp://。"
        case 55, 26: return "信寄到一半失敗，請稍後再試。"
        default: break
        }
        if t.contains("550") || t.contains("553") || t.contains("554") || t.contains("555") { return "郵件伺服器拒絕寄出。請確認寄件人地址就是登入的那個帳號。" }
        return "寄送失敗（代碼 \(code)），詳細訊息在下方「記錄」。"
    }

    func apply() { run("重啟 Rakazo（約 1 分鐘）", "\(composeBase) up -d --pull never --wait --wait-timeout 300") }
    func status() { run("查詢狀態", "docker compose -p rakazo ps --format '{{.Service}}\t{{.Status}}'") }
    func stop() { run("停止 Rakazo", "\(composeBase) stop") }
}

// MARK: UI

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).padding(.leading, 4)
            VStack(alignment: .leading, spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
        }
    }
}

struct Row<Content: View>: View {
    let label: String
    var hint: String? = nil
    var info: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(label)
                    if let info {
                        InfoTip(text: info)
                    }
                }
                if let hint { Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            .frame(width: 220, alignment: .leading)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

final class InfoTipState: ObservableObject {
    @Published var show = false
    @Published var hovering = false
}

struct InfoTip: View {
    let text: String
    @StateObject private var st = InfoTipState()
    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 14))
            .foregroundStyle(st.hovering || st.show ? Color.accentColor : Color.secondary)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
            .onHover { h in
                st.hovering = h
                if h {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { if st.hovering { st.show = true } }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { if !st.hovering { st.show = false } }
                }
            }
            .onTapGesture { st.show.toggle() }
            .overlay(alignment: .bottomLeading) {
                if st.show {
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 300, alignment: .leading)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.4)))
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                        .offset(x: -4, y: -26)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .zIndex(st.show ? 10 : 0)
            .accessibilityLabel(text)
    }
}

struct Sep: View { var body: some View { Divider().padding(.leading, 14) } }

struct ContentView: View {
    @ObservedObject var m: Model

    func field(_ text: Binding<String>, _ prompt: String) -> some View {
        TextField("", text: text, prompt: Text(prompt)).textFieldStyle(.roundedBorder)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Card(title: "連線網址") {
                        Row(label: "對外網址", hint: "同時寫入 BETTER_AUTH_URL、WEB_ORIGIN、API_URL") {
                            field($m.url, "https://主機名.tailxxxx.ts.net:5173")
                        }
                        Sep()
                        Row(label: "主機名稱", hint: "RAKAZO_HOST，依對外網址自動填入") {
                            Text(m.hostFromURL.isEmpty ? "—" : m.hostFromURL).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Sep()
                        Row(label: "其他允許的主機名稱", hint: "選填，逗號分隔") {
                            field($m.allowedHosts, "例如 100.x.x.x,my-mac")
                        }
                    }

                    Card(title: "Tailscale") {
                        Row(label: "同步 Tailscale serve", hint: "按「儲存並套用」時，依對外網址的埠號自動更新") {
                            Toggle("", isOn: $m.syncTailscale).labelsHidden().toggleStyle(.switch)
                        }
                        Sep()
                        Row(label: "目前狀態", hint: "只會改指向 Rakazo 的設定，其他服務不動") {
                            HStack(spacing: 8) {
                                Image(systemName: m.tsOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(m.tsOK ? .green : .orange)
                                Text(m.tsStatus).font(.callout).textSelection(.enabled)
                                    .lineLimit(1).truncationMode(.middle).help(m.tsStatus)
                                Spacer(minLength: 8)
                                Button("重新檢查") { m.refreshTailscale() }
                                Button("立即同步") { m.syncTailscaleOnly() }
                            }
                        }
                    }

                    Card(title: "註冊") {
                        Row(label: "允許註冊", hint: "SIGNUPS_ENABLED") {
                            Toggle("", isOn: $m.signupsEnabled).labelsHidden().toggleStyle(.switch)
                        }
                        Sep()
                        Row(label: "允許註冊的 Email", hint: "逗號分隔；空白＝任何人") {
                            field($m.allowlist, "you@example.com")
                        }
                        if m.emailMode == "none" && m.signupsEnabled && !m.allowlist.trimmingCharacters(in: .whitespaces).isEmpty {
                            Sep()
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                Text("有限定 Email 時，Rakazo 要寄驗證信，新帳號才能註冊。請按下方「寄信」的「設定精靈」完成設定。")
                                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                        }
                    }

                    Card(title: "寄信") {
                        Row(label: "目前狀態", info: "Rakazo 用這裡的設定寄出註冊驗證信和「忘記密碼」信。建議按「設定精靈」：會一步一步帶你設定 Gmail 或 Resend，測試信寄成功才會儲存。") {
                            let st = m.mailStatus
                            HStack(spacing: 8) {
                                Image(systemName: st.icon).foregroundStyle(st.color)
                                Text(st.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                Button("設定精靈…") { m.showWizard = true }.buttonStyle(.borderedProminent)
                            }
                        }
                        Sep()
                        Button { withAnimation { m.showMailAdvanced.toggle() } } label: {
                            HStack(spacing: 6) {
                                Image(systemName: m.showMailAdvanced ? "chevron.down" : "chevron.right").font(.caption)
                                Text("進階：手動設定").font(.callout)
                                Spacer()
                            }.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        if m.showMailAdvanced {
                        Sep()
                        Row(label: "寄信方式") {
                            Picker("", selection: $m.emailMode) {
                                Text("不寄信").tag("none"); Text("Resend").tag("resend"); Text("SMTP").tag("smtp")
                            }.labelsHidden().pickerStyle(.segmented).fixedSize()
                        }
                        if m.emailMode == "resend" {
                            Sep()
                            Row(label: "Resend API Key", hint: "re_ 開頭；顯示方式跟著「顯示金鑰」") {
                                if m.showKeys { field($m.resendKey, "re_…") }
                                else { SecureField("", text: $m.resendKey, prompt: Text("re_…")).textFieldStyle(.roundedBorder) }
                            }
                        }
                        if m.emailMode == "smtp" {
                            Sep()
                            Row(label: "SMTP 網址", info: "格式是 smtps://帳號:密碼@主機:465，或 smtp://帳號:密碼@主機:587。帳號或密碼裡有 @、: 、/ 等符號時，要先做網址編碼（例如 @ 寫成 %40）。Gmail 要用「應用程式密碼」，不是登入密碼。") {
                                if m.showKeys { field($m.smtpUrl, "smtps://帳號:密碼@smtp.example.com:465") }
                                else { SecureField("", text: $m.smtpUrl, prompt: Text("smtps://帳號:密碼@主機:465")).textFieldStyle(.roundedBorder) }
                            }
                        }
                        if m.emailMode != "none" {
                            Sep()
                            Row(label: "寄件人", hint: "必填；Resend 要用已驗證網域的地址") {
                                field($m.emailFrom, "Rakazo <noreply@你的網域>")
                            }
                            Sep()
                            Row(label: "回覆地址", hint: "選填") { field($m.emailReplyTo, "you@example.com") }
                            Sep()
                            Row(label: "寄測試信", hint: "用畫面上的設定寄，不用先儲存") {
                                HStack(spacing: 8) {
                                    field($m.testTo, "收件人 Email")
                                    if m.testing { ProgressView().controlSize(.small) }
                                    Button("寄出") { m.sendTest() }.disabled(m.testing)
                                }
                            }
                        }
                        }
                    }

                    Card(title: "金鑰") {
                        Row(label: "OpenRouter API Key") {
                            if m.showKeys { field($m.openrouter, "sk-or-…") }
                            else { SecureField("", text: $m.openrouter, prompt: Text("sk-or-…")).textFieldStyle(.roundedBorder) }
                        }
                        Sep()
                        Row(label: "Composio API Key") {
                            if m.showKeys { field($m.composio, "選填") }
                            else { SecureField("", text: $m.composio, prompt: Text("選填")).textFieldStyle(.roundedBorder) }
                        }
                        Sep()
                        Row(label: "顯示金鑰") {
                            Toggle("", isOn: $m.showKeys).labelsHidden().toggleStyle(.switch)
                        }
                    }

                    Card(title: "其他") {
                        Row(label: "Bot 電腦閒置休眠", hint: "毫秒；0＝不休眠") { field($m.idleMs, "預設") }
                        Sep()
                        Row(label: "上傳檔案上限", hint: "MB") { field($m.maxUpload, "預設") }
                        Sep()
                        Row(label: "記錄等級", info: "決定 Rakazo 在背景寫下多少運作紀錄：debug 最詳細，適合查問題；info 是一般建議；warn 只記警告；error 只記錯誤。") {
                            Picker("", selection: $m.logLevel) {
                                ForEach(["debug", "info", "warn", "error"], id: \.self) { Text($0) }
                            }.labelsHidden().pickerStyle(.segmented).fixedSize()
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }

            Divider()

            // 記錄區：標題列永遠顯示，內容可收合
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "text.alignleft").foregroundStyle(.secondary)
                    Text("記錄").font(.callout.weight(.semibold))
                    if !m.showLog {
                        Text(m.log.split(separator: "\n").last.map(String.init) ?? "")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if m.showLog {
                        if let old = m.clearedLog, m.log.isEmpty {
                            Button("復原") { m.log = old; m.clearedLog = nil }.buttonStyle(.borderless).font(.caption)
                                .help("把剛剛清除的記錄放回來")
                        } else if !m.log.isEmpty {
                            Button("清除") { m.clearedLog = m.log; m.log = "" }.buttonStyle(.borderless).font(.caption)
                                .help("只清掉畫面上的記錄，不影響設定")
                        }
                    }
                    Button { withAnimation(.easeInOut(duration: 0.15)) { m.showLog.toggle() } } label: {
                        Image(systemName: m.showLog ? "chevron.down" : "chevron.up").frame(width: 16, height: 16)
                    }
                    .buttonStyle(.borderless)
                    .help(m.showLog ? "收起記錄" : "展開記錄")
                }
                if m.showLog {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(m.log.isEmpty ? "（沒有記錄）" : m.log)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(m.log.isEmpty ? .secondary : .primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                Color.clear.frame(height: 1).id("end")
                            }
                            .padding(10)
                        }
                        .onChange(of: m.log) { _, _ in proxy.scrollTo("end") }
                    }
                    .frame(height: 96)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 10)

            Divider()

            // 底部按鈕列
            HStack(spacing: 8) {
                Button("重新讀取") { m.load() }
                Button("只儲存") { _ = m.save() }
                Button("儲存並套用") { m.saveAndApply() }.buttonStyle(.borderedProminent).keyboardShortcut("s")
                if m.busy { ProgressView().controlSize(.small).padding(.leading, 4) }
                Spacer()
                Button("狀態") { m.status() }
                Button("開啟 Rakazo") { if let u = URL(string: m.url) { NSWorkspace.shared.open(u) } }
                Menu("更多") {
                    Button("啟動／重啟 Rakazo") { m.apply() }
                    Button("停止 Rakazo") { m.stop() }
                    Divider()
                    Button("用文字編輯器開啟 .env（進階）") {
                        NSWorkspace.shared.open([URL(fileURLWithPath: envPath)], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"), configuration: .init())
                    }
                    Button("在 Finder 顯示 rakazo 資料夾") { NSWorkspace.shared.selectFile(envPath, inFileViewerRootedAtPath: rakazoDir) }
                }.fixedSize()
            }
            .controlSize(.large)
            .disabled(m.busy)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(.bar)
        }
        .frame(minWidth: 760, minHeight: 560)
        .onAppear { if !m.didLoad { m.load() } }
        .sheet(isPresented: $m.showWizard) { MailWizard(m: m) }
    }
}

// MARK: 寄信設定精靈

final class WizState: ObservableObject {
    @Published var step = 0
    @Published var choice = "gmail"
    @Published var gmailAddr = ""
    @Published var gmailPwd = ""
    @Published var rKey = ""
    @Published var rDomain = ""
    @Published var rName = "Rakazo"
    @Published var rLocal = "noreply"
    @Published var testTo = ""
    @Published var error = ""
    @Published var resultMsg = ""
    @Published var resultOK: Bool? = nil
    @Published var snapshot: [String] = []
}


struct MailWizard: View {
    @ObservedObject var m: Model
    @Environment(\.dismiss) var dismiss
    @StateObject private var w = WizState()

    var totalSteps: Int { w.choice == "none" ? 2 : 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("寄信設定精靈").font(.title2.bold())
                Spacer()
                Text("步驟 \(w.step + 1) / \(totalSteps)").foregroundStyle(.secondary)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
            if !w.error.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(w.error).fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            HStack {
                Button("取消") { cancel() }.keyboardShortcut(.cancelAction)
                Spacer()
                if w.step > 0 { Button("上一步") { w.error = ""; w.resultOK = nil; w.step -= 1 }.disabled(m.testing) }
                primaryButton
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 620, height: 640)
        .onAppear(perform: prefill)
    }

    @ViewBuilder var content: some View {
        if w.step == 0 { chooseView }
        else if w.step == 1 {
            if w.choice == "gmail" { gmailView } else if w.choice == "resend" { resendView } else { noneView }
        } else { testView }
    }

    @ViewBuilder var primaryButton: some View {
        if w.step == 0 {
            Button("下一步") { w.error = ""; w.step = 1 }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        } else if w.step == 1 && w.choice == "none" {
            Button("儲存並套用") { m.emailMode = "none"; m.saveAndApply(); dismiss() }.buttonStyle(.borderedProminent)
        } else if w.step == 1 {
            Button("下一步：寄測試信") { if buildConfig() { w.step = 2 } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        } else {
            Button("儲存並套用") { m.showMailAdvanced = false; m.saveAndApply(); dismiss() }
                .buttonStyle(.borderedProminent)
                .disabled(w.resultOK != true || m.testing)
                .help(w.resultOK == true ? "儲存設定並重新啟動 Rakazo（約 1 分鐘）" : "測試信寄成功後才能儲存")
        }
    }

    // MARK: 步驟 1：選方式

    var chooseView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rakazo 要用什麼方式寄出驗證信和「忘記密碼」信？").font(.headline)
            option("gmail", "用 Gmail 寄（推薦）", "最簡單，不需要自己的網域，大約 5 分鐘。信會從你的 Gmail 寄出。")
            option("resend", "用自己的網域寄（Resend）", "寄件人會是 noreply@你的網域，看起來比較正式。需要到網域商後台加幾筆 DNS 記錄。")
            option("none", "先不寄信", "之後再設定。限定 Email 的註冊和「忘記密碼」會沒辦法用。")
        }
    }

    func option(_ tag: String, _ title: String, _ desc: String) -> some View {
        Button { w.choice = tag } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: w.choice == tag ? "largecircle.fill.circle" : "circle")
                    .font(.title3).foregroundStyle(w.choice == tag ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.semibold))
                    Text(desc).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(w.choice == tag ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: w.choice == tag ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func stepItem(_ n: Int, _ title: String, _ detail: String, link: (String, String)? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.callout.bold()).frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor.opacity(0.25)))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let link {
                    Button { if let u = URL(string: link.1) { NSWorkspace.shared.open(u) } } label: {
                        Label(link.0, systemImage: "arrow.up.right.square")
                    }
                }
            }
        }
    }

    func labeled<C: View>(_ t: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(t).font(.callout.weight(.medium)); c() }
            .padding(.leading, 34)
    }

    // MARK: 步驟 2：填資料

    var gmailView: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepItem(1, "開啟 Google 帳戶的「兩步驟驗證」", "要先開兩步驟驗證，才能建立應用程式密碼。已經開過就跳過這步。",
                     link: ("打開兩步驟驗證頁面", "https://myaccount.google.com/signinoptions/twosv"))
            stepItem(2, "建立「應用程式密碼」", "名稱輸入 Rakazo，按「建立」，畫面會出現一組 16 個字母的密碼。先複製它，視窗不要急著關。如果頁面說「這項設定不適用」，代表第 1 步還沒完成。",
                     link: ("打開應用程式密碼頁面", "https://myaccount.google.com/apppasswords"))
            stepItem(3, "填入下面兩格", "密碼直接貼上就好，中間的空格會自動去掉。")
            labeled("Gmail 地址") {
                TextField("", text: $w.gmailAddr, prompt: Text("you@gmail.com")).textFieldStyle(.roundedBorder)
            }
            labeled("應用程式密碼（16 碼）") {
                SecureField("", text: $w.gmailPwd, prompt: Text("xxxx xxxx xxxx xxxx")).textFieldStyle(.roundedBorder)
            }
            Text("密碼只會存在這台 Mac 的 ~/rakazo/.env。之後想停用，到 Google 的應用程式密碼頁刪掉它就好。")
                .font(.caption).foregroundStyle(.secondary).padding(.leading, 34)
        }
    }

    var resendView: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepItem(1, "註冊或登入 Resend", "免費方案每月可寄 3,000 封，自己用很夠。",
                     link: ("打開 Resend", "https://resend.com/signup"))
            stepItem(2, "新增並驗證你的網域", "到 Domains 按「Add Domain」，輸入網域（例如 example.com）。Resend 會列出幾筆 DNS 記錄，到網域商後台照著新增，再回 Resend 按「Verify」。狀態變成 Verified 就完成了，可能要等幾分鐘到幾小時。",
                     link: ("打開 Domains 頁面", "https://resend.com/domains"))
            stepItem(3, "建立 API Key", "到 API Keys 按「Create API Key」，名稱填 Rakazo，權限選 Sending access。金鑰只會顯示一次，建好馬上複製。",
                     link: ("打開 API Keys 頁面", "https://resend.com/api-keys"))
            stepItem(4, "填入下面欄位", "寄件人會顯示成「名稱 <開頭@網域>」。")
            labeled("Resend API Key") {
                SecureField("", text: $w.rKey, prompt: Text("re_…")).textFieldStyle(.roundedBorder)
            }
            labeled("已驗證的網域") {
                TextField("", text: $w.rDomain, prompt: Text("例如 example.com")).textFieldStyle(.roundedBorder)
            }
            labeled("寄件人名稱與信箱開頭") {
                HStack(spacing: 6) {
                    TextField("", text: $w.rName, prompt: Text("Rakazo")).textFieldStyle(.roundedBorder).frame(width: 140)
                    TextField("", text: $w.rLocal, prompt: Text("noreply")).textFieldStyle(.roundedBorder).frame(width: 120)
                    Text("@" + (w.rDomain.isEmpty ? "你的網域" : w.rDomain)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    var noneView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rakazo 將不會寄任何信。").font(.headline)
            Text("按「儲存並套用」後會重新啟動 Rakazo，大約 1 分鐘。之後想設定，再打開這個精靈就好。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if m.signupsEnabled && !m.allowlist.trimmingCharacters(in: .whitespaces).isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("你有限定註冊 Email。不寄信的話，新帳號會無法完成註冊。").fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: 步驟 3：寄測試信

    var testView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("寄一封測試信，確認設定正確").font(.headline)
            Text("寄件人：\(m.emailFrom)").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            VStack(alignment: .leading, spacing: 4) {
                Text("收件人").font(.callout.weight(.medium))
                HStack(spacing: 8) {
                    TextField("", text: $w.testTo, prompt: Text("you@example.com")).textFieldStyle(.roundedBorder)
                    if m.testing { ProgressView().controlSize(.small) }
                    Button("寄測試信") { runTest() }.disabled(m.testing)
                }
            }
            if let ok = w.resultOK {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .font(.title2).foregroundStyle(ok ? Color.green : Color.red)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ok ? "寄出成功！" : "寄送失敗").font(.body.weight(.semibold))
                        Text(w.resultMsg).fixedSize(horizontal: false, vertical: true)
                        Text(ok ? "確認收到信後，按右下角「儲存並套用」。Rakazo 會重新啟動，大約 1 分鐘。" : "按「上一步」修改後，再寄一次。")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill((ok ? Color.green : Color.red).opacity(0.1)))
            }
        }
    }

    // MARK: 動作

    func prefill() {
        w.snapshot = [m.emailMode, m.resendKey, m.smtpUrl, m.emailFrom, m.emailReplyTo]
        w.testTo = m.testTo
        let f = m.emailFrom
        if let a = f.firstIndex(of: "<"), let b = f.firstIndex(of: ">"), a < b {
            let name = f[..<a].trimmingCharacters(in: .whitespaces)
            let parts = String(f[f.index(after: a)..<b]).split(separator: "@", maxSplits: 1)
            if m.emailMode == "resend", parts.count == 2 {
                if !name.isEmpty { w.rName = name }
                w.rLocal = String(parts[0]); w.rDomain = String(parts[1])
            }
        }
        if m.emailMode == "resend" { w.choice = "resend"; w.rKey = m.resendKey }
        else if m.smtpUrl.contains("smtp.gmail.com"), let c = URLComponents(string: m.smtpUrl) {
            w.choice = "gmail"; w.gmailAddr = c.user ?? ""; w.gmailPwd = c.password ?? ""
        }
    }

    func cancel() {
        if w.snapshot.count == 5 && !m.testing {
            m.emailMode = w.snapshot[0]; m.resendKey = w.snapshot[1]; m.smtpUrl = w.snapshot[2]
            m.emailFrom = w.snapshot[3]; m.emailReplyTo = w.snapshot[4]
        }
        dismiss()
    }

    func buildConfig() -> Bool {
        w.error = ""; w.resultOK = nil
        if w.choice == "gmail" {
            let addr = w.gmailAddr.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let pwd = w.gmailPwd.filter { !$0.isWhitespace }
            guard addr.contains("@"), addr.contains("."), !addr.contains(" ") else { w.error = "請填正確的 Gmail 地址。"; return false }
            guard pwd.count == 16, pwd.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
                w.error = "應用程式密碼應該是 16 個英文字母（空格不算）。請確認貼的是應用程式密碼，不是 Gmail 登入密碼。"; return false
            }
            var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            allowed.remove(charactersIn: "")
            let user = addr.addingPercentEncoding(withAllowedCharacters: allowed) ?? addr
            m.emailMode = "smtp"
            m.smtpUrl = "smtps://\(user):\(pwd)@smtp.gmail.com:465"
            m.emailFrom = "Rakazo <\(addr)>"
            m.resendKey = ""
            w.gmailAddr = addr
            if w.testTo.trimmingCharacters(in: .whitespaces).isEmpty { w.testTo = addr }
            return true
        }
        let key = w.rKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var dom = w.rDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for p in ["https://", "http://", "www."] where dom.hasPrefix(p) { dom = String(dom.dropFirst(p.count)) }
        if let at = dom.lastIndex(of: "@") { dom = String(dom[dom.index(after: at)...]) }
        while dom.hasSuffix("/") { dom = String(dom.dropLast()) }
        let name = w.rName.trimmingCharacters(in: .whitespaces)
        let local = w.rLocal.trimmingCharacters(in: .whitespaces)
        guard key.hasPrefix("re_"), key.count > 10 else { w.error = "Resend API Key 應該是 re_ 開頭。"; return false }
        guard dom.contains("."), !dom.contains(" ") else { w.error = "請填在 Resend 驗證過的網域，例如 example.com。"; return false }
        guard !local.isEmpty, !local.contains("@"), !local.contains(" ") else { w.error = "信箱開頭只要填 @ 前面的部分，例如 noreply。"; return false }
        guard name.rangeOfCharacter(from: CharacterSet(charactersIn: "#$'\"<>")) == nil else { w.error = "寄件人名稱不能含 # $ < > 或引號。"; return false }
        w.rDomain = dom
        m.emailMode = "resend"
        m.resendKey = key
        m.smtpUrl = ""
        m.emailFrom = name.isEmpty ? "\(local)@\(dom)" : "\(name) <\(local)@\(dom)>"
        return true
    }

    func runTest() {
        let t = w.testTo.trimmingCharacters(in: .whitespaces)
        guard t.contains("@") else { w.error = "請填收件人 Email。"; return }
        w.error = ""; w.resultOK = nil; m.testTo = t
        m.sendTest { ok, msg in w.resultOK = ok; w.resultMsg = msg }
    }
}

