param(
    [switch]$KeepData
)

$ErrorActionPreference = 'Stop'

function Test-UninstallerAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-UninstallerAdministrator)) {
    Write-Error 'Please run this uninstaller as Administrator.'
    exit 1
}

$installDir = Join-Path $env:ProgramFiles 'PcNinja\WinUpdateTool'
$installParentDir = Join-Path $env:ProgramFiles 'PcNinja'
$programDataDir = Join-Path $env:ProgramData 'PcNinja\WinUpdateTool'
$programDataParentDir = Join-Path $env:ProgramData 'PcNinja'
$startMenuDir = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\PcNinja'
$startMenuShortcut = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\PcNinja\WinUpdate Tool.lnk'
$desktopShortcut = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'WinUpdate Tool.lnk'
$uninstallKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PcNinja WinUpdate Tool'

Set-Location -LiteralPath $env:TEMP

function Remove-EmptyDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ((Test-Path -LiteralPath $Path) -and -not (Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $Path -Force
    }
}

try {
    Unregister-ScheduledTask -TaskName 'PcNinja WinUpdate Tool' -TaskPath '\PcNinja\' -Confirm:$false -ErrorAction Stop
    Write-Host 'Scheduled task removed.'
}
catch {
    Write-Host 'Scheduled task was not present.'
}

try {
    Unregister-ScheduledTask -TaskName 'PcNinja WinUpdate Tool Retry' -TaskPath '\PcNinja\' -Confirm:$false -ErrorAction Stop
    Write-Host 'Retry task removed.'
}
catch {
    Write-Host 'Retry task was not present.'
}

try {
    Unregister-ScheduledTask -TaskName 'PcNinja WinUpdate Tool Run Once' -TaskPath '\PcNinja\' -Confirm:$false -ErrorAction Stop
    Write-Host 'Run-once task removed.'
}
catch {
    Write-Host 'Run-once task was not present.'
}

try {
    $scheduleService = New-Object -ComObject Schedule.Service
    $scheduleService.Connect()
    $rootFolder = $scheduleService.GetFolder('\')
    $rootFolder.DeleteFolder('PcNinja', 0)
    Write-Host 'Scheduled task folder removed.'
}
catch {
    Write-Host 'Scheduled task folder was not present or was not empty.'
}

foreach ($path in @($startMenuShortcut, $desktopShortcut)) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

if (Test-Path -LiteralPath $uninstallKey) {
    Remove-Item -LiteralPath $uninstallKey -Recurse -Force
}

if (Test-Path -LiteralPath $installDir) {
    Remove-Item -LiteralPath $installDir -Recurse -Force
}

if (-not $KeepData -and (Test-Path -LiteralPath $programDataDir)) {
    Remove-Item -LiteralPath $programDataDir -Recurse -Force
}

try {
    if ([System.Diagnostics.EventLog]::SourceExists('PcNinja WinUpdate Tool')) {
        [System.Diagnostics.EventLog]::DeleteEventSource('PcNinja WinUpdate Tool')
        Write-Host 'Event Log source removed.'
    }
}
catch {
    Write-Host "Event Log source was not removed: $($_.Exception.Message)"
}

Remove-EmptyDirectory -Path $startMenuDir
Remove-EmptyDirectory -Path $installParentDir
if (-not $KeepData) {
    Remove-EmptyDirectory -Path $programDataParentDir
}

Write-Host 'PcNinja WinUpdate Tool uninstalled.'
if ($KeepData) {
    Write-Host "Config and logs were kept here: $programDataDir"
}


