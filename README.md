# HabitBlocker

> A macOS menu bar utility that adds friction to habitual website visits by blocking selected domains during focused work.

**HabitBlocker** lets you add domains or URLs such as `youtube.com` or a YouTube video URL, then control blocking from the macOS menu bar. It supports quick and custom focus sessions, a deliberate unlock wait for focus sessions, local activity summaries, and optional focus notifications.

[한국어 안내 보기](README_ko.md)

## Built with Manus 1.6

This project was built with **Manus 1.6** through a vibe-coding workflow: the product flow, SwiftUI menu bar interface, domain-blocking logic, refactoring, automated tests, and documentation were iteratively created and validated from a natural-language product brief.

## Requirements

| Requirement | Details |
|---|---|
| Operating system | macOS 13 or later |
| Build tools | Xcode or Xcode Command Line Tools with Swift |
| Permissions | An administrator password is required only when applying or removing system-wide blocking rules. |

## Clone, Build, Test, and Run

Clone this repository, make the scripts executable, run the core tests, build the app bundle, and open it.

```zsh
git clone https://github.com/hyuunnn/url-chadan.git
cd url-chadan

chmod +x Scripts/build.sh Scripts/test.sh
./Scripts/test.sh
./Scripts/build.sh
open Build/HabitBlocker.app
```

The app appears as a shield icon in the macOS menu bar. Click the icon to open the popover.

> On the first change to a blocking rule, macOS asks for an administrator password because HabitBlocker updates only its own managed section of `/etc/hosts`.

## How to Use

| Step | Action |
|---|---|
| 1 | Open the shield icon in the menu bar. |
| 2 | Add a domain like `youtube.com` or paste a full URL in **Blocked Sites**. |
| 3 | Turn **Block Registered Sites** on to apply the rule immediately. Turn it off to remove the rule immediately. |
| 4 | Start a focus session with a quick preset or a custom duration from 1 to 1,440 minutes. |
| 5 | When ending a focus session, complete the configured unlock wait before confirming the final unblock. |

The standard block toggle is intentionally immediate. The unlock wait applies only when ending a focus session.

## Features

| Feature | Behavior |
|---|---|
| Menu bar control | Manage status, block lists, focus sessions, unlock waits, and summaries from a single SwiftUI popover. |
| Domain and URL input | Accepts domain names and full URLs, extracting the host safely. |
| System-wide hosts blocking | Maps selected domains to `127.0.0.1` and `::1` through a dedicated `/etc/hosts` section. |
| YouTube expansion | Adding `youtube.com` also blocks `www`, `m`, `music`, `studio`, and `youtu.be`. |
| Focus sessions | Supports 25, 45, and 60 minute presets plus custom durations from 1 to 1,440 minutes. |
| Unlock wait | A 30-second, 1-minute, or 5-minute wait applies only to focus-session exits. |
| Local summary | Shows today’s focus starts, planned focus minutes, and unlock attempts. Activity data stays on this Mac and is pruned after 90 days. |
| Focus messages | Displays encouragement inside the app and can send a macOS notification when permission is granted. |
| Launch at login | Uses the macOS login-item service to launch from the menu bar after sign-in. |

## Development Commands

| Command | Purpose |
|---|---|
| `./Scripts/test.sh` | Compiles and runs deterministic core tests without modifying `/etc/hosts`. |
| `./Scripts/build.sh` | Creates and ad-hoc signs `Build/HabitBlocker.app`. |
| `open Build/HabitBlocker.app` | Opens the locally built menu bar app. |

## Automated Tests

The core test suite covers the logic that can be safely verified without administrator access:

| Area | Covered behavior |
|---|---|
| Domain normalization | URL host extraction, case normalization, and invalid-input rejection. |
| Hostname expansion | Standard `www` aliases and YouTube-specific aliases. |
| Managed-section removal | Preservation of unrelated hosts entries when HabitBlocker rules are removed. |
| Desired hosts content | Replacement of old rules, creation of IPv4 and IPv6 entries, and clean unblocking. |

## Project Structure

| Path | Responsibility |
|---|---|
| `Sources/HabitBlocker/HabitBlockerApp.swift` | App entry point and menu bar scene. |
| `Sources/HabitBlocker/MenuContentView.swift` | SwiftUI menu popover and visual components. |
| `Sources/HabitBlocker/BlockerStore.swift` | Blocking state, focus sessions, summaries, notifications, and local persistence. |
| `Sources/HabitBlocker/Models.swift` | Domain normalization plus blocking and activity data models. |
| `Sources/HabitBlocker/HostFileService.swift` | Managed hosts-rule generation, removal, and privileged update handling. |
| `Tests/HabitBlockerCoreTests.swift` | Deterministic core-logic tests. |
| `Scripts/build.sh` | Build and ad-hoc signing script. |
| `Scripts/test.sh` | Core-test build and execution script. |

## Blocking Method and Limitations

HabitBlocker is a lightweight behavior-change tool, not a security product. It uses a managed local hosts mapping instead of a VPN, proxy, browser extension, or network filter. This is intentionally simple and private, but it has limitations.

| Limitation | Implication |
|---|---|
| Existing browser connections | A tab that was already open may continue temporarily because browsers can retain connections and DNS caches. Fully quit and reopen the browser to force a fresh connection. |
| VPNs, proxies, or secure DNS | Some configurations or apps can bypass hosts-based resolution. |
| Browser error page | HabitBlocker blocks the connection; it does not inject a custom in-browser block page. |
| App not running | A focus timer is checked and reconciled the next time the app launches. Keep the menu bar app running for timely automatic completion. |

Apple documents `MenuBarExtra` as a persistent menu bar control and notes that menu-bar-only utilities can use `LSUIElement` to remain out of the Dock and app switcher.[1] [2]

## References

[1]: https://developer.apple.com/documentation/swiftui/menubarextra "Apple Developer — MenuBarExtra"
[2]: https://developer.apple.com/documentation/swiftui/menubarextrastyle "Apple Developer — MenuBarExtraStyle"
