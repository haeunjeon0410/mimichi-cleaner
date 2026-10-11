# 바탕화면에 바로가기 생성 (아이콘은 최초 1회 생성)
$root = $PSScriptRoot
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'MimichiCleaner.ps1') -MakeIcon
$desk = [Environment]::GetFolderPath('Desktop')
$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut((Join-Path $desk '미미치 청소 도우미.lnk'))
$lnk.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
$lnk.Arguments = '"' + (Join-Path $root 'Launch.vbs') + '"'
$lnk.WorkingDirectory = $root
$ico = Join-Path $root 'mimi.ico'
if (Test-Path $ico) { $lnk.IconLocation = $ico }
$lnk.Description = '미미치 청소 도우미'
$lnk.Save()
"바로가기 생성 완료: $($lnk.FullName)"