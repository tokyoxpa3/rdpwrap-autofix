# RDP Wrapper 一鍵修復工具

> Windows 更新後 RDP Wrapper 失效？雙擊一次就好。
> One-click auto-repair for RDP Wrapper after Windows Update breaks it.

[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D6?logo=windows)](https://github.com/tokyoxpa3/rdpwrap-autofix)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell)](https://github.com/tokyoxpa3/rdpwrap-autofix)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Release](https://img.shields.io/github/v/release/tokyoxpa3/rdpwrap-autofix)](https://github.com/tokyoxpa3/rdpwrap-autofix/releases)

---

## 這是什麼

Windows 每次安裝安全性更新，`termsrv.dll` 的版本就會改變，RDP Wrapper 因為找不到對應的
patch 偏移量而失效，工作列上的 RDP 圖示就會變成「not supported」。

以往你得手動做這一串：

1. 到 GitHub 抓最新的 `rdpwrap.ini`
2. 跑 `uninstall.bat`
3. 跑 `install.bat`
4. 再跑 `reinstall.bat`（關服務 → 複製 ini → 開服務）

**這個工具把它變成一個步驟：雙擊 `一鍵修復RDP.bat`，按 `1`。**

---

## 快速開始

### 方法一：下載 Release（最簡單）

1. 到 [Releases](https://github.com/tokyoxpa3/rdpwrap-autofix/releases) 下載最新的 zip
2. 解壓縮到任何資料夾（路徑不要有特殊符號）
3. 雙擊 **`一鍵修復RDP.bat`**
4. 跳出 UAC 時按「是」
5. 在選單按 **`1`**

就這樣。不需要事先安裝任何東西。

### 方法二：複製原始碼

```powershell
git clone https://github.com/tokyoxpa3/rdpwrap-autofix.git
cd rdpwrap-autofix
.\一鍵修復RDP.bat
```

---

## 選單說明

```
============================================================
  RDP Wrapper 一鍵修復工具  v1.0.0
============================================================
------------------------------------------------------------
 Windows 組建     : 26200.9457
 termsrv.dll      : 10.0.26100.9444
 Wrapper 狀態     : 已安裝 (C:\Program Files\RDP Wrapper)
 目前 ini 版本    : 2026-09-09a
 ini 支援此組建   : 是
 Terminal Services: Running
------------------------------------------------------------

 1. 檢查並自動修復（建議）
 2. 強制重新下載並套用最新 ini
 3. 完整重新安裝（移除 -> 安裝 -> 套用 ini）
 4. 只重新啟動 Terminal Services
 5. 建立自動修復排程（登入後 / 每日）
 6. 移除自動修復排程
 0. 離開
```

平常按 **`1`** 就好，它會自己判斷該做多少事：

| 目前狀況 | 工具的反應 |
| --- | --- |
| ini 已支援目前的 `termsrv.dll` | 什麼都不做，直接結束（不會白重啟服務） |
| ini 過舊，但 Wrapper 還在 | 只換 ini + 重啟服務（最快路徑） |
| Wrapper 不完整或損毀 | 自動改用完整安裝流程 |

---

## 命令列用法

適合寫進腳本或排程：

```powershell
# 只檢查狀態，不做任何變更
.\RDPWrap-AutoFix.ps1 -Mode Check

# 靜默自動修復：只有在真的失效時才動作
.\RDPWrap-AutoFix.ps1 -Mode Auto

# 更新 ini（內容相同且可用就不重啟服務）
.\RDPWrap-AutoFix.ps1 -Mode Update

# 無條件重新下載並套用
.\RDPWrap-AutoFix.ps1 -Mode Force -Yes

# 完整重新安裝
.\RDPWrap-AutoFix.ps1 -Mode Reinstall

# 建立 / 移除自動修復排程
.\RDPWrap-AutoFix.ps1 -Mode RegisterTask
.\RDPWrap-AutoFix.ps1 -Mode UnregisterTask

# 指定自訂 ini 來源
.\RDPWrap-AutoFix.ps1 -Mode Force -Source "https://example.com/rdpwrap.ini"
```

| 參數 | 說明 |
| --- | --- |
| `-Mode` | `Menu`（預設）、`Auto`、`Check`、`Update`、`Force`、`Reinstall`、`RegisterTask`、`UnregisterTask` |
| `-Source` | 自訂 ini 網址，省略則使用內建的多個鏡像來源 |
| `-Yes` | 不詢問任何確認，直接執行 |

---

## 全自動：讓它自己顧

選單按 `5`，會建立一個名為 `RDPWrap AutoFix` 的排程工作：

- **登入後 30 秒**執行一次
- 之後**每天 12:00**再檢查一次
- 以 `SYSTEM` 身分執行，不需要 UAC 提示

判斷條件很保守——只有「目前 ini 不包含現在的 `termsrv.dll` 版本」才會動作。
所以平常完全不會干擾你，但 Windows 更新完重開機後會自己修好。

移除排程：選單按 `6`，或執行 `-Mode UnregisterTask`。

---

## 運作原理

1. 檢查管理員權限，沒有就自動跳出 UAC 提權
2. 讀出 `C:\Windows\System32\termsrv.dll` 的版本（例如 `10.0.26100.9444`）
3. 從 GitHub 下載最新 `rdpwrap.ini`，**失敗時自動依序改用鏡像站**：
   `raw.githubusercontent.com` → `cdn.jsdelivr.net` → `raw.gitmirror.com` → `ghproxy.net` → `gh-proxy.com`
4. 驗證下載內容（必須含 `[Main]`、`[PatchCodes]`、`Updated=`，且大小合理），
   避免把錯誤頁面寫進 `rdpwrap.ini` 反而弄壞 RDP
5. 備份舊 ini 到 `backup\`（保留最近 10 份）
6. 確認新 ini 是否包含目前 `termsrv.dll` 版本的區段
7. 需要時才執行完整安裝
8. 覆蓋 `C:\Program Files\RDP Wrapper\rdpwrap.ini`
9. 重啟 `Terminal Services`（含相依服務如 `UmRdpService`）
10. 驗證：服務是否執行中、`rdpwrap.dll` 是否被載入、ini 是否支援目前版本

### 為什麼通常不需要 uninstall / install

RDP Wrapper 的運作方式是：把 `TermService` 的 `ServiceDll` 指向 `rdpwrap.dll`，
而那個 DLL **只在服務啟動時讀取一次 ini**。

所以單純的版本失效，只要換 ini + 重啟服務就會好，不需要動到 DLL。
本工具只有在偵測到 `ServiceDll` 沒指向 `rdpwrap.dll`、或 `rdpwrap.dll` 檔案不見時，
才會走完整重裝流程。

完整重裝需要 `RDPWInst.exe`。為了不轉散布第三方執行檔，
本工具會**在需要時才從 [stascorp/rdpwrap](https://github.com/stascorp/rdpwrap/releases) 官方來源下載**。

---

## 常見問題

### 會不會中斷我現在的遠端桌面連線？

會。重啟 `Terminal Services` 本來就會中斷連線，這是無法避免的
（傳統的 `reinstall.bat` 也一樣）。工具偵測到你是用 RDP 連進來時，
會先警告並要求確認。若 RDP 已經失效，你本來就是從本機操作，不受影響。

### 顯示「最新 ini 尚未包含 [版本] 區段」

代表上游還沒更新支援你的 Windows 組建。這時候套用也沒用，只能等上游更新，
或改用 `-Source` 指定其他 ini 來源。工具會問你要不要繼續，選 `N` 即可。

### 防毒軟體報毒 / 把檔案刪掉

RDP Wrapper 整個生態（包含官方的 `RDPWInst.exe`）長期被各家防毒誤判，
這是這個工具本身的特性，不是本專案的問題。

若工具提示「重新安裝後仍偵測不到 `rdpwrap.dll`」，請把
`C:\Program Files\RDP Wrapper\` 加入防毒排除清單後再執行一次。

### 套用後還是不能用

1. 看 `RDPWrap-AutoFix.log`（在工具資料夾內）
2. 開 `RDPConf.exe` 看 `Listener state`
3. 極少數情況需要重新開機

### 可以還原舊的 ini 嗎？

可以，`backup\` 裡面有時間戳記備份，手動複製回
`C:\Program Files\RDP Wrapper\rdpwrap.ini` 再重啟服務即可。

### 需要什麼環境？

- Windows 10 / 11（x86 或 x64）
- Windows PowerShell 5.1（系統內建，不需要額外安裝）
- 系統管理員權限（工具會自動請求）
- 網路連線（用來下載 ini）

---

## 檔案說明

| 檔案 | 用途 |
| --- | --- |
| `一鍵修復RDP.bat` | 雙擊入口，自動跳 UAC 提權 |
| `RDPWrap-AutoFix.ps1` | 主程式 |
| `RDPWrap-AutoFix.log` | 執行記錄，出問題時看這個 |
| `backup/` | 每次覆蓋前的舊 ini 備份，保留最近 10 份 |
| `rdpwrap.ini` | 本機保存的 ini，會自動同步成最新版 |

---

## 致謝

本工具只是自動化流程的膠水，真正讓 RDP 能用的是這些專案：

- [stascorp/rdpwrap](https://github.com/stascorp/rdpwrap) — RDP Wrapper Library
- [sebaxakerhtc/rdpwrap.ini](https://github.com/sebaxakerhtc/rdpwrap.ini) — 持續維護的 ini

---

## 授權

[MIT](LICENSE)

本專案不包含、也不再散布任何第三方的執行檔或二進位檔案。
