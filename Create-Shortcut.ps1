# 바탕화면에 "미미 청소 도우미" 바로가기를 만들어요 (아이콘은 처음 한 번 만들어져요)
$root = $PSScriptRoot
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'MimichiCleaner.ps1') -MakeIcon
$desk = [Environment]::GetFolderPath('Desktop')
$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut((Join-Path $desk '미미 청소 도우미.lnk'))
$lnk.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
$lnk.Arguments = '"' + (Join-Path $root 'Launch.vbs') + '"'
$lnk.WorkingDirectory = $root
$ico = Join-Path $root 'mimi.ico'
if (Test-Path $ico) { $lnk.IconLocation = $ico }
$lnk.Description = '미미 청소 도우미'
$lnk.Save()
"바탕화면에 바로가기를 만들었어요: $($lnk.FullName)"