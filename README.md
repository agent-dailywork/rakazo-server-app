# Rakazo 自架（rakazo-server-app）

一個 macOS SwiftUI 小工具，用來安裝與管理**自架版 Rakazo**（Docker published images + Tailscale HTTPS）。

| 分頁 | 功能 |
|---|---|
| 總覽 | 開啟時自動健康檢查（Docker、服務、本機網頁、Tailscale、OpenRouter、Composio、寄信…），每項附「怎麼處理」；啟動／重啟、停止、更新（先自動備份）、備份資料庫、最近的錯誤、診斷報告 |
| 設定 | 編輯 `~/rakazo/.env`：網址、註冊名單、金鑰、上傳上限；「儲存並套用」會先備份 `.env`、同步 `tailscale serve`、重啟服務。內建**寄信設定精靈**（Gmail 應用程式密碼／Resend），測試信成功才能套用；會擋下 `ck_` 開頭的 Composio 金鑰 |
| 安裝 | 新機器 6 步驟：環境檢查 → 下載準備 → 網址 → 金鑰 → 第一個帳號（先設寄信，或 `bootstrap-owner`）→ 啟動檢查 |

操作說明與常見卡點：[docs/自架操作手冊.md](docs/自架操作手冊.md)。給 AI Agent 用的 skill：[rakazo-self-host](https://github.com/agent-dailywork/rakazo-self-host)。

## 需求

- macOS 14+（Apple Silicon）
- Xcode Command Line Tools（`xcode-select --install`），用 `swiftc` 編譯
- Docker Desktop 26+、Tailscale

## 編譯與安裝

```sh
git clone https://github.com/agent-dailywork/rakazo-server-app ~/rakazo/tools/RakazoServer
cd ~/rakazo/tools/RakazoServer
./build.sh   # 編譯並安裝到 /Applications/Rakazo 自架.app（ad-hoc 簽章）
```

第一次打開若被 Gatekeeper 擋下：在 Finder 對 App 按右鍵 →「打開」。

## 安全

- 金鑰與密碼只存在本機 `~/rakazo/.env`，App 不會上傳或記錄。
- 本 repo 不含任何 `.env`、帳號或金鑰。
