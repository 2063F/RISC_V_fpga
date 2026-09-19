# program.ps1
# Tang Primer 25K へビットストリームを書き込む
#
# 使い方:
#   powershell -ExecutionPolicy Bypass -File tools/program.ps1           # SRAM (揮発)
#   powershell -ExecutionPolicy Bypass -File tools/program.ps1 -Flash    # 外部SPIフラッシュ (永続)
#   powershell -ExecutionPolicy Bypass -File tools/program.ps1 -ScanOnly # 検出のみ
#
# SRAM は数秒で終わり電源を切ると消えます。まず SRAM で動作を確認してから
# フラッシュに焼くのが安全です。

[CmdletBinding()]
param(
    # 外部SPIフラッシュに書き込む (電源を切っても残る)
    [switch]$Flash,
    # ケーブルとデバイスの検出だけ行って終了する
    [switch]$ScanOnly
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$fsFile   = Join-Path $repoRoot 'gowin_project\riscv_cpu\impl\pnr\riscv_cpu.fs'

# build.tcl が使っているデバイス型番に合わせること。
$device = 'GW5A-25A'

# programmer_cli --run の番号:
#   2 = SRAM Program, 4 = SRAM Program and Verify
#   8 = exFlash Erase,Program, 9 = exFlash Erase,Program,Verify
$operation = if ($Flash) { 9 } else { 4 }

# -----------------------------------------------------------------------------
# programmer_cli の呼び出し
# -----------------------------------------------------------------------------
# programmer_cli.exe は Python を同梱した実行ファイルで、PYTHONIOENCODING を
# 継承してしまう。開発環境によっては "utf-8:surrogateescape" などが設定されて
# おり、同梱 Python がその指定を解釈できずに
#   Fatal Python error: Py_Initialize: can't initialize sys standard streams
#   LookupError: unknown encoding: utf-8:surrogateescape
# で即死する。子プロセスの間だけ Python 系の変数を外して呼ぶ。
function Invoke-Programmer {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $saved = @{}
    foreach ($name in 'PYTHONIOENCODING', 'PYTHONHOME', 'PYTHONPATH', 'PYTHONSTARTUP') {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name)
        Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    }

    try {
        $output = & $script:programmer @Arguments 2>&1 | Out-String
        return [pscustomobject]@{ Output = $output; ExitCode = $LASTEXITCODE }
    }
    finally {
        foreach ($name in @($saved.Keys)) {
            if ($null -ne $saved[$name] -and $saved[$name] -ne '') {
                Set-Item "Env:$name" $saved[$name]
            }
        }
    }
}

# -----------------------------------------------------------------------------
# Programmer を探す
# -----------------------------------------------------------------------------
$programmer = Get-Command 'programmer_cli' -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty Source -First 1

if (-not $programmer) {
    # @() で必ず配列にする。1件だけのとき文字列が返り、[0] が先頭1文字になる。
    $candidates = @(
        Get-ChildItem 'C:\Gowin' -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName 'Programmer\bin\programmer_cli.exe' } |
            Where-Object { Test-Path $_ }
    )

    if (-not $candidates) {
        throw 'programmer_cli.exe が見つかりません。Gowin Programmer を導入するか PATH に追加してください。'
    }
    $programmer = $candidates[0]
}

Write-Host "Programmer: $programmer"

# -----------------------------------------------------------------------------
# ボードが繋がっているか確認する
# -----------------------------------------------------------------------------
Write-Host ''
Write-Host 'Scanning for the board...'
$scan = Invoke-Programmer -Arguments @('--scan')
Write-Host $scan.Output.Trim()

if ($scan.Output -match 'Fatal Python error|LookupError') {
    Write-Host ''
    Write-Warning 'programmer_cli の起動に失敗しました (同梱 Python の初期化エラー)。'
    Write-Host '  PYTHONIOENCODING / PYTHONHOME / PYTHONPATH を外してから実行してください。'
    exit 1
}

if ($scan.Output -notmatch 'Target Cable') {
    Write-Host ''
    Write-Warning 'JTAG ケーブルが見つかりません。USB 接続とドライバを確認してください。'
    exit 1
}

if ($scan.Output -match 'No Gowin devices found') {
    Write-Host ''
    Write-Warning 'ボードが検出されませんでした。'
    Write-Host '  - Tang Primer 25K Dock の USB-C を PC に接続してください'
    Write-Host '    (給電専用ポートではなく、BL616 デバッガ側)'
    Write-Host '  - 接続すると JTAG とシリアルポートが現れます'
    exit 1
}

if ($ScanOnly) {
    Write-Host ''
    Write-Host 'Scan only - nothing was programmed.'
    exit 0
}

# -----------------------------------------------------------------------------
# ビットストリームを確認する
# -----------------------------------------------------------------------------
if (-not (Test-Path $fsFile)) {
    throw "ビットストリームがありません: $fsFile`n先に build.tcl を実行してください (README の手順を参照)。"
}

$fsInfo = Get-Item $fsFile

# ソースより古いビットストリームを焼いてしまう事故を防ぐ。
$newerSources = @(
    Get-ChildItem (Join-Path $repoRoot 'src') -Filter *.v -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt $fsInfo.LastWriteTime }
)

if ($newerSources.Count -gt 0) {
    Write-Warning 'ビットストリームより新しいソースがあります:'
    $newerSources | ForEach-Object { Write-Host "    $($_.Name)" }
    Write-Host '  build.tcl を実行し直してから書き込んでください。'
    $answer = Read-Host '古いビットストリームのまま書き込みますか? (Y/N)'
    if ($answer -notin @('Y', 'y')) {
        Write-Host 'Cancelled.'
        exit 0
    }
}

Write-Host ''
Write-Host "Bitstream: $fsFile"
Write-Host "  built at $($fsInfo.LastWriteTime)"
Write-Host "Device   : $device"
Write-Host "Target   : $(if ($Flash) { 'external SPI flash (永続)' } else { 'SRAM (電源を切ると消えます)' })"
Write-Host ''

$result = Invoke-Programmer -Arguments @(
    '--device', $device,
    '--run',    "$operation",
    '--fsFile', $fsFile
)
Write-Host $result.Output.Trim()

Write-Host ''
if ($result.ExitCode -eq 0) {
    Write-Host 'Programming finished.'
    Write-Host ''
    Write-Host 'loop55.hex を焼いた場合の期待動作:'
    Write-Host '  LED[0] : 約1.5Hz で点滅 (クロックが生きている)'
    Write-Host '  LED[1] : 点灯しっぱなし (CPU が x1 = 55 を計算し終えた)'
    Write-Host '  リセットは S1。LED[1] が一瞬消えて再点灯すれば CPU が動いています。'
} else {
    Write-Warning "Programming failed (exit code $($result.ExitCode))."
}

exit $result.ExitCode
