# Native Whisper timestamp decoding 및 자동 언어 감지 수정 설계

## 배경

Quill의 Native Whisper 경로는 번들된 `whisper-cli`에 `-nt -mc 0`을 항상 전달한다. `-nt`는 출력에서 시간 표시만 숨기는 옵션이 아니라 timestamp token 생성을 비활성화하고, whisper.cpp가 오디오를 30초 고정 단위로 이동하게 만든다.

실제 저장된 135초 오디오를 같은 모델과 한국어 설정으로 비교했을 때 현재 옵션(`-nt -mc 0`)은 473자를 전사했고, `-nt`만 제거한 옵션(`-mc 0`)은 623자를 전사했다. 따라서 이번 수정은 모델, threshold, VAD, 오디오 변환을 바꾸지 않고 확인된 두 호출 인자 문제만 해결한다.

또한 Quill은 `Auto Detect`를 선택하면 언어 인자를 생략한다. Legacy mlx-whisper는 언어 생략을 자동 감지로 처리하지만, 번들된 whisper.cpp v1.9.1 CLI의 기본 언어는 `en`이다. Native Whisper에서는 언어 생략이 자동 감지가 아니라 영어 고정으로 동작한다.

## 목표

1. Native Whisper가 timestamp 기반 seek를 사용하도록 `-nt`를 제거한다.
2. `Auto Detect` 선택 시 Native Whisper에 `-l auto`를 명시한다.
3. 기존의 window 간 text context 정책인 `-mc 0`은 유지한다.
4. Legacy mlx-whisper, 모델, VAD, threshold, 오디오 변환, JSON 파싱은 변경하지 않는다.
5. Meeting Summary와 Post-processing 품질 문제는 코드 수정 범위에서 제외하고 별도 GitHub 이슈로 기록한다.

## 비목표

- 이전 text context를 활성화하지 않는다.
- timestamp나 context 옵션을 Settings에 노출하지 않는다.
- Whisper 모델 또는 quantization을 변경하지 않는다.
- silence/no-speech threshold를 조정하지 않는다.
- Meeting Summary 또는 Post-processing 코드를 수정하지 않는다.
- 실제 사용자 오디오나 대형 모델을 자동 테스트 fixture로 추가하지 않는다.

## 접근법

### 선택: Native runtime 인자만 최소 수정

`NativeWhisperRuntime.transcribe`의 argument 배열에서 `-nt`를 제거한다. 언어 값이 비어 있거나 `nil`이면 Native runtime이 `auto`를 기본값으로 사용해 항상 `-l <language>`를 전달한다.

예상 인자는 다음과 같다.

```text
-m <model>
-f <audio>
-mc 0
-oj
-of <output>
-l ko        # 명시 언어
```

또는:

```text
-l auto      # Auto Detect
```

`TranscriptionLanguage.whisperArgument`는 Legacy mlx-whisper에서도 사용되므로 의미를 전역으로 변경하지 않는다. Legacy에서는 기존처럼 Auto일 때 `--language`를 생략해야 한다. Native runtime 내부의 기본값 처리만 수정해 두 backend의 서로 다른 CLI 의미를 분리한다.

## 데이터 흐름

### 명시 언어

```text
TranscriptionLanguage(code: "ko")
→ whisperArgument == "ko"
→ NativeWhisperRuntime(languageCode: "ko")
→ whisper-cli -l ko
```

### 자동 언어 감지

```text
TranscriptionLanguage.auto
→ whisperArgument == nil
→ NativeWhisperRuntime(languageCode: nil)
→ whisper-cli -l auto
```

### timestamp decoding

```text
기존: -nt → no-timestamps token → 30초 고정 seek
수정: -nt 없음 → timestamp token 사용 → 인식된 발화 위치 기반 seek
```

## 오류 처리

기존 오류 처리를 그대로 유지한다.

- runner 없음
- 모델 없음
- 오디오 읽기 실패
- process non-zero exit
- JSON과 stdout 모두 빈 결과

이번 변경은 process argument만 수정하므로 오류 타입과 사용자 메시지를 변경하지 않는다.

## 테스트 설계

`Tests/NativeWhisperRuntimeTests.swift`의 helper script 기반 argument 검증을 보강한다.

1. Native argument에 `-nt`와 `--no-timestamps`가 없음을 검증한다.
2. `-mc` 다음 값이 계속 `0`인지 검증한다.
3. 명시 언어 `ko`가 `-l ko`로 전달되는지 검증한다.
4. `languageCode: nil`이 `-l auto`로 전달되는지 검증한다.
5. GPU disable 인자가 추가되지 않았는지 기존 검증을 유지한다.
6. JSON top-level `text` 및 `transcription[].text` 파싱 테스트를 유지한다.
7. `make native-whisper-helper-test`와 `make test-transcription`을 실행한다.

대형 모델 A/B는 저장소 자동 테스트에서 제외한다. 개인 오디오, 설치된 모델, 긴 실행 시간에 의존하기 때문이다. 구현 검증 근거로 기존 수동 A/B 결과를 사용하되, 회귀 방지는 argument contract 테스트가 담당한다.

## Meeting Summary 및 Post-processing 후속 이슈

별도 코드 변경 없이 `woosublee/quill`에 영어 GitHub 이슈 하나를 생성한다.

권장 제목:

> Investigate Meeting Summary and post-processing quality regressions

이슈는 쉬운 설명을 우선하고 다음 내용을 포함한다.

### 사용자 영향

- Meeting Summary와 Post-processing 품질 문제로 현재 두 기능을 꺼 두고 사용 중이다.
- 이후 실제 오류 사례를 같은 이슈에 추가해 코드 구조와 함께 비교할 필요가 있다.

### 처리 흐름

```text
raw transcript
→ Post-processing
→ postProcessedTranscript
→ Meeting Summary
```

### 확인된 코드 동작

- Meeting Summary 초기 설정이 Post-processing backend/model/fallback/output language를 상속한다.
- 준비된 선택이면 Meeting Summary가 자동 활성화될 수 있다.
- Local backend에는 cloud fallback이 없다.
- Meeting Summary는 raw보다 processed transcript를 우선 사용한다.
- `Preserve exact wording` 경로가 제거되어 Post-processing이 켜져 있으면 일반 cleanup이 실행된다.
- 12,000자를 넘는 transcript는 overlap 없는 문자 기준 chunk로 나뉘고, partial JSON 결과만 최종 merge에 전달된다.

### 단정하지 않을 내용

위 구조가 품질 저하를 만들 가능성은 있지만, 실제 오류 사례와 동일 입력 A/B 없이 특정 모델이나 단계가 원인이라고 단정하지 않는다. 확인된 동작과 검증이 필요한 가설을 명확히 분리한다.

### 이후 오류에 함께 기록할 정보

- Quill/Quill Dev 및 앱 버전
- Post-processing과 Summary의 backend/model
- 기능 활성화 여부
- raw transcript가 정상인지
- processed transcript부터 달라졌는지
- Summary만 잘못됐는지
- 짧은 회의인지 12,000자를 넘는 긴 회의인지
- `meetingSummaryJSON`의 model ID, backend kind, source fingerprint
- 재현 단계와 기대 결과/실제 결과

### 검증 매트릭스

1. 동일 raw + Post-processing OFF/ON
2. 동일 raw + Cloud/Local Post-processing
3. 동일 source + Cloud/Local Summary
4. 12,000자 이하/이상 Summary
5. raw source와 processed source 비교

### 완료 조건

- 품질 저하가 처음 발생하는 단계를 raw, processed, summary 중 하나로 특정한다.
- backend/model 선택이 UI와 저장된 metadata에서 명확히 확인된다.
- 동일 입력 A/B 또는 semantic golden fixture로 회귀를 재현한다.
- 수정 범위를 Post-processing, Summary routing, source 선택, chunking 중 하나로 좁힌다.

## 구현 범위

예상 변경 파일:

- `Sources/NativeWhisperRuntime.swift`
- `Tests/NativeWhisperRuntimeTests.swift`

필요한 경우 argument contract를 검사하는 기존 source-level 테스트만 최소 수정한다. 관련 없는 리팩터링은 하지 않는다.

## 검증 기준

- 모든 관련 테스트가 통과한다.
- Native runtime 인자에 `-nt`가 없다.
- Native runtime 인자에는 항상 `-l`이 있고 Auto는 `auto`다.
- `-mc 0`은 유지된다.
- Legacy mlx-whisper 인자는 변경되지 않는다.
- Meeting Summary/Post-processing 코드에는 변경이 없다.
