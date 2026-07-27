# 업데이트 상태 복원 및 릴리스 안전성 설계

## 목적

Quill의 Sparkle 업데이트 흐름에서 확인된 다음 세 문제를 최소 변경으로 해결한다.

1. 자동 확인에서 업데이트를 발견해도 앱 재시작 후 설정창과 메뉴바의 업데이트 카드가 사라질 수 있다.
2. 표시 버전과 빌드 번호가 서로 다른 방향으로 움직이거나 공식 릴리스가 동시에 실행되면, 최신 표시 버전보다 낮은 릴리스가 업데이트 대상으로 선택될 수 있다.
3. `Info.plist`가 Sparkle 2.9.2에서 읽지 않는 `SUUpdateCheckInterval` 키를 사용한다.

현재 `UpdateManager`와 Sparkle의 공통 확인 경로를 유지하고, 별도 업데이터나 설정창 진입 시 강제 네트워크 확인은 추가하지 않는다.

## 배경과 확인된 원인

### 업데이트 카드 상태

Sparkle은 마지막 확인 시각인 `SULastCheckTime`을 저장하지만, Quill의 `updateAvailable`, 표시 버전, 릴리스 날짜, 릴리스 노트 URL은 프로세스 메모리에만 존재한다. 자동 확인에서 업데이트를 찾은 뒤 앱을 재시작하면 카드 상태는 초기화된다. 마지막 확인 후 하루가 지나지 않았다면 Sparkle은 즉시 다시 확인하지 않으므로, 수동 확인이나 다음 예약 확인 전까지 카드가 보이지 않을 수 있다.

### 업데이트 버전 선택

Sparkle은 사용자에게 보이는 `CFBundleShortVersionString`이 아니라 `CFBundleVersion`과 appcast의 `sparkle:version`을 비교한다. 현재 릴리스 workflow는 후보 표시 버전과 빌드 번호가 기존 공개 릴리스보다 모두 증가하는지 검사하지 않는다. 두 공식 workflow를 함께 직렬화하는 `concurrency` 그룹도 없다.

### 확인 주기 설정

Quill은 `SUUpdateCheckInterval=86400`을 설정하지만 Sparkle 2.9.2는 `SUScheduledCheckInterval`을 읽는다. 현재 Sparkle 기본값도 86,400초라 실효 동작은 같지만, Quill이 의도한 설정은 적용되지 않는다.

## 목표

- 자동 또는 수동 확인에서 찾은 업데이트 카드를 앱 재시작 후에도 복원한다.
- 이미 설치했거나 정상 확인에서 더 이상 존재하지 않는 업데이트 정보는 제거한다.
- 확인 실패나 일시적인 오프라인 상태 때문에 기존에 확인한 업데이트 정보를 잃지 않는다.
- 사용자가 Sparkle에서 건너뛴 버전을 자동으로 다시 노출하지 않는다.
- 공식 stable 릴리스의 표시 버전과 빌드 번호가 기존 최대값보다 모두 큰 경우에만 배포를 허용한다.
- 두 공식 stable 릴리스 workflow를 저장소 전체에서 직렬화한다.
- 실제 Sparkle 확인 주기 키를 명시적으로 사용한다.
- production appcast나 기존 GitHub Release를 수정하지 않고 변경을 검증한다.

## 제외 범위

- Sparkle을 다른 업데이트 프레임워크로 교체하지 않는다.
- 누적 appcast로 전환하거나 기존 Release의 appcast 자산을 다시 생성하지 않는다.
- 설정창을 열거나 앱이 활성화될 때마다 강제 확인하지 않는다.
- prerelease용 `manual-release.yml`과 `dev-release.yml`에 stable 표시 버전 단조 증가 규칙을 적용하지 않는다. 다만 이미 공개된 prerelease의 빌드 번호는 다음 stable 빌드 번호의 하한에 포함한다.
- 업데이트 설정 UI의 배치나 시각 디자인을 변경하지 않는다.
- 기존 Git tag, GitHub Release, DMG 자산을 삭제하거나 수정하지 않는다.

## 설계 1: 업데이트 상태 영속화

### 저장 모델

업데이트 카드 복원에 필요한 값만 담는 작은 저장 모델을 둔다.

- `buildVersion`: Sparkle `SPUAppcastItem.versionString`
- `displayVersion`: Sparkle `SPUAppcastItem.displayVersionString`
- `releaseDate`: 선택 값
- `releaseNotesURL`: 선택 값

모델은 하나의 Codable 값으로 직렬화하여 Quill의 `UserDefaults`에 저장한다. 확인 진행 여부인 `isChecking`과 오류 메시지 같은 일시 상태는 저장하지 않는다.

저장과 복원 책임은 `UpdateManager`에 직접 흩어 놓지 않고, 테스트 가능한 작은 내부 저장소 타입으로 분리한다. 저장소는 주입된 `UserDefaults`를 사용하여 테스트에서 별도 suite를 사용할 수 있게 한다.

### 빌드 비교

복원 판단은 표시 버전이 아니라 Sparkle과 동일한 버전 비교 규칙을 사용한다.

- 저장된 `buildVersion`이 현재 앱의 `CFBundleVersion`보다 크면 복원한다.
- 같거나 작으면 이미 설치했거나 오래된 정보이므로 저장 상태를 제거한다.
- 저장 데이터가 손상되었거나 필수 값이 없으면 조용히 제거하고 앱 실행을 계속한다.

앱 자체의 비교와 Sparkle의 비교가 달라지지 않도록 단순 문자열 비교나 별도 semantic version 비교를 도입하지 않는다.

### 상태 흐름

#### 업데이트 발견

Sparkle의 유효 업데이트 delegate가 호출되면 다음 순서로 처리한다.

1. 기존 `@Published` 화면 상태를 갱신한다.
2. 같은 값으로 저장 모델을 기록한다.
3. 자동 확인과 수동 확인 모두 동일한 경로를 사용한다.

#### 앱 시작

`UpdateManager` 초기화 시 저장 모델을 읽는다.

1. 공식 release build tag인 경우에만 저장 상태 복원을 시도한다.
2. 저장된 빌드가 현재 빌드보다 높고 Sparkle의 minor·major skip 범위에 포함되지 않으면 카드 상태를 복원한다.
3. 저장된 빌드가 현재 빌드 이하이거나 `SUSkippedVersion` 이하라면 저장 모델과 카드 상태를 제거한다.
4. major update 정보가 있는 경우 `SUSkippedMajorVersion`, `SUSkippedMajorSubreleaseVersion`, `minimumAutoupdateVersion`, `ignoreSkippedUpgradesBelowVersion`을 Sparkle과 같은 방향으로 비교한다.
5. 저장 데이터 복원과 별개로 기존 Sparkle 자동 확인 스케줄은 그대로 시작한다.

#### 업데이트 없음

Sparkle이 정상적으로 업데이트 없음 결과를 반환하면 화면 상태와 저장 모델을 함께 제거한다.

#### 확인 실패

네트워크 오류, feed 오류, 서명 검증 오류처럼 업데이트 존재 여부를 정상적으로 판단하지 못한 경우에는 기존 저장 모델을 제거하지 않는다. 마지막으로 성공한 확인 결과를 유지하고 오류는 기존 오류 처리 경로로 전달한다.

#### 업데이트 설치 후 재실행

설치된 앱의 `CFBundleVersion`이 저장된 빌드 이상이 되므로 초기 복원 단계에서 오래된 저장 모델이 자동으로 제거된다. 별도의 설치 완료 플래그는 추가하지 않는다.

### 기존 상태와의 관계

- `updateLastCheckDate`는 현재처럼 마지막 확인 표시 용도로 유지한다.
- `SULastCheckTime`과 실제 확인 예약은 Sparkle이 계속 관리한다.
- `updateAvailable`, 표시 버전, 릴리스 날짜, 릴리스 노트 URL의 기존 공개 인터페이스를 유지하여 `SettingsView`와 `MenuBarView`를 변경하지 않거나 최소화한다.
- 로컬·개발 빌드의 release tag guard와 GitHub Release 웹 fallback은 유지한다.

## 설계 2: 공식 릴리스 단조 증가 검증

### 공용 검증 스크립트

공식 stable 릴리스 전에 실행할 읽기 전용 검증 스크립트를 `scripts/` 아래에 추가한다. workflow 안에 비교 로직을 중복 작성하지 않는다.

입력:

- 후보 `APP_VERSION`
- 후보 `BUILD_NUMBER`
- 대상 저장소 `woosublee/quill`
- GitHub API 인증 토큰

검증 데이터:

1. GitHub Releases API에서 공개된 non-draft Release를 페이지네이션하여 조회한다.
2. `vX.Y.Z` 형식의 stable tag만 표시 버전 비교 대상으로 사용한다.
3. 각 stable Release의 `appcast.xml`에서 `sparkle:version`과 `sparkle:shortVersionString`을 읽고, 표시 버전이 tag와 다르면 안전하게 실패한다.
4. Sparkle 도입 이후 stable Release의 appcast가 없거나 손상된 경우에는 안전하게 실패한다.
5. Sparkle 도입 전이라 appcast가 없는 과거 stable Release는 표시 버전 비교에는 포함하고 빌드 최대값 계산에서는 제외한다.
6. 공개 prerelease는 해당 tag의 `version.mk`에서 `BUILD_NUMBER`를 읽어 빌드 최대값 계산에만 포함한다. Sparkle 도입 이후 prerelease의 빌드 메타데이터를 읽지 못하면 안전하게 실패한다.

통과 조건:

- 후보 `APP_VERSION`이 기존 stable 표시 버전 최대값보다 엄격히 크다.
- 후보 `BUILD_NUMBER`가 기존 appcast 빌드 번호 최대값보다 엄격히 크다.
- 비교할 기존 stable Release나 appcast가 없으면 해당 검사를 통과시킨다.

실패 출력:

- 후보 표시 버전과 빌드 번호
- 기존 최대 표시 버전과 빌드 번호
- 실패한 비교 조건
- 비교에 사용한 Release tag

검증 스크립트는 GitHub 데이터를 변경하지 않는다. 테스트에서는 네트워크 대신 fixture 입력을 사용할 수 있게 데이터 조회와 비교를 분리한다.

### workflow 적용

다음 공식 workflow가 같은 검증 스크립트를 사용한다.

- `.github/workflows/self-signed-release.yml`
- `.github/workflows/release.yml`

검증은 앱 빌드, tag push, GitHub Release 생성보다 먼저 실행한다. 실패하면 외부 상태를 만들기 전에 workflow를 종료한다.

두 공식 stable workflow와 `manual-release.yml`에는 저장소 전체에서 공유되는 동일한 `concurrency` 그룹을 설정한다. manual prerelease의 빌드 번호도 다음 stable의 하한이므로 preflight와 prerelease publication이 겹치지 않아야 한다.

- 그룹: 공식 Quill stable release 전용 고정 이름
- `cancel-in-progress: false`

먼저 시작한 릴리스를 취소하지 않고 완료시킨다. GitHub concurrency는 실행 1개와 대기 1개만 유지하므로 공식 stable 릴리스는 한 번에 하나씩 dispatch한다. 이 제약 아래 대기 중인 다음 릴리스는 앞선 릴리스가 공개된 뒤 단조 증가 검사를 실행하여, 낮은 버전이 나중에 `latest`가 되는 경합을 막는다.

### 게시 후 읽기 전용 확인

Release 생성 후 다음을 확인한다.

- GitHub latest tag가 방금 배포한 tag와 같다.
- `/releases/latest/download/appcast.xml`이 방금 배포한 Release로 연결된다.
- appcast의 `sparkle:version`과 `sparkle:shortVersionString`이 후보 빌드·표시 버전과 같다.
- enclosure URL이 방금 배포한 `Quill.dmg`를 가리킨다.
- appcast 생성 전에 CI private key에서 파생한 public key가 앱의 `SUPublicEDKey`와 일치한다.
- 생성한 DMG의 EdDSA signature를 같은 public key로 다시 검증한다.

GitHub latest와 asset 전파 지연은 제한된 횟수로 재시도한다. 최종 실패 시 자동 삭제나 롤백을 수행하지 않고 workflow를 실패 처리하여 잘못된 latest 상태를 즉시 드러낸다.

## 설계 3: Sparkle 확인 주기 키 수정

`Info.plist`에서 다음 키를 교체한다.

```diff
- SUUpdateCheckInterval
+ SUScheduledCheckInterval
```

값은 `86400`으로 유지한다. `SUEnableAutomaticChecks=true`와 `SUAutomaticallyUpdate=false`의 현재 기본 정책은 변경하지 않는다.

기존 사용자의 UserDefaults에 `SUScheduledCheckInterval` override가 있으면 Sparkle의 기존 우선순위를 따른다. 잘못된 `SUUpdateCheckInterval` UserDefaults 값을 마이그레이션하는 코드는 추가하지 않는다. Quill이 해당 값을 사용자 설정으로 기록한 적이 없고, 현재 기본값과도 동일하기 때문이다.

## 오류 처리

- 저장 모델 decode 실패: 상태를 제거하고 실행을 계속한다.
- 현재 앱 빌드 정보를 읽지 못함: 잘못된 업데이트 카드를 복원하지 않고 저장 상태를 보존하여 다음 정상 실행에서 다시 판단한다.
- Sparkle 확인 실패: 기존에 확인한 업데이트 카드를 보존한다.
- GitHub API 실패 또는 rate limit: 공식 릴리스 검증을 실패시킨다. 검증을 건너뛰고 릴리스를 계속하지 않는다.
- appcast 다운로드·파싱 실패: 공식 릴리스 검증을 실패시킨다.
- 게시 후 latest 확인 실패: 기존 Release를 자동 변경하지 않고 workflow를 실패 처리한다.

## 테스트 설계

### 업데이트 상태 단위 테스트

- 유효한 업데이트 발견 시 저장 모델이 기록된다.
- 새 `UpdateManager` 또는 상태 복원 단위가 저장 모델을 읽어 카드를 복원한다.
- 저장 빌드가 현재 빌드보다 높을 때만 복원한다.
- 저장 빌드가 현재 빌드와 같거나 낮으면 제거한다.
- 저장 빌드가 `SUSkippedVersion`과 같으면 자동 복원하지 않는다.
- 정상적인 업데이트 없음 결과는 화면 상태와 저장 모델을 제거한다.
- 확인 실패는 기존 저장 모델을 보존한다.
- 손상된 저장 데이터는 앱을 중단하지 않고 제거한다.
- 릴리스 날짜와 릴리스 노트 URL이 없는 appcast item도 복원할 수 있다.

### 릴리스 검증 스크립트 테스트

fixture 기반으로 다음을 검증한다.

- 표시 버전과 빌드 번호가 모두 증가하면 통과한다.
- 표시 버전이 낮거나 같으면 실패한다.
- 빌드 번호가 낮거나 같으면 실패한다.
- 표시 버전만 증가하고 빌드가 감소하면 실패한다.
- 빌드만 증가하고 표시 버전이 감소하면 실패한다.
- GitHub latest 지정이 잘못되어도 전체 stable Release의 최대값을 사용한다.
- draft는 모든 비교에서 제외하고, prerelease는 stable 표시 버전 최대값에서는 제외하되 빌드 번호 최대값에는 포함한다.
- Sparkle 이전 Release의 appcast 누락은 허용한다.
- 존재하는 appcast가 손상되면 실패한다.
- 비교 대상이 없는 첫 stable 릴리스는 통과한다.

### 소스 계약 테스트

- `Info.plist`에 `SUScheduledCheckInterval=86400`이 존재한다.
- `SUUpdateCheckInterval`이 존재하지 않는다.
- 두 공식 stable workflow가 같은 검증 스크립트를 호출한다.
- 두 공식 stable workflow가 같은 `concurrency` 그룹과 `cancel-in-progress: false`를 사용한다.
- prerelease workflow에는 stable 단조 증가 검사가 추가되지 않는다.

## 수동 검증

1. 기존 테스트 전체를 실행한다.
2. 서명된 Quill 앱을 빌드한다.
3. 격리된 UserDefaults suite 또는 테스트 환경에 현재 앱보다 높은 저장 snapshot을 준비한다.
4. 앱을 실행하고 설정창과 메뉴바에 업데이트 카드가 즉시 복원되는지 확인한다.
5. 현재 앱과 같거나 낮은 snapshot에서는 카드가 나타나지 않고 저장 상태가 정리되는지 확인한다.
6. 오프라인 또는 확인 실패 조건에서 기존 카드가 사라지지 않는지 확인한다.
7. 검증 스크립트를 현재 공개 Release 데이터에 대해 dry-run으로 실행한다.
8. 낮은 표시 버전, 낮은 빌드 번호 fixture가 외부 상태 변경 없이 실패하는지 확인한다.
9. production GitHub Release와 appcast는 생성하거나 수정하지 않는다.

## 예상 변경 파일

- `Sources/UpdateManager.swift`
- 업데이트 snapshot 저장소를 위한 작은 새 Swift 파일 또는 기존 파일의 private 보조 타입
- `Info.plist`
- `scripts/` 아래 공식 릴리스 단조 증가 검증 스크립트
- `.github/workflows/self-signed-release.yml`
- `.github/workflows/release.yml`
- `Tests/UpdateManagerSafetyTests.swift` 또는 새 상태 복원 테스트
- `Tests/BuildMetadataTests.swift` 또는 새 릴리스 검증 테스트

정확한 파일 분리는 구현 계획 단계에서 기존 테스트 구조와 재사용 가능한 경계를 다시 확인하여 확정한다.

## 구현 순서

1. `main`을 기준으로 별도 브랜치를 만든다.
2. 상태 저장·복원과 릴리스 검증의 실패 테스트를 먼저 작성한다.
3. 업데이트 snapshot 저장소와 `UpdateManager` 연결을 구현한다.
4. 공식 릴리스 검증 스크립트와 fixture 테스트를 구현한다.
5. 두 공식 workflow에 검증과 공용 concurrency 그룹을 적용한다.
6. Sparkle interval 키를 수정하고 소스 계약 테스트를 갱신한다.
7. 전체 테스트, 서명 빌드, GUI 상태 복원, 실제 공개 데이터 dry-run을 수행한다.
8. 결과를 보고한 뒤 커밋·푸시·PR은 사용자 요청에 따라 별도로 진행한다.

## 성공 기준

- 업데이트 발견 후 앱을 재시작해도 유효한 업데이트 카드가 설정창과 메뉴바에 유지된다.
- 설치 완료, 정상적인 업데이트 없음, 또는 사용자의 버전 건너뛰기 이후에는 오래된 카드가 자동 노출되지 않는다.
- 오프라인이나 일시적 확인 실패는 마지막으로 성공한 업데이트 정보를 제거하지 않는다.
- 낮거나 같은 표시 버전 또는 빌드 번호를 가진 공식 stable 릴리스는 tag 생성 전에 차단된다.
- 두 공식 stable workflow가 동시에 latest 상태를 변경할 수 없다.
- Sparkle의 실제 확인 주기 키가 `86400`초로 명시된다.
- 기존 테스트와 새 테스트가 모두 통과하고 서명된 앱에서 상태 복원이 확인된다.
