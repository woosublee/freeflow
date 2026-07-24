# Prompt Settings Separation Design

- **Date:** 2026-07-24
- **Status:** Approved
- **Scope:** Settings 정보 구조와 UI 경계 분리
- **Related design:** [`2026-07-17-model-first-settings-redesign.md`](./2026-07-17-model-first-settings-redesign.md)

## Goal

`Models` Settings 안에 함께 배치된 Prompt 편집·테스트 기능을 독립된 `Prompts` 메뉴로 이동한다.

변경 후 사용자는 다음 두 목적을 서로 다른 화면에서 처리한다.

- `Models`: 기능별 backend, model, provider, language와 입력 설정 관리
- `Prompts`: System Prompt와 Context Prompt 편집·초기화·테스트 및 Instruction Guard 관리

기존 model-first 설정 구조와 모든 저장값·runtime 동작은 유지하면서, `Models` 화면의 길이와 복잡도만 줄이는 것이 목표다.

## Current problem

현재 `ModelsSettingsView`는 Cloud Provider, Transcription, Post-processing, Context, Meeting Summary의 backend와 model 설정을 제공한다. 여기에 다음 Prompt 관련 기능도 각 기능의 `Details` 안에 포함되어 있다.

- Post-processing Details
  - System Prompt 편집과 기본값 관리
  - System Prompt 테스트와 결과
  - Instruction Guard
- Context Details
  - Context Prompt 편집과 기본값 관리
  - Context Prompt 테스트와 결과
  - Screenshot Resolution

Prompt 편집기는 기본값 비교, 긴 `TextEditor`, 테스트 입력, 실행 결과, 실제 전송 Prompt를 모두 포함한다. 이 때문에 model을 선택하려는 사용자에게 `Models` 화면이 지나치게 길고, model 설정과 Prompt 작성이라는 서로 다른 작업이 한 메뉴에서 경쟁한다.

업스트림은 별도의 `PromptsSettingsView`를 제공하지만, Quill은 이후 다음 동작을 추가했으므로 업스트림 구현을 그대로 복사하지 않는다.

- Cloud와 Local AI backend 선택
- backend-aware readiness
- `AppState` service factory를 통한 테스트
- `QuillUserIssueView` 기반 구조화된 오류와 복구
- 영어·한국어 localization

업스트림에서는 정보 구조만 참고하고 Quill의 현재 동작을 보존한다.

## Design decisions

### Add a peer Prompts menu

Settings sidebar 순서는 다음과 같다.

```text
General
Appearance
Models
Prompts
Shortcuts
Input
Calendar
About
```

`Prompts`는 `Models` 바로 뒤에 배치한다. Prompt가 model을 사용하는 관계는 유지하되, model 선택 후 Prompt를 세부 조정하는 자연스러운 순서를 제공한다.

`SettingsTab`에는 `.prompts`를 추가하고 `SettingsView`는 해당 탭에서 `PromptsSettingsView`를 표시한다.

- Title: `Prompts`
- Korean localization: `프롬프트`
- SF Symbol: `text.bubble`

### Keep model-adjacent settings in Models

`Models`는 다음 구조를 유지한다.

```text
Models
├─ Cloud Provider
├─ Transcription
├─ Post-processing
│  └─ Details
│     ├─ Model
│     ├─ Output Language
│     ├─ Fallback Model
│     └─ Custom Vocabulary
├─ Context
│  └─ Details
│     ├─ Model
│     └─ Screenshot Resolution
└─ Meeting Summary
```

다음 항목은 `Models`에 남긴다.

- Cloud Provider와 API credential
- 모든 Transcription 설정과 model lifecycle
- Post-processing과 Context의 enabled state, backend, primary/fallback model
- Output Language
- Custom Vocabulary
- Screenshot Resolution
- Meeting Summary 설정

`Screenshot Resolution`은 Prompt 본문이 아니라 Context 입력의 품질·비용을 조절하는 설정이다. 따라서 현재 `contextPromptSection`에서 별도 section으로 분리한 뒤 `Models > Context > Details`에 유지한다.

### Put prompt-specific behavior in Prompts

`PromptsSettingsView`는 세 개의 peer `SettingsCard`를 순서대로 표시한다.

```text
Prompts
├─ System Prompt
├─ Instruction Guard
└─ Context Prompt
```

#### System Prompt

현재 기능을 그대로 제공한다.

- Prompt 역할 설명
- 기본 Prompt와 사용자 지정 Prompt 상태
- 새 기본 Prompt가 있을 때 안내
- 기본 Prompt 표시, 전환, 초기화
- 사용자 지정 Prompt 편집기
- 샘플 transcript 입력
- 현재 Post-processing backend로 테스트
- 결과, 구조화된 오류, 재시도, 실제 전송 Prompt 표시

#### Instruction Guard

현재 toggle과 설명을 그대로 제공한다.

- `instructionExecutionGuardEnabled` binding
- 받아쓰기 내용을 명령으로 실행한 것으로 판단될 때 retry 또는 literal transcript fallback을 수행한다는 설명

Instruction Guard는 Prompt 텍스트 자체는 아니지만 Prompt 실행 안전성과 직접 관련되므로 `Prompts`에 포함한다.

#### Context Prompt

현재 Prompt 관련 기능만 제공한다.

- Prompt 역할 설명
- 기본 Prompt와 사용자 지정 Prompt 상태
- 새 기본 Prompt가 있을 때 안내
- 기본 Prompt 표시, 전환, 초기화
- 사용자 지정 Prompt 편집기
- 현재 앱의 metadata와 가능한 screenshot을 캡처해 테스트
- 결과, 구조화된 오류, 재시도, 실제 전송 Prompt 표시

`Screenshot Resolution`은 이 카드에 포함하지 않는다.

## Code boundaries

### SettingsTab and navigation

`Sources/CalendarIntegrationModels.swift`의 `SettingsTab`에 `.prompts`를 추가한다.

- `orderedCases`: `.models`와 `.shortcuts` 사이
- `title`: `Prompts`
- `icon`: `text.bubble`

`Sources/SettingsView.swift`의 tab switch에 다음 연결을 추가한다.

```swift
case .prompts:
    PromptsSettingsView()
```

### PromptsSettingsView

기존 Settings View들이 같은 파일에 모여 있는 관례와 최소 변경 원칙을 따라, 이번 변경에서는 `PromptsSettingsView`를 `Sources/SettingsView.swift` 안의 독립된 SwiftUI View로 둔다.

View-local state:

- `customSystemPromptInput`
- `customContextPromptInput`
- 기본 Prompt 표시 여부
- 각 테스트의 running, output, issue/error, sent prompt
- System Prompt 테스트용 sample input

Persistent state는 기존 `AppState` property를 그대로 사용한다.

- `customSystemPrompt`
- `customSystemPromptLastModified`
- `customContextPrompt`
- `customContextPromptLastModified`
- `instructionExecutionGuardEnabled`

새 persistence key나 migration은 추가하지 않는다.

### ModelsSettingsView cleanup

`ModelsSettingsView`에서 다음 상태와 UI를 제거한다.

- Prompt editor draft
- 기본 Prompt 표시 여부
- Prompt 테스트 state
- `systemPromptSection`
- `instructionGuardSection`
- `contextPromptSection`의 Prompt 편집·테스트 부분
- System/Context Prompt 테스트 함수

현재 `contextPromptSection` 안의 Screenshot Resolution UI는 `contextScreenshotResolutionSection`처럼 독립된 section으로 분리해 `contextDetails`에서 사용한다.

Models와 Prompts 사이에 view-local state나 callback을 공유하지 않는다. 두 화면은 `AppState`를 유일한 영구 설정 경계로 사용한다.

## Data and behavior preservation

Prompt를 저장하는 방식은 변경하지 않는다.

- 입력값이 기본 Prompt와 같거나 비어 있으면 custom value와 last-modified date를 비운다.
- 기본 Prompt와 다르면 trim한 값을 저장하고 현재 날짜를 last-modified date로 기록한다.
- 새 기본 Prompt 안내는 기존 날짜 비교 규칙을 유지한다.
- Reset과 Switch to Default는 기존 custom value와 last-modified date를 비운다.

Prompt 테스트는 현재 Quill 경로를 유지한다.

- System Prompt: `appState.makePostProcessingService()`
- Context Prompt: `appState.makeAppContextService()`
- Readiness: `appState.isAIProcessingBackendReady(for:)`
- 오류: `QuillUserIssueRecord`와 `QuillUserIssueView`
- 선택 backend와 model은 `AppState`의 현재 값을 사용하며 테스트 중 변경하지 않는다.

메뉴 이동은 runtime pipeline, model 선택, fallback, 기본값 또는 기존 사용자 설정을 바꾸지 않는다.

## Error handling

현재 오류 표현을 보존한다.

- 선택한 backend가 준비되지 않으면 해당 테스트 버튼을 비활성화한다.
- Cloud backend인데 API Key가 없으면 기존 provider configuration warning을 표시한다.
- Local AI model이 준비되지 않았으면 backend readiness 결과를 반영한다.
- System Prompt 테스트 실패는 Post-processing service가 생성한 `QuillUserIssueRecord`를 표시한다.
- Context capture 또는 inference 실패는 기존 issue 또는 context error를 표시한다.
- retry 가능한 issue만 기존 recovery mapping을 통해 retry action을 제공한다.

오류가 발생해도 Prompt, backend, model 또는 enabled state를 자동 변경하지 않는다.

## Localization and accessibility

- `Prompts`의 영어·한국어 catalog entry를 제공한다.
- 기존 Prompt card의 문자열과 번역을 재사용한다.
- sidebar row는 기존 `localizedCatalogString(tab.title)` 경로를 사용한다.
- `text.bubble` 아이콘과 title을 함께 표시해 아이콘에만 의미를 의존하지 않는다.
- Prompt test button의 disabled state와 inline warning을 유지한다.
- 기존 toggle label과 accessibility semantics를 유지한다.

## Testing

### Navigation contract

- `SettingsTab.orderedCases`에서 `.prompts`가 `.models` 다음, `.shortcuts` 이전인지 확인한다.
- `.prompts` title과 icon을 확인한다.
- `SettingsView`가 `.prompts`를 `PromptsSettingsView`로 연결하는지 확인한다.

### Models UI contract

기존 `ModelsSettingsUIContractTests`를 새 경계에 맞게 조정한다.

- Cloud Provider, Transcription, Post-processing, Context, Meeting Summary card가 유지된다.
- Models block에 System Prompt editor, Context Prompt editor, Instruction Guard가 남아 있지 않다.
- Post-processing Details에 Output Language, fallback model, Custom Vocabulary가 유지된다.
- Context Details에 Screenshot Resolution이 유지된다.
- 기존 backend, model lifecycle, readiness 계약은 변경하지 않는다.

### Prompts UI contract

`Tests/PromptsSettingsUIContractTests.swift`를 추가하고 Makefile test wiring에 정확히 한 번 포함한다. 기존 `ModelsSettingsUIContractTests`는 Models에 남는 계약만 검사하도록 좁힌다.

- `PromptsSettingsView`가 존재한다.
- card 순서가 System Prompt, Instruction Guard, Context Prompt다.
- 두 editor가 기존 default/custom 저장 규칙을 사용한다.
- 기본값 보기, 전환, reset과 newer-default 안내가 유지된다.
- System test가 `makePostProcessingService()`를 사용한다.
- Context test가 `makeAppContextService()`를 사용한다.
- 두 테스트가 backend readiness, provider warning, 구조화된 issue를 유지한다.
- Prompts block에 Screenshot Resolution이 포함되지 않는다.

### Localization and regression

- `Prompts`에 영어·한국어 번역이 있는지 확인한다.
- 전체 `make test`를 실행한다.
- 앱을 빌드하고 Settings navigation과 두 화면을 직접 확인한다.
- 기존 custom System/Context Prompt가 메뉴 이동 후 그대로 표시되는지 확인한다.
- Cloud와 Local AI 선택 각각에서 test readiness와 결과 표시를 확인한다.

## Non-goals

이번 변경에는 다음을 포함하지 않는다.

- 새로운 Prompt 종류 추가
- Meeting Summary Prompt를 사용자 편집 설정으로 노출
- Prompt preset, version history, import/export 추가
- Prompt persistence key 또는 기본 Prompt 변경
- model, backend, fallback 또는 provider 동작 변경
- Settings 전체 파일 분해
- Models 이외 다른 메뉴의 정보 구조 변경
- 업스트림 `PromptsSettingsView`의 직접 cherry-pick

## Acceptance criteria

1. Settings sidebar에 `Models` 다음 `Prompts` 메뉴가 표시된다.
2. `Prompts` 화면은 System Prompt, Instruction Guard, Context Prompt 세 카드를 제공한다.
3. Prompt 편집, default/custom 상태, newer-default 안내, reset과 테스트 동작이 기존과 동일하다.
4. Prompt 테스트는 현재 선택된 Quill Cloud/Local AI backend와 구조화된 오류 처리를 유지한다.
5. `Models` 화면에는 Prompt 편집기와 Instruction Guard가 남아 있지 않다.
6. Screenshot Resolution은 `Models > Context > Details`에 남아 있다.
7. 기존 사용자 설정과 persistence key는 변경되지 않는다.
8. 영어·한국어에서 새 메뉴가 올바르게 표시된다.
9. 관련 contract test와 전체 테스트가 통과한다.
10. 앱에서 Models 화면이 짧아지고 Prompts 화면이 독립적으로 스크롤된다.
