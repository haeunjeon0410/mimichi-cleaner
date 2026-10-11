param([string]$Script = (Join-Path $PSScriptRoot '..\MimichiCleaner.ps1'))
# PowerShell 변수는 대소문자를 구분하지 않고, 호출한 함수의 변수가 그대로 보이는 "동적 범위"예요.
# 그래서 함수 안에서 `$c = ...` 처럼 쓰면 색상표 `$C` 를 가려서, 그 함수가 부르는 다른 함수가 엉뚱한 값을 읽게 돼요.
# 이 점검은 "공용으로 쓰는 변수 이름"을 함수 안에서 덮어쓰는 곳이 없는지 찾아요.
$protected = 'C', 'DL', 'SL', 'Sc', 'Dest', 'UserHome', 'LogFile', 'MinMB', 'Pal', 'Brush', 'form', 'canvas', 'lv', 'tips',
             'Grid', 'GridHappy', 'rAn', 'rCl', 'rRes', 'rFoot', 'rTip', 'rIllus', 'rList', 'rCardC'

$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $Script), [ref]$null, [ref]$null)
function Get-VarName($node) {
    if ($node -is [System.Management.Automation.Language.ConvertExpressionAst]) { $node = $node.Child }
    if ($node -is [System.Management.Automation.Language.VariableExpressionAst] -and -not $node.VariablePath.IsScript -and -not $node.VariablePath.IsGlobal) { return $node.VariablePath.UserPath }
    $null
}
$problems = @()
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    $names = @()
    foreach ($a in $fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) { $v = Get-VarName $a.Left; if ($v) { $names += $v } }
    foreach ($fe in $fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) { $names += $fe.Variable.VariablePath.UserPath }
    foreach ($p in $fn.Parameters) { $names += $p.Name.VariablePath.UserPath }
    if ($fn.Body.ParamBlock) { foreach ($p in $fn.Body.ParamBlock.Parameters) { $names += $p.Name.VariablePath.UserPath } }
    foreach ($n in ($names | Sort-Object -Unique)) {
        if ($protected -contains $n) { $problems += "{0}() 안에서 공용 변수 `${1} 를 덮어써요" -f $fn.Name, $n }
    }
}
# 함수 이름이 PowerShell 기본 별칭/명령과 겹치면 별칭이 먼저 실행돼요 (예: lp = Out-Printer)
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    $clash = Get-Command $fn.Name -All -ErrorAction SilentlyContinue | Where-Object { $_.CommandType -ne 'Function' }
    if ($clash) { $problems += "함수 이름 $($fn.Name) 이(가) 기본 명령과 겹쳐요: $(($clash | ForEach-Object { $_.CommandType.ToString() + ':' + $_.Name }) -join ', ')" }
}
if ($problems) { $problems; "FAIL: $($problems.Count)건"; exit 1 } else { "PASS: 변수/함수 이름 충돌 없음" }
