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
git clone https://github.com/hyuunnn/HabitBlocker.git
cd HabitBlocker

chmod +x Scripts/build.sh Scripts/test.sh
./Scripts/test.sh
./Scripts/build.sh
open Build/HabitBlocker.app
```

The app appears as a shield icon in the macOS menu bar. Click the icon to open the popover.

> On the first blocking change, macOS asks for an administrator password. HabitBlocker only changes the network proxy auto-configuration and never modifies system files such as `/etc/hosts`.

## How to Use

| Step | Action |
|---|---|
| 1 | Open the shield icon in the menu bar. |
| 2 | Add a domain like `youtube.com` or paste a full URL in **Blocked Sites**. |
| 3 | Turn **Block Registered Sites** on to apply the rule immediately. Turn it off to remove the rule immediately. |
| 4 | Start a focus session with a quick preset or a custom duration from 1 to 1,440 minutes. |
| 5 | When ending a focus session, complete the configured unlock wait before confirming the final unblock. |

The standard block toggle is intentionally immediate. The unlock wait applies only when ending a focus session.

## Usage Flow

![HabitBlocker usage flow](Assets/habitblocker-usage-flow.png)

*Illustrative usage-flow mockup: add a domain, enable blocking or begin a focus session, then complete the deliberate unlock step when ending that session.*

## Features

| Feature | Behavior |
|---|---|
| Menu bar control | Manage status, block lists, focus sessions, unlock waits, and summaries from a single SwiftUI popover. |
| Domain and URL input | Accepts domain names and full URLs, extracting the host safely. |
| System-wide PAC blocking | Applies a proxy auto-config (PAC) rule that routes blocked domains to a local listener on 127.0.0.1. Never modifies system files such as `/etc/hosts`. |
| YouTube expansion | Adding `youtube.com` also blocks `www`, `m`, `music`, `studio`, and `youtu.be`. |
| Focus sessions | Supports 25, 45, and 60 minute presets plus custom durations from 1 to 1,440 minutes. |
| Unlock wait | A 30-second, 1-minute, or 5-minute wait applies only to focus-session exits. |
| Local summary | Shows today’s focus starts, planned focus minutes, and unlock attempts. Activity data stays on this Mac and is pruned after 90 days. |
| Focus messages | Displays encouragement inside the app and can send a macOS notification when permission is granted. |
| Launch at login | Uses the macOS login-item service to launch from the menu bar after sign-in. |

## Development Commands

| Command | Purpose |
|---|---|
| `./Scripts/test.sh` | Compiles and runs deterministic core tests. |
| `./Scripts/build.sh` | Creates and ad-hoc signs `Build/HabitBlocker.app`. |
| `open Build/HabitBlocker.app` | Opens the locally built menu bar app. |

## Automated Tests

The core test suite covers the logic that can be safely verified without administrator access:

| Area | Covered behavior |
|---|---|
| Domain normalization | URL host extraction, case normalization, and invalid-input rejection. |
| Hostname expansion | Standard `www` aliases and YouTube-specific aliases. |
| PAC generation and matching | Evaluates the PAC with JavaScriptCore to verify subdomain blocking, suffix false-positive prevention, and case/FQDN handling. |
| Network service parsing | Strips headers, errors, and disabled markers from `networksetup` output. |
| Admin script generation | Service-name quoting and escaping, previous proxy-setting restoration, and hosts-cleanup inclusion. |
| Hosts cleanup (migration) | Removes the legacy managed section while preserving unrelated hosts entries. |

## Project Structure

| Path | Responsibility |
|---|---|
| `Sources/HabitBlocker/HabitBlockerApp.swift` | App entry point and menu bar scene. |
| `Sources/HabitBlocker/MenuContentView.swift` | SwiftUI menu popover and visual components. |
| `Sources/HabitBlocker/BlockerStore.swift` | Blocking state, focus sessions, summaries, notifications, and local persistence. |
| `Sources/HabitBlocker/Models.swift` | Domain normalization plus blocking and activity data models. |
| `Sources/HabitBlocker/ProxyBlockService.swift` | PAC generation and serving, local reject listener, system proxy apply and restore. |
| `Sources/HabitBlocker/AdminShell.swift` | Wrapper for running privileged shell commands. |
| `Sources/HabitBlocker/HostFileService.swift` | Legacy hosts-rule cleanup (migration only). |
| `Tests/HabitBlockerCoreTests.swift` | Deterministic core-logic tests. |
| `Scripts/build.sh` | Build and ad-hoc signing script. |
| `Scripts/test.sh` | Core-test build and execution script. |
| `Assets/habitblocker-usage-flow.png` | Usage-flow visual shown in both README files. |

## Blocking Method and Limitations

HabitBlocker is a lightweight behavior-change tool, not a security product. Blocking uses the **system proxy auto-configuration (PAC)** mechanism and never modifies a single system file.

### How it works

| Step | Description |
|---|---|
| 1 | The app builds a PAC script from the block list, and a loopback-only (127.0.0.1) listener serves that script. |
| 2 | Each network service's proxy auto-configuration points at this PAC URL. Applying or removing a rule asks for the administrator password once; the previous proxy settings are backed up and restored on unblock. |
| 3 | The PAC routes only blocked domains to the local listener, which answers with a 403 block page. Everything else connects directly (DIRECT). |
| 4 | DNS and `/etc/hosts` are never touched, so name resolution and local services stay intact. The worst case of a misconfiguration is "blocking does not happen". |

Browsers' secure DNS (DoH) is not a bypass: the PAC decides by hostname before any DNS query happens, so it is more robust against secure DNS than a hosts-file approach.

### Limitations

| Limitation | Implication |
|---|---|
| App not running | The local listener that serves the PAC lives inside the app, so blocking is temporarily lifted while the app is fully quit. The settings remain in place and blocking resumes immediately on relaunch; focus timers are reconciled then too. Keep the menu bar app running for long blocking periods (launch-at-login is supported). |
| Clients that ignore the system proxy | Most browsers follow the system proxy, but some CLI tools (curl, etc.) and apps that force their own proxy settings can bypass it. |
| VPNs | VPN clients that ignore the system proxy can bypass it. |
| Existing browser connections | A tab that was already open may continue temporarily because browsers retain connections. Fully quit and reopen the browser to apply blocking to fresh connections. |
| Port conflict | If another program occupies port 47471, blocked sites may show the browser's default error page instead. |

### Upgrading from an older version

Version 1.0 wrote blocking rules into `/etc/hosts`. The current version never modifies the hosts file; it detects leftover rules automatically and, on the next apply or unblock, removes them and restores the original hosts content within the same administrator approval.

Apple documents `MenuBarExtra` as a persistent menu bar control and notes that menu-bar-only utilities can use `LSUIElement` to remain out of the Dock and app switcher.[1] [2]

## References

[1]: https://developer.apple.com/documentation/swiftui/menubarextra "Apple Developer — MenuBarExtra"
[2]: https://developer.apple.com/documentation/swiftui/menubarextrastyle "Apple Developer — MenuBarExtraStyle"
