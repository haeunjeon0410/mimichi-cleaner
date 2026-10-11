# Mimichi Cleaner

Windows 디스크 정리 도구입니다. 시스템 드라이브(보통 C)를 분석하여 삭제 가능한 항목, 다른 드라이브로 이동하면 좋은 항목, 건드리면 안 되는 항목을 분류해 보여주며, 사용자가 선택한 항목만 처리합니다.

A Windows disk cleaner written in PowerShell. It scans the system drive, classifies what it finds as *safe to delete*, *worth moving to another drive*, *needs review* or *leave alone*, and only processes the items the user selects. No installer or extra dependencies.

<p align="center">
  <img src="docs/03-result.png" alt="분석 결과 화면" width="720">
</p>

## 기능

- **항목 분류**: 각 항목에 사유를 표시하고 네 가지로 구분합니다.

  | 구분 | 대상 예시 |
  |---|---|
  | 삭제 가능 | 임시 파일, 브라우저·npm·pip 캐시, 휴지통, 사용하지 않는 프로젝트의 `node_modules` |
  | 이동 권장 | 용량이 큰 동영상·사진·압축 파일, 오래된 설치 파일, 용량이 큰 프로젝트 폴더 |
  | 확인 필요 | 용도를 알 수 없는 AppData 폴더 등 |
  | 변경 금지 | Windows, Program Files, Docker/WSL 가상 디스크 등 (선택할 수 없음) |
- **삭제보다 이동**: 큰 파일은 삭제하지 않고 다른 드라이브의 `정리대기` 폴더로 이동합니다.
- **경로 유지**: 폴더를 이동한 뒤 원래 위치에 디렉터리 정션(junction)을 남기므로, 기존 프로그램이 같은 경로로 계속 접근할 수 있습니다.
- **기록**: 분석은 읽기 전용이며, 처리 전 확인을 한 번 더 요청합니다. 모든 작업은 `log.csv`에 기록됩니다.
- **화면**: 창 크기를 조절할 수 있으며, 화면 배율(125%, 150% 등)에 맞게 표시됩니다.
- **의존성 없음**: Windows 기본 포함 PowerShell 5.1만 필요합니다.

| 시작 | 분석 중 | 완료 |
|:---:|:---:|:---:|
| <img src="docs/01-start.png" width="260"> | <img src="docs/02-analyzing.png" width="260"> | <img src="docs/04-done.png" width="260"> |

<p align="center"><img src="docs/animation.png" alt="분석·청소 중 애니메이션" width="640"></p>

## 요구 사항

- Windows 10 / 11
- PowerShell 5.1 (Windows 기본 포함)
- 이동 기능을 사용하려면 시스템 드라이브 외의 고정 드라이브가 필요합니다. 없는 경우 이동 항목은 안내만 표시됩니다.

## 사용 방법

1. 저장소를 내려받습니다 (`Code → Download ZIP` 또는 `git clone`).
2. `Launch.vbs`를 실행합니다. 콘솔 창 없이 프로그램이 열립니다.
3. 바탕화면 바로가기가 필요하면 `Create-Shortcut.ps1`을 PowerShell에서 실행합니다.
4. **드라이브 분석하기**를 누르고, 처리할 항목을 선택한 뒤 **청소 시작**을 누릅니다.

최초 사용 시에는 분석 결과를 먼저 검토하고, 삭제 가능 항목부터 처리하는 것을 권장합니다.

분석에는 환경에 따라 수 분이 소요될 수 있으며, 진행 중인 폴더가 화면에 표시됩니다. 파일 수가 매우 많은 폴더는 측정 시간에 상한을 두며, 이 경우 목록에 "일부만 계산"으로 표시됩니다. 실제 삭제량은 표시된 값보다 클 수 있습니다.

### 실행 옵션

```powershell
powershell -ExecutionPolicy Bypass -File .\MimichiCleaner.ps1 -Dest "E:\Moved" -MinMB 300
```

| 옵션 | 설명 |
|---|---|
| `-Dest <폴더>` | 이동 대상 폴더. 기본값은 시스템 드라이브를 제외한 고정 드라이브 중 여유 공간이 가장 큰 드라이브의 `정리대기` |
| `-MinMB <숫자>` | 큰 파일로 간주할 최소 크기(MB). 기본값 100 |
| `-AutoAnalyze` | 실행 즉시 분석 시작 |

### 글꼴 (선택)

화면 글꼴은 [LINE Seed Sans KR](https://seed.line.me/)을 사용하도록 구성되어 있으며, 라이선스 문제로 저장소에 포함하지 않았습니다. `LINESeedKR-Rg.ttf`, `LINESeedKR-Bd.ttf`를 `fonts/` 폴더에 넣으면 적용되고, 없으면 맑은 고딕으로 표시됩니다.

## 안전 정책

- 삭제 대상은 **삭제 가능 항목에 한정**되며, 캐시·임시 파일(수정 후 2일이 지난 것)·휴지통·`node_modules`입니다. 사용자가 직접 선택한 경우에만 삭제합니다.
- 큰 파일과 폴더는 **삭제하지 않고 이동**합니다. 폴더 이동은 복사 → 파일 수·용량 검증 → 이름 변경 → 정션 생성 → 원본 삭제 순으로 진행하므로, 중간 단계에서 실패해도 원본은 보존됩니다.
- 폴더 내부에 링크가 있거나, 사용 중인 파일이 있거나, 대상 드라이브의 공간이 부족하면 해당 항목은 건너뜁니다.
- 정션은 따라가지 않으므로, 이미 이동한 폴더를 다시 집계하거나 삭제하지 않습니다.
- 청소가 진행되는 동안에는 창을 닫을 수 없습니다.
- 원복: 원래 위치의 정션을 제거(`rmdir <경로>`, 대상 파일은 삭제되지 않음)한 뒤 `정리대기`의 폴더를 원래 위치로 되돌립니다.

> 이 소프트웨어는 파일을 삭제하는 기능을 포함합니다. 중요한 자료는 사전에 백업하고, 처리 전에 목록을 확인하십시오. 사용으로 발생한 손해에 대해 책임지지 않습니다 (MIT License).

## 개발

화면은 PowerShell에서 WinForms를 직접 그려 구현했으며(`MimichiCleaner.ps1`), 폴더 스캔은 C#(`Add-Type`)으로 처리합니다.

```powershell
.\MimichiCleaner.ps1 -SelfTest            # 마우스 이동·최대화·크기 변경을 시뮬레이션하여 화면 동작 점검
.\MimichiCleaner.ps1 -Snapshot out.png    # 예시 데이터로 화면을 PNG로 저장 (-SnapPhase before|analyzing|ready|done)
.\tests\engine.tests.ps1 -Script .\MimichiCleaner.ps1 -Work $env:TEMP   # 임시 사용자 폴더에서 정리·이동 로직 테스트
.\tests\lint.ps1                          # 공용 변수 덮어쓰기 및 기본 명령과의 이름 충돌 점검
```

- PowerShell은 변수 이름의 대소문자를 구분하지 않고, 함수가 호출한 함수의 변수 범위를 그대로 참조합니다. 또한 `lp`(Out-Printer)와 같은 기본 별칭은 동일한 이름의 함수보다 우선 실행됩니다. `tests/lint.ps1`은 이러한 충돌을 점검합니다.
- 예기치 않은 오류는 오류 창을 표시하지 않고 `error.log`에 기록됩니다.

## 고지

본 프로젝트는 비영리 팬 작품입니다. 미미치(みみっち)는 다마고치 시리즈의 캐릭터이며 © Bandai의 소유입니다. 본 프로젝트는 Bandai와 제휴 관계가 없으며 승인을 받지 않았습니다. 권리자의 요청이 있을 경우 해당 이미지를 삭제합니다.

## 라이선스

코드는 [MIT License](LICENSE)를 따릅니다. 캐릭터와 글꼴의 권리는 각 권리자에게 있습니다.
