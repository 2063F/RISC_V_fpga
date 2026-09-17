# install_riscv_toolchain.ps1
# Windows 用の RISC-V ツールチェーン導入支援スクリプト
#
# 使い方:
#   powershell -ExecutionPolicy Bypass -File tools/install_riscv_toolchain.ps1
#
# 本プロジェクトは RV32IM (圧縮命令なし) の bare-metal ツールチェーンを使います。
# ツール名の接頭辞は配布元によって異なり、どちらでもビルドできます:
#   - riscv-none-elf-*        (xPack 版。xpm で入る)
#   - riscv64-unknown-elf-*   (SiFive / crosstool-NG 系の一般的な名前)

$ErrorActionPreference = 'Stop'

# 探索する接頭辞。先に見つかったほうを採用する。
$prefixes = @('riscv-none-elf', 'riscv64-unknown-elf')
$tools    = @('gcc', 'objcopy', 'objdump')

# PATH に無くても xPack の既定インストール先は直接見に行く。
$xpackRoot = Join-Path $env:APPDATA 'xPacks\@xpack-dev-tools\riscv-none-elf-gcc'

function Find-ToolchainOnPath {
    foreach ($p in $prefixes) {
        $gcc = Get-Command "$p-gcc" -ErrorAction SilentlyContinue
        if ($gcc) {
            return [pscustomobject]@{
                Prefix = $p
                BinDir = Split-Path $gcc.Source -Parent
                Source = 'PATH'
            }
        }
    }
    return $null
}

function Find-ToolchainInXpack {
    if (-not (Test-Path $xpackRoot -PathType Container)) { return $null }

    # 複数バージョンが入っている場合は新しいものを優先する。
    $candidates = Get-ChildItem $xpackRoot -Directory |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName '.content\bin' } |
        Where-Object { Test-Path (Join-Path $_ 'riscv-none-elf-gcc.exe') }

    if ($candidates) {
        return [pscustomobject]@{
            Prefix = 'riscv-none-elf'
            BinDir = $candidates[0]
            Source = 'xPack'
        }
    }
    return $null
}

function Show-Toolchain {
    param([Parameter(Mandatory)] $Toolchain)

    $ok = $true
    foreach ($t in $tools) {
        $exe = Join-Path $Toolchain.BinDir "$($Toolchain.Prefix)-$t.exe"
        if (Test-Path $exe) {
            Write-Host "  OK: $($Toolchain.Prefix)-$t"
        }
        else {
            Write-Warning "  Missing: $($Toolchain.Prefix)-$t"
            $ok = $false
        }
    }
    return $ok
}

# -----------------------------------------------------------------------------
# 1. すでに使えるツールチェーンがあるか調べる
# -----------------------------------------------------------------------------
$found = Find-ToolchainOnPath
if (-not $found) { $found = Find-ToolchainInXpack }

if ($found) {
    Write-Host "RISC-V toolchain found ($($found.Source)): $($found.BinDir)"
    Write-Host "Prefix: $($found.Prefix)-*"
    Write-Host ''
    $complete = Show-Toolchain -Toolchain $found

    if ($found.Source -eq 'xPack') {
        Write-Host ''
        Write-Warning 'This toolchain is installed but not on PATH.'
        Write-Host 'Add it for the current session with:'
        Write-Host "  `$env:Path += ';$($found.BinDir)'"
        Write-Host 'Or permanently with:'
        Write-Host "  [Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path','User') + ';$($found.BinDir)', 'User')"
    }

    if ($complete) {
        Write-Host ''
        Write-Host 'Toolchain verification succeeded.'
        Write-Host ''
        Write-Host 'Reminder: this CPU implements RV32IM only (no compressed instructions).'
        Write-Host 'Always build with:  -march=rv32im -mabi=ilp32'
        exit 0
    }

    Write-Warning 'The toolchain is incomplete. Reinstall it, or install the xPack build below.'
}
else {
    Write-Host 'No RISC-V toolchain found on PATH or under the xPack install directory.'
}

# -----------------------------------------------------------------------------
# 2. 見つからなければ xpm (Node.js) 経由で入れる
#    winget には RISC-V の bare-metal GCC パッケージが存在しないため使わない。
# -----------------------------------------------------------------------------
Write-Host ''
Write-Host 'The xPack build can be installed with xpm, which needs Node.js (npm).'

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Warning 'Node.js was not found. Install it first:'
    Write-Host '  winget install --id OpenJS.NodeJS.LTS -e'
    Write-Host 'Then reopen PowerShell and rerun this script.'
    exit 1
}

$confirm = Read-Host 'Install the RISC-V toolchain with xpm now? (Y/N)'
if ($confirm -notin @('Y', 'y')) {
    Write-Host 'Installation cancelled. To do it manually:'
    Write-Host '  npm install --global xpm'
    Write-Host '  xpm install --global @xpack-dev-tools/riscv-none-elf-gcc@latest'
    exit 0
}

if (-not (Get-Command xpm -ErrorAction SilentlyContinue)) {
    Write-Host 'Installing xpm...'
    npm install --global xpm
}

Write-Host 'Installing @xpack-dev-tools/riscv-none-elf-gcc...'
xpm install --global '@xpack-dev-tools/riscv-none-elf-gcc@latest'

$installed = Find-ToolchainInXpack
if (-not $installed) {
    Write-Warning 'Install finished but the toolchain was not found under:'
    Write-Warning "  $xpackRoot"
    Write-Host 'Locate riscv-none-elf-gcc.exe manually and add its directory to PATH.'
    exit 1
}

Write-Host ''
Write-Host "Installed to: $($installed.BinDir)"
[void](Show-Toolchain -Toolchain $installed)
Write-Host ''
Write-Host 'Add it to PATH permanently with:'
Write-Host "  [Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path','User') + ';$($installed.BinDir)', 'User')"
Write-Host ''
Write-Host 'Reminder: this CPU implements RV32IM only (no compressed instructions).'
Write-Host 'Always build with:  -march=rv32im -mabi=ilp32'
