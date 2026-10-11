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
$Dest = Join-Path $Work "fakedest_$id"
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
Check "파일이 정리대기로 이동" ($r -eq $true -and -not [IO.File]::Exists("$UserHome\Videos\a.mp4") -and [IO.File]::Exists("$Dest\Videos\a.mp4"))
Mk "$UserHome\Videos\b.mp4" 100; Mk "$Dest\Videos\b.mp4" 50
$r = Move-OneFile "$UserHome\Videos\b.mp4"
Check "이름이 겹치면 덮어쓰지 않고 이름 변경해서 이동" ($r -eq $true -and [IO.File]::Exists("$Dest\Videos\b.mp4") -and (Get-ChildItem "$Dest\Videos" -Filter '*_b.mp4').Count -eq 1)
Check "없는 파일은 실패로 처리" ((Move-OneFile "$UserHome\nope.txt") -eq $false)

"[3] Move-FolderWithJunction (정상)"
$p = "$UserHome\Desktop\proj"
Mk "$p\a.txt" 2000; Mk "$p\sub\b.bin" 300000; Mk "$p\sub\deep\c.txt" 10
$msg = Move-FolderWithJunction $p
Check "성공 메시지 없음 (msg='$msg')" ($msg -eq '')
$item = Get-Item -LiteralPath $p -Force
Check "원래 경로가 링크(정션)로 남음" (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
Check "링크를 통해 원본 파일이 그대로 보임" ([IO.File]::Exists("$p\sub\b.bin") -and [IO.File]::Exists("$p\sub\deep\c.txt"))
Check "실제 파일은 정리대기에 있음" ([IO.File]::Exists("$Dest\Desktop\proj\sub\b.bin"))
Check "옛 폴더(.mimichi-old) 남지 않음" (-not [IO.Directory]::Exists("$p.mimichi-old"))
Check "로그 기록됨" ((Get-Content $LogFile -Raw) -match 'move\+junction')
"[3b] 다시 분석하면 링크는 따라가지 않아요"
$w = New-Walk "$UserHome\Desktop"
Check "링크 안 파일을 C 용량으로 세지 않음 (count=$($w.Count), links=$($w.Links))" ($w.Count -eq 0 -and $w.Links -eq 1)
$msg = Move-FolderWithJunction $p
Check "이미 링크인 폴더는 건너뜀 ('$msg')" ($msg -like '*이미 연결된*')

"[4] 거절/안전 케이스"
$q = "$UserHome\Documents\withlink"
Mk "$q\x.txt" 10; Mk "$UserHome\other\y.txt" 10
New-Item -ItemType Junction -Path "$q\inner" -Target "$UserHome\other" | Out-Null
$msg = Move-FolderWithJunction $q
Check "폴더 안에 링크가 있으면 건너뜀 ('$msg')" ($msg -like '*링크*' -and [IO.File]::Exists("$q\x.txt") -and -not [IO.Directory]::Exists("$Dest\Documents\withlink"))
$msg = Move-FolderWithJunction "$Work"
Check "사용자 폴더 밖은 건너뜀 ('$msg')" ($msg -like '*밖*')

$lk = "$UserHome\Documents\locked"
Mk "$lk\held.txt" 100; Mk "$lk\free.txt" 100
$fs = [IO.File]::Open("$lk\held.txt", 'Open', 'ReadWrite', 'None')
$msg = Move-FolderWithJunction $lk
$fs.Close()
Check "사용 중인 파일이 있으면 원본을 그대로 두고 실패 ('$msg')" ($msg -ne '' -and [IO.File]::Exists("$lk\held.txt") -and [IO.File]::Exists("$lk\free.txt") -and -not ((Get-Item -LiteralPath $lk -Force).Attributes -band [IO.FileAttributes]::ReparsePoint))
Check "실패 후 정리대기에 반쪽 복사본이 남지 않음" (-not [IO.Directory]::Exists("$Dest\Documents\locked"))
$msg2 = Move-FolderWithJunction $lk
Check "프로그램을 닫은 뒤 다시 하면 성공 ('$msg2')" ($msg2 -eq '' -and ((Get-Item -LiteralPath $lk -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)

"[5] Remove-Tree (node_modules 삭제, 링크는 링크만 지움)"
$nm = "$UserHome\Desktop\app\node_modules"
Mk "$nm\pkg\index.js" 100; Mk "$UserHome\keepme\important.txt" 10
New-Item -ItemType Junction -Path "$nm\linked" -Target "$UserHome\keepme" | Out-Null
Remove-Tree $nm
Check "node_modules 삭제됨" (-not [IO.Directory]::Exists($nm))
Check "링크가 가리키던 폴더의 파일은 안전" ([IO.File]::Exists("$UserHome\keepme\important.txt"))

"결과: PASS $ok / FAIL $bad"
# 정리 (링크는 링크만 지워요)
foreach ($l in "$UserHome\Desktop\proj", "$UserHome\Documents\locked", "$UserHome\Documents\withlink\inner") { if ([IO.Directory]::Exists($l)) { try { [IO.Directory]::Delete($l) } catch { } } }
try { [IO.Directory]::Delete($UserHome, $true); [IO.Directory]::Delete($Dest, $true) } catch { "cleanup note: $_" }
