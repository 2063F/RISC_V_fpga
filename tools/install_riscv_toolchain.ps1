# install_riscv_toolchain.ps1
# Windows 用の RISC-V ツールチェーン導入支援スクリプト
#
# 使い方:
#   powershell -ExecutionPolicy Bypass -File tools/install_riscv_toolchain.ps1

$ErrorActionPreference = 'Stop'

$toolchainDir = Join-Path $env:USERPROFILE 'riscv-toolchain'
$binDir = Join-Path $toolchainDir 'bin'

Write-Host "RISC-V toolchain will be installed under: $toolchainDir"

# Check for winget
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'winget was not found. Install winget first and rerun this script.'
}

function Test-Toolchain {
    param(
        [string]$CommandName,
        [string]$DisplayName
    )

    $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue
    if ($cmd) {
        Write-Host "OK: $DisplayName -> $($cmd.Source)"
        return $true
    }

    Write-Warning "Not found yet: $DisplayName"
    return $false
}

# Ask the user whether to install the package.
$confirm = Read-Host 'Install RISC-V toolchain using winget? (Y/N)'
if ($confirm -notin @('Y', 'y')) {
    Write-Host 'Installation cancelled.'
    exit 0
}

# Install a commonly used RISC-V toolchain package if available.
# The exact package name may vary by environment, so this script prints guidance if it fails.
try {
    winget install --id "RISC-V.CPP" --source winget -e --accept-source-agreements --accept-package-agreements
    Write-Host 'Install command completed.'
}
catch {
    Write-Warning "Automatic install failed. Please install a RISC-V toolchain manually and add its bin directory to PATH."
    Write-Warning 'Typical tools needed: riscv64-unknown-elf-gcc, riscv64-unknown-elf-objcopy, riscv64-unknown-elf-objdump'
}

# Update current session PATH if the common install directory now exists.
if (Test-Path $binDir -PathType Container) {
    if ($env:Path -notlike "*$binDir*") {
        $env:Path = "$env:Path;$binDir"
        Write-Host "Updated current session PATH with: $binDir"
    }
}

# Verify tools in the current session.
$allGood = $true
foreach ($tool in @(
    @{ Name = 'riscv64-unknown-elf-gcc'; Display = 'RISC-V GCC' },
    @{ Name = 'riscv64-unknown-elf-objcopy'; Display = 'RISC-V objcopy' },
    @{ Name = 'riscv64-unknown-elf-objdump'; Display = 'RISC-V objdump' }
)) {
    if (-not (Test-Toolchain -CommandName $tool.Name -DisplayName $tool.Display)) {
        $allGood = $false
    }
}

if ($allGood) {
    Write-Host ''
    Write-Host 'Toolchain verification succeeded.'
}
else {
    Write-Host ''
    Write-Host 'If the commands are still not found, open a new PowerShell window and run:'
    Write-Host '  Get-Command riscv64-unknown-elf-gcc'
    Write-Host '  where.exe riscv64-unknown-elf-gcc'
}

# Print instructions for manual PATH setup
Write-Host ''
Write-Host 'If needed, add the toolchain directory to PATH with:'
Write-Host "  [Environment]::SetEnvironmentVariable('Path', \$env:Path + ';$binDir', 'User')"
Write-Host ''
Write-Host 'Then verify with:'
Write-Host '  riscv64-unknown-elf-gcc --version'
Write-Host '  riscv64-unknown-elf-objcopy --version'
