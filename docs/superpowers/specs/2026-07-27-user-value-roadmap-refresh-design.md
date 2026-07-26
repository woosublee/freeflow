# 사용자 가치 중심 로드맵 전면 정비 설계

## 목표

Quill v0.1.28의 실제 제품 상태, 현재 열린 GitHub 이슈, 최근 완료된 작업, 코드 감사에서 확인된 미추적 문제를 하나의 실행 가능한 로드맵으로 통합한다.

이번 정비는 기존의 소비자 전달 품질과 신뢰성 투자를 버리지 않는다. 데이터 보존·녹음 무결성·개인정보 약속을 먼저 지킨 뒤, Quill이 사용자의 반복적인 회의 업무를 실제로 줄이는 방향으로 제품 우선순위를 확장한다.

제품의 다음 핵심 루프는 다음과 같다.

```text
회의를 놓치지 않음
→ 신뢰할 수 있게 기록
→ 검토 가능한 회의록으로 정리
→ 할 일을 실제로 실행
→ 다음 회의에서 이전 맥락을 이어감
```

## 감사 기준선

- 제품 기준: Quill v0.1.28, build 31
- 소스 기준: `1ce6f9b Prepare v0.1.28 release (#239)`
- GitHub 대상: `woosublee/quill`
- 현재 로드맵 정본: GitHub issue #176
- 현재 열린 이슈: 30개
- GitHub milestone: 없음
- 열린 PR: 없음
- 최신 릴리스와 `main`: 동일

저장소에 별도 `ROADMAP.md`는 만들지 않는다. #176을 단일 정본으로 유지하고, 필요한 저장소 문서는 #176을 가리키도록 한다.

## 확정된 제품 결정

1. #176을 로드맵의 단일 정본으로 유지한다.
2. 현재 열린 이슈와 새로 확인된 미추적 문제를 전수·실행 단위로 관리한다.
3. 큰 사용자 결과만 epic으로 만들고, 독립적으로 완료·검증 가능한 하위 이슈로 나눈다.
4. 로드맵은 우선순위와 시간 범위를 함께 사용한다.
   - `P0/P1`: 현재 제품 신뢰와 실패
   - `Now/Next/Later`: 사용자 가치 전달 순서
   - `Foundation`: 기능 개발의 안전성과 유지보수 기반
   - `Needs Decision`: 제품 결정 또는 외부 전제가 먼저 필요한 항목
5. 신뢰성 작업 다음의 첫 사용자 가치는 `Meeting Follow-through`다.
6. Now/Next는 로컬 우선 개인·소규모 팀 사용자를 중심으로 한다.
7. Quill 계정, hosted backend, Quill Cloud, 공동 편집은 Later의 검토 항목이며 현재 제품 전제가 아니다.
8. 회의 앱 감지는 자동 녹음이 아니라 사용자의 명시적 확인을 요청하는 방식으로 시작한다.
9. Cloud Meeting Summary는 Calendar 제목·시간·참석자 정보를 기본적으로 provider에 보내지 않는다.
10. GitHub 이슈는 영어로 작성한다.

## 유지할 제품 원칙

### 데이터 보존과 녹음 신뢰가 기능보다 우선

- history 또는 미디어를 자동 파괴하기 전에 사용자가 복구하거나 판단할 수 있어야 한다.
- permanent audio는 playback과 retry의 정본이다.
- recovery가 cleanup보다 먼저 실행된다.
- 녹음 UI가 성공으로 보이는 동안 한쪽 오디오가 조용히 누락돼서는 안 된다.
- 장시간 회의가 무응답 또는 buffer starvation 때문에 조용히 실패해서는 안 된다.

### Local-first는 명시적 선택이다

- Transcription, Post-processing, Context, Meeting Summary의 backend 선택을 독립적으로 보존한다.
- Local 실패를 이유로 Cloud로 조용히 전환하지 않는다.
- Cloud 사용자도 기존 설정과 fallback을 잃지 않는다.
- 사용자의 데이터가 Mac을 떠나는 시점과 범위를 설명할 수 있어야 한다.

### AI 결과는 검토·수정·근거 확인이 가능해야 한다

- 근거 없는 owner, due date, decision을 사실처럼 만들지 않는다.
- Transcript와 Calendar 텍스트는 instruction이 아니라 source data다.
- 자동 외부 전송은 기본값으로 만들지 않는다.
- Summary, action item, follow-up 초안은 사용자가 승인하기 전까지 초안이다.

### 기존 사용자 선택을 보존한다

- upgrade 직후 활성 기능, 모델, prompt, language, provider가 임의로 바뀌지 않는다.
- 기능 enablement와 backend readiness를 분리한다.
- legacy 선택을 제거할 때는 명시적 수명과 migration을 정의한다.

## #176의 새 정보 구조

#176의 기존 Wave/Phase 혼합 구조를 다음 구조로 교체한다.

### 1. Current Product Baseline

v0.1.28까지 실제 출시된 주요 기능과 근거 이슈·PR을 간결하게 기록한다.

- durable segmented recording recovery
- cloud chunk/retry/resume
- Native Whisper와 Metal contract
- 5-step onboarding
- default Note Browser
- en/ko localization
- Local AI runtime과 Post-processing/Context backend
- Record-only audio notes
- file export와 retranscription recovery
- in-app Meeting Summary
- dedicated Prompts settings

완료된 작업은 현재 실행 목록과 섞지 않는다. `Shipped`, `Accepted risk`, `Inactive path`를 구분한다.

### 2. P0 — Trust & Data Safety

데이터 유실, 개인정보 약속 불일치, 회의 기록 무결성처럼 영향이 치명적인 항목을 둔다.

### 3. P1 — Active Product Failures

현재 사용자가 재현할 수 있는 회귀, 무한 대기, 잘못된 복구 액션, 첫 실행 불일치를 둔다.

### 4. Now — Meeting Follow-through

회의 결과를 실제 후속 행동으로 바꾸는 기능을 둔다.

### 5. Next — Meeting Memory & Capture

기록이 쌓일수록 가치가 커지고, 다음 회의를 놓치지 않도록 돕는 기능을 둔다.

### 6. Later — Advanced Intelligence & Portability

화자·혼합 언어·회의 간 Q&A·선택적 공유·암호화 백업처럼 기반 작업과 수요 확인이 필요한 기능을 둔다.

### 7. Foundation

테스트, diagnostics, domain store 분리, architecture reference처럼 사용자 기능을 안전하게 개발하기 위한 작업을 둔다.

### 8. Needs Decision / Icebox

제품 경계 또는 외부 전제 결정 전에는 구현을 약속하지 않을 항목을 둔다.

## 상태와 라벨 체계

### 상태 의미

- `Planned`: 범위와 acceptance criteria가 정의됨
- `In progress`: 구현 또는 검증이 진행 중
- `Blocked`: 명시된 선행 작업 또는 외부 전제에 차단됨
- `Deferred`: 유효한 기능이지만 현재 시간 범위 밖
- `Needs decision`: 제품 방향 결정이 먼저 필요함
- `Accepted risk`: 문제를 해결한 것이 아니라 현재 위험을 수용함
- `Superseded`: 더 작은 replacement issue로 범위를 이전하고 원래 논의를 보존함
- `Shipped`: 현재 릴리스에 포함되고 검증됨

### GitHub 라벨

기존 `bug`, `enhancement`, `documentation`, `size/*`를 보존하고 다음 라벨을 추가한다.

Priority:

- `priority/p0`
- `priority/p1`
- `priority/p2`
- `priority/p3`

Status:

- `status/blocked`
- `status/needs-decision`
- `status/deferred`
- `status/accepted-risk`

Area:

- `area/reliability`
- `area/recording`
- `area/transcription`
- `area/meeting-notes`
- `area/search`
- `area/calendar`
- `area/privacy`
- `area/platform`
- `area/distribution`

Structure:

- `epic`

목표 날짜가 확정되지 않았으므로 이번 정비에서 milestone은 만들지 않는다. milestone은 실제 릴리스 범위를 확정할 때 별도로 도입한다.

## 기존 열린 이슈 전수 배치

#176 자체를 제외한 현재 열린 이슈 29개를 다음과 같이 배치한다.

### P0 / P1

| 이슈 | 배치 | 조치 |
|---|---|---|
| #240 | P0 epic | history load recovery의 부모로 유지 |
| #241 | P0 | destructive reset과 orphan cleanup을 막는 첫 릴리스 단위 |
| #242 | P0, blocked | #241 이후 archive-and-continue 구현 |
| #243 | P0, blocked | #241과 #242 이후 snapshot restore 구현 |
| #193 | P1, blocked | 최소 #241 이후 retention과 storage cap 구현 |
| #234 | P1 | stale/misleading recovery action 회귀 수정 |
| #214 | P1 | 지속 buffer starvation 감지와 복구 |
| #236 | P1 | Apple Live 중 audio-source dropdown 성능 문제 계측·수정 |
| #195 | P1 | 완료된 localization 항목을 제거하고 현재 Note Browser 상태·검색·접근성 실패에 집중 |
| #188 | P1, externally blocked | outdated README 설명을 제거하고 enrollment·migration 결정에 집중 |

### 사용자 기능

| 이슈 | 배치 | 조치 |
|---|---|---|
| #105 | Next | 자동 녹음이 아닌 confirm-first meeting detection으로 범위 갱신 |
| #136 | Superseded after split | P1 silence-gap padding과 Next global source-switch shortcut replacement를 만든 뒤 원래 논의를 보존하고 종료 |
| #190 | Next | 완료된 #187 blocker와 placeholder를 갱신하고 수동 speaker naming을 포함 |
| #191 | Needs decision | EventKit 구현 약속을 제거하고 Calendar direction decision으로 재정의 |
| #231 | Next epic | runtime 검증, model package, transport, long-form, evaluation으로 분할 |
| #45 | Now | imported-audio metadata를 Meeting Packet과 Note Browser metadata 작업에 연결 |
| #160 | Later epic | portable archive를 첫 단계로 두고 CloudKit/Quill Cloud commitment를 분리 |

### Foundation

| 이슈 | 배치 | 조치 |
|---|---|---|
| #208 | Foundation | Core Data와 AVFoundation test warning 제거 |
| #107 | Foundation | behavior-test 전환 트랙에 연결 |
| #108 | Foundation | #107과 같은 behavior-test 트랙에 연결 |
| #217 | Foundation | 완료된 primitive를 표시하고 legacy controller/WAV consolidation에 집중 |
| #192 | Foundation, blocked | #217 이후 domain-scoped store 분리. 최신 파일 규모로 본문 갱신 |
| #26 | Foundation umbrella | upstream compatibility 목표를 유지하고 #217→#192 실행 순서를 연결 |
| #194 | Foundation | MetricKit, rotating logs, secret-safe diagnostics export |
| #216 | Foundation/documentation | v0.1.28 구조에 맞는 living reference로 갱신 |

### Needs Decision / 정리

| 이슈 | 배치 | 조치 |
|---|---|---|
| #145 | Shipped Baseline | Gemini CLI 제거와 offline smoke를 독립 이슈로 이동한 뒤 출시 완료 epic으로 종료 |
| #71 | Icebox | hosted calendar backend가 현재 제품 경계와 충돌함을 명시 |
| #9 | Needs decision | legacy mlx lifecycle을 maintenance-only로 재정의 |
| #132 | Needs decision | durable audio 해결분을 제거하고 legacy 오류 분류만 #9와 통합 검토 |

### Superseded during refresh

- #136은 두 replacement issue가 생성되고 상호 링크된 뒤 이 섹션에 기록한다.
- 이 섹션은 완료 기능을 뜻하지 않는다. 원래 이슈가 더 명확한 실행 단위로 대체됐음을 추적한다.

## 신규 신뢰성·정합성 이슈

코드 감사와 문서 대조로 확인했으며 기존 이슈와 직접 중복되지 않는 항목이다.

| 배치 | 신규 이슈 |
|---|---|
| P0 | `Exclude Calendar metadata from Cloud Meeting Summary by default` |
| P1 | `Add a final-commit timeout and durable fallback for Realtime transcription` |
| P1 | `Surface degraded microphone/system-audio capture before recording continues` |
| P1 | `Preserve execution metadata when editing a transcript` |
| P1 | `Initialize Note Browser and MCP services after first-run setup` |
| P1 | `Represent Context inference failures as typed state` |
| P1 | `Align Apple Speech privacy claims with enforced on-device behavior` |
| P1 | `Allow Record-only setup without unnecessary microphone permission` |
| P1 | `Migrate provider credentials from settings JSON to Keychain` |
| P1 | `Align README, website, privacy policy, and release notes with v0.1.28` |
| P1, blocked by #243 | `Add a user-visible recovery center for recoverable recordings and notes` |
| Next | `Normalize large imported audio to the durable WAV transcription pipeline` |

각 이슈는 다음 형식을 사용한다.

- User problem
- Current behavior and evidence
- Proposed scope
- Non-goals
- Acceptance criteria
- Dependencies
- Roadmap placement

보안 또는 개인정보 이슈에는 실제 credential, 로컬 인증서 이름, 사용자 홈 경로를 기록하지 않는다.

## Now Epic — Meeting Follow-through

### Epic

`Turn meeting summaries into an actionable follow-through workflow`

### 하위 이슈

1. `Promote extracted action items to persistent, stable entities`
2. `Build an Action Items Inbox across meetings`
3. `Support owner, due date, status, dismissal, and source navigation for action items`
4. `Generate a reviewable Follow-up Pack for email, Slack, and personal checklists`
5. `Export a complete Meeting Packet as Markdown, JSON, clipboard, and Share Sheet`
6. `Allow users to correct and approve Meeting Summary content`

### 범위 원칙

- action item은 Summary JSON의 임시 checkbox에서 안정적인 ID를 가진 도메인 상태로 승격한다.
- Inbox는 완료, 보류, 오탐 무시, 원본 근거 이동을 지원한다.
- Follow-up Pack은 자동 전송하지 않는다.
- Meeting Packet은 title, date, attendees, overview, decisions, action items, open questions, source timestamps를 포함한다.
- Summary 수정은 원본 transcript와 provenance를 보존한다.

## Next Epic — Meeting Memory

### Epic

`Make accumulated meetings useful before and across future meetings`

### 하위 이슈

1. `Add local unified search across transcripts, summaries, decisions, actions, attendees, and questions`
2. `Add date, person, series, and status filters with archive and favorites`
3. `Link recurring meetings into editable meeting series`
4. `Show a privacy-safe pre-meeting briefing card`
5. `Add meeting templates and per-series summary rules`
6. `Add recording bookmarks with optional notes`
7. `Expand custom vocabulary into scoped glossary, aliases, and preferred spelling`
8. `Add explainable recording and note quality checks`

### 의존성

- Action Items entity → briefing의 미완료 작업
- Meeting series → briefing과 series-level rules
- Local unified search → source-grounded cross-meeting Q&A
- 정확한 audio timeline → bookmark와 Soundbite

## Next — Capture Reliability and Accessibility

기존 이슈를 재사용하는 항목:

- #105 confirm-first meeting detection
- #190 speaker diarization and manual naming
- #231 Qwen3-ASR evaluation and integration

신규 이슈:

1. `Support mixed-language transcription with independent summary language`
2. `Add an optional local live-caption overlay`
3. `Add consent wording, pause controls, sensitive-range exclusion, and processing disclosure`

회의 감지는 Zoom, Meet, Teams, Slack Huddle 등의 신호를 사용하더라도 기본적으로 녹음을 시작하지 않는다. 사용자에게 `Record this meeting?`를 표시하고 명시적 승인을 받는다.

## Later — Portability and Advanced Use

1. `Export action items to Apple Reminders through a one-way adapter`
2. `Add source-grounded cross-meeting Q&A after local search`
3. `Create a selected-range audio Soundbite with transcript context`
4. `Attach manual screen snapshots to meeting timestamps`
5. #160 아래에서 encrypted portable archive backup/restore 구현
6. `Explore summary-first shared collections without sharing original audio by default`

첫 task integration은 Apple Reminders의 단방향 export다. 양방향 sync와 여러 provider adapter는 stable action item ID와 idempotency가 검증된 뒤에만 확장한다.

## 명시적으로 제외하는 기능

- 감정 분석, 참여도 점수, 직원 성과 평가
- 사용자 검토 없는 이메일·Slack·task 자동 전송
- 기본 활성화된 자동 녹음
- 항상 켜진 전체 화면·앱 활동 기록
- 회의에서 사용자를 대신해 발언하는 자율 에이전트
- 근거가 없는 범용 조직 지식 Chat
- 초기 단계의 CRM별 영업 코칭과 관리자 대시보드
- 장기 음성 생체 프로필을 통한 자동 신원 추적

## Cloud Meeting Summary와 Calendar 개인정보 정책

현재 공개 개인정보 설명은 Calendar event data를 AI provider에 보내지 않는다고 설명하지만, v0.1.28의 Cloud Meeting Summary prompt는 Calendar title, time, attendees를 포함할 수 있다.

정책은 기존 공개 약속을 보존하는 방향으로 정한다.

- Local Meeting Summary는 Calendar metadata를 사용할 수 있다.
- Cloud Meeting Summary는 Calendar metadata를 기본 제외한다.
- 향후 포함 기능을 제공하려면 전송 범위를 설명하는 별도 명시 동의가 필요하다.
- privacy policy와 실제 코드가 일치한 뒤에만 관련 공개 문구를 확정한다.

## GitHub 적용 순서

1. 모든 명령에 `-R woosublee/quill`을 명시한다.
2. 필요한 priority/status/area/epic 라벨을 생성한다.
3. 각 신규 이슈의 제목, 본문, 댓글까지 검색해 중복을 재확인한다.
4. P0/P1 신규 이슈를 생성한다.
5. Now epic과 하위 이슈를 생성한다.
6. Next epic과 하위 이슈를 생성한다.
7. Later와 Foundation follow-up 이슈를 생성한다.
8. 기존 이슈의 본문, placeholder, blocker, label, 관계를 갱신한다.
9. 분할 대상은 replacement issue와 상호 링크가 준비된 뒤 처리한다.
10. 모든 새 이슈 번호가 확정된 뒤 #176을 마지막에 재작성한다.

## 분할·통합 안전 규칙

- #136은 두 replacement issue 생성 전 닫지 않는다.
- #231은 parent epic을 유지하고 하위 이슈 번호가 생긴 뒤 본문을 갱신한다.
- #145는 residual follow-up 두 개가 생성되고 링크된 뒤에만 닫는다.
- #9와 #132는 legacy 정책 결정 전 닫지 않는다.
- #107과 #108은 기존 논의를 보존하며 공통 behavior-test 트랙에서 함께 표시한다.
- #26, #217, #192는 umbrella와 실행 단계 관계를 명시하되 논의를 합치기 위해 성급히 닫지 않는다.
- #45는 Meeting Packet/metadata 범위가 실제로 대체하기 전까지 열린 상태를 유지한다.

## 오류 처리와 재실행 안전성

- 신규 이슈 생성 결과를 순서대로 기록하고, 재실행 시 제목과 연결 관계를 확인해 중복 생성하지 않는다.
- 권한 부족, rate limit, API 오류가 발생하면 해당 단계에서 중단하고 성공·실패 목록을 보고한다.
- 기존 issue body를 변경하기 전 원문을 로컬 작업 자료로 보존한다.
- 닫기 작업은 replacement 또는 residual issue가 준비된 뒤에만 수행한다.
- GitHub Projects는 현재 token scope로 검증되지 않았으므로 이번 작업의 정본으로 사용하지 않는다.

## 검증 기준

### 이슈 완전성

- 로드맵 정본인 #176 자체를 제외한 작업 시작 시점의 열린 이슈 29개가 Shipped/실행/Needs Decision/Superseded 중 정확히 한 위치에 나타난다.
- #176은 현재 제품 버전, 상태 범례, 실행 순서와 모든 이슈 링크를 제공하는 단일 정본으로 유지된다.
- 신규 이슈도 정확히 한 roadmap horizon에 배치된다.
- 닫힌 이슈가 현재 실행 목록에 남지 않는다.
- epic과 하위 이슈 관계가 본문과 GitHub 관계에서 일치한다.

### 메타데이터

- 모든 열린 실행 이슈에 priority가 있다.
- 모든 이슈에 최소 하나의 area가 있다.
- deferred, blocked, needs-decision, accepted-risk 상태가 본문 표현과 label에서 일치한다.
- placeholder issue reference가 남지 않는다.

### 제품 정합성

- Shipped Baseline이 v0.1.28 코드와 릴리스에 일치한다.
- Local AI, Record-only, Meeting Summary, Prompts가 이미 출시된 기능으로 표시된다.
- #179 같은 위험 수용 항목이 기능 완료로 표현되지 않는다.
- Cloud Summary의 Calendar 정책이 로드맵과 신규 이슈에서 일관된다.
- auto-recording이 committed default처럼 표현되지 않는다.

### 저장소 안전

- 생성·수정한 모든 GitHub URL이 `woosublee/quill`을 가리킨다.
- upstream에는 쓰기 작업이 없다.
- PR 또는 push는 별도 요청 없이는 수행하지 않는다.

## 완료 조건

이번 작업은 다음이 모두 충족되면 완료다.

1. 기존 열린 이슈가 최신 제품 상태에 맞게 분류·갱신된다.
2. 미추적 P0/P1 문제와 승인된 사용자 가치 기능이 중복 없이 이슈화된다.
3. 큰 기능은 epic과 실행 가능한 하위 이슈로 구성된다.
4. #176이 새 정보 구조로 전면 재작성된다.
5. 모든 기존·신규 이슈가 로드맵의 정확히 한 위치에 연결된다.
6. 라벨, dependency, replacement, residual 관계가 검증된다.
7. 생성·수정·종료·보류된 이슈 목록을 링크와 함께 보고한다.

이번 범위에는 기능 코드 구현, 릴리스 버전 변경, 실제 privacy policy 수정, hosted backend 구축이 포함되지 않는다. 해당 작업은 새 로드맵 순서에 따라 별도 설계와 구현 계획으로 진행한다.
