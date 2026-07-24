# 인앱 회의 요약 설계

## 목표

완료된 전사 노트에서 사용자가 한 번의 명시적 동작으로 검토 가능한 회의 요약 초안을 생성하고, Note Browser 안에서 원문과 나란히 오가며 검토할 수 있게 한다.

v1의 역할은 기존 MCP 기반 회의록을 대체하는 것이 아니다. 인앱 요약은 Quill이 확실하게 보유한 현재 전사문과 캘린더 메타데이터만 사용해 빠른 검토 초안을 만든다. People 문서, 이전 회의록, Obsidian vault, Notion, URL 및 사용자가 별도로 제공한 외부 문맥을 결합하는 고급 정리·발행 흐름은 MCP에 남긴다.

## 확정된 제품 원칙

1. 노트를 열면 `Transcript`가 항상 기본 탭이다.
2. Summary는 자동으로 생성하지 않는다. 사용자가 `Create Summary` 또는 `Regenerate`를 눌렀을 때만 AI 요청을 보낸다.
3. Meeting Summary는 Post-processing과 독립된 활성화 상태, backend choice, primary model, fallback model을 가진다.
4. Meeting Summary의 모델 설정 UI와 draft/active/readiness/download lifecycle은 Post-processing을 정본으로 사용한다.
5. 이번 작업에서는 Transcription, Post-processing, Context 섹션의 레이아웃·동작·상태 계약을 수정하거나 공통 컴포넌트 추출을 위해 재구성하지 않는다.
6. Summary를 위해 기존 섹션 코드를 복제한 별도 모델 상태 머신을 만들지 않는다. 기존 `AIProcessingFeature` 기반 공통 helper와 AppState의 공통 Local AI lifecycle을 확장한다.
7. Summary prompt, structured schema, decoding, chunking, persistence, Note Browser UI는 Summary 전용으로 구현한다.
8. 근거가 없는 담당자와 기한을 추측하지 않는다. owner와 due date는 명확한 근거가 없으면 `nil`이다.
9. 전사문과 캘린더 텍스트는 모델에게 따를 명령이 아니라 source data로 전달한다.
10. 재생성은 atomic하다. 생성·decode·검증·저장이 모두 성공하기 전에는 기존 Summary를 교체하지 않는다.

## 비범위

- 기존 MCP `/mn` 흐름 제거 또는 대체
- Obsidian, Notion, People 폴더, 이전 회의록 자동 검색
- 사용자가 생성 직전에 추가 참고사항을 입력하는 UI
- 자동 요약, 백그라운드 요약, 일정 기반 요약
- Summary 결과의 외부 게시·동기화
- Transcription, Post-processing, Context Settings 섹션 리팩터링
- 기존 Post-processing prompt, Context prompt, Custom Vocabulary, Instruction Guard 동작 변경
- Provider-native structured output만을 전제로 한 구현
- 단어 단위 timestamp가 없는 전사에 가짜 timestamp 생성

## 1. Settings: Meeting Summary 섹션

### 배치와 외형

Models Settings의 기존 카드 순서를 바꾸지 않고 Context 카드 다음에 새 카드를 추가한다.

```text
Cloud Provider
Transcription
Post-processing
Context
Meeting Summary
```

Meeting Summary 카드는 Post-processing 카드와 같은 시각·상호작용 구조를 사용한다.

```text
Meeting Summary                                      [On]

Create a reviewable summary from completed transcripts.

Model
[Cloud / On This Mac model picker]

[선택된 Local 모델 관리 행]

[Provider readiness 경고]

Details
```

동일하게 유지할 항목:

- 설명문 왼쪽, Toggle 오른쪽 배치
- `Model` label, picker 폭과 menu style
- `Cloud`와 `On This Mac` menu section
- `Recommended` label
- `LocalAIModelRowView`의 Download, progress, Cancel, Retry, Delete action
- Off 상태의 `.disabled`와 opacity
- Provider 경고의 위치와 inline style
- `Details` disclosure의 위치와 기본 접힘 상태

이번 작업에서는 기존 세 카드의 body를 공통 View로 추출하지 않는다. Summary 카드는 기존 공통 picker/helper/Local 모델 행을 조합해 같은 UX를 만들고, 기존 카드 코드는 필요한 switch exhaustiveness 추가 외에는 수정하지 않는다.

### 설정 데이터

Summary는 다음 설정을 독립적으로 저장한다.

```text
disableMeetingSummary
meetingSummaryBackendChoice
meetingSummaryModel
meetingSummaryFallbackModel
meetingSummaryOutputLanguage
meetingSummarySettingsInitialized
```

`meetingSummaryBackendChoice`가 Local이어도 마지막 Cloud model ID는 `meetingSummaryModel`에 remembered choice로 남긴다.

기존 사용자의 첫 초기화에서는 현재 Post-processing model과 fallback을 한 번 복사하되, 이후 두 기능을 연결하지 않는다. 첫 초기화 시 preferred Summary choice가 ready하면 Summary를 활성화하고, 다른 ready choice가 있으면 기존 공통 fallback 우선순위로 활성화한다. ready choice가 하나도 없으면 remembered choice만 저장하고 Summary는 Off로 시작한다.

### 공통 feature 확장

```swift
enum AIProcessingFeature {
    case postProcessing
    case context
    case meetingSummary
}
```

다음 기존 공통 경로에 `.meetingSummary` 처리를 추가한다.

- `settingsAIProcessingChoice(for:)`
- `setAIProcessingChoiceDraft(_:for:)`
- `setAIProcessingFeatureEnabled(_:for:)`
- `handleAIProcessingChoiceSelection(_:for:)`
- `retainedLocalAIModelID(for:)`
- `syncCloudModelDraft(_:for:)`
- `managedLocalAIResolverInput(for:)`
- `reconcileRetainedLocalAIModel(for:)`
- `aiProcessingChoicePicker(for:)`
- `currentAIProcessingChoice(for:)`
- `selectAIProcessingBackendChoice(_:for:)`
- `readyAIProcessingChoice(preferred:for:)`
- `commitAIProcessingSettingsDraft(...)`
- `normalizeAIProcessingChoices()`
- `AIProcessingFeature.allCases`
- `pendingLocalAISelections`

Summary를 위한 별도의 pending/download dictionary나 별도 Local 모델 installer를 만들지 않는다.

## 2. 모델 설정 상태 계약

### 상태 경계

```text
Settings draft
- meetingSummaryEnabledDraft
- meetingSummaryChoiceDraft
- meetingSummaryModelDraft
- retainedMeetingSummaryLocalModelID

실제 active
- disableMeetingSummary
- meetingSummaryBackendChoice

임시 Local 선택
- pendingLocalAISelections[.meetingSummary]

실제 다운로드
- 기존 localAIInstallStates / localAIInstallTasks
```

Note Browser는 Settings draft나 pending selection을 읽지 않는다. 실제 active 상태와 현재 backend readiness만 읽는다.

### Toggle Off

Toggle을 끄면 즉시 `disableMeetingSummary = true`를 적용한다.

- model picker, Local 모델 행, Details를 비활성화하고 흐리게 표시한다.
- Cloud API key 경고를 표시하지 않는다.
- remembered backend와 Cloud model ID를 보존한다.
- 기존 Summary 데이터와 Action item 완료 상태는 삭제하지 않는다.

### Toggle On + ready choice

현재 draft choice가 ready하면 즉시 active choice로 적용하고 Summary를 켠다.

- Cloud readiness: 공유 API key가 비어 있지 않다.
- Local readiness: status refresh가 끝났고, 플랫폼이 Local AI를 지원하며, 선택 모델 상태가 `.ready`다.

### Toggle On + unready choice

Settings에서는 On과 선택값을 임시로 표시하지만 실제 active 상태는 바꾸지 않는다.

- 이전 active choice가 ready하면 Note Browser는 계속 이전 choice를 사용한다.
- 이전 ready choice가 없으면 실제 Summary 기능은 Off를 유지한다.
- Models 탭 이탈 또는 Settings 종료 시 공통 commit 규칙으로 정리한다.

### Cloud model + API key 없음

Summary가 draft On이고 Cloud choice를 선택했지만 API key가 없으면 다음 경고를 표시한다.

```text
Meeting Summary is on, but cloud summarization is unavailable until an API key is configured.
```

- Cloud choice는 Settings draft로만 유지한다.
- 기존 ready active choice는 바꾸지 않는다.
- Models Settings 내부에 `Open Provider Settings` 버튼은 추가하지 않는다.
- 같은 화면의 Cloud Provider 카드에서 key를 설정한다.
- Summary가 Off이면 이 경고를 표시하지 않는다.

### 미설치 Local model 선택

- picker에서 선택할 수 있다.
- `pendingLocalAISelections[.meetingSummary]`에 model ID를 기록한다.
- picker 아래에 기존 `LocalAIModelRowView`를 표시한다.
- 실제 active choice는 설치 전까지 변경하지 않는다.

다운로드를 시작하지 않고 Models 탭을 벗어나면 pending 선택을 폐기한다. Settings에 돌아오면 정규화된 실제 active choice 또는 Off 상태를 표시한다.

### Models 탭 이탈 시 정규화 우선순위

1. 사용자가 요청한 draft choice가 ready하면 적용한다.
2. 이전 active choice가 ready하면 유지한다.
3. 설치된 Recommended Local model이 있으면 적용한다.
4. 그 밖의 설치된 Local model 중 첫 번째를 적용한다.
5. API key가 있으면 remembered Summary Cloud model을 적용한다.
6. ready choice가 없으면 Summary를 Off로 변경한다.

### Local download lifecycle

다운로드를 시작하면 pending association과 download task는 Models 탭 이동 및 Settings 종료 후에도 유지한다.

- 같은 Local 모델을 여러 AI Processing feature가 기다리면 실제 다운로드 task는 하나다.
- 완료되면 기존 `waitingFeatures(for:)`와 `applyReadyLocalAIModelToWaitingFeatures(_:)` 경로로 Summary choice를 적용한다.
- Settings를 떠나는 동안 실제 Summary가 Off로 정리됐다면 다운로드 완료만으로 기능을 몰래 다시 켜지 않는다. 설치된 모델은 remembered/active choice가 되고, 기능 활성화는 기존 공통 commit 계약을 따른다.
- Cancel, failure, Retry, partial cleanup, Delete는 기존 Local AI lifecycle을 그대로 사용한다.

### 외부 상태 동기화

Settings가 열려 있을 때 실제 Summary choice, disable 상태, model ID, Local install 상태가 바뀌면 draft를 동기화한다. 사용자가 Custom API Model field를 편집 중이면 외부 model ID로 입력을 덮어쓰지 않는다.

## 3. Summary Details

Summary Details는 model UX의 공통 부분만 Post-processing과 동일하게 사용한다.

```text
Details
- Custom API Model
- Output Language
- Summary Fallback Model
```

다음 Post-processing 전용 설정은 재사용하지 않는다.

- Custom Vocabulary
- Post-processing System Prompt
- Instruction Execution Guard toggle

Summary prompt는 별도 코드와 별도 version을 사용한다. v1에서는 구조화 출력과 정확성 계약을 보호하기 위해 전체 system prompt를 교체하는 사용자 편집 UI를 제공하지 않는다.

## 4. 요약 가능 조건

새 Summary 생성은 다음 조건을 모두 만족할 때 가능하다.

1. `disableMeetingSummary == false`
2. 현재 Summary backend choice가 ready다.
3. 노트 intent가 일반 dictation 또는 import된 전사 노트다.
4. 전사 처리가 완료됐다.
5. 현재 Note Browser에 표시되는 전사문을 trim한 결과가 비어 있지 않다.
6. import, live recording, cloud transcription, audio-only, recovery placeholder, fatal transcription failure 상태가 아니다.
7. 동일 노트의 Summary 생성이 이미 진행 중이지 않다.

다음은 필수 조건이 아니다.

- Post-processing 활성화 또는 `usedPostProcessing == true`
- Context 활성화 또는 `usedContextCapture == true`
- 캘린더 event match 존재

Summary source transcript는 Note Browser의 현재 editable transcript를 정본으로 사용한다. Post-processing이 꺼져 있으면 raw transcript를 저장한 현재 note content를 사용하고, 사용자가 수정했다면 수정된 최신 내용을 사용한다.

기존 Summary는 기능 또는 모델이 현재 unavailable이어도 열람·복사할 수 있다. 새 생성과 Regenerate만 막는다.

## 5. Note Browser UI

### 탭

Note detail header 아래, 본문 위에 macOS compact segmented control을 추가한다.

```text
[ Transcript | Summary ]
```

- 노트를 열거나 다른 노트를 선택하면 `Transcript`가 기본이다.
- Summary가 없고 Meeting Summary가 Off이면 Summary 탭을 표시하지 않는다.
- Meeting Summary가 On이면 Summary 탭을 표시한다.
- 저장된 Summary가 있으면 기능이 Off여도 Summary 탭을 표시해 기존 결과를 읽을 수 있게 한다.
- 전사 편집은 Transcript 탭에서만 가능하다.

### Summary가 없는 상태

기능과 backend가 ready하면 `Create Summary` action을 제공한다. 기능이 On이지만 backend가 unavailable하면 Settings의 draft가 아니라 실제 readiness를 기준으로 원인을 안내하고 Models Settings 진입 action을 제공한다.

### 생성 중

- Transcript 탭은 계속 읽고 편집할 수 있다.
- 동일 노트의 중복 생성 action을 막는다.
- 진행 상태는 Summary 탭과 floating toolbar action에 표시한다.
- 생성 시작 시 source fingerprint를 캡처한다.
- 완료 시 현재 fingerprint가 달라졌으면 결과를 저장하지 않고 전사문 변경 안내를 표시한다.

### 생성 성공

decode, validation, persistence가 모두 성공한 뒤 Summary 탭으로 전환한다. 새 결과가 저장되기 전에는 기존 Summary를 유지한다.

### 기존 Summary + 기능 Off 또는 backend unavailable

Summary는 읽기 전용으로 유지한다.

```text
Meeting Summary is off
This saved summary is still available. Turn the feature on to regenerate it.
```

또는 backend unavailable 이유를 표시하고 Regenerate만 비활성화한다.

### stale 상태

저장된 `sourceFingerprint`와 현재 source fingerprint가 다르면 Summary를 삭제하지 않고 `Out of date`로 표시한다.

```text
Transcript changed after this summary was generated.
[Regenerate]
```

## 6. Summary 결과 구조

Summary는 versioned Codable payload로 저장한다.

```swift
struct MeetingSummaryEnvelope: Codable, Equatable {
    let schemaVersion: Int
    let promptVersion: Int
    let generatedAt: Date
    let sourceFingerprint: String
    let modelID: String
    let backendKind: String
    let content: MeetingSummaryContent
}

struct MeetingSummaryContent: Codable, Equatable {
    let overview: String
    let keyPoints: [MeetingSummaryPoint]
    let decisions: [MeetingSummaryPoint]
    let actionItems: [MeetingSummaryActionItem]
    let openQuestions: [MeetingSummaryPoint]
}

struct MeetingSummaryPoint: Codable, Equatable, Identifiable {
    let id: UUID
    let text: String
    let sourceQuote: String?
}

struct MeetingSummaryActionItem: Codable, Equatable, Identifiable {
    let id: UUID
    let task: String
    let owner: String?
    let dueDate: String?
    let sourceQuote: String?
    var isCompleted: Bool
}
```

모델은 UUID와 `isCompleted`를 생성하지 않는다. 모델 응답을 decode한 뒤 앱이 ID와 local completion 상태를 부여한다.

Regenerate 시 normalized `task + owner + dueDate`가 일치하는 Action item은 기존 `isCompleted`를 보존한다. 일치하지 않는 새 항목은 미완료 상태로 시작한다.

모델 ID와 backend kind는 진단과 재현성을 위해 저장하지만 일반 Summary UI에는 노출하지 않는다.

## 7. 근거 연결

현재 공통 전사 payload에는 안정적인 단어 단위 timestamp가 없으므로 v1에서 timestamp를 생성하거나 추측하지 않는다.

결정과 Action item에는 가능한 경우 짧은 `sourceQuote`를 요구한다. 앱은 quote가 현재 transcript 안에 존재하는지 검증한다.

- exact match가 있으면 `View in Transcript` action으로 Transcript 탭을 열고 해당 range를 강조한다.
- exact match가 없으면 quote를 근거 excerpt로 표시하되 직접 이동 action은 제공하지 않는다.
- quote가 없거나 검증되지 않은 owner/due date는 추측하지 않는다.
- 모델이 생성한 임의의 confidence 숫자는 저장하거나 표시하지 않는다.

## 8. 입력 source와 fingerprint

v1 source는 다음으로 제한한다.

- 현재 editable transcript
- calendar title, start/end, attendee names처럼 Quill에 이미 저장된 calendar metadata

다음은 Summary 요청에 보내지 않는다.

- audio binary
- screenshot
- local filesystem path
- debug status
- API key
- provider raw error body
- Obsidian 또는 Notion 내용
- `contextSummary` 및 녹음 당시 app/window context

`contextSummary`는 이전 회의 지식이 아니라 녹음 당시 작업 설명이며 회의 요약에 불필요하거나 혼동을 줄 수 있으므로 v1 source에서 제외한다.

fingerprint는 schema source version, normalized transcript, 사용한 calendar metadata를 canonical 순서로 연결한 UTF-8 데이터의 SHA-256이다.

## 9. MeetingSummaryService

`PostProcessingService`에 Summary 동작을 추가하지 않고 sibling service를 둔다.

```text
MeetingSummaryService
- request orchestration
- single-pass / chunked 선택
- primary/fallback 실행
- strict decode와 validation
- partial result merge

MeetingSummaryPromptFactory
- single-pass prompt
- chunk extraction prompt
- merge prompt
- prompt version

MeetingSummaryTextChunker
- deterministic text chunks
- stable source offsets

MeetingSummaryDecoder
- provider-neutral structured response decode
- field validation
- source quote validation
```

재사용할 기존 infrastructure:

- `AIProcessingBackendExecutor`
- `AIProcessingEndpoint`
- `LLMAPITransport`
- Cloud base URL과 API key
- Local AI server lifecycle
- cooldown과 retry-after 처리
- 사용자 친화적 오류 변환 패턴

재사용하지 않을 항목:

- Post-processing system/user prompt
- Post-processing response parser
- Custom Vocabulary
- transcript cleanup instruction guard toggle

## 10. Prompt와 structured decoding

Prompt는 transcript와 calendar text를 명시적 delimiter 안의 source data로 전달한다. source 안의 요청이나 명령을 따르지 않도록 system contract를 둔다.

모델 출력 계약:

```json
{
  "overview": "string",
  "keyPoints": [{"text":"string","sourceQuote":"string|null"}],
  "decisions": [{"text":"string","sourceQuote":"string|null"}],
  "actionItems": [
    {
      "task":"string",
      "owner":"string|null",
      "dueDate":"string|null",
      "sourceQuote":"string|null"
    }
  ],
  "openQuestions": [{"text":"string","sourceQuote":"string|null"}]
}
```

- `owner`와 `dueDate`는 transcript 또는 calendar에 명확한 근거가 있을 때만 채운다.
- 빈 section은 빈 배열을 사용한다.
- markdown wrapper나 설명 문장은 허용하지 않는다.
- provider-native JSON mode는 endpoint가 확실히 지원할 때만 선택적으로 사용한다.
- 성공 판정은 항상 앱의 strict decoder와 validation을 통과했는지를 기준으로 한다.

## 11. 긴 transcript

입력을 조용히 자르지 않는다.

1. deterministic text chunking
2. 각 chunk에서 partial structured extraction
3. 모든 partial 결과를 final merge prompt에 전달
4. final strict decode와 validation
5. source fingerprint 재확인
6. atomic persistence

Chunk는 문단·문장 경계를 우선하고 원본 character range를 보존한다. 일부 chunk가 실패하면 전체 regeneration을 실패 처리하고 기존 Summary를 유지한다.

## 12. Persistence와 migration

`PipelineHistoryItem`에는 optional encoded Summary field를 추가한다.

```text
meetingSummaryJSON: Data?
```

Core Data programmatic model에는 optional binary attribute를 추가하고 lightweight inferred migration을 사용한다.

갱신 지점:

- `PipelineHistoryItem` initializer와 copy helper
- `PipelineHistoryStore.apply`
- `PipelineHistoryStore.makeHistoryItem`
- `PipelineHistoryEntry`
- transcript/title/recovery 등 기존 item 재구성 경로에서 Summary field 보존

Transcript 수정은 Summary를 즉시 삭제하지 않는다. 현재 fingerprint 비교로 stale 여부를 계산한다.

## 13. 오류 처리

다음 원칙을 적용한다.

- 생성 실패 시 기존 Summary를 유지한다.
- 첫 생성 실패 시 Transcript를 그대로 유지한다.
- API key, raw provider body, local path, debug metadata를 사용자 메시지에 포함하지 않는다.
- authentication, rate limit, timeout, invalid response, local runtime unavailable을 사용자 행동 중심 문구로 변환한다.
- rate limit과 사용 가능한 fallback이 있으면 기존 공통 fallback 정책을 적용한다.
- fallback까지 실패하면 atomic 실패로 종료한다.
- 모델이 schema를 지키지 않으면 invalid response로 처리하고 불완전한 결과를 저장하지 않는다.

## 14. Localization과 접근성

새 사용자 문자열은 English와 Korean catalog에 함께 추가한다.

- Meeting Summary 설정 설명과 경고
- Transcript / Summary 탭
- Create Summary / Regenerate
- 생성 중, stale, feature Off, model unavailable 상태
- section labels
- copy action과 오류 안내

segmented control, action item checkbox, section copy, source jump action에 accessibility label과 keyboard focus를 제공한다. Reduce Motion에서는 탭 전환과 source highlight를 짧은 cross-fade 또는 정적 강조로 대체한다.

## 15. 검증

### 모델 Settings 회귀 계약

`.meetingSummary`에 대해 다음을 검증한다.

1. Cloud choice + API key 없음 경고
2. Off 상태에서 Provider 경고 숨김
3. ready choice 선택 시 즉시 active
4. 미설치 Local 선택 시 pending, active 불변
5. 다운로드 시작 없이 탭 이탈 시 pending 폐기
6. 다른 ready 모델이 있으면 자동 복원
7. ready 모델이 없으면 Summary Off
8. 다운로드 시작 후 탭 이탈 시 task와 pending 유지
9. 같은 Local 모델을 여러 feature가 기다리면 task 하나
10. Cancel, failure, Retry, Delete가 기존 Local AI lifecycle을 사용
11. 외부 active 변경 시 Summary draft 동기화
12. Note Browser가 Settings draft를 active처럼 노출하지 않음

기존 Transcription, Post-processing, Context 테스트의 기대값과 source contract는 변경하지 않는다.

### Summary domain/service

- strict decode 성공·실패
- unknown field와 malformed JSON 처리
- owner/dueDate null 규칙
- source quote 검증
- deterministic fingerprint
- transcript edit 후 stale 판정
- single-pass와 chunked 결과
- chunk 누락 없이 merge
- primary 실패 후 fallback
- generation 중 source 변경 시 결과 폐기
- regeneration atomicity
- Action item completion 보존

### Persistence

- Summary가 없는 기존 store load
- Summary encode/decode round trip
- transcript/title/recovery item 재구성 시 Summary 보존
- optional Core Data field migration

### Note Browser

- Transcript 기본 탭
- 기능 On/Off와 기존 Summary 유무에 따른 탭 표시
- Create/Regenerate availability
- 기존 Summary read-only 열람
- stale 표시
- source quote로 Transcript 이동
- full/section/action item copy

### 최종 검증

- 관련 unit/contract tests
- 앱 compile
- `git diff --check`
- 기존 Models Settings 세 카드가 시각·동작상 변경되지 않았는지 수동 확인
- Quill Dev에서 Cloud key 없음, 미설치 Local 선택, 탭 이동, 다운로드 시작·취소·완료, Summary 생성·재생성 확인
