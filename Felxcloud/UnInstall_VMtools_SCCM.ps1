$ErrorActionPreference = 'Stop'

$logRoot = Join-Path $env:ProgramData 'VMwareToolsUninstall'
New-Item -Path $logRoot -ItemType Directory -Force | Out-Null
$wrapperLog = Join-Path $logRoot 'SCCM_Uninstall_Wrapper.log'
$scriptPath = Join-Path $PSScriptRoot 'UnInstall_VMtools_Local_NOreboots.ps1'

function Write-WrapperLog {
    param([Parameter(Mandatory = $true)][string]$Message)
    Add-Content -Path $wrapperLog -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"
}

if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    Write-WrapperLog "ERROR: uninstall script not found at '$scriptPath'."
    exit 1
}

# Ensure the child process uses 64-bit Windows PowerShell, including when SCCM
# accidentally starts this wrapper in a 32-bit process on 64-bit Windows.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $powerShellExe = Join-Path $env:WINDIR 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
}
else {
    $powerShellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
}

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$stdoutPath = Join-Path $logRoot "SCCM_Uninstall_$timestamp.stdout.log"
$stderrPath = Join-Path $logRoot "SCCM_Uninstall_$timestamp.stderr.log"

try {
    Write-WrapperLog "Starting '$scriptPath' using '$powerShellExe'."
    $arguments = @(
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$scriptPath`""
    )

    $process = Start-Process -FilePath $powerShellExe `
        -ArgumentList $arguments `
        -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath

    foreach ($streamPath in @($stdoutPath, $stderrPath)) {
        if (Test-Path -LiteralPath $streamPath) {
            Get-Content -LiteralPath $streamPath | ForEach-Object { Write-WrapperLog $_ }
        }
    }

    Write-WrapperLog "Uninstall script exited with code $($process.ExitCode)."
    exit $process.ExitCode
}
catch {
    Write-WrapperLog "ERROR: $($_.Exception.Message)"
    exit 1
}
