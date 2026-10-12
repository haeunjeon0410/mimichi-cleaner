param([string]$Script, [string]$Work)
# 엔진 함수만 떼어서 "가짜 사용자 폴더"에서 테스트해요 (실제 데이터는 건드리지 않아요)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$src = Get-Content $Script -Raw -Encoding UTF8
$cs = [regex]::Match($src, "(?s)Add-Type -ReferencedAssemblies.*?\r?\n'@").Value
Invoke-Expression $cs
$eng = [regex]::Match($src, '(?s)# ---------- 청소 엔진 ----------.*?(?=# ---------- 화면)').Value
function Pump { }
function GB($b) { [math]::Round($b / 1GB, 2) }
$id = [guid]::NewGuid().ToString('N').Substring(0, 6)
$UserHome = Join-Path $Work "fakehome_$id"
$Dest = Join-Path $Work "fakedest_$id"; $script:IsAdmin = $true
$LogFile = Join-Path $Dest 'log.csv'
[void][IO.Directory]::CreateDirectory($UserHome)
Invoke-Expression $eng
$ok = 0; $bad = 0
function Check($name, $cond) { if ($cond) { $script:ok++; "  PASS  $name" } else { $script:bad++; "  FAIL  $name" } }
function Mk($path, $bytes) { [void][IO.Directory]::CreateDirectory((Split-Path $path)); [IO.File]::WriteAllBytes($path, (New-Object byte[] $bytes)) }

"[1] Clear-Dir (2일 넘은 것만)"
$t = "$UserHome\temp1"
Mk "$t\old.tmp" 5000; Mk "$t\sub\old2.tmp" 3000; Mk "$t\new.tmp" 1000
[IO.File]::SetLastWriteTime("$t\old.tmp", (Get-Date).AddDays(-5)); [IO.File]::SetLastWriteTime("$t\sub\old2.tmp", (Get-Date).AddDays(-5))
$freed = Clear-Dir $t 2
Check "오래된 파일만 지움 (freed=$freed)" ($freed -eq 8000 -and -not [IO.File]::Exists("$t\old.tmp") -and [IO.File]::Exists("$t\new.tmp"))
Check "비어 버린 하위 폴더 정리" (-not [IO.Directory]::Exists("$t\sub"))

"[2] Move-OneFile"
Mk "$UserHome\Videos\a.mp4" 4000
$r = Move-OneFile "$UserHome\Videos\a.mp4"
Check "파일이 같은 경로로 이동" ($r -eq $true -and -not [IO.File]::Exists("$UserHome\Videos\a.mp4") -and [IO.File]::Exists((Dest-Path "$UserHome\Videos\a.mp4")))
Mk "$UserHome\Videos\b.mp4" 100; Mk (Dest-Path "$UserHome\Videos\b.mp4") 50
$r = Move-OneFile "$UserHome\Videos\b.mp4"
Check "이름이 겹치면 덮어쓰지 않고 이름 변경해서 이동" ($r -eq $true -and [IO.File]::Exists((Dest-Path "$UserHome\Videos\b.mp4")) -and (Get-ChildItem (Split-Path (Dest-Path "$UserHome\Videos\b.mp4")) -Filter '*_b.mp4').Count -eq 1)
Check "없는 파일은 실패로 처리" ((Move-OneFile "$UserHome\nope.txt") -eq $false)

"[3] Move-FolderWithJunction (정상)"
$p = "$UserHome\Desktop\proj"
Mk "$p\a.txt" 2000; Mk "$p\sub\b.bin" 300000; Mk "$p\sub\deep\c.txt" 10
$msg = Move-FolderWithJunction $p
Check "성공 메시지 없음 (msg='$msg')" ($msg -eq '')
$item = Get-Item -LiteralPath $p -Force
Check "원래 경로가 링크(정션)로 남음" (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
Check "링크를 통해 원본 파일이 그대로 보임" ([IO.File]::Exists("$p\sub\b.bin") -and [IO.File]::Exists("$p\sub\deep\c.txt"))
Check "실제 파일은 대상 드라이브의 같은 경로에 있음" ([IO.File]::Exists((Dest-Path "$p\sub\b.bin")))
Check "옛 폴더(.mimichi-old) 남지 않음" (-not [IO.Directory]::Exists("$p.mimichi-old"))
Check "로그 기록됨" ((Get-Content $LogFile -Raw) -match 'move\+junction')
"[3b] 다시 분석하면 링크는 따라가지 않아요"
$w = New-Walk "$UserHome\Desktop"
Check "링크 안 파일을 C 용량으로 세지 않음 (count=$($w.Count), links=$($w.Links))" ($w.Count -eq 0 -and $w.Links -eq 1)
$msg = Move-FolderWithJunction $p
Check "이미 링크인 폴더는 건너뜀 ('$msg')" ($msg -like '*이미 정션*')

"[4] 거절/안전 케이스"
$q = "$UserHome\Documents\withlink"
Mk "$q\x.txt" 10; Mk "$UserHome\other\y.txt" 10
New-Item -ItemType Junction -Path "$q\inner" -Target "$UserHome\other" | Out-Null
$msg = Move-FolderWithJunction $q
Check "폴더 안에 링크가 있으면 건너뜀 ('$msg')" ($msg -like '*링크*' -and [IO.File]::Exists("$q\x.txt") -and -not [IO.Directory]::Exists((Dest-Path $q)))
$msg = Move-FolderWithJunction "$env:SystemRoot\Fonts"
Check "Windows 폴더는 건너뜀 ('$msg')" ($msg -like '*Windows*')
$script:IsAdmin = $false
$msg = Move-FolderWithJunction "$env:SystemDrive\Program Files"
Check "관리자가 아니면 Program Files는 건너뜀 ('$msg')" ($msg -like '*관리자*')
$script:IsAdmin = $true

$lk = "$UserHome\Documents\locked"
Mk "$lk\held.txt" 100; Mk "$lk\free.txt" 100
$fs = [IO.File]::Open("$lk\held.txt", 'Open', 'ReadWrite', 'None')
$msg = Move-FolderWithJunction $lk
$fs.Close()
Check "사용 중인 파일이 있으면 원본을 그대로 두고 실패 ('$msg')" ($msg -ne '' -and [IO.File]::Exists("$lk\held.txt") -and [IO.File]::Exists("$lk\free.txt") -and -not ((Get-Item -LiteralPath $lk -Force).Attributes -band [IO.FileAttributes]::ReparsePoint))
Check "실패 후 대상에 반쪽 복사본이 남지 않음" (-not [IO.Directory]::Exists((Dest-Path $lk)))
$msg2 = Move-FolderWithJunction $lk
Check "프로그램을 닫은 뒤 다시 하면 성공 ('$msg2')" ($msg2 -eq '' -and ((Get-Item -LiteralPath $lk -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)

"[5] Remove-Tree (node_modules 삭제, 링크는 링크만 지움)"
$nm = "$UserHome\Desktop\app\node_modules"
Mk "$nm\pkg\index.js" 100; Mk "$UserHome\keepme\important.txt" 10
New-Item -ItemType Junction -Path "$nm\linked" -Target "$UserHome\keepme" | Out-Null
Remove-Tree $nm
Check "node_modules 삭제됨" (-not [IO.Directory]::Exists($nm))
Check "링크가 가리키던 폴더의 파일은 안전" ([IO.File]::Exists("$UserHome\keepme\important.txt"))


"[6] 병렬 스캔(BatchScan)은 순차 스캔과 같은 결과"
$pr = "$UserHome\parallel"
foreach ($i in 1..12) { Mk "$pr\d$i\f$i.bin" (1000 * $i); Mk "$pr\d$i\sub\g.bin" 77 }
New-Item -ItemType Junction -Path "$pr\d3\lnk" -Target "$UserHome\keepme" | Out-Null
$seq = @(1..12 | ForEach-Object { (New-Walk "$pr\d$_").Total })
$ws = @(1..12 | ForEach-Object { New-W "$pr\d$_" })
$b = [BatchScan]::new([Walker[]]$ws, 6); $t0 = Get-Date; while (-not $b.Done -and ((Get-Date) - $t0).TotalSeconds -lt 20) { Start-Sleep -Milliseconds 20 }
Check "병렬 12개가 모두 끝남 (완료 $($b.Completed))" ($b.Done -and $b.Completed -eq 12)
Check "병렬 결과 == 순차 결과" ((($ws | ForEach-Object { $_.Total }) -join ',') -eq ($seq -join ','))
Check "빈 목록도 바로 끝남" ([BatchScan]::new([Walker[]]@(), 6).Done)
Check "시간 상한이 동작 (WinSxS를 0.05초만 훑으면 Truncated)" ((New-Walk "$env:SystemRoot\WinSxS" -maxSec 0.05).Truncated)
[IO.Directory]::Delete("$pr\d3\lnk")

"[7] OneDrive 폴더는 옮기지 않아요"
Mk "$UserHome\OneDrive\Docs\a.txt" 10
$msg = Move-FolderWithJunction "$UserHome\OneDrive\Docs"
Check "OneDrive 폴더 건너뜀 ('$msg')" ($msg -like '*OneDrive*' -and [IO.File]::Exists("$UserHome\OneDrive\Docs\a.txt") -and -not [IO.Directory]::Exists((Dest-Path "$UserHome\OneDrive\Docs")))
"[8] 시작 프로그램 끄기 (임시 레지스트리 경로에서만 시험, 실제 설정은 건드리지 않음)"
$rk = "HKCU:\Software\MimichiTest_$id"
$script:StartupKeys = @(@{ Admin = $false; Run = "$rk\Run"; Appr = "$rk\Appr" }, @{ Admin = $true; Run = "$rk\RunAdmin"; Appr = "$rk\ApprAdmin" })
[void](New-Item "$rk\Run" -Force); [void](New-Item "$rk\RunAdmin" -Force)
foreach ($n in @(@('SteamX', '"C:\Steam\steam.exe" -silent'), @('SunJavaUpdateSched', 'C:\Java\jusched.exe'), @('RtkAudUService', 'C:\Windows\System32\DriverStore\x\rtk.exe'),
                 @('MyScript', 'powershell.exe -File C:\a.ps1'), @('AhnLabTray', 'C:\AhnLab\a.exe'), @('Unknown1', 'C:\Foo\foo.exe'))) { Set-ItemProperty "$rk\Run" -Name $n[0] -Value $n[1] }
Set-ItemProperty "$rk\RunAdmin" -Name 'LGUpdater' -Value 'C:\LG\up.exe'
$ents = @(Get-StartupEntries)
Check "등록된 7개를 모두 읽음 (읽은 수 $($ents.Count))" ($ents.Count -eq 7 -and @($ents | Where-Object Enabled).Count -eq 7)
$cls = @{}; foreach ($x in $ents) { $cls[$x.Name] = Classify-Startup $x }
Check "런처·업데이트 알림은 끄기 대상" ($cls['SteamX'] -eq 'off' -and $cls['SunJavaUpdateSched'] -eq 'off' -and $cls['LGUpdater'] -eq 'off')
Check "드라이버·보안·직접 만든 스크립트는 그대로 둠" ($cls['RtkAudUService'] -eq 'keep' -and $cls['AhnLabTray'] -eq 'keep' -and $cls['MyScript'] -eq 'keep')
Check "모르는 프로그램은 건드리지 않음" ($null -eq $cls['Unknown1'])
$steam = $ents | Where-Object Name -eq 'SteamX'
$r = Set-StartupDisabled $steam
$after = @(Get-StartupEntries | Where-Object Name -eq 'SteamX')[0]
Check "끄면 '사용 안 함'으로 바뀜 (msg='$r')" ($r -eq '' -and -not $after.Enabled)
Check "프로그램 등록 값은 그대로 남음 (삭제 아님)" ((Get-ItemProperty "$rk\Run").SteamX -eq '"C:\Steam\steam.exe" -silent')
Check "작업 관리자 형식(첫 바이트 3 + 12바이트)으로 기록" ((Get-ItemProperty "$rk\Appr").SteamX[0] -eq 3 -and (Get-ItemProperty "$rk\Appr").SteamX.Length -eq 12)
$script:IsAdmin = $false
$r = Set-StartupDisabled (Get-StartupEntries | Where-Object Name -eq 'LGUpdater')
Check "관리자가 아니면 시스템 전체 항목은 건너뜀 ('$r')" ($r -like '*관리자*' -and @(Get-StartupEntries | Where-Object { $_.Name -eq 'LGUpdater' -and $_.Enabled }).Count -eq 1)
$script:IsAdmin = $true
$r = Set-StartupDisabled (Get-StartupEntries | Where-Object Name -eq 'LGUpdater')
Check "관리자면 시스템 전체 항목도 끔 (msg='$r')" ($r -eq '' -and -not @(Get-StartupEntries | Where-Object Name -eq 'LGUpdater')[0].Enabled)
Remove-Item $rk -Recurse -Force

"[9] 게임 녹화 끄기 / 메모리 사용 목록 (임시 레지스트리 경로에서만 시험)"
$gk = "HKCU:\Software\MimichiTest9_$id"
$script:GameDvr = @{ Store = "$gk\Store"; Capture = "$gk\Capture" }
[void](New-Item "$gk\Store" -Force); Set-ItemProperty "$gk\Store" -Name GameDVR_Enabled -Value 1 -Type DWord
Check "켜져 있으면 끄기 대상으로 인식" (Test-GameDvrOn)
$r = Set-GameDvrOff
Check "끄면 꺼진 상태가 됨 (msg='$r')" ($r -eq '' -and -not (Test-GameDvrOn) -and (Get-ItemProperty "$gk\Capture").AppCaptureEnabled -eq 0)
Check "이미 꺼져 있으면 대상 아님" (-not (Test-GameDvrOn))
Remove-Item $gk -Recurse -Force
$mt = @(Get-MemoryTop 3)
Check "메모리 상위 프로그램을 큰 순서로 돌려줌 ($(($mt | ForEach-Object Name) -join ','))" ($mt.Count -eq 3 -and $mt[0].Bytes -ge $mt[1].Bytes -and $mt[1].Bytes -ge $mt[2].Bytes -and $mt[0].Name -notmatch '^svchost$')
"결과: PASS $ok / FAIL $bad"
# 정리 (링크는 링크만 지워요)
foreach ($l in "$UserHome\Desktop\proj", "$UserHome\Documents\locked", "$UserHome\Documents\withlink\inner") { if ([IO.Directory]::Exists($l)) { try { [IO.Directory]::Delete($l) } catch { } } }
try { [IO.Directory]::Delete($UserHome, $true); [IO.Directory]::Delete($Dest, $true) } catch { "cleanup note: $_" }
