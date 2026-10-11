# Mimichi Cleaner

Windows 디스크 정리 도구. 시스템 드라이브 분석 후 항목 분류, 선택 항목만 처리.

<p align="center"><img src="docs/03-result.png" alt="분석 결과" width="720"></p>

## 기능

- 분석 결과 4단계 분류: 삭제 가능 / 이동 권장 / 확인 필요 / 변경 금지
- 삭제 대상: 임시 파일, 캐시, 휴지통, `node_modules`
- 이동 대상: 대용량 파일·폴더. 삭제 없이 다른 드라이브로 이동
- 폴더 이동 시 원래 위치에 정션 생성. 기존 경로 유지
- 작업 이력 `log.csv` 기록
- 창 크기 조절, 화면 배율 대응
- 추가 설치 없음. Windows 기본 PowerShell 5.1만 사용

| 시작 | 분석 중 | 완료 |
|:---:|:---:|:---:|
| <img src="docs/01-start.png" width="260"> | <img src="docs/02-analyzing.png" width="260"> | <img src="docs/04-done.png" width="260"> |

## 요구 사항

- Windows 10 / 11
- PowerShell 5.1
- 이동 기능: 시스템 드라이브 외 고정 드라이브 1개 이상

## 사용

1. 저장소 다운로드
2. `Launch.vbs` 실행
3. 바탕화면 바로가기: `Create-Shortcut.ps1` 실행
4. 드라이브 분석 → 항목 선택 → 청소 시작

분석 소요 시간: 환경에 따라 수 분. 대용량 폴더는 측정 시간 상한 적용, 목록에 "일부만 계산" 표시.

## 옵션

```powershell
powershell -ExecutionPolicy Bypass -File .\MimichiCleaner.ps1 -Dest "E:\Moved" -MinMB 300
```

| 옵션 | 설명 | 기본값 |
|---|---|---|
| `-Dest` | 이동 대상 폴더 | 여유 공간이 가장 큰 비시스템 드라이브의 `정리대기` |
| `-MinMB` | 대용량 파일 기준(MB) | 100 |
| `-AutoAnalyze` | 실행 즉시 분석 | - |

## 안전 정책

- 삭제: 사용자가 선택한 삭제 가능 항목에 한정
- 파일·폴더: 삭제 대신 이동
- 폴더 이동 절차: 복사 → 검증 → 이름 변경 → 정션 생성 → 원본 삭제. 단계별 실패 시 원본 보존
- 건너뜀 조건: 내부 링크 존재, 사용 중인 파일, 대상 드라이브 공간 부족
- 청소 진행 중 창 닫기 차단
- 원복: 정션 제거(`rmdir <경로>`) 후 `정리대기` 폴더를 원위치로 이동

중요 자료는 사전 백업 권장. 사용에 따른 손해 책임 없음.

## 글꼴

[LINE Seed Sans KR](https://seed.line.me/) 사용. 라이선스상 저장소 미포함. `fonts/`에 `LINESeedKR-Rg.ttf`, `LINESeedKR-Bd.ttf` 배치 시 적용, 미배치 시 맑은 고딕.

## 개발

```powershell
.\MimichiCleaner.ps1 -SelfTest            # 화면 동작 점검
.\MimichiCleaner.ps1 -Snapshot out.png    # 화면 PNG 저장
.\tests\engine.tests.ps1 -Script .\MimichiCleaner.ps1 -Work $env:TEMP
.\tests\lint.ps1                          # 변수·함수 이름 충돌 점검
```

## 고지

비영리 팬 작품. 미미치(みみっち)는 다마고치 시리즈 캐릭터로 © Bandai 소유이며, 본 프로젝트와 무관. 권리자 요청 시 이미지 삭제.

## 라이선스

[MIT](LICENSE)
