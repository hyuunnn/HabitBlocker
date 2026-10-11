# HabitBlocker

A macOS menu bar app that blocks selected websites while you focus.

[한국어](README_ko.md)

## Requirements

- macOS 14 or later.
- Xcode or Xcode Command Line Tools with Swift to build from source.
- Administrator authorization when applying or removing blocking rules.

## Build and run

```zsh
git clone https://github.com/hyuunnn/habitblocker.git
cd habitblocker
./Scripts/build.sh
open Build/HabitBlocker.app
```

The app appears as a shield icon in the menu bar.

## Usage

1. Open the menu bar icon and add a domain such as `youtube.com` or a URL to **차단 목록** (Blocked Sites). A URL is stored as a domain; blocking covers that domain and its subdomains, including all pages on them.
2. Choose how to block:

   - **등록 사이트 차단** (Block Registered Sites): turn blocking on or off without an unlock wait.
   - **AI로 내용 판단** (Judge With AI): off blocks every page on a listed domain. On leaves the site open and asks a local model whether the current tab is focus, neutral, or drift, using only its URL and title. A drift judgment closes that tab. Download, select, and delete models in **모델 설정** (Model Settings). The default is the laptop-sized 4-bit Clef-flash 9B (about 5.2 GB).
   - **집중 시작** (Start Focus): start a 25-, 45-, or 60-minute session, or enter 1–1,440 minutes. Blocking must be off before starting. When the timer ends, the app attempts to remove the blocking rules.

3. To end a focus session early, choose **종료** (End), wait for the selected delay, then confirm with **차단 해제** (Unblock). The delay options are 30 seconds, 1 minute, and 5 minutes.

Administrator authorization may also be requested when the focus timer ends. If authorization is canceled or unblocking fails, blocking can remain. An unlock wait still requires confirmation even if the focus timer ends while you are waiting.

The block list and unlock delay can be changed only while blocking is off. During a focus session or an unlock wait, the block toggle is disabled. The app's Quit command is unavailable while blocking or a session is active, or while rules are being applied.

**오늘의 요약** (Today's Summary) shows focus starts, elapsed minutes recorded when a session finishes or blocking is removed, and unlock attempts. Activity records stay on this Mac, and older days' records are automatically removed.

Enable **로그인 시 자동 실행** (Launch at Login) to start the app after sign-in. Focus notifications require macOS notification permission.

![Example: add sites, start a session, and wait before ending it early](Assets/habitblocker-usage-flow-v2.png)

## Blocking and limitations

HabitBlocker uses macOS proxy auto-configuration (PAC). It replaces the enabled network services' automatic proxy configuration with a script served by the app at `127.0.0.1:47471`. Listed domains go to a local listener that rejects requests; other domains connect directly. `/etc/hosts` is never modified.

The app saves the previous automatic proxy settings before changing them and attempts to restore them if PAC application cannot be verified. Unblocking restores those settings and succeeds only after restoration is verified.

- Blocking applies to clients that follow the system proxy settings. Apps, command-line tools, or VPN configurations that ignore them can bypass it.
- Existing browser connections may keep working temporarily. Quit and reopen the browser to test new connections.
- AI judgment reads only the front browser tab's URL and title, on this Mac. It does not capture the screen or send page text anywhere. Browsers that do not expose the URL are judged from the window title. Closing a tab needs Automation or Accessibility permission. An uncertain judgment leaves the tab open.
- Blocked HTTPS sites show the browser's connection error; the app's block page is available for HTTP. That applies to URL blocking.
- Keep the app running. After a crash or forced quit, blocking is not guaranteed and proxy settings may remain. Relaunch the app to restore the local listener and manage blocking. A conflict on port `47471` can also prevent the listener from working.

If unblocking fails, check the app's error message and the active network service's automatic proxy configuration in macOS System Settings. The app retains its proxy backup until restoration is verified.

## Development

```zsh
./Scripts/test.sh
```

`Tests/HabitBlockerCoreTests.swift` runs without administrator authorization. It covers domain normalization (including internationalized domains), PAC matching and request parsing, network-service parsing, focus-time accounting, proxy backup and restoration, administrator script generation, AI judgment parsing, and the local model catalog.

App code is in `Sources/HabitBlocker/`:

| Files | Role |
|---|---|
| `HabitBlockerApp.swift`, `MenuContentView.swift`, `AISettingsView.swift` | App entry point, menu bar UI, and model settings. |
| `BlockerStore.swift`, `FocusGuard.swift`, `BrowserActivity.swift` | Blocking state, focus sessions, and tab judgment. |
| `Models.swift`, `FocusJudgment.swift`, `ModelCatalog.swift`, `LocalModelController.swift` | Domain normalization, judgment rules, and local model download and runtime. |
| `ProxyBlockService.swift`, `AdminShell.swift` | PAC listener, proxy backup and restoration, and privileged commands. |

`./Scripts/build.sh` creates and ad-hoc signs `Build/HabitBlocker.app`.
