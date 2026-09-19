# uart_monitor.ps1
# ボードの UART 出力を表示する。対話モードでは打った文字をそのまま送る。
#
# 使い方:
#   powershell -ExecutionPolicy Bypass -File tools/uart_monitor.ps1
#   powershell -ExecutionPolicy Bypass -File tools/uart_monitor.ps1 -Seconds 10 -Send 'Z'
#   powershell -ExecutionPolicy Bypass -File tools/uart_monitor.ps1 -Interactive
#   powershell -ExecutionPolicy Bypass -File tools/uart_monitor.ps1 -Port COM5 -Baud 115200
#
# ポートを省略すると、シリアルポートが1つだけならそれを使います。

[CmdletBinding()]
param(
    # 使用するシリアルポート (省略時は自動検出)
    [string]$Port,
    # ボーレート。uart_tx.v / uart_rx.v は 50MHz / 434 = 115200bps 固定
    [int]$Baud = 115200,
    # 受信を続ける秒数 (対話モードでは無視)
    [int]$Seconds = 8,
    # 受信開始からこの秒数後に送る文字列 (エコー確認用)。空なら何も送らない
    [string]$Send = '',
    [int]$SendAfter = 3,
    # 打った文字をそのまま送る。Esc または Ctrl+] で終了
    [switch]$Interactive,
    # 受信バイトを16進でも表示する (文字化けの切り分け用)
    [switch]$ShowHex
)

$ErrorActionPreference = 'Stop'

if (-not $Port) {
    $ports = @([System.IO.Ports.SerialPort]::GetPortNames())
    if ($ports.Count -eq 0) {
        throw 'シリアルポートが見つかりません。ボードの USB 接続を確認してください。'
    }
    if ($ports.Count -gt 1) {
        throw "シリアルポートが複数あります: $($ports -join ', ')`n-Port で指定してください。"
    }
    $Port = $ports[0]
}

function Show-Chunk {
    param([string]$Text)
    if (-not $Text) { return }
    if ($ShowHex) {
        $hex = ($Text.ToCharArray() | ForEach-Object { '{0:x2}' -f [int]$_ }) -join ' '
        Write-Host -NoNewline "$($Text -replace "`r", '')"
        Write-Host -NoNewline " <$hex>" -ForegroundColor DarkGray
    } else {
        Write-Host -NoNewline ($Text -replace "`r", '')
    }
}

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
$sp.ReadTimeout  = 200
$sp.WriteTimeout = 1000
# DTR/RTS はボードのリセットに配線されていることがあるので既定のまま触らない。

try {
    try {
        $sp.Open()
    } catch {
        throw "$Port を開けません: $($_.Exception.Message)`n" +
              'TeraTerm など他の端末ソフトが開いていないか確認してください。'
    }

    $sp.DiscardInBuffer()

    if ($Interactive) {
        Write-Host "Port    : $Port @ $Baud bps (8N1)"
        Write-Host '打った文字がそのままボードへ送られます。Esc または Ctrl+] で終了。'
        Write-Host ('-' * 60)

        $txCount = 0
        $rxCount = 0

        while ($true) {
            # 受信
            $chunk = $sp.ReadExisting()
            if ($chunk) {
                $rxCount += $chunk.Length
                Show-Chunk $chunk
            }

            # 送信
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)

                # Esc、または Ctrl+] で終了
                if ($key.Key -eq 'Escape' -or
                    ($key.Modifiers -band [ConsoleModifiers]::Control) -and $key.KeyChar -eq ']') {
                    break
                }

                $ch = $key.KeyChar
                if ($key.Key -eq 'Enter') { $ch = "`r" }

                if ($ch -ne [char]0) {
                    $sp.Write([string]$ch)
                    $txCount++
                }
            }

            Start-Sleep -Milliseconds 20
        }

        Write-Host ''
        Write-Host ('-' * 60)
        Write-Host "sent $txCount byte(s), received $rxCount byte(s)."
        return
    }

    # --- 非対話モード ---------------------------------------------------------
    Write-Host "Port    : $Port @ $Baud bps (8N1)"
    Write-Host "Listening for $Seconds second(s)..."
    if ($Send) { Write-Host "Will send '$Send' after $SendAfter second(s)" }
    Write-Host ('-' * 60)

    $deadline = (Get-Date).AddSeconds($Seconds)
    $sendAt   = (Get-Date).AddSeconds($SendAfter)
    $sent     = -not $Send
    $total    = 0

    while ((Get-Date) -lt $deadline) {
        if (-not $sent -and (Get-Date) -ge $sendAt) {
            $sp.Write($Send)
            Write-Host ''
            Write-Host "[sent '$Send']" -ForegroundColor Yellow
            $sent = $true
        }

        $chunk = $sp.ReadExisting()
        if ($chunk) {
            $total += $chunk.Length
            Show-Chunk $chunk
        }

        Start-Sleep -Milliseconds 50
    }

    Write-Host ''
    Write-Host ('-' * 60)
    Write-Host "$total bytes received."

    if ($total -eq 0) {
        Write-Warning '1バイトも受信できませんでした。'
        Write-Host '  - ビットストリームが UART を使うプログラム入りか確認してください'
        Write-Host '    (src/fpga_top.v の INIT_FILE)'
        Write-Host '  - ボーレートは 115200bps 固定です (uart_tx.v の CLK_DIV = 434)'
        Write-Host '  - リセット (S1) を押すとプログラムが最初から走り直します'
    }
}
finally {
    if ($sp.IsOpen) { $sp.Close() }
    $sp.Dispose()
}
