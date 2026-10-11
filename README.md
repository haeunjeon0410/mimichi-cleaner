# 🐰 Mimichi Cleaner · 미미치 청소 도우미

픽셀 캐릭터 **미미**가 도와주는 Windows 디스크 정리 도구예요.
C 드라이브가 꽉 찼을 때 **"지워도 되는 것 / 다른 드라이브로 옮기면 좋은 것 / 건드리면 위험한 것"** 을 알아서 나눠서 보여주고,
**내가 체크한 것만** 정리해 줘요.

> A tiny pixel-art disk cleaner for Windows. It scans your system drive, sorts what it finds into
> *safe to delete / worth moving to another drive / leave alone*, and only touches what you tick.
> No installer, no dependencies — just the PowerShell that ships with Windows.

<p align="center">
  <img src="docs/03-result.png" alt="분석 결과 화면" width="720">
</p>

## 특징

- **분류해서 보여줘요** — 항목마다 이유를 붙여서 4가지로 나눠요.
  | 구분 | 예시 |
  |---|---|
  | 🟢 삭제해도 돼요 | 임시파일, 브라우저/npm/pip 캐시, 휴지통, 안 쓰는 프로젝트의 `node_modules` |
  | 🔵 다른 드라이브로 옮기면 좋아요 | 큰 동영상·사진·압축파일, 오래된 설치 파일, 용량 큰 프로젝트 폴더 |
  | 🟡 직접 확인이 필요해요 | 어떤 프로그램 건지 모르는 AppData 폴더 등 |
  | 🔴 건드리면 위험해요 | Windows, Program Files, Docker/WSL 가상 디스크 등 (체크 자체가 안 돼요) |
- **지우기보다 옮기기** — 큰 파일은 지우지 않고 다른 드라이브의 `정리대기` 폴더로 옮겨요.
- **프로젝트 폴더도 안 깨져요** — 폴더를 옮기고 원래 자리에 *연결(정션)* 을 남겨서, 프로그램이 같은 경로로 계속 접근해요.
- **미리 보고, 확인하고, 기록해요** — 분석은 읽기만 해요. 체크한 항목만 한 번 더 물어본 뒤 진행하고, 모든 작업은 `log.csv`에 남아요.
- **창 크기 조절·고해상도 대응** — 화면 배율(125%, 150% …)에서도 선명하게 보이고, 창을 늘리면 목록도 같이 늘어나요.
- **설치할 게 없어요** — 윈도우에 기본으로 들어있는 PowerShell 5.1 하나면 돼요.

| 시작 | 분석 중 | 청소 끝 |
|:---:|:---:|:---:|
| <img src="docs/01-start.png" width="260"> | <img src="docs/02-analyzing.png" width="260"> | <img src="docs/04-done.png" width="260"> |

미미는 분석·청소하는 동안 빗자루로 쓱쓱 쓸고, 끝나면 신나서 뛰어요 (`docs/animation.png`).

<p align="center"><img src="docs/animation.png" alt="미미가 빗자루로 청소하는 모습" width="640"></p>

## 사용법

1. 이 저장소를 내려받아요 (`Code → Download ZIP` 또는 `git clone`).
2. **`Launch.vbs`를 더블클릭**하면 창이 떠요. (검은 터미널 창은 안 떠요)
3. 바탕화면 아이콘이 필요하면 `Create-Shortcut.ps1`을 우클릭 → *PowerShell에서 실행*.
4. **드라이브 분석하기** → 목록에서 정리할 항목을 체크 → **청소 시작!**

처음 쓸 때는 *분석*만 해 보고 목록을 훑어본 다음, 🟢 항목부터 정리하는 걸 추천해요.

### 옵션

PowerShell에서 직접 실행하면 옵션을 줄 수 있어요.

```powershell
powershell -ExecutionPolicy Bypass -File .\MimichiCleaner.ps1 -Dest "E:\Moved" -MinMB 300
```

| 옵션 | 설명 |
|---|---|
| `-Dest <폴더>` | 파일을 옮겨 둘 곳. 기본값은 *시스템 드라이브가 아닌 드라이브 중 여유 공간이 가장 큰 곳*의 `정리대기` |
| `-MinMB <숫자>` | 이 크기(MB) 이상이면 "큰 파일"로 봐요 (기본 100) |
| `-AutoAnalyze` | 실행하자마자 분석을 시작해요 |

다른 드라이브가 하나도 없으면 *옮기기* 항목은 안내만 보여주고 체크할 수 없게 돼요.

### 폰트 (선택)

화면 글꼴은 [LINE Seed Sans KR](https://seed.line.me/)를 쓰도록 만들었어요. 라이선스 때문에 저장소에는 넣지 않았어요.
`LINESeedKR-Rg.ttf`, `LINESeedKR-Bd.ttf` 를 내려받아 `fonts/` 폴더에 넣으면 적용돼요. 없으면 *맑은 고딕*으로 보여요.

## 안전하게 쓰기 위한 약속

- **삭제하는 것은 🟢 항목뿐**이에요: 캐시·임시파일(만든 지 2일 넘은 것만)·휴지통·`node_modules`. 직접 체크해야만 지워요.
- 큰 파일/폴더는 **지우지 않고 옮겨요.** 폴더는 *복사 → 개수·용량 확인 → 연결 만들기 → 원본 정리* 순서라서, 중간에 실패해도 원본은 그대로예요.
- 폴더 안에 연결(링크)이 있거나, 쓰는 프로그램이 있거나, 옮길 드라이브 공간이 모자라면 **건너뛰어요.**
- 폴더 연결(정션)은 따라가지 않아요. 이미 옮겨 둔 폴더를 다시 세거나 지우지 않아요.
- 청소하는 동안에는 창을 닫을 수 없어요.
- 되돌리고 싶으면: 원래 자리의 연결을 지우고(`rmdir <경로>`, 파일은 안 지워져요) `정리대기`의 폴더를 되돌려 놓으면 돼요.

> ⚠️ 디스크 정리 도구는 결국 파일을 지우는 도구예요. 중요한 자료는 백업해 두고, 처음엔 목록을 꼼꼼히 읽어 보세요.
> 사용으로 생긴 문제에 대해 책임지지 않아요 (MIT 라이선스).

## 만든 방법 / 개발

- 화면은 WinForms를 PowerShell에서 직접 그렸어요 (`MimichiCleaner.ps1` 하나). 폴더 스캔은 C#(`Add-Type`)로 빠르게 해요.
- 점검용 옵션
  ```powershell
  .\MimichiCleaner.ps1 -SelfTest                    # 마우스/최대화/크기 변경을 흉내 내서 화면 동작 점검
  .\MimichiCleaner.ps1 -Snapshot out.png            # 예시 데이터로 화면을 PNG로 저장 (-SnapPhase before|analyzing|ready|done)
  .\tests\engine.tests.ps1 -Script .\MimichiCleaner.ps1 -Work $env:TEMP   # 가짜 사용자 폴더에서 정리/이동 로직 테스트
  ```
- 오류가 나면 창에 오류 창이 뜨는 대신 `error.log`에 남아요.

## 알림

이 프로젝트는 취미로 만든 팬 작품이에요. 미미치(みみっち)는 다마고치 시리즈의 캐릭터로 © Bandai 소유이며,
이 프로젝트는 Bandai와 관련이 없고 승인받은 것도 아니에요. 도트 그림은 직접 다시 그린 팬아트이고, 저작권자의 요청이 있으면 내릴게요.

## 라이선스

코드는 [MIT License](LICENSE)예요. (캐릭터와 폰트는 각 권리자의 것이에요.)
