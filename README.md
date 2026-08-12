# 습관 차단기

**습관 차단기**는 macOS 메뉴 막대에서 차단할 사이트를 관리하고, 필요할 때 즉시 차단하거나 집중 세션을 시작할 수 있는 개인용 도구입니다. 예를 들어 `youtube.com` 또는 특정 유튜브 영상 링크를 추가하면, 앱이 도메인을 추출해 유튜브 접속을 차단합니다.

> 이 앱은 차단 규칙을 `/etc/hosts` 파일의 전용 구역에만 기록합니다. 규칙을 적용하거나 해제할 때 macOS 관리자 암호가 필요하며, 앱은 그 외의 기존 hosts 항목을 보존하도록 설계되었습니다.

| 항목 | 동작 |
|---|---|
| 메뉴 막대 제어 | 방패 아이콘을 눌러 차단 상태, 목록, 집중 세션을 한 곳에서 관리합니다. |
| URL 입력 | `youtube.com`, `www.youtube.com`, `https://www.youtube.com/watch?v=…`처럼 도메인 또는 URL을 입력할 수 있습니다. |
| 시스템 전체 차단 | 활성화하면 등록한 도메인을 `127.0.0.1` 및 `::1`에 연결해 브라우저와 대부분의 앱에서 접근을 막습니다. |
| 유튜브 보완 규칙 | `youtube.com`을 등록하면 `www`, `m`, `music`, `studio` 하위 도메인과 `youtu.be`도 함께 처리합니다. |
| 집중 세션 | 25분, 45분 또는 60분 동안 차단을 유지합니다. 앱이 실행 중이면 시간이 끝난 뒤 자동으로 해제합니다. |
| 자동 실행 | 로그인 시 메뉴 막대 유틸리티를 자동 실행하도록 설정할 수 있습니다. |

## 실행 방법

프로젝트 폴더의 다음 앱을 Finder에서 이중 클릭하거나 터미널에서 열면 됩니다.

```zsh
open "/Users/hyun/Documents/url-chadan/Build/HabitBlocker.app"
```

처음 실행하면 화면 상단 메뉴 막대에 방패 아이콘이 나타납니다. 아이콘을 눌러 `youtube.com`을 입력하고 **등록 사이트 차단**을 켜세요. macOS가 관리자 인증을 요청하면 본인의 암호로 승인해야 실제 시스템 차단 규칙이 적용됩니다.

| 상황 | 할 일 |
|---|---|
| 사이트를 새로 추가·삭제함 | 차단 중일 때는 **목록 변경사항 적용**을 눌러 hosts 규칙을 다시 반영합니다. |
| 차단을 잠시 멈추고 싶음 | **등록 사이트 차단** 스위치를 끕니다. |
| 집중 시간을 즉시 끝내고 싶음 | 메뉴에서 **종료**를 선택합니다. |
| 앱을 다시 빌드하고 싶음 | 프로젝트 폴더에서 `./Scripts/build.sh`를 실행합니다. |

## 차단 방식과 한계

이 도구는 네트워크 필터나 VPN을 설치하지 않고, macOS의 로컬 호스트 이름 매핑을 이용합니다. 따라서 일반적인 웹 브라우징 습관을 끊기 위한 **가벼운 마찰 장치**에 적합합니다. 다만 특정 앱의 자체 DNS, VPN, 프록시, 보안 DNS 설정 또는 이미 열려 있는 연결은 이 규칙을 우회하거나 즉시 반영되지 않을 수 있습니다. 강제성이 높은 자녀 보호·기업 보안·네트워크 정책 용도에는 적합하지 않습니다.

도메인 차단은 개별 영상 주소가 아니라 사이트 단위입니다. 즉 `https://www.youtube.com/watch?v=...`를 등록하면 해당 영상 하나가 아니라 YouTube 접속 전반을 막습니다. 이는 “특정 영상만 막기”보다 반복적으로 사이트를 여는 습관을 줄이는 목적에 맞춘 설계입니다.

## 파일 구조

| 경로 | 설명 |
|---|---|
| `Sources/HabitBlocker/HabitBlockerApp.swift` | SwiftUI 메뉴 막대 UI, 도메인 정규화, hosts 규칙 관리 코드입니다. |
| `Resources/Info.plist` | 메뉴 막대 전용 실행(`LSUIElement`)과 앱 메타데이터입니다. |
| `Scripts/build.sh` | 앱 번들 생성과 ad-hoc 서명을 수행하는 빌드 스크립트입니다. |
| `Build/HabitBlocker.app` | 바로 실행할 수 있는 생성 결과입니다. |

## 참고 자료

Apple은 `MenuBarExtra`를 메뉴 막대에 지속적으로 표시되는 제어 요소를 만드는 SwiftUI 씬으로 제공하며, 메뉴 막대 전용 유틸리티에는 Dock과 앱 전환기에서 아이콘을 감추기 위해 `LSUIElement`를 사용할 수 있다고 안내합니다.[1] 또한 `MenuBarExtra`의 `window` 스타일은 표준 컨트롤을 담는 팝오버형 창을 표시하는 데 적합합니다.[2]

[1]: https://developer.apple.com/documentation/swiftui/menubarextra "Apple Developer — MenuBarExtra"
[2]: https://developer.apple.com/documentation/swiftui/menubarextrastyle "Apple Developer — MenuBarExtraStyle"
