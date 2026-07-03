$ErrorActionPreference = 'SilentlyContinue'

$programDataDir = Join-Path $env:ProgramData 'PcNinja\WinUpdateTool'
$programDataParentDir = Join-Path $env:ProgramData 'PcNinja'

function Remove-EmptyDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ((Test-Path -LiteralPath $Path) -and -not (Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

foreach ($taskName in @(
    'PcNinja WinUpdate Tool',
    'PcNinja WinUpdate Tool Retry',
    'PcNinja WinUpdate Tool Run Once'
)) {
    Unregister-ScheduledTask -TaskName $taskName -TaskPath '\PcNinja\' -Confirm:$false -ErrorAction SilentlyContinue
}

try {
    $scheduleService = New-Object -ComObject Schedule.Service
    $scheduleService.Connect()
    $rootFolder = $scheduleService.GetFolder('\')
    $rootFolder.DeleteFolder('PcNinja', 0)
}
catch {
    $null = $_
}

if (Test-Path -LiteralPath $programDataDir) {
    Remove-Item -LiteralPath $programDataDir -Recurse -Force -ErrorAction SilentlyContinue
}

try {
    if ([System.Diagnostics.EventLog]::SourceExists('PcNinja WinUpdate Tool')) {
        [System.Diagnostics.EventLog]::DeleteEventSource('PcNinja WinUpdate Tool')
    }
}
catch {
    $null = $_
}

Remove-EmptyDirectory -Path $programDataParentDir


