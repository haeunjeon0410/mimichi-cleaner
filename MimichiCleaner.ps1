<#
  미미치 청소 도우미 (Mimichi Cleaner)
  픽셀 캐릭터가 도와주는 Windows 디스크 정리 도구.
  - 시스템 드라이브(보통 C)에서 삭제 가능 항목과 이동 권장 항목을 분류하여 표시하고,
    사용자가 선택한 항목만 처리합니다. 파일은 삭제 대신 이동하는 것을 기본으로 합니다.
  - Windows 기본 PowerShell 5.1만 필요하며 별도 설치가 없습니다.

  실행 옵션:
    -Dest <폴더>   이동 대상 폴더 (기본: 시스템 드라이브 외 드라이브 중 여유 공간이 가장 큰 드라이브의 '정리대기')
    -MinMB <숫자>  대용량 파일 기준 크기(MB) (기본 100)
    -MakeIcon      아이콘(mimi.ico)만 생성하고 종료
    -AutoAnalyze   실행 즉시 분석 시작
    -Zoom <배율>   화면 크기 배율 (기본 0.8, 범위 0.5~2.0)
    -SelfTest      마우스·최대화·크기 변경을 시뮬레이션하여 화면 동작 점검 후 종료 (개발용)
#>
param(
    [string]$Dest = '',
    [int]$MinMB = 100,
    [double]$Zoom = 0.8,
    [switch]$MakeIcon,
    [switch]$AutoAnalyze,
    [switch]$SelfTest,
    [string]$Snapshot,
    [string]$SnapPhase = 'ready',
    [int]$SnapFrame = 3,
    [int]$SnapW = 0,
    [int]$SnapH = 0
)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
# 예기치 않은 오류는 오류 창 대신 error.log에 기록
[Windows.Forms.Application]::SetUnhandledExceptionMode([Windows.Forms.UnhandledExceptionMode]::CatchException)
[Windows.Forms.Application]::add_ThreadException([Threading.ThreadExceptionEventHandler]{
    param($sender, $e)
    try { Add-Content -Path (Join-Path $PSScriptRoot 'error.log') -Value ("{0}  {1}" -f (Get-Date -Format s), $e.Exception.Message) -Encoding UTF8 } catch { }
})

Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.IO;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class MimiCanvas : Control {
    public MimiCanvas() {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
    }
    // 창 가장자리 입력은 부모 창이 처리하도록 위임 (크기 조절)
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x84) {
            Form f = FindForm();
            if (f != null && f.WindowState == FormWindowState.Normal) {
                int lp = m.LParam.ToInt32();
                Point p = f.PointToClient(new Point((short)(lp & 0xFFFF), (short)((lp >> 16) & 0xFFFF)));
                int g = 7;
                if (p.X < g || p.Y < g || p.X >= f.ClientSize.Width - g || p.Y >= f.ClientSize.Height - g) { m.Result = (IntPtr)(-1); return; }
            }
        }
        base.WndProc(ref m);
    }
}
public class MimiForm : Form {
    public void SetMaxBounds(Rectangle r) { MaximizedBounds = r; }   // 최대화해도 작업표시줄을 가리지 않게
    protected override CreateParams CreateParams { get { CreateParams cp = base.CreateParams; cp.Style |= 0x20000; return cp; } }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x84 && WindowState == FormWindowState.Normal) {
            int lp = m.LParam.ToInt32();
            Point p = PointToClient(new Point((short)(lp & 0xFFFF), (short)((lp >> 16) & 0xFFFF)));
            int g = 7; bool l = p.X < g, r = p.X >= ClientSize.Width - g, t = p.Y < g, b = p.Y >= ClientSize.Height - g;
            if (t && l) { m.Result = (IntPtr)13; return; }
            if (t && r) { m.Result = (IntPtr)14; return; }
            if (b && l) { m.Result = (IntPtr)16; return; }
            if (b && r) { m.Result = (IntPtr)17; return; }
            if (l) { m.Result = (IntPtr)10; return; }
            if (r) { m.Result = (IntPtr)11; return; }
            if (t) { m.Result = (IntPtr)12; return; }
            if (b) { m.Result = (IntPtr)15; return; }
        }
        base.WndProc(ref m);
    }
}
// 폴더 스캐너: 링크(정션/심볼릭) 미추적, 시간 분할(Step) 실행으로 화면 정지 방지.
// 폴더 열거 시 함께 반환되는 크기·수정일 정보를 재사용 (파일별 재조회 없음).
public class Walker {
    Stack<string> dirs = new Stack<string>();
    Stack<int> depths = new Stack<int>();
    List<string> visited = new List<string>();
    string root;
    public long Total, Freed, MinBytes, OlderThanTicks;   // OlderThanTicks: 0이면 모든 파일
    public int Count, Links, MaxDepth = 99, MaxMs;          // MaxMs: 0이면 시간 제한 없음
    public bool Done, Delete, Truncated;                    // Truncated: 시간 제한 때문에 일부만 센 경우
    Stopwatch total = Stopwatch.StartNew();
    public string FindDirName;
    public HashSet<string> Exts;
    public HashSet<string> Exclude = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    public List<string> BigPaths = new List<string>(), ExtPaths = new List<string>(), FoundDirs = new List<string>();
    public List<long> BigSizes = new List<long>(), ExtSizes = new List<long>();

    public Walker(string path) {
        root = path;
        if (Directory.Exists(path)) { dirs.Push(path); depths.Push(0); } else Done = true;
    }
    public void Step(int budgetMs) {
        Stopwatch sw = Stopwatch.StartNew();
        while (dirs.Count > 0 && sw.ElapsedMilliseconds < budgetMs) {
            if (MaxMs > 0 && total.ElapsedMilliseconds > MaxMs) { Truncated = true; dirs.Clear(); depths.Clear(); break; }
            string d = dirs.Pop(); int depth = depths.Pop();
            if (Exclude.Contains(d)) continue;
            if (Delete) visited.Add(d);
            DirectoryInfo di = new DirectoryInfo(d);
            FileInfo[] files = null;
            try { files = di.GetFiles(); } catch { }
            if (files != null) {
                foreach (FileInfo fi in files) {
                    try {
                        long len = fi.Length;
                        bool old = OlderThanTicks <= 0 || fi.LastWriteTimeUtc.Ticks < OlderThanTicks;
                        if (Delete) {
                            if (old) { try { fi.Attributes = FileAttributes.Normal; fi.Delete(); Freed += len; } catch { } }
                            continue;
                        }
                        Count++;
                        if (old) Total += len;
                        if (MinBytes > 0 && len >= MinBytes) { BigPaths.Add(fi.FullName); BigSizes.Add(len); }
                        if (Exts != null && old && Exts.Contains(fi.Extension.ToLowerInvariant())) { ExtPaths.Add(fi.FullName); ExtSizes.Add(len); }
                    } catch { }
                }
            }
            DirectoryInfo[] subs = null;
            try { subs = di.GetDirectories(); } catch { }
            if (subs != null) {
                foreach (DirectoryInfo s in subs) {
                    try { if ((s.Attributes & FileAttributes.ReparsePoint) != 0) { Links++; continue; } } catch { continue; }
                    if (FindDirName != null && string.Equals(s.Name, FindDirName, StringComparison.OrdinalIgnoreCase)) { FoundDirs.Add(s.FullName); continue; }
                    if (depth + 1 > MaxDepth) continue;
                    dirs.Push(s.FullName); depths.Push(depth + 1);
                }
            }
        }
        if (dirs.Count == 0 && !Done) {
            Done = true;
            if (Delete) {   // 비어 있는 폴더 정리 (깊은 폴더부터)
                visited.Sort(delegate(string a, string b) { return b.Length.CompareTo(a.Length); });
                foreach (string v in visited) {
                    if (v == root) continue;
                    try { if (Directory.GetFileSystemEntries(v).Length == 0) Directory.Delete(v); } catch { }
                }
            }
        }
    }
}
public static class Gfx {
    [DllImport("user32.dll")] static extern bool ReleaseCapture();
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int msg, int w, int l);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")] static extern int GetDeviceCaps(IntPtr dc, int idx);
    public static void DragWindow(IntPtr h) { ReleaseCapture(); SendMessage(h, 0xA1, 2, 0); }
    public static float DpiScale() {
        try { SetProcessDPIAware(); } catch { }
        IntPtr dc = GetDC(IntPtr.Zero); int dpi = GetDeviceCaps(dc, 88); ReleaseDC(IntPtr.Zero, dc);
        if (dpi < 96) dpi = 96; return dpi / 96f;
    }
    public static GraphicsPath Round(float x, float y, float w, float h, float r) {
        GraphicsPath p = new GraphicsPath(); float d = r * 2;
        if (d > w) d = w; if (d > h) d = h;
        p.AddArc(x, y, d, d, 180, 90); p.AddArc(x + w - d, y, d, d, 270, 90);
        p.AddArc(x + w - d, y + h - d, d, d, 0, 90); p.AddArc(x, y + h - d, d, d, 90, 90);
        p.CloseFigure(); return p;
    }
    public static void Card(Graphics g, float x, float y, float w, float h, float r, Color fill, Color border, int shadow) {
        for (int i = shadow; i >= 1; i--) {
            using (GraphicsPath p = Round(x - i, y - i + 4, w + 2 * i, h + 2 * i, r + i))
            using (SolidBrush b = new SolidBrush(Color.FromArgb(5, 40, 110, 80))) g.FillPath(b, p);
        }
        using (GraphicsPath p = Round(x, y, w, h, r)) {
            using (SolidBrush b = new SolidBrush(fill)) g.FillPath(b, p);
            using (Pen pen = new Pen(border, 1.2f)) g.DrawPath(pen, p);
        }
    }
    public static Region RoundRegion(int w, int h, int r) { using (GraphicsPath p = Round(0, 0, w, h, r)) return new Region(p); }
}
'@
$Zoom = [math]::Min(2.0, [math]::Max(0.5, $Zoom))   # 기본 화면 크기 배율 (1.0 = 설계 크기)
$Sc = [Gfx]::DpiScale() * $Zoom

$ErrorActionPreference = 'SilentlyContinue'
$UserHome = $env:USERPROFILE
$SL = $env:SystemDrive.TrimEnd(':')          # 정리할 드라이브 (보통 C)
$script:closing = $false
$script:frame = 0
$script:prog = 0.0
$script:filling = $false

# 이동 대상: 미지정 시 시스템 드라이브 외 고정 드라이브 중 여유 공간이 가장 큰 드라이브
if (-not $Dest) {
    $disk = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Where-Object { $_.DeviceID.TrimEnd(':') -ne $SL } |
        Sort-Object FreeSpace -Descending | Select-Object -First 1
    if ($disk) { $Dest = Join-Path ($disk.DeviceID + '\') '정리대기' }
}
$script:DestOK = [bool]$Dest
$DL = '?'; if ($Dest) { $DL = $Dest.Substring(0, 1).ToUpper() }
$LogFile = $null; if ($Dest) { $LogFile = Join-Path $Dest 'log.csv' }

# ---------- 폰트 (fonts 폴더의 LINE Seed Sans KR을 프로세스 내에서만 사용, 없으면 맑은 고딕) ----------
$script:pfc = New-Object Drawing.Text.PrivateFontCollection
foreach ($ff in 'LINESeedKR-Rg.ttf', 'LINESeedKR-Bd.ttf') {
    $fp = Join-Path $PSScriptRoot "fonts\$ff"
    if (Test-Path $fp) { $script:pfc.AddFontFile($fp) }
}
$script:Fams = @{}
foreach ($fm in $script:pfc.Families) { $script:Fams[$fm.Name] = $fm }
$script:FamName = @{ 'Regular' = 'LINE Seed Sans KR Regular'; 'Bold' = 'LINE Seed Sans KR Bold' }
function Mk-Font($size, $weight = 'Regular', $scale = 1) {
    $fam = $script:Fams[$script:FamName[$weight]]
    $px = [single]($size * 96 / 72 * $scale)
    if ($fam) { New-Object Drawing.Font($fam, $px, [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel) }
    else {
        $st = [Drawing.FontStyle]::Regular; if ($weight -eq 'Bold') { $st = [Drawing.FontStyle]::Bold }
        New-Object Drawing.Font('Malgun Gothic', $px, $st, [Drawing.GraphicsUnit]::Pixel)
    }
}
function HexC($h) { [Drawing.ColorTranslator]::FromHtml($h) }
function GB($b) { [math]::Round($b / 1GB, 2) }
function Pump { [Windows.Forms.Application]::DoEvents(); if ($script:closing) { throw 'closing' } }

# ---------- 픽셀 캐릭터 (미미치) ----------

$Grid = @(
    '..........oooo................oooo..........',
    '........oooohooo............ooohhooo........',
    '.......ohoheeeeeo..........ohhoeeeeeo.......',
    '.......oheeeeeeeo..........oheeeeeeeo.......',
    '......ohheeeeeeeeo........ooheeeeeeeeo......',
    '......oheeeeeeeeeo........ooeeeeeeeeeo......',
    '......oheeeeeeeeeo........ooeeeeeeeeeo......',
    '......ooheeeeeeeeeo......ohoeeeeeeeeeo......',
    '.......oheeeeeeeeeo......oheeeeeeeeeo.......',
    '.......oheeeeeeeeeo......oheeeeeeeeeo.......',
    '.......ohoeeeeeeeeo......ooeeeeeeeeeo.......',
    '........oheeeeeeeeeo....ooheeeeeeeeo........',
    '........ohheeeeeeeeo....ooeeeeeeeeeo........',
    '.........oheeeeeeeeeooooooeeeeeeeeo.........',
    '.........oheeeeeeeehhhhooeeeeeeeeeo.........',
    '........ohheeeeeeeeeeeeeeeeeeeeeeeeo........',
    '........oheeeeeeeeeeeeeeeeeeeeeeeeeo........',
    '........oheeeeeeeeeeeeeeeeeeeeeeeeeo........',
    '.......ooheeeeeeeeeeeeeeeeeeeeeeeeeeo.......',
    '.......ooeeeeeeeeeeeeeeeeeeeeeeeeeeeo.......',
    '.......oooooooooooooooooooooooooooooo.......',
    '......owwwwwwwwwwwwwwwwwwwwwwwwwwwwwSo......',
    '......owwwwwwwwwwwwwwwwwwwwwwwwwwwwwSo......',
    '......owwwwwoowwwwwwwwwwwwwwwwoowwwwSo......',
    '.....owwwwwoooowwwwwwwwwwwwwwoooowwwwSo.....',
    '.....owwwwwoooowwwwwwwwwwwwwwoooowwwwSo.....',
    '.....owwwwwwoowwwwwwwwwwwwwwwwoowwwwwSo.....',
    '.....owwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwSo.....',
    '....owwwwpppwwwwwwwwwwwwwwwwwwwwpppwwwSo....',
    '...oowwwpppppwwwwwwwwwwwwwwwwwwpppppwwSoo...',
    '..owowwwpppppwwwwwwwwwwwwwwwwwwpppppwwSoSo..',
    '.owwowwwpppppwwwwwowwoowwowwwwwpppppwwSowSo.',
    'owwwowwwwpppwwwwwwwoowwoowwwwwwwpppwwwSowwSo',
    'owwwowwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwSowwSo',
    'owwwowwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwSowwSo',
    '.owwowwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwSowSo.',
    '..oo.owwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwSo.oo..',
    '.....owwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwSo.....',
    '......owwwwwwwwwwwwwwwwwwwwwwwwwwwwwSo......',
    '......owwwwwwwwwwwwwwwwwwwwwwwwwwwwwSo......',
    '.......oSwwwwwwwwwwwwwwwwwwwwwwwwwwSo.......',
    '........oSSwwwwwwwwwwwwwwwwwwwwwwSSo........',
    '.........oowwwwwwwwwwwwwwwwwwwwwwoo.........',
    '........owwoooooooooooooooooooooowwo........',
    '........owwwwwwwo..........owwwwwwwo........',
    '........owwwwwwwo..........owwwwwwwo........',
    '.........owwwwwo............owwwwwo.........',
    '..........ooooo..............ooooo..........'
)
$GridHappy = @(
    '..........oooo................oooo..........',
    '........oooohooo............ooohhooo........',
    '.......ohoheeeeeo..........ohhoeeeeeo.......',
    '.......oheeeeeeeo..........oheeeeeeeo.......',
    '......ohheeeeeeeeo........ooheeeeeeeeo......',
    '......oheeeeeeeeeo........ooeeeeeeeeeo......',
    '......oheeeeeeeeeo........ooeeeeeeeeeo......',
    '......ooheeeeeeeeeo......ohoeeeeeeeeeo......',
    '.......oheeeeeeeeeo......oheeeeeeeeeo.......',
    '.......oheeeeeeeeeo......oheeeeeeeeeo.......',
    '.......ohoeeeeeeeeo......ooeeeeeeeeeo.......',
    '........oheeeeeeeeeo....ooheeeeeeeeo........',
    '........ohheeeeeeeeo....ooeeeeeeeeeo........',
    '.........oheeeeeeeeeooooooeeeeeeeeo.........',
    '.........oheeeeeeeehhhhooeeeeeeeeeo.........',
    '........ohheeeeeeeeeeeeeeeeeeeeeeeeo........',
    '........oheeeeeeeeeeeeeeeeeeeeeeeeeo........',
    '........oheeeeeeeeeeeeeeeeeeeeeeeeeo........',
    '.......ooheeeeeeeeeeeeeeeeeeeeeeeeeeo.......',
    '.......ooeeeeeeeeeeeeeeeeeeeeeeeeeeeo.......',
    '.......oooooooooooooooooooooooooooooo.......',
    '......owwwwwwwwwwwwwwwwwwwwwwwwwwwwwSo......',
    '......owwwwwwwwwwwwwwwwwwwwwwwwwwwwwSo......',
    '......owwwwwwwwwwwwwwwwwwwwwwwwwwwwwSo......',
    '.....owwwwwwoowwwwwwwwwwwwwwwwoowwwwwSo.....',
    '.....owwwwwowwowwwwwwwwwwwwwwowwowwwwSo.....',
    '.....owwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwSo.....',
    '.....owwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwSo.....',
    '....owwwwpppwwwwwwwwwwwwwwwwwwwwpppwwwSo....',
    '...oowwwpppppwwwwwwwwwwwwwwwwwwpppppwwSoo...',
    '..owowwwpppppwwwwwwwwwwwwwwwwwwpppppwwSoSo..',
    '.owwowwwpppppwwwwwowwoowwowwwwwpppppwwSowSo.',
    'owwwowwwwpppwwwwwwwoowwoowwwwwwwpppwwwSowwSo',
    'owwwowwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwSowwSo',
    'owwwowwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwSowwSo',
    '.owwowwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwSowSo.',
    '..oo.owwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwSo.oo..',
    '.....owwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwSo.....',
    '......owwwwwwwwwwwwwwwwwwwwwwwwwwwwwSo......',
    '......owwwwwwwwwwwwwwwwwwwwwwwwwwwwwSo......',
    '.......oSwwwwwwwwwwwwwwwwwwwwwwwwwwSo.......',
    '........oSSwwwwwwwwwwwwwwwwwwwwwwSSo........',
    '.........oowwwwwwwwwwwwwwwwwwwwwwoo.........',
    '........owwoooooooooooooooooooooowwo........',
    '........owwwwwwwo..........owwwwwwwo........',
    '........owwwwwwwo..........owwwwwwwo........',
    '.........owwwwwo............owwwwwo.........',
    '..........ooooo..............ooooo..........'
)

$Pal = @{ 'o' = '#000054'; 'w' = '#ffffff'; 'e' = '#33331b'; 'h' = '#6b7f63'; 'p' = '#f4b6c2'; 'S' = '#dfe4f0'
          'd' = '#6f9a86'; 'f' = '#fbfffc'; 'l' = '#bfd9ca'; 'g' = '#b08f45'; 'y' = '#f7dc92'; 'z' = '#ebc572'; 'c' = '#a5c9b8' }
# 장식 도트 (문서 / 폴더 / 구름)
$GridDoc = @(
    'dddddddd..',
    'dffffffdd.',
    'dffffffdfd',
    'dffffffddd',
    'dfllllfffd',
    'dffffffffd',
    'dfllllllfd',
    'dffffffffd',
    'dfllllfffd',
    'dffffffffd',
    'dfllllllfd',
    'dffffffffd',
    'dddddddddd'
)
$GridFolder = @(
    '..gggg........',
    '.gyyyyg.......',
    'gggggggggggggg',
    'gyyyyyyyyyyyyg',
    'gyyyyyyyyyyyyg',
    'gyyyyyyyyyyyyg',
    'gyzzzzzzzzzzyg',
    'gyyyyyyyyyyyyg',
    'gyyyyyyyyyyyyg',
    'gggggggggggggg'
)
$GridCloud = @(
    '....ccc.......',
    '...cfffc.ccc..',
    '..cfffffcfffc.',
    '.cfffffffffffc',
    'cffffffffffffc',
    '.cfffffffffffc',
    '..ccccccccccc.'
)

$Brush = @{}
foreach ($k in $Pal.Keys) { $Brush[$k] = New-Object Drawing.SolidBrush (HexC $Pal[$k]) }

function Draw-Grid($g, $rows, $unit, $ox, $oy) {
    $prev = $g.SmoothingMode; $g.SmoothingMode = 'None'
    for ($y = 0; $y -lt $rows.Count; $y++) {
        $row = $rows[$y]
        for ($x = 0; $x -lt $row.Length; $x++) {
            $chr = [string]$row[$x]
            if ($chr -ne '.') { $g.FillRectangle($Brush[$chr], [single]($ox + $x * $unit), [single]($oy + $y * $unit), [single]$unit, [single]$unit) }
        }
    }
    $g.SmoothingMode = $prev
}
# 도트 그림은 비트맵으로 1회 생성 후 프레임마다 복사 (성능)
function New-Sprite($rows, $unit) {
    $bmp = New-Object Drawing.Bitmap ($rows[0].Length * $unit), ($rows.Count * $unit)
    $g = [Drawing.Graphics]::FromImage($bmp); Draw-Grid $g $rows $unit 0 0; $g.Dispose()
    $bmp
}
function Draw-Sprite($g, $bmp, $x, $y) {
    $im = $g.InterpolationMode; $po = $g.PixelOffsetMode
    $g.InterpolationMode = 'NearestNeighbor'; $g.PixelOffsetMode = 'Half'
    $g.DrawImage($bmp, [single]$x, [single]$y, [single]$bmp.Width, [single]$bmp.Height)
    $g.InterpolationMode = $im; $g.PixelOffsetMode = $po
}
$SprMimi = New-Sprite $Grid 3; $SprHappy = New-Sprite $GridHappy 3
$SprDoc = New-Sprite $GridDoc 3; $SprFolder = New-Sprite $GridFolder 3; $SprCloud = New-Sprite $GridCloud 3

function Make-Icon($path) {
    $bmp = New-Object Drawing.Bitmap 64, 64
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.Clear([Drawing.Color]::Transparent)
    Draw-Grid $g $Grid 1 10 8
    $g.Dispose()
    $ic = [Drawing.Icon]::FromHandle($bmp.GetHicon())
    $fs = [IO.File]::Create($path)
    $ic.Save($fs); $fs.Close()
}
$IcoPath = Join-Path $PSScriptRoot 'mimi.ico'
if ($MakeIcon -or -not (Test-Path $IcoPath)) { Make-Icon $IcoPath }
if ($MakeIcon) { exit }

$BrC = @{}; $PnC = @{}
function Br($h) { if (-not $BrC[$h]) { $BrC[$h] = New-Object Drawing.SolidBrush (HexC $h) }; $BrC[$h] }
function Pn($h, $w = 1) { $k = "$h/$w"; if (-not $PnC[$k]) { $p = New-Object Drawing.Pen (HexC $h), $w; $p.LineJoin = 'Round'; $p.StartCap = 'Round'; $p.EndCap = 'Round'; $PnC[$k] = $p }; $PnC[$k] }

function Draw-Star($g, $cx, $cy, $r, $fillHex, $lineHex) {
    $prev = $g.SmoothingMode; $g.SmoothingMode = 'AntiAlias'
    $k = $r * 0.3
    $pts = [Drawing.PointF[]]@(
        (New-Object Drawing.PointF($cx, ($cy - $r))), (New-Object Drawing.PointF(($cx + $k), ($cy - $k))),
        (New-Object Drawing.PointF(($cx + $r), $cy)), (New-Object Drawing.PointF(($cx + $k), ($cy + $k))),
        (New-Object Drawing.PointF($cx, ($cy + $r))), (New-Object Drawing.PointF(($cx - $k), ($cy + $k))),
        (New-Object Drawing.PointF(($cx - $r), $cy)), (New-Object Drawing.PointF(($cx - $k), ($cy - $k)))
    )
    if ($fillHex) { $g.FillPolygon((Br $fillHex), $pts) }
    if ($lineHex) { $g.DrawPolygon((Pn $lineHex 1.6), $pts) }
    $g.SmoothingMode = $prev
}

# 빗자루: 캐릭터와 동일한 3px 도트. 막대는 외곽선 있는 도트 계단, 솔은 줄무늬 스프라이트
$GridBroomHead = @(
    '...kkkkkkk...',
    '..kbbbbbbbk..',
    '.kaanaaanaak.',
    '.kaanaaanaak.',
    'kaaanaaanaaak',
    'kmmmmmmmmmmmk',
    '.kkkkkkkkkkk.'
)
$BroomPal = @{ 'k' = '#7a5224'; 'b' = '#b9802e'; 'a' = '#f4cf72'; 'm' = '#d9a441'; 'n' = '#e6b955' }
function Draw-Broom($g, $bx, $by, $tx, $ty) {
    $prev = $g.SmoothingMode; $g.SmoothingMode = 'None'
    $u = 3
    $xb = [math]::Round($bx / $u) * $u
    $topY = $by - 15
    $n = [math]::Max(2, [int][math]::Ceiling(($topY - $ty) / $u))
    for ($r = $n; $r -ge 0; $r--) {
        $y = $topY - $r * $u
        $xc = [math]::Round(($xb + ($tx - $xb) * ($r / $n)) / $u) * $u
        $g.FillRectangle((Br '#7a5224'), [single]($xc - $u), [single]$y, [single]($u * 3), [single]$u)
        $g.FillRectangle((Br '#d19a55'), [single]$xc, [single]$y, [single]$u, [single]$u)
    }
    for ($ry = 0; $ry -lt $GridBroomHead.Count; $ry++) {
        $row = $GridBroomHead[$ry]
        for ($cx = 0; $cx -lt $row.Length; $cx++) {
            $ch = [string]$row[$cx]
            if ($ch -ne '.') { $g.FillRectangle((Br $BroomPal[$ch]), [single]($xb - 6 * $u + $cx * $u), [single]($by - 15 + $ry * $u), [single]$u, [single]$u) }
        }
    }
    $g.SmoothingMode = $prev
}

# ---------- 청소 애니메이션 ----------
# 쓸기 1회 = 14프레임. 쓸 때마다 캐릭터가 뛰며 기울고, 솔 끝에서 먼지가 밀려남.
function Draw-Illus($g, $ox, $oy) {
    $f = $script:frame; $ph = $script:phase
    $work = ($ph -in 'analyzing', 'cleaning'); $done = ($ph -eq 'done')
    $t = $f * 2 * [math]::PI / 14
    $s = [math]::Sin($t); $cosv = [math]::Cos($t)
    $groundY = $oy + 198
    $dx = 0; $dy = 0
    if ($work) { $dx = [int][math]::Round($s * 5); $dy = -[int][math]::Round([math]::Abs($s) * 4) }
    elseif ($done) { $dy = -[int][math]::Round([math]::Abs([math]::Sin($f * 0.5)) * 16) }
    elseif (($f % 10) -ge 5) { $dy = -2 }
    $mx = $ox + 104 + $dx; $my = $oy + 54 + $dy

    # 바닥 그림자
    $shW = 112 - [math]::Abs($dy) * 2.2
    $g.FillEllipse((Br '#d3e9d8'), [int]($mx + 66 - $shW / 2), ($groundY - 4), [int]$shW, 16)
    $g.FillEllipse((Br '#c4e0c9'), [int]($mx + 66 - $shW / 3), ($groundY - 1), [int]($shW * 0.66), 9)

    # 장식 (문서 / 폴더 / 구름)
    Draw-Sprite $g $SprDoc ($ox + 6) ($oy + 88)
    Draw-Sprite $g $SprFolder ($ox + 20) ($oy + 142)
    Draw-Sprite $g $SprCloud ($ox + 214) ($oy + 160)

    # 빗자루: 캐릭터 뒤에서 왼팔이 잡고, 솔이 바닥을 쓺
    $hx = $mx + 8; $hy = $my + 90
    if ($work) { $swing = 24 } elseif ($done) { $swing = 2 } else { $swing = 4 }
    $bx = $ox + 80 + $s * $swing + $dx * 0.6
    $by = $groundY - 6 - 4 * $s * $s
    if ($done) { $bx = $ox + 76; $by = $groundY - 6 }
    $tx = $hx + ($hx - $bx) * 0.8; $ty = $hy + ($hy - $by) * 0.8
    Draw-Broom $g $bx $by $tx $ty

    # 먼지: 솔 이동 방향으로 밀려남 (솔보다 앞에서 튀어 오름)
    if ($work) {
        $prevSm = $g.SmoothingMode; $g.SmoothingMode = 'None'
        $sg = 1; if ($cosv -lt 0) { $sg = -1 }
        if ([math]::Abs($cosv) -gt 0.2) {
            for ($k = 1; $k -le 7; $k++) {
                $px = $bx + $sg * (22 + $k * 6) + ((($f * 7 + $k * 5) % 5) - 2)
                $py = $groundY - 6 - ($k * $k) * 0.5 - (($k + $f) % 3) * 2
                $sz = [math]::Max(3, 8 - $k)
                $col = '#a9c1b0'; if (($k % 2) -eq 0) { $col = '#c9dccd' }
                $g.FillRectangle((Br $col), [int]$px, [int]$py, [int]$sz, [int]$sz)
            }
        }
        if ([math]::Abs($s) -gt 0.85) {
            $sg2 = 1; if ($s -lt 0) { $sg2 = -1 }
            $pxp = $bx + $sg2 * 34
            $g.FillRectangle((Br '#bcd2c2'), [int]($pxp - 7), ($groundY - 18), 14, 10)
            $g.FillRectangle((Br '#d3e5d8'), [int]($pxp - 2), ($groundY - 25), 10, 9)
            $g.FillRectangle((Br '#bcd2c2'), [int]($pxp + 7), ($groundY - 13), 8, 7)
        }
        $g.SmoothingMode = $prevSm
        for ($i = 0; $i -lt 3; $i++) {
            if ((([math]::Floor($f / 2) + $i * 3) % 8) -lt 3) { Draw-Star $g ($ox + 36 + $i * 70) ($groundY - 18 + (($i % 2) * 8)) 7 '#fffbe3' '#f2c94c' }
        }
    }

    # 캐릭터 (작업 중 웃는 눈, 간헐적 깜빡임)
    $spr = $SprMimi
    if ($work) { $spr = $SprHappy; if (($f % 22) -eq 0) { $spr = $SprMimi } }
    elseif ($done) { $spr = $SprHappy }
    elseif (($f % 30) -eq 0) { $spr = $SprHappy }
    Draw-Sprite $g $spr $mx $my

    # 반짝이 장식
    $stars = @(@(28, 34, 10, 0), @(240, 28, 8, 1), @(252, 112, 9, 2), @(70, 66, 6, 3), @(196, 20, 6, 4))
    foreach ($st in $stars) {
        if ((($f + $st[3] * 2) % 7) -lt 5) {
            $line = '#7fc4a3'; $fill = '#f4fff6'
            if ($st[3] % 2 -eq 1) { $line = '#f2c94c'; $fill = '#fffbe3' }
            Draw-Star $g ($ox + $st[0]) ($oy + $st[1]) $st[2] $fill $line
        }
    }
    if ($done) {
        foreach ($i in 0..5) {
            $a = $i * 1.05 + $f * 0.35; $r = 70 + (($f * 5 + $i * 9) % 26)
            Draw-Star $g ($mx + 66 + [math]::Cos($a) * $r) ($my + 60 + [math]::Sin($a) * $r * 0.8) 6 '#fffbe3' '#f2c94c'
        }
    }
}

# ---------- 청소 엔진 ----------
# 폴더 순회는 Walker(C#)가 전담. 링크(정션)를 따라가지 않으므로 이미 이동한 폴더를 재집계·삭제하지 않음.
function New-Walk($path, $min = 0, $olderDays = 0, $exts = $null, $findDir = $null, $maxDepth = 99, $exclude = @(), [switch]$Delete, $maxSec = 0) {
    $w = New-Object Walker $path
    $w.MaxMs = [int]($maxSec * 1000)
    if ($min -gt 0) { $w.MinBytes = [long]$min }
    if ($olderDays -gt 0) { $w.OlderThanTicks = (Get-Date).AddDays(-$olderDays).ToUniversalTime().Ticks }
    if ($exts) { $w.Exts = New-Object 'System.Collections.Generic.HashSet[string]'; foreach ($e in $exts) { [void]$w.Exts.Add($e) } }
    if ($findDir) { $w.FindDirName = $findDir }
    $w.MaxDepth = $maxDepth
    foreach ($x in $exclude) { [void]$w.Exclude.Add($x) }
    $w.Delete = [bool]$Delete
    while (-not $w.Done) { $w.Step(30); Pump }
    $w
}
function Dir-Size($p, $days = 0) { (New-Walk $p -olderDays $days).Total }
function Clear-Dir($path, $days) { (New-Walk $path -olderDays $days -Delete).Freed }
function Free-Of($path) { try { (New-Object IO.DriveInfo ($path.Substring(0, 1))).AvailableFreeSpace } catch { [long]::MaxValue } }
function Get-RecycleSize {
    $sum = 0
    foreach ($i in (New-Object -ComObject Shell.Application).NameSpace(10).Items()) { $sum += $i.Size }
    $sum
}
function Write-Log($action, $src, $dst, $size) {
    if (-not $LogFile) { return }
    [void][IO.Directory]::CreateDirectory($Dest)
    [pscustomobject]@{ Time = (Get-Date -Format s); Action = $action; From = $src; To = $dst; MB = [math]::Round($size / 1MB, 0) } |
        Export-Csv -Path $LogFile -Append -NoTypeInformation -Encoding UTF8
}
function Move-OneFile($file) {
    try {
        $rel = $file.Substring($UserHome.Length).TrimStart('\')
        $target = Join-Path $Dest $rel
        [void][IO.Directory]::CreateDirectory((Split-Path $target))
        if ([IO.File]::Exists($target)) { $target = Join-Path (Split-Path $target) ((Get-Date -Format 'HHmmss') + '_' + (Split-Path $file -Leaf)) }
        $size = (New-Object IO.FileInfo $file).Length
        [IO.File]::Move($file, $target)
        Write-Log 'move' $file $target $size
        $true
    } catch { $false }
}
# 폴더 이동 후 원래 위치에 정션 생성.
# 순서: 복사 → 개수·용량 검증 → 원본 이름 변경 → 정션 생성 → 원본 삭제. 단계별 실패 시 원본 보존.
function Move-FolderWithJunction($src) {
    $src = (Resolve-Path -LiteralPath $src).Path.TrimEnd('\')
    if (-not $src.StartsWith($UserHome + '\')) { return '사용자 폴더 외부 (건너뜀)' }
    if ((Get-Item -LiteralPath $src -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { return '이미 정션 폴더 (건너뜀)' }
    $dst = Join-Path $Dest ($src.Substring($UserHome.Length).TrimStart('\'))
    if ([IO.Directory]::Exists($dst)) { return "대상 폴더가 이미 존재: $dst (건너뜀)" }
    $w1 = New-Walk $src
    if ($w1.Links -gt 0) { return '폴더 내 링크 존재 (건너뜀)' }
    if ((Free-Of $Dest) -lt ($w1.Total * 1.02 + 200MB)) { return '대상 드라이브 공간 부족 (건너뜀)' }
    [void][IO.Directory]::CreateDirectory($dst)
    $p = Start-Process robocopy -ArgumentList "`"$src`" `"$dst`" /E /COPY:DAT /DCOPY:DAT /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NP" -WindowStyle Hidden -PassThru
    $null = $p.Handle
    while (-not $p.HasExited) { Pump; Start-Sleep -Milliseconds 120 }
    $w2 = New-Walk $dst
    if ($p.ExitCode -ge 8 -or $w2.Count -ne $w1.Count -or $w2.Total -ne $w1.Total) {
        Remove-Tree $dst
        return '복사 검증 실패 (원본 보존)'
    }
    $old = "$src.mimichi-old"
    try { [IO.Directory]::Move($src, $old) } catch {
        Remove-Tree $dst
        return '폴더 사용 중 (원본 보존). 해당 프로그램 종료 후 재시도'
    }
    try { New-Item -ItemType Junction -Path $src -Target $dst -ErrorAction Stop | Out-Null } catch {
        [IO.Directory]::Move($old, $src); Remove-Tree $dst
        return '정션 생성 실패 (원복 완료)'
    }
    Write-Log 'move+junction' $src $dst $w1.Total
    Remove-Tree $old
    if ([IO.Directory]::Exists($old)) { return "이동 완료. 이전 폴더 일부 삭제 실패: $old" }
    ''
}
# 폴더 일괄 삭제 (깊은 경로를 위해 cmd 사용, 링크는 링크만 제거)
function Remove-Tree($path) {
    if ([IO.Directory]::Exists($path)) { cmd.exe /c "rmdir /s /q `"$path`"" | Out-Null }
}

# ---------- 화면 (목업에서 뽑은 색 그대로) ----------
# 모든 좌표는 논리 좌표(96dpi 기준). 그릴 때 화면 배율($Sc) 적용.
$script:W = 900; $script:H = 756
$script:phase = 'before'; $script:hover = ''; $script:tip = 0
$script:footerText = ''; $script:sayText = ''
$script:freeC = 0; $script:freeD = 0; $script:cFrac = 0.0
$C = @{
    winBg = '#EDF8EB'; titleBg = '#F5FAF4'; titleLine = '#E6F1E6'; winBorder = '#A0C1AA'
    card = '#F9FCF8'; edgeC = '#C6DCCE'; edgeR = '#DFE9E1'; edgeT = '#E4EEE3'; divider = '#E1ECE4'
    head = '#001F18'; greet = '#143224'; sub = '#324C46'; titleTxt = '#132922'; cardTitle = '#051B16'
    red = '#EF5867'; redBar = '#EC666B'; redBarHi = '#F87679'; redTrack = '#E4BBB9'; redTrackBg = '#FFF3F3'
    usage = '#415651'; dTxt = '#344443'; dIcon = '#3A4C4D'; chevron = '#2E4245'
    resTitle = '#000A09'; resIcon = '#6DA184'; badgeBg = '#D1E0D7'; badgeTxt = '#23423A'
    emptyTxt = '#0A1818'; hint = '#3F5655'; emptyIcon = '#ACC6B1'; tipTxt = '#415A5B'; leaf = '#5E8C6C'
    dotOff = '#E1EFDF'; dotOn = '#C4E0BE'; btn = '#4B9E88'; btnEdge = '#3D8C78'; btnHover = '#56AA93'; btnOff = '#A9CBBF'
    hoverBtn = '#E1EFDF'; hoverClose = '#F7D4D6'
}
$fGreet = Mk-Font 11; $fHead = Mk-Font 18.5 'Bold'; $fSub = Mk-Font 10; $fBtn = Mk-Font 12.5 'Bold'
$fCardT = Mk-Font 12 'Bold'; $fBig = Mk-Font 23 'Bold'; $fSmall = Mk-Font 9.5; $fResT = Mk-Font 12.5 'Bold'
$fBadge = Mk-Font 10 'Bold'; $fEmpty = Mk-Font 12; $fHint = Mk-Font 10; $fTip = Mk-Font 10; $fFoot = Mk-Font 10 'Bold'
$fTitle = Mk-Font 11; $fRow = Mk-Font 10
$fList = Mk-Font 9.5 'Regular' $Sc      # 목록은 변환 없이 그리므로 배율 직접 적용
$sfT = [Drawing.StringFormat]::GenericTypographic.Clone(); $sfT.FormatFlags = 'NoWrap, MeasureTrailingSpaces'
$sfE = New-Object Drawing.StringFormat; $sfE.Trimming = 'EllipsisCharacter'; $sfE.FormatFlags = 'NoWrap'; $sfE.LineAlignment = 'Center'
function RC($x, $y, $w, $h) { New-Object Drawing.Rectangle ([int]$x), ([int]$y), ([int]$w), ([int]$h) }

# 창 크기에 맞춰 레이아웃 재계산 (좌측 텍스트·버튼 고정, 카드·목록 확장)
function Apply-Layout($w, $h) {
    $script:W = $w; $script:H = $h
    $script:rMin = RC ($w - 146) 8 32 28; $script:rMax = RC ($w - 96) 8 32 28; $script:rClose = RC ($w - 44) 8 32 28
    $script:rAn = RC 33 229 253 51
    $script:rCardC = RC ($w - 327) 75 299 172
    $illX = 300 + [math]::Max(0, [int]((($w - 327) - 300 - 270) / 2))
    $script:rIllus = RC $illX 70 270 232
    $resH = [math]::Max(280, $h - 394)
    $script:rRes = RC 30 309 ($w - 60) $resH
    $rb = 309 + $resH
    $script:rFoot = RC 30 ($rb - 75) ($w - 60) 75
    $script:rCl = RC ($w - 198) ($rb - 65) 136 46
    $script:rTip = RC 20 ($h - 69) ($w - 40) 48
    $script:rList = RC 46 366 ($w - 92) ($rb - 447)
    if ($lv) {
        $lv.SetBounds([int]($rList.X * $Sc), [int]($rList.Y * $Sc), [int]($rList.Width * $Sc), [int]($rList.Height * $Sc))
        $tot = $lv.ClientSize.Width - [Windows.Forms.SystemInformation]::VerticalScrollBarWidth
        $c1 = [int]($tot * 0.40); $c2 = [int](90 * $Sc)
        if ($lv.Columns.Count -ge 3) { $lv.Columns[0].Width = $c1; $lv.Columns[1].Width = $c2; $lv.Columns[2].Width = [math]::Max(80, $tot - $c1 - $c2) }
    }
}
Apply-Layout 900 756
function Inv($r) {
    $canvas.Invalidate((New-Object Drawing.Rectangle ([int]([math]::Floor($r.X * $Sc) - 2)), ([int]([math]::Floor($r.Y * $Sc) - 2)), ([int]([math]::Ceiling($r.Width * $Sc) + 4)), ([int]([math]::Ceiling($r.Height * $Sc) + 4))))
}
function ToLogical($p) { New-Object Drawing.Point ([int][math]::Floor($p.X / $Sc)), ([int][math]::Floor($p.Y / $Sc)) }

# LINE Seed는 줄 상자 아래쪽 여백이 커서, 줄 상자 기준으로 가운데 정렬하면 글자가 위로 치우쳐 보임.
# 실측: 한글 글자 중심이 글자 크기의 약 0.26배만큼 위 -> 그만큼 내려서 시각적으로 가운데 정렬.
$TextDrop = 0.265
function TxtL($g, $t, $font, $hex, $x, $cy) { $g.DrawString($t, $font, (Br $hex), [single]$x, [single]($cy - $font.GetHeight($g) / 2 + $font.Size * $TextDrop), $sfT) }
function TxtW($g, $t, $font) { $g.MeasureString($t, $font, 9999, $sfT).Width }
function TxtC($g, $t, $font, $hex, $cx, $cy) { $w = TxtW $g $t $font; $g.DrawString($t, $font, (Br $hex), [single]($cx - $w / 2), [single]($cy - $font.GetHeight($g) / 2 + $font.Size * $TextDrop), $sfT) }

function Draw-Search($g, $cx, $cy, $hex) {
    $p = Pn $hex 2.6
    $g.DrawEllipse($p, [single]($cx - 10), [single]($cy - 10), 16, 16)
    $g.DrawLine($p, [single]($cx + 4), [single]($cy + 4), [single]($cx + 10), [single]($cy + 10))
}
function Draw-DocIcon($g, $x, $y, $w, $h, $fillHex, $lineHex) {
    $path = [Gfx]::Round($x, $y, $w, $h, 4)
    $g.FillPath((Br $fillHex), $path); $path.Dispose()
    $p = Pn $lineHex 1.8
    foreach ($i in 0..2) { $ly = $y + $h * (0.36 + $i * 0.2); $g.DrawLine($p, [single]($x + $w * 0.25), [single]$ly, [single]($x + $w * 0.75), [single]$ly) }
}
function Draw-Drive($g, $x, $y) {
    $path = [Gfx]::Round($x, $y, 24, 14, 4); $g.DrawPath((Pn $C.dIcon 1.8), $path); $path.Dispose()
    $g.DrawLine((Pn $C.dIcon 1.6), [single]($x + 2), [single]($y + 8), [single]($x + 22), [single]($y + 8))
    $g.FillEllipse((Br $C.dIcon), [single]($x + 17), [single]($y + 9.5), 3, 3)
}
function Draw-Leaf($g, $cx, $cy) {
    $st = $g.Save(); $g.TranslateTransform($cx, $cy); $g.RotateTransform(-38)
    $g.FillEllipse((Br $C.leaf), -9, -5, 18, 10)
    $g.DrawLine((Pn '#EDF8EB' 1.4), -8, 0, 8, 0)
    $g.Restore($st)
    $g.DrawLine((Pn $C.leaf 1.8), [single]($cx - 7), [single]($cy + 9), [single]($cx - 1), [single]($cy + 2))
}

# ---------- 정적 레이어 (상태·창 크기 변경 시에만 재생성) ----------
function Render-Static {
    $W = $script:W; $H = $script:H
    $bmp = New-Object Drawing.Bitmap ([int]($W * $Sc)), ([int]($H * $Sc))
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.ScaleTransform($Sc, $Sc)
    $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'
    $win = [Gfx]::Round(0.8, 0.8, ($W - 1.6), ($H - 1.6), 22)
    $g.FillPath((Br $C.winBg), $win)
    $g.SetClip($win)
    $g.FillRectangle((Br $C.titleBg), 0, 0, $W, 44)
    $g.DrawLine((Pn $C.titleLine 1.4), 0, 44, $W, 44)
    $g.ResetClip()
    $g.DrawPath((Pn $C.winBorder 1.6), $win)
    # 제목줄
    $g.InterpolationMode = 'NearestNeighbor'; $g.PixelOffsetMode = 'Half'; $g.DrawImage($mimiBmp, 20, 9, 22, 24); $g.PixelOffsetMode = 'HighQuality'; $g.InterpolationMode = 'HighQualityBicubic'
    TxtL $g '미미치 청소 도우미' $fTitle $C.titleTxt 52 22
    # 인사말 / 제목
    TxtL $g '안녕하세요!' $fGreet $C.greet 43 82
    TxtL $g '느려진 PC를' $fHead $C.head 42 111
    TxtL $g '깨끗하게 정리해 드릴게요' $fHead $C.head 42 146
    TxtL $g '지금 바로 드라이브를 분석해서' $fSub $C.sub 43 181
    TxtL $g '정리할 파일을 찾아볼까요?' $fSub $C.sub 43 203
    # C 드라이브 카드
    $cx = $rCardC.X; $cy = $rCardC.Y
    [Gfx]::Card($g, $cx, $cy, $rCardC.Width, $rCardC.Height, 20, (HexC $C.card), (HexC $C.edgeC), 8)
    TxtL $g "$SL 드라이브" $fCardT $C.cardTitle ($cx + 20) ($cy + 32)
    $pct = '{0:N0}%' -f ($script:cFrac * 100)
    $barHex = '#5BBF8E'; $numHex = '#2FA06B'
    if ($script:cFrac -ge 0.7) { $barHex = '#F2B84B'; $numHex = '#D99A1E' }
    if ($script:cFrac -ge 0.9) { $barHex = $C.redBar; $numHex = $C.red }
    TxtL $g $pct $fBig $numHex ($cx + 19) ($cy + 64)
    $pw2 = TxtW $g $pct $fBig
    TxtL $g ('사용 중 · 여유 {0} GB' -f (GB $script:freeC)) $fSmall $C.usage ($cx + 19 + $pw2 + 10) ($cy + 67)
    $track = [Gfx]::Round(($cx + 20), ($cy + 85), 259, 19, 9.5)
    $g.FillPath((Br $C.redTrackBg), $track); $g.DrawPath((Pn $C.redTrack 1.4), $track); $track.Dispose()
    $nseg = 33; $segW = 6.2; $fill = [math]::Round($script:cFrac * $nseg)
    for ($i = 0; $i -lt $fill; $i++) {
        $sx = $cx + 24 + $i * 7.7
        $g.FillRectangle((Br $barHex), [single]$sx, [single]($cy + 89), [single]$segW, 11)
        $g.FillRectangle((Br $C.redBarHi), [single]$sx, [single]($cy + 89), [single]$segW, 3)
    }
    $g.DrawLine((Pn $C.divider 1.4), ($cx + 20), ($cy + 120), ($cx + 280), ($cy + 120))
    Draw-Drive $g ($cx + 22) ($cy + 137)
    $dText = '이동할 드라이브 없음'; if ($script:DestOK) { $dText = ('{0} 드라이브   여유 {1} GB' -f $DL, (GB $script:freeD)) }
    TxtL $g $dText $fRow $C.dTxt ($cx + 56) ($cy + 144)
    $cp = Pn $C.chevron 1.8; $chx = $rCardC.Right - 26
    $g.DrawLine($cp, $chx, ($cy + 138), ($chx + 6), ($cy + 144)); $g.DrawLine($cp, ($chx + 6), ($cy + 144), $chx, ($cy + 150))
    # 분석 결과 카드
    $rx = $rRes.X; $ry = $rRes.Y
    [Gfx]::Card($g, $rx, $ry, $rRes.Width, $rRes.Height, 22, (HexC $C.card), (HexC $C.edgeR), 7)
    Draw-DocIcon $g ($rx + 22) ($ry + 12) 23 28 $C.resIcon '#F4FBF6'
    TxtL $g '분석 결과' $fResT $C.resTitle ($rx + 63) ($ry + 26)
    $badge = @{ 'before' = @('분석 전', $C.badgeBg, $C.badgeTxt); 'analyzing' = @('분석 중', '#F6E7B8', '#6B5300')
                'ready' = @('분석 완료', '#C4E0BE', '#1F4D2E'); 'cleaning' = @('정리 중', '#F6E7B8', '#6B5300'); 'done' = @('정리 완료', '#CFE3F7', '#1F4F7A') }[$script:phase]
    $bw = (TxtW $g $badge[0] $fBadge) + 30
    $bp = [Gfx]::Round(($rRes.Right - 16 - $bw), ($ry + 12), $bw, 28, 14)
    $g.FillPath((Br $badge[1]), $bp); $bp.Dispose()
    TxtC $g $badge[0] $fBadge $badge[2] ($rRes.Right - 16 - $bw / 2) ($ry + 26)
    $g.DrawLine((Pn '#ECF1ED' 1.6), ($rx + 1), ($ry + 49), ($rRes.Right - 1), ($ry + 49))
    if ($script:phase -notin 'ready', 'cleaning') {
        $ec = $rx + $rRes.Width / 2; $cy0 = ($ry + 50 + $rRes.Bottom) / 2
        Draw-DocIcon $g ($ec - 26) ($cy0 - 90) 52 64 '#F9FCF8' $C.emptyIcon
        $dp = [Gfx]::Round(($ec - 26), ($cy0 - 90), 52, 64, 8); $g.DrawPath((Pn $C.emptyIcon 2.6), $dp); $dp.Dispose()
        Draw-Star $g ($ec + 40) ($cy0 - 90) 9 $null $C.emptyIcon
        Draw-Star $g ($ec + 54) ($cy0 - 72) 5 $null $C.emptyIcon
        Draw-Star $g ($ec - 42) ($cy0 - 44) 6 $null $C.emptyIcon
        $lines = @('드라이브를 분석하면', '정리할 수 있는 항목을 알려 드릴게요'); $hint = "'드라이브 분석하기'를 눌러 주세요"
        if ($script:phase -ne 'before' -and $script:sayText) {
            $parts = @($script:sayText -split "`n"); $lines = @($parts[0]); if ($parts.Count -gt 1) { $lines += $parts[1] }; $hint = ''
            if ($parts.Count -gt 2) { $hint = ($parts[2..($parts.Count - 1)] -join '  ') }
        }
        TxtC $g $lines[0] $fEmpty $C.emptyTxt $ec ($cy0 + 1)
        if ($lines.Count -gt 1) { TxtC $g $lines[1] $fEmpty $C.emptyTxt $ec ($cy0 + 28) }
        if ($hint) {
            $hw = TxtW $g $hint $fHint
            while ($hw -gt ($rRes.Width - 80) -and $hint.Length -gt 10) { $hint = $hint.Substring(0, $hint.Length - 4) + '...'; $hw = TxtW $g $hint $fHint }
            Draw-Star $g ($ec - $hw / 2 - 16) ($cy0 + 74) 8 $null $C.emptyIcon
            TxtC $g $hint $fHint $C.hint $ec ($cy0 + 74)
        }
    }
    # 팁 바
    [Gfx]::Card($g, $rTip.X, $rTip.Y, $rTip.Width, $rTip.Height, 24, (HexC $C.card), (HexC $C.edgeT), 5)
    Draw-Leaf $g ($rTip.X + 36) ($rTip.Y + 24)
    $win.Dispose(); $g.Dispose()
    $bmp
}
$script:static = $null
function Rebuild { $old = $script:static; $script:static = Render-Static; if ($old) { $old.Dispose() }; $canvas.Invalidate() }

# ---------- 폼 / 캔버스 ----------
$mimiBmp = New-Object Drawing.Bitmap 44, 48
$gm = [Drawing.Graphics]::FromImage($mimiBmp); Draw-Grid $gm $Grid 1 0 0; $gm.Dispose()

$form = New-Object MimiForm
$form.Text = '미미치 청소 도우미'; $form.FormBorderStyle = 'None'; $form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object Drawing.Size ([int](900 * $Sc)), ([int](756 * $Sc)); $form.BackColor = HexC $C.winBg
$form.MinimumSize = New-Object Drawing.Size ([int](780 * $Sc)), ([int](640 * $Sc))
if (Test-Path $IcoPath) { $form.Icon = New-Object Drawing.Icon($IcoPath) }
function Apply-Region {
    if ($form.WindowState -eq 'Normal') { $form.Region = [Gfx]::RoundRegion($form.Width, $form.Height, [int](22 * $Sc)) } else { $form.Region = $null }
}
Apply-Region
$canvas = New-Object MimiCanvas
$canvas.Dock = 'Fill'; $canvas.BackColor = HexC $C.winBg
$form.Controls.Add($canvas)

# ---------- 목록 (오너 드로우) ----------
$lv = New-Object Windows.Forms.ListView
$lv.Parent = $canvas
$lv.View = 'Details'; $lv.CheckBoxes = $true; $lv.FullRowSelect = $true; $lv.HideSelection = $false; $lv.ShowGroups = $false
$lv.BorderStyle = 'None'; $lv.BackColor = HexC $C.card; $lv.Visible = $false
[void]$lv.Columns.Add('항목', 330); [void]$lv.Columns.Add('크기', 90); [void]$lv.Columns.Add('설명', 370)
$lv.OwnerDraw = $true; $lv.Font = $fList
$rowImg = New-Object Windows.Forms.ImageList; $rowImg.ImageSize = New-Object Drawing.Size(1, [int](30 * $Sc)); $lv.SmallImageList = $rowImg
$sfCell = New-Object Drawing.StringFormat; $sfCell.LineAlignment = 'Center'; $sfCell.Trimming = 'EllipsisCharacter'; $sfCell.FormatFlags = 'NoWrap'
Apply-Layout 900 756
$groupDef = [ordered]@{
    'del'   = '삭제 가능 (재생성되는 항목)'
    'move'  = "이동 권장 (${DL} 드라이브)"
    'check' = '확인 필요'
    'keep'  = '변경 금지'
}
$tagColor = @{ 'del' = '#2F8F5B'; 'move' = '#2E6FB0'; 'check' = '#A9780E'; 'keep' = '#C0453D' }
$brTag = @{}; foreach ($kk in $tagColor.Keys) { $brTag[$kk] = New-Object Drawing.SolidBrush (HexC $tagColor[$kk]) }
$brHeadBg = New-Object Drawing.SolidBrush (HexC '#EEF6EE'); $brHdrRow = New-Object Drawing.SolidBrush (HexC '#EDF5EC')
$brSel = New-Object Drawing.SolidBrush (HexC '#E0EFE3'); $brRow = New-Object Drawing.SolidBrush (HexC $C.card)
$brHeadTxt = New-Object Drawing.SolidBrush (HexC $C.usage); $penSep = New-Object Drawing.Pen (HexC '#E6EFE8'), 1
$lv.Add_DrawColumnHeader({
    $g = $_.Graphics; $b = $_.Bounds
    $g.FillRectangle($brHeadBg, $b)
    $g.TextRenderingHint = 'AntiAlias'
    $g.DrawString($_.Header.Text, $fList, $brHeadTxt, (New-Object Drawing.RectangleF(($b.Left + 8 * $Sc), ($b.Top + $fList.Size * $TextDrop), ($b.Width - 10 * $Sc), $b.Height)), $sfCell)
})
$lv.Add_DrawItem({ })
$lv.Add_DrawSubItem({
    $e = $_; $g = $e.Graphics; $b = $e.Bounds; $it = $e.Item; $type = $it.Tag.Act.Type
    $g.TextRenderingHint = 'AntiAlias'
    $fore = $brTag[$it.Tag.Key]
    if ($type -eq 'header') {
        $g.FillRectangle($brHdrRow, $b)
        if ($e.ColumnIndex -eq 0) { $g.DrawString($it.Text, $fList, $fore, (New-Object Drawing.RectangleF(($b.Left + 8 * $Sc), ($b.Top + $fList.Size * $TextDrop), ($b.Width + 300 * $Sc), $b.Height)), $sfCell) }
        return
    }
    if ($it.Selected) { $g.FillRectangle($brSel, $b) } else { $g.FillRectangle($brRow, $b) }
    $g.DrawLine($penSep, $b.Left, ($b.Bottom - 1), $b.Right, ($b.Bottom - 1))
    $x0 = $b.Left + 8 * $Sc
    if ($e.ColumnIndex -eq 0) {
        $gs = [Windows.Forms.CheckBoxRenderer]::GetGlyphSize($g, [Windows.Forms.VisualStyles.CheckBoxState]::UncheckedNormal)
        if ($type -ne 'info') {
            $st = 'UncheckedNormal'; if ($it.Checked) { $st = 'CheckedNormal' }
            [Windows.Forms.CheckBoxRenderer]::DrawCheckBox($g, (New-Object Drawing.Point(($b.Left + [int](4 * $Sc)), [int]($b.Top + ($b.Height - $gs.Height) / 2))), [Windows.Forms.VisualStyles.CheckBoxState]$st)
        }
        $x0 = $b.Left + $gs.Width + 10 * $Sc
    }
    $g.DrawString($e.SubItem.Text, $fList, $fore, (New-Object Drawing.RectangleF($x0, ($b.Top + $fList.Size * $TextDrop), ($b.Right - $x0 - 4 * $Sc), $b.Height)), $sfCell)
})
$lv.Add_ItemCheck({
    $it = $lv.Items[$_.Index]
    if (-not $script:filling -and $it.Tag.Act.Type -in 'info', 'header') { $_.NewValue = $_.CurrentValue }
})
$lv.Add_ItemChecked({ Update-Sum })

function Set-Phase($p) {
    $script:phase = $p
    $lv.Visible = ($p -in 'ready', 'cleaning')
    Rebuild
}
function Refresh-Free {
    $d = Get-PSDrive $SL
    $script:freeC = $d.Free; if ($script:DestOK) { $script:freeD = (Get-PSDrive $DL).Free }
    $script:cFrac = $d.Used / ($d.Used + $d.Free)
    Rebuild
}
function Say($text) {
    $script:sayText = $text
    if ($script:trace) { Add-Content -Path $script:trace -Value ('{0:HH:mm:ss.fff}  {1}' -f (Get-Date), ($text -replace "`n", ' | ')) }
    if ($script:phase -in 'ready', 'cleaning') { $script:footerText = ($text -replace "`n", '   '); Inv $rFoot } else { Rebuild }
}
function Update-Sum {
    if ($script:filling) { return }
    $del = 0; $mov = 0
    foreach ($it in $lv.CheckedItems) {
        $t = $it.Tag.Act.Type
        if ($t -in 'cache', 'recycle', 'nodemodules') { $del += $it.Tag.Size } elseif ($t -in 'movefiles', 'movefolder') { $mov += $it.Tag.Size }
    }
    $script:footerText = "선택: 삭제 {0} GB · 이동 {1} GB" -f (GB $del), (GB $mov)
    Inv $rFoot
}

# ---------- 움직이는 부분 ----------
$brShadow = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(45, 47, 111, 94))
function Draw-Button($g, $rect, $text, $enabled, $hot, $icon) {
    $path = [Gfx]::Round($rect.X, $rect.Y, $rect.Width, $rect.Height, ($rect.Height / 2))
    if ($enabled) {
        $sh = [Gfx]::Round($rect.X, ($rect.Y + 3), $rect.Width, $rect.Height, ($rect.Height / 2))
        $g.FillPath($brShadow, $sh); $sh.Dispose()
        $col = $C.btn; if ($hot) { $col = $C.btnHover }
        $g.FillPath((Br $col), $path); $g.DrawPath((Pn $C.btnEdge 1.4), $path)
    } else { $g.FillPath((Br $C.btnOff), $path) }
    $tw = TxtW $g $text $fBtn
    $iw = 0; if ($icon) { $iw = 34 }
    $x0 = $rect.X + ($rect.Width - $tw - $iw) / 2
    if ($icon) { Draw-Search $g ($x0 + 12) ($rect.Y + $rect.Height / 2 - 1) '#FFFFFF' }
    TxtL $g $text $fBtn '#FFFFFF' ($x0 + $iw) ($rect.Y + $rect.Height / 2)
    $path.Dispose()
}
function Draw-TitleBtns($g) {
    $gc = Pn $C.titleTxt 1.5
    foreach ($nm in 'min', 'max', 'close') {
        $r = @{ 'min' = $rMin; 'max' = $rMax; 'close' = $rClose }[$nm]
        if ($script:hover -eq $nm) {
            $col = $C.hoverBtn; if ($nm -eq 'close') { $col = $C.hoverClose }
            $hp = [Gfx]::Round($r.X, $r.Y, $r.Width, $r.Height, 8); $g.FillPath((Br $col), $hp); $hp.Dispose()
        }
        $cx = $r.X + 16; $cy = $r.Y + 14
        switch ($nm) {
            'min' { $g.DrawLine($gc, ($cx - 7), $cy, ($cx + 7), $cy) }
            'max' {
                if ($form.WindowState -eq 'Maximized') { $g.DrawRectangle($gc, ($cx - 5), ($cy - 3), 10, 10); $g.DrawLine($gc, ($cx - 2), ($cy - 6), ($cx + 8), ($cy - 6)); $g.DrawLine($gc, ($cx + 8), ($cy - 6), ($cx + 8), ($cy + 4)) }
                else { $g.DrawRectangle($gc, ($cx - 6), ($cy - 6), 12, 12) }
            }
            'close' { $g.DrawLine($gc, ($cx - 6), ($cy - 6), ($cx + 6), ($cy + 6)); $g.DrawLine($gc, ($cx + 6), ($cy - 6), ($cx - 6), ($cy + 6)) }
        }
    }
}
$tips = @('캐시와 임시 파일은 지워도 필요하면 자동으로 다시 생겨요', "큰 파일은 지우지 않고 $DL 드라이브로 옮겨 둘 수 있어요", '옮긴 폴더도 원래 경로 그대로 열 수 있어요')
$canvas.Add_Paint({
  try {
    $g = $_.Graphics; $clip = $_.ClipRectangle
    if (-not $script:static) { return }
    try { $g.DrawImage($script:static, $clip, $clip, [Drawing.GraphicsUnit]::Pixel) } catch { }
    $g.ScaleTransform($Sc, $Sc)
    $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAlias'
    $lc = New-Object Drawing.Rectangle ([int][math]::Floor($clip.X / $Sc)), ([int][math]::Floor($clip.Y / $Sc)), ([int]([math]::Ceiling($clip.Width / $Sc) + 1)), ([int]([math]::Ceiling($clip.Height / $Sc) + 1))
    $anOn = ($script:phase -in 'before', 'ready', 'done')
    if ($lc.IntersectsWith($rIllus)) { Draw-Illus $g $rIllus.X $rIllus.Y }
    if ($lc.IntersectsWith($rAn)) { Draw-Button $g $rAn '드라이브 분석하기' $anOn ($script:hover -eq 'an') $true }
    if ($lc.Y -lt 46) { Draw-TitleBtns $g }
    if ($lc.IntersectsWith($rFoot) -and $script:phase -in 'ready', 'cleaning') {
        $g.DrawString($script:footerText, $fFoot, (Br $C.dTxt), (New-Object Drawing.RectangleF(50, ($rFoot.Y + 8 + $fFoot.Size * $TextDrop), ($rCl.X - 64), 28)), $sfE)
        if ($script:phase -eq 'cleaning') {
            $bwid = $rCl.X - 80
            $bp = [Gfx]::Round(50, ($rFoot.Y + 44), $bwid, 14, 7); $g.FillPath((Br $C.dotOff), $bp); $bp.Dispose()
            $pw = [int]($bwid * [math]::Max(0.03, $script:prog))
            $bp2 = [Gfx]::Round(50, ($rFoot.Y + 44), $pw, 14, 7); $g.FillPath((Br $C.btn), $bp2); $bp2.Dispose()
        }
        Draw-Button $g $rCl '청소 시작' ($script:phase -eq 'ready') ($script:hover -eq 'cl') $false
    }
    if ($lc.IntersectsWith($rTip)) {
        TxtL $g $tips[$script:tip % 3] $fTip $C.tipTxt ($rTip.X + 56) ($rTip.Y + 24)
        $ai = $script:tip % 3; $x = $rTip.Right - 24
        for ($i = 2; $i -ge 0; $i--) {
            $w = 9; $col = $C.dotOff; if ($i -eq $ai) { $w = 28; $col = $C.dotOn }
            $x -= $w; $dp = [Gfx]::Round($x, ($rTip.Y + 19), $w, 9, 4.5); $g.FillPath((Br $col), $dp); $dp.Dispose(); $x -= 8
        }
    }
  } catch { $script:lastPaintError = "$_" }
})
function Hit($p) {
    if ($rClose.Contains($p)) { return 'close' }; if ($rMin.Contains($p)) { return 'min' }; if ($rMax.Contains($p)) { return 'max' }
    if ($rAn.Contains($p) -and $script:phase -in 'before', 'ready', 'done') { return 'an' }
    if ($rCl.Contains($p) -and $script:phase -eq 'ready') { return 'cl' }
    ''
}
function Toggle-Max {
    if ($form.WindowState -eq 'Maximized') { $form.WindowState = 'Normal' }
    else { $form.SetMaxBounds([Windows.Forms.Screen]::FromControl($form).WorkingArea); $form.WindowState = 'Maximized' }
}
$canvas.Add_MouseMove({
    $h = Hit (ToLogical $_.Location)
    if ($h -ne $script:hover) { $script:hover = $h; Inv $rAn; Inv $rCl; Inv (RC ($rMin.X - 2) 0 120 46) }
    if ($h) { $canvas.Cursor = [Windows.Forms.Cursors]::Hand } else { $canvas.Cursor = [Windows.Forms.Cursors]::Default }
})
$canvas.Add_MouseLeave({ if ($script:hover) { $script:hover = ''; Inv $rAn; Inv $rCl; Inv (RC ($rMin.X - 2) 0 120 46) } })
$canvas.Add_MouseDown({
    $p = ToLogical $_.Location
    if ($p.Y -lt 44 -and -not (Hit $p) -and $_.Button -eq 'Left' -and $form.WindowState -eq 'Normal') { [Gfx]::DragWindow($form.Handle) }
})
$canvas.Add_MouseDoubleClick({
    $p = ToLogical $_.Location
    if ($p.Y -lt 44 -and -not (Hit $p)) { Toggle-Max }
})
$canvas.Add_MouseUp({
    switch (Hit (ToLogical $_.Location)) {
        'close' { $form.Close() }
        'min' { $form.WindowState = 'Minimized' }
        'max' { Toggle-Max }
        'an' { Start-Analyze }
        'cl' { Start-Clean }
    }
})

# 창 크기 변경 종료 후 레이아웃 재계산
$resizeTimer = New-Object Windows.Forms.Timer
$resizeTimer.Interval = 50
$resizeTimer.Add_Tick({
    $resizeTimer.Stop()
    Apply-Region
    Apply-Layout ([int]($form.ClientSize.Width / $Sc)) ([int]($form.ClientSize.Height / $Sc))
    Rebuild
})
$form.Add_SizeChanged({ $resizeTimer.Stop(); $resizeTimer.Start() })

# ---------- 분석 ----------
$script:rows = @()
function Add-Row($tag, $path, $size, $why, $act, $trunc = $false, [switch]$Always) {
    if ($size -lt 50MB -and -not $Always) { return }
    if ($trunc) { $why += ' (일부만 계산)' }
    if (-not $script:DestOK -and $act.Type -in 'movefiles', 'movefolder') { $act = @{ Type = 'info' }; $why += ' (이동할 드라이브 없음)' }
    $script:rows += [pscustomobject]@{ Tag = $tag; Path = $path; Size = $size; Why = $why; Act = $act }
}
function Scan-Size($path, $sec, $days = 0) { $w = New-Walk $path -maxSec $sec -olderDays $days; @{ Size = $w.Total; Trunc = $w.Truncated } }
function Fill-List {
    $script:filling = $true
    $lv.BeginUpdate(); $lv.Items.Clear()
    foreach ($k in $groupDef.Keys) {
        $list = @($script:rows | Where-Object Tag -eq $k | Sort-Object Size -Descending)
        if ($list.Count -eq 0) { continue }
        $h = New-Object Windows.Forms.ListViewItem($groupDef[$k])
        $h.Tag = @{ Act = @{ Type = 'header' }; Size = 0; Key = $k }
        [void]$lv.Items.Add($h)
        foreach ($r in $list) {
            $it = New-Object Windows.Forms.ListViewItem($r.Path.Replace($UserHome, '~').Replace('\', '/'))
            $sizeText = '-'; if ($r.Size -gt 0) { $sizeText = '{0} GB' -f (GB $r.Size) }
            [void]$it.SubItems.Add($sizeText); [void]$it.SubItems.Add($r.Why)
            $it.ForeColor = HexC $tagColor[$k]
            $it.Tag = @{ Act = $r.Act; Size = $r.Size; Path = $r.Path; Key = $k }
            [void]$lv.Items.Add($it)
            if ($r.Act.Type -eq 'cache') { $it.Checked = $true }
        }
    }
    $lv.EndUpdate()
    $script:filling = $false
    Update-Sum
}
function Start-Analyze {
    Set-Phase 'analyzing'; $script:rows = @(); $lv.Items.Clear()
    $L = $env:LOCALAPPDATA
    try {
        Say "살펴보는 중이에요 (1/5)`n임시 파일과 캐시를 확인하고 있어요"
        $cache = @(
            @($env:TEMP, '사용자 임시 파일 (2일 경과분)', 2), @("$env:SystemRoot\Temp", 'Windows 임시 파일 (2일 경과분, 일부 관리자 권한 필요)', 2),
            @("$L\CrashDumps", '프로그램 충돌 기록', 0), @("$L\D3DSCache", '그래픽 셰이더 캐시 (재생성)', 0),
            @("$L\npm-cache", 'npm 캐시 (재다운로드)', 0), @("$L\pip\Cache", 'pip 캐시 (재다운로드)', 0),
            @("$L\Yarn\Cache", 'yarn 캐시 (재다운로드)', 0),
            @("$L\Google\Chrome\User Data\Default\Cache", 'Chrome 캐시 (로그인·북마크 유지)', 0),
            @("$L\Microsoft\Edge\User Data\Default\Cache", 'Edge 캐시 (로그인·북마크 유지)', 0),
            @("$L\Microsoft\Windows\INetCache", '인터넷 임시 파일', 0), @("$L\Microsoft\Windows\WER", 'Windows 오류 보고서', 0)
        )
        foreach ($ce in $cache) { $r = Scan-Size $ce[0] 8 $ce[2]; Add-Row 'del' $ce[0] $r.Size $ce[1] @{ Type = 'cache'; Path = $ce[0]; Days = $ce[2] } $r.Trunc }
        Add-Row 'del' '휴지통' (Get-RecycleSize) '휴지통 비우기 (기본 선택 안 됨)' @{ Type = 'recycle' }

        Say "살펴보는 중이에요 (2/5)`n시스템 파일은 보기만 할게요"
        foreach ($f in 'hiberfil.sys', 'pagefile.sys', 'swapfile.sys') {
            $item = Get-Item -LiteralPath "$SL`:\$f" -Force
            if ($item) {
                if ($f -eq 'hiberfil.sys') { Add-Row 'check' $item.FullName $item.Length '최대 절전 파일. 미사용 시 관리자 권한으로 powercfg -h off 실행' @{ Type = 'info' } }
                else { Add-Row 'keep' $item.FullName $item.Length 'Windows 가상 메모리. 삭제 금지' @{ Type = 'info' } }
            }
        }
        if (Test-Path "$SL`:\Windows.old") {
            $r = Scan-Size "$SL`:\Windows.old" 20
            Add-Row 'check' "$SL`:\Windows.old" $r.Size '이전 Windows 백업. 디스크 정리 > 이전 Windows 설치에서 삭제' @{ Type = 'info' } $r.Trunc
        }
        $info = @{ Type = 'info' }
        # 시스템 폴더는 안내만 표시 (파일 수가 많아 크기를 측정하지 않음)
        foreach ($sys in @(@("$SL`:\Program Files", '설치된 프로그램. 이동 시 실행 불가'), @("$SL`:\Program Files (x86)", '설치된 프로그램 (32비트)'),
                           @("$SL`:\ProgramData", '프로그램 공용 데이터'), @($env:SystemRoot, 'Windows 시스템'))) {
            Add-Row 'keep' $sys[0] 0 $sys[1] $info -Always
        }

        Say "살펴보는 중이에요 (3/5)`nAppData를 둘러보는 중이에요"
        $skip = 'Temp', 'CrashDumps', 'D3DSCache', 'npm-cache', 'pip', 'Yarn'
        $t3 = Get-Date   # AppData는 폴더 수가 많아 전체 100초까지만 측정
        foreach ($d in Get-ChildItem $L -Directory -Force) {
            if ($skip -contains $d.Name -or ($d.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
            if (((Get-Date) - $t3).TotalSeconds -gt 100) { break }
            Say "살펴보는 중이에요 (3/5)`nAppData: $($d.Name)"
            $r = Scan-Size $d.FullName 4; $sz = $r.Size; $tr = $r.Trunc
            if ($sz -lt 200MB) { continue }
            switch -Regex ($d.Name) {
                '^Packages$' { Add-Row 'keep' $d.FullName $sz 'Microsoft Store 앱 데이터' $info $tr }
                'Docker|wsl' { Add-Row 'keep' $d.FullName $sz 'Docker/WSL 가상 디스크. 직접 이동 시 손상' $info $tr }
                '^Programs$' { Add-Row 'keep' $d.FullName $sz '사용자 설치 프로그램' $info $tr }
                '^Microsoft$' { Add-Row 'keep' $d.FullName $sz 'Windows/Office/Edge 데이터' $info $tr }
                '^(Google|BraveSoftware)$' { Add-Row 'keep' $d.FullName $sz '브라우저 프로필(로그인/북마크)' $info $tr }
                '^(Steam|Epic)' { Add-Row 'move' $d.FullName $sz "게임 런처. 런처 설정에서 라이브러리 위치를 ${DL}로 변경 (자동 이동 불가)" $info $tr }
                default { Add-Row 'check' $d.FullName $sz '프로그램 데이터. 용도 확인 후 판단' $info $tr }
            }
        }
        $t3 = Get-Date
        foreach ($d in Get-ChildItem $env:APPDATA -Directory -Force) {
            if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if (((Get-Date) - $t3).TotalSeconds -gt 50) { break }
            Say "살펴보는 중이에요 (3/5)`nAppData(Roaming): $($d.Name)"
            $r = Scan-Size $d.FullName 3
            Add-Row 'check' $d.FullName $r.Size 'Roaming 프로그램 데이터. 어떤 프로그램 건지 확인 후 판단' $info $r.Trunc
        }

        Say "살펴보는 중이에요 (4/5)`n프로젝트 폴더를 확인하고 있어요"
        $projPaths = @()
        foreach ($root in 'Desktop', 'Documents') {
            foreach ($d in Get-ChildItem (Join-Path $UserHome $root) -Directory -Force) {
                if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                Say "살펴보는 중이에요 (4/5)`n$root`: $($d.Name)"
                $r = Scan-Size $d.FullName 12
                if ($r.Size -ge 300MB) {
                    $projPaths += $d.FullName
                    Add-Row 'move' $d.FullName $r.Size "대용량 폴더. ${DL}로 이동 후 원래 위치에 정션 생성 (경로 유지)" @{ Type = 'movefolder'; Path = $d.FullName } $r.Trunc
                }
            }
        }

        Say "살펴보는 중이에요 (5/5)`n큰 파일을 찾고 있어요"
        $installerExt = '.exe', '.msi', '.iso', '.zip', '.7z', '.rar'
        $instSet = New-Object 'System.Collections.Generic.HashSet[string]'
        $dlw = New-Walk (Join-Path $UserHome 'Downloads') -exts $installerExt -olderDays 30 -maxSec 25
        foreach ($p in $dlw.ExtPaths) { [void]$instSet.Add($p) }
        if ($dlw.ExtPaths.Count -gt 0) {
            $isum = 0; foreach ($z in $dlw.ExtSizes) { $isum += $z }
            Add-Row 'move' "다운로드의 오래된 설치·압축 파일 ($($dlw.ExtPaths.Count)개)" $isum "30일 경과 exe/msi/iso/zip. 삭제 없이 ${DL}로 이동" @{ Type = 'movefiles'; Files = @($dlw.ExtPaths) }
        }
        foreach ($m in 'Desktop', 'Videos', 'Pictures', 'Music', 'Documents', 'Downloads') {
            $p = Join-Path $UserHome $m
            Say "살펴보는 중이에요 (5/5)`n큰 파일: $m"
            $w = New-Walk $p -min ($MinMB * 1MB) -exclude $projPaths -maxSec 35
            $files = @(); $sizes = @()
            for ($i = 0; $i -lt $w.BigPaths.Count; $i++) {
                if ($m -eq 'Downloads' -and $instSet.Contains($w.BigPaths[$i])) { continue }
                $files += $w.BigPaths[$i]; $sizes += $w.BigSizes[$i]
            }
            if ($files.Count -gt 0) {
                $sum = ($sizes | Measure-Object -Sum).Sum
                $top = (0..($files.Count - 1) | Sort-Object { $sizes[$_] } -Descending | Select-Object -First 3 | ForEach-Object { [IO.Path]::GetFileName($files[$_]) }) -join ', '
                Add-Row 'move' "$p ($($files.Count)개 파일)" $sum "${MinMB}MB 이상 대용량 파일. 예: $top" @{ Type = 'movefiles'; Files = $files } $w.Truncated
            }
        }
        foreach ($root in 'Desktop', 'Documents') {
            Say "살펴보는 중이에요 (5/5)`nnode_modules: $root"
            $w = New-Walk (Join-Path $UserHome $root) -findDir 'node_modules' -maxDepth 4 -maxSec 25
            if ($w.FoundDirs.Count -gt 0) {
                $nsum = 0; foreach ($n in $w.FoundDirs) { $nsum += (Scan-Size $n 4).Size }
                Add-Row 'del' "$root 의 node_modules ($($w.FoundDirs.Count)개)" $nsum 'npm install로 재생성 가능. 미사용 프로젝트만 선택' @{ Type = 'nodemodules'; Paths = @($w.FoundDirs) }
            }
        }
        Fill-List
        Set-Phase 'ready'; Update-Sum
    } catch {
        $script:lastErr = "$_"
        if ("$_" -ne 'closing') { Say "앗, 문제가 생겼어요: $_"; Set-Phase 'done' }
    }
}

# ---------- 청소 ----------
function Start-Clean {
    $checked = @($lv.CheckedItems)
    if ($checked.Count -eq 0) { Say '선택한 항목이 없어요'; return }
    $nDel = @($checked | Where-Object { $_.Tag.Act.Type -in 'cache', 'recycle', 'nodemodules' }).Count
    $nMove = $checked.Count - $nDel
    $hasFolder = @($checked | Where-Object { $_.Tag.Act.Type -eq 'movefolder' }).Count -gt 0
    $msg = "삭제 ${nDel}건, 이동 ${nMove}건을 진행할까요?`n`n옮기는 파일은 $Dest 에 보관되고, 지우지 않아요."
    if ($hasFolder) { $msg += "`n폴더를 옮기려면 그 폴더를 쓰는 프로그램(VS Code, 터미널 등)을 먼저 닫아 주세요." }
    if ([Windows.Forms.MessageBox]::Show($form, $msg, '미미치 청소 도우미', 'YesNo', 'Question') -ne 'Yes') { return }
    $script:prog = 0; Set-Phase 'cleaning'
    $before = (Get-PSDrive $SL).Free; $done = 0; $fails = @()
    try {
        foreach ($it in $checked) {
            $a = $it.Tag.Act
            Say ("열심히 정리하는 중이에요`n{0}" -f $it.Text)
            switch ($a.Type) {
                'cache' { [void](Clear-Dir $a.Path $a.Days); Write-Log 'delete-cache' $a.Path '' $it.Tag.Size }
                'recycle' { Clear-RecycleBin -Force -Confirm:$false; Write-Log 'empty-recyclebin' '' '' $it.Tag.Size }
                'nodemodules' { foreach ($p in $a.Paths) { Remove-Tree $p; Pump }; Write-Log 'delete-node_modules' ($a.Paths -join ';') '' $it.Tag.Size }
                'movefiles' {
                    if ((Free-Of $Dest) -lt ($it.Tag.Size * 1.02 + 100MB)) { $fails += "$($it.Text): 대상 드라이브 공간 부족 (건너뜀)" }
                    else { foreach ($f in $a.Files) { if (-not (Move-OneFile $f)) { $fails += "${f}: 이동 실패" }; Pump } }
                }
                'movefolder' { $r = Move-FolderWithJunction $a.Path; if ($r) { $fails += "$($it.Text): $r" } }
            }
            $done++; $script:prog = $done / $checked.Count; Inv $rFoot; Pump
        }
        Refresh-Free
        $gain = (Get-PSDrive $SL).Free - $before
        $txt = "정리가 끝났어요!`n$SL 드라이브 여유 공간이 {0} GB 늘었어요`n옮긴 파일은 $Dest 에 있고, 기록은 log.csv에 남겼어요" -f (GB $gain)
        if ($fails.Count -gt 0) { $txt += "`n건너뛰었거나 실패한 항목 $($fails.Count)건: $($fails[0])" }
        $lv.Items.Clear(); $script:sayText = $txt; Set-Phase 'done'
    } catch {
        if ("$_" -ne 'closing') { $script:sayText = "앗, 문제가 생겼어요: $_"; Set-Phase 'done' }
    }
}

# ---------- 자체 점검 (-SelfTest): 마우스·최대화·크기 변경 시뮬레이션 ----------
function Run-SelfTest {
    $form.Show()
    for ($i = 0; $i -lt 4; $i++) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 80 }
    $script:tOk = 0; $script:tBad = 0
    function T($name, $cond) { if ($cond) { $script:tOk++; "  PASS  $name" } else { $script:tBad++; "  FAIL  $name" } }
    function Pump-Until([scriptblock]$cond, $ms = 4000) { $end = (Get-Date).AddMilliseconds($ms); while ((Get-Date) -lt $end -and -not (& $cond)) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 30 }; Pump-Ms 120 }
    function Pump-Ms($ms) { $end = (Get-Date).AddMilliseconds($ms); while ((Get-Date) -lt $end) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 20 } }
    function Mouse($ev, $lx, $ly) {
        $a = [Windows.Forms.MouseEventArgs]::new([Windows.Forms.MouseButtons]::Left, 1, [int]($lx * $Sc), [int]($ly * $Sc), 0)
        [void][Windows.Forms.Control].GetMethod($ev, [Reflection.BindingFlags]'NonPublic,Instance').Invoke($canvas, [object[]]@($a))
        [Windows.Forms.Application]::DoEvents()
    }
    $e0 = $Error.Count
    "[화면 점검] 배율 x$Sc"
    Mouse 'OnMouseMove' ($rAn.X + 20) ($rAn.Y + 20)
    T "분석 버튼 위로 마우스를 옮기면 hover (현재 '$($script:hover)')" ($script:hover -eq 'an')
    Mouse 'OnMouseMove' 5 700
    T "빈 곳으로 옮기면 hover 해제" ($script:hover -eq '')
    Mouse 'OnMouseMove' ($rClose.X + 10) ($rClose.Y + 10)
    T "닫기 버튼 hover" ($script:hover -eq 'close')
    Mouse 'OnMouseMove' ($rMax.X + 10) ($rMax.Y + 10)
    T "최대화 버튼 hover" ($script:hover -eq 'max')
    Mouse 'OnMouseMove' ($rCl.X + 10) ($rCl.Y + 10)
    T "분석 전에는 '청소 시작' 위치가 반응하지 않음" ($script:hover -eq '')
    Toggle-Max; Pump-Until { $form.WindowState -eq 'Maximized' -and $rRes.Width -gt 840 }
    T "최대화" ($form.WindowState -eq 'Maximized' -and $rRes.Width -gt 840)
    Toggle-Max; Pump-Until { $form.WindowState -eq 'Normal' -and $rRes.Width -eq 840 }
    T "복원" ($form.WindowState -eq 'Normal' -and $rRes.Width -eq 840)
    $form.ClientSize = New-Object Drawing.Size ([int](1100 * $Sc)), ([int](820 * $Sc)); Pump-Until { $rRes.Width -eq 1040 }
    T "창을 키우면 결과 카드와 목록도 커짐 (카드 폭 $($rRes.Width))" ($rRes.Width -eq 1040 -and $lv.Width -gt [int](900 * $Sc))
    $form.ClientSize = New-Object Drawing.Size ([int](800 * $Sc)), ([int](660 * $Sc)); Pump-Until { $rRes.Width -le 740 }
    T "창을 줄이면 최소 크기(780x640)까지 줄어듦 (카드 폭 $($rRes.Width))" ($rRes.Width -ge 720 -and $rRes.Width -le 740)
    $form.ClientSize = New-Object Drawing.Size ([int](900 * $Sc)), ([int](756 * $Sc)); Pump-Until { $rRes.Width -eq 840 }
    $script:filling = $true
    foreach ($d in @(@('del', $env:TEMP, 3GB, '임시', @{ Type = 'cache' }), @('move', "$UserHome\Videos", 5GB, '큰 파일', @{ Type = 'movefiles' }), @('keep', $env:SystemRoot, 30GB, '본체', @{ Type = 'info' }))) { Add-Row $d[0] $d[1] $d[2] $d[3] $d[4] }
    Fill-List; Set-Phase 'ready'; Pump-Ms 300
    T "결과 단계: 목록이 보이고 행이 채워짐 (행 $($lv.Items.Count))" ($lv.Visible -and $lv.Items.Count -ge 5)
    T "임시파일 항목은 기본 체크, 큰 파일은 해제" ($lv.CheckedItems.Count -eq 1)
    Mouse 'OnMouseMove' ($rCl.X + 10) ($rCl.Y + 10)
    T "결과 단계에서는 '청소 시작' 버튼이 반응함 (hover '$($script:hover)')" ($script:hover -eq 'cl')
    foreach ($ph in 'analyzing', 'cleaning', 'done', 'before') { Set-Phase $ph; Pump-Ms 150 }
    T "모든 단계로 바꿔 그려도 그리기 오류 없음" (-not $script:lastPaintError)
    $bmp = New-Object Drawing.Bitmap $form.Width, $form.Height
    $form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height))); $bmp.Dispose()
    T "그리기 오류 없음 ($($script:lastPaintError))" (-not $script:lastPaintError)
    T "테스트 중 처리 안 된 오류 없음 ($($Error.Count - $e0)건)" (($Error.Count - $e0) -eq 0)
    if ($Error.Count -gt $e0) { "--- 처리 안 된 오류 ---"; $Error[0..([math]::Min(5, $Error.Count - $e0 - 1))] | ForEach-Object { '  ' + $_.Exception.Message + '  @ ' + $_.InvocationInfo.PositionMessage.Split("`n")[0..1] -join ' ' } }
    "결과: PASS $($script:tOk) / FAIL $($script:tBad)"
    $form.Close()
}

$form.Add_FormClosing({
    if ($script:phase -eq 'cleaning') {
        $_.Cancel = $true
        [void][Windows.Forms.MessageBox]::Show($form, '정리하는 동안에는 창을 닫을 수 없어요. 끝난 뒤에 닫아 주세요.', '미미치 청소 도우미', 'OK', 'Information')
        return
    }
    $script:closing = $true
})
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 80
$timer.Add_Tick({
    if ($form.WindowState -eq 'Minimized') { return }
    $script:frame++
    Inv $rIllus
    if (($script:frame % 45) -eq 0) { $script:tip++; Inv $rTip }
})
$timer.Start()

Refresh-Free
Set-Phase 'before'
if ($SelfTest) { Run-SelfTest; exit }

# 스크린샷용 (-Snapshot): 예시 데이터로 화면을 PNG로 저장
if ($Snapshot) {
    $timer.Stop()
    if ($SnapW -gt 0) {
        $form.ClientSize = New-Object Drawing.Size ([int]($SnapW * $Sc)), ([int]($SnapH * $Sc))
        Apply-Region; Apply-Layout $SnapW $SnapH
    }
    if ($AutoAnalyze) {
        $script:trace = Join-Path $PSScriptRoot 'trace.log'; Set-Content -Path $script:trace -Value 'trace start'
        $form.Opacity = 0; $form.ShowInTaskbar = $false   # 점검용이라 화면에는 보이지 않게
        $form.Show(); [Windows.Forms.Application]::DoEvents()
        $sw = [Diagnostics.Stopwatch]::StartNew(); Start-Analyze; "analysis took $([int]$sw.Elapsed.TotalSeconds)s, rows=$($script:rows.Count), phase=$($script:phase), lastErr=[$($script:lastErr)]"
        $bmp = New-Object Drawing.Bitmap $form.Width, $form.Height
        $form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
        $bmp.Save($Snapshot, [Drawing.Imaging.ImageFormat]::Png)
        $script:rows | Sort-Object Size -Descending | Select-Object -First 8 | ForEach-Object { "{0,-5} {1,6} GB  {2}" -f $_.Tag, (GB $_.Size), $_.Path }
        $form.Close(); exit
    }
    $script:filling = $true
    $demo = @(
        @('del', $env:TEMP, 3.2GB, '사용자 임시 파일 (2일 경과분)', @{ Type = 'cache' }),
        @('del', "$env:LOCALAPPDATA\npm-cache", 1.8GB, 'npm 캐시 (재다운로드)', @{ Type = 'cache' }),
        @('del', "$UserHome\Desktop 의 node_modules (4개)", 1.1GB, 'npm install로 재생성 가능. 미사용 프로젝트만 선택', @{ Type = 'nodemodules' }),
        @('move', "$UserHome\Videos (8개 파일)", 14.5GB, "${MinMB}MB 이상 대용량 파일. 예: record.mp4, trip.mov", @{ Type = 'movefiles' }),
        @('move', "$UserHome\Documents\old-project", 6.3GB, "대용량 폴더. ${DL}로 이동 후 원래 위치에 정션 생성 (경로 유지)", @{ Type = 'movefolder' }),
        @('check', "$env:APPDATA\SomeApp", 1.2GB, '프로그램 데이터. 용도 확인 후 판단', @{ Type = 'info' }),
        @('keep', $env:SystemRoot, 30GB, 'Windows 시스템', @{ Type = 'info' })
    )
    foreach ($d in $demo) { Add-Row $d[0] $d[1] $d[2] $d[3] $d[4] }
    Fill-List
    $script:prog = 0.6; $script:frame = $SnapFrame
    if ($SnapPhase -eq 'done') { $script:sayText = "정리가 끝났어요!`n$SL 드라이브 여유 공간이 12.4 GB 늘었어요`n옮긴 파일은 $DL`:\정리대기 에 있고, 기록은 log.csv에 남겼어요"; $lv.Items.Clear() }
    if ($SnapPhase -eq 'analyzing') { $script:sayText = "살펴보는 중이에요 (3/5)`nAppData를 둘러보는 중이에요" }
    Set-Phase $SnapPhase
    $form.Show()
    for ($i = 0; $i -lt 4; $i++) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 120 }
    $bmp = New-Object Drawing.Bitmap $form.Width, $form.Height
    $form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
    $bmp.Save($Snapshot, [Drawing.Imaging.ImageFormat]::Png)
    $form.Close()
    exit
}

if ($AutoAnalyze) { $form.Add_Shown({ Start-Analyze }) }
[void]$form.ShowDialog()