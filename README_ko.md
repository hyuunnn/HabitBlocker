# 습관 차단기

> 집중해야 할 때 특정 웹사이트 방문에 마찰을 더해 습관적 접속을 줄이는 macOS 메뉴 막대 유틸리티입니다.

**습관 차단기**는 `youtube.com` 또는 유튜브 영상 URL처럼 도메인이나 URL을 등록하고, macOS 메뉴 막대에서 차단 상태를 관리하는 도구입니다. 빠른 선택 및 직접 입력 집중 세션, 집중 세션 전용 해제 대기, 로컬 활동 요약, 선택적 집중 알림을 제공합니다.

[English README](README.md)

## Manus 1.6으로 제작

이 프로젝트는 **Manus 1.6**을 활용한 바이브 코딩 방식으로 제작되었습니다. 자연어 제품 요구사항을 바탕으로 제품 흐름, SwiftUI 메뉴 막대 인터페이스, 도메인 차단 로직, 리팩토링, 자동 테스트, 문서를 반복적으로 만들고 검증했습니다.

## 요구 사항

| 항목 | 내용 |
|---|---|
| 운영체제 | macOS 13 이상 |
| 빌드 도구 | Swift가 포함된 Xcode 또는 Xcode Command Line Tools |
| 권한 | 시스템 전체 차단 규칙을 적용하거나 제거할 때만 관리자 암호가 필요합니다. |

## 저장소 복제, 빌드, 테스트, 실행

저장소를 복제한 뒤 스크립트 실행 권한을 부여하고, 핵심 테스트와 앱 빌드를 실행한 다음 앱을 엽니다.

```zsh
git clone https://github.com/hyuunnn/url-chadan.git
cd url-chadan

chmod +x Scripts/build.sh Scripts/test.sh
./Scripts/test.sh
./Scripts/build.sh
open Build/HabitBlocker.app
```

앱을 실행하면 macOS 화면 상단 메뉴 막대에 방패 아이콘이 나타납니다. 아이콘을 누르면 제어 화면이 열립니다.

> 차단 규칙을 처음 변경할 때 macOS가 관리자 암호를 요청합니다. 습관 차단기는 `/etc/hosts` 중 자신이 관리하는 전용 구역만 변경합니다.

## 사용 방법

| 순서 | 할 일 |
|---|---|
| 1 | 메뉴 막대의 방패 아이콘을 누릅니다. |
| 2 | **차단 목록**에 `youtube.com` 같은 도메인을 넣거나 전체 URL을 붙여 넣습니다. |
| 3 | **등록 사이트 차단**을 켜면 즉시 규칙을 적용하고, 끄면 즉시 규칙을 제거합니다. |
| 4 | 빠른 시간 선택 또는 1~1,440분 직접 입력으로 집중 세션을 시작합니다. |
| 5 | 집중 세션을 끝낼 때는 설정한 해제 대기 시간이 지난 뒤 최종 해제를 확인합니다. |

일반 차단 토글은 즉시 반영되며, 해제 대기는 **집중 세션 종료에만** 적용됩니다.

## 주요 기능

| 기능 | 동작 |
|---|---|
| 메뉴 막대 제어 | 하나의 SwiftUI 팝오버에서 상태, 목록, 집중 세션, 해제 대기, 요약을 관리합니다. |
| 도메인·URL 입력 | 도메인과 전체 URL을 입력받아 호스트를 안전하게 추출합니다. |
| 시스템 전체 hosts 차단 | 선택한 도메인을 `127.0.0.1`, `::1`로 연결하는 전용 `/etc/hosts` 규칙을 만듭니다. |
| YouTube 확장 | `youtube.com`을 등록하면 `www`, `m`, `music`, `studio`, `youtu.be`도 함께 차단합니다. |
| 집중 세션 | 25·45·60분 빠른 선택과 1~1,440분 직접 입력을 지원합니다. |
| 해제 대기 | 집중 세션 종료에만 30초·1분·5분의 해제 대기를 적용합니다. |
| 로컬 요약 | 오늘의 집중 시작 횟수, 설정 시간, 해제 시도를 보여 줍니다. 활동 데이터는 이 Mac에만 저장하고 90일 뒤 자동 정리합니다. |
| 집중 메시지 | 앱 안에 안내 문구를 보여 주고, 권한이 허용되면 macOS 알림도 보냅니다. |
| 로그인 시 실행 | macOS 로그인 항목 서비스를 통해 로그인 후 메뉴 막대에서 자동 실행할 수 있습니다. |

## 개발 명령어

| 명령어 | 용도 |
|---|---|
| `./Scripts/test.sh` | `/etc/hosts`를 변경하지 않고 핵심 로직 자동 테스트를 컴파일·실행합니다. |
| `./Scripts/build.sh` | `Build/HabitBlocker.app`을 만들고 ad-hoc 서명합니다. |
| `open Build/HabitBlocker.app` | 로컬에서 빌드한 메뉴 막대 앱을 엽니다. |

## 자동 테스트

관리자 권한 없이 안전하게 확인할 수 있는 핵심 로직을 테스트합니다.

| 영역 | 검증 내용 |
|---|---|
| 도메인 정규화 | URL 호스트 추출, 대소문자 정규화, 잘못된 입력 거부 |
| 호스트 확장 | 일반 `www` 별칭과 YouTube 전용 별칭 |
| 관리 구역 제거 | 차단 규칙 삭제 때 관련 없는 기존 hosts 항목이 유지되는지 확인 |
| hosts 내용 생성 | 이전 규칙 교체, IPv4·IPv6 규칙 생성, 차단 해제 후 깨끗한 제거 |

## 프로젝트 구조

| 경로 | 역할 |
|---|---|
| `Sources/HabitBlocker/HabitBlockerApp.swift` | 앱 진입점과 메뉴 막대 씬 |
| `Sources/HabitBlocker/MenuContentView.swift` | SwiftUI 메뉴 팝오버와 화면 구성 요소 |
| `Sources/HabitBlocker/BlockerStore.swift` | 차단 상태, 집중 세션, 요약, 알림, 로컬 저장소 관리 |
| `Sources/HabitBlocker/Models.swift` | 도메인 정규화와 차단·활동 데이터 모델 |
| `Sources/HabitBlocker/HostFileService.swift` | 관리 대상 hosts 규칙 생성·제거와 관리자 권한 처리 |
| `Tests/HabitBlockerCoreTests.swift` | 결정론적 핵심 로직 테스트 |
| `Scripts/build.sh` | 앱 빌드와 ad-hoc 서명 스크립트 |
| `Scripts/test.sh` | 핵심 테스트 빌드·실행 스크립트 |

## 차단 방식과 한계

습관 차단기는 보안 제품이 아니라 가벼운 행동 변화 도구입니다. VPN, 프록시, 브라우저 확장, 네트워크 필터가 아니라 로컬 hosts 매핑을 사용합니다. 이 방식은 단순하고 개인 정보에 친화적이지만 다음 한계가 있습니다.

| 한계 | 의미 |
|---|---|
| 기존 브라우저 연결 | 이미 열린 탭은 브라우저가 연결과 DNS 캐시를 유지해 잠시 계속 보일 수 있습니다. 브라우저를 완전히 종료한 뒤 다시 열면 새 연결을 강제할 수 있습니다. |
| VPN·프록시·보안 DNS | 일부 설정이나 앱은 hosts 기반 해석을 우회할 수 있습니다. |
| 브라우저 오류 화면 | 연결 자체를 막는 방식이라 브라우저 안에 사용자 지정 차단 화면을 삽입하지 않습니다. |
| 앱 미실행 상태 | 앱이 완전히 종료된 동안에는 집중 타이머가 실행되지 않습니다. 다음 앱 실행 시 상태를 다시 확인합니다. 자동 종료 시점을 정확히 처리하려면 메뉴 막대 앱을 계속 실행하세요. |

Apple은 `MenuBarExtra`를 지속적인 메뉴 막대 제어 요소로 안내하며, 메뉴 막대 전용 유틸리티는 `LSUIElement`를 사용해 Dock과 앱 전환기에서 숨길 수 있다고 설명합니다.[1] [2]

## 참고 자료

[1]: https://developer.apple.com/documentation/swiftui/menubarextra "Apple Developer — MenuBarExtra"
[2]: https://developer.apple.com/documentation/swiftui/menubarextrastyle "Apple Developer — MenuBarExtraStyle"
