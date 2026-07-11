param(
    [switch]$CreateDesktopShortcut,
    [switch]$RunAfterInstall
)

$ErrorActionPreference = 'Stop'

function Test-InstallerAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-InstallerAdministrator)) {
    Write-Error 'Please run this installer as Administrator.'
    exit 1
}

$sourceDir = Split-Path -Parent $PSCommandPath
$installDir = Join-Path $env:ProgramFiles 'PcNinja\WinUpdateTool'
$programDataDir = Join-Path $env:ProgramData 'PcNinja\WinUpdateTool'
$logDir = Join-Path $programDataDir 'Logs'
$startMenuDir = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\PcNinja'
$shortcutPath = Join-Path $startMenuDir 'WinUpdate Tool.lnk'
$desktopShortcutPath = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'WinUpdate Tool.lnk'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
$installAssetsDir = Join-Path $installDir 'assets'
$appIconPath = Join-Path $installAssetsDir 'PcNinja.ico'
$uninstallKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PcNinja WinUpdate Tool'
$appVersion = '1.1.3.0'

foreach ($path in @($installDir, $installAssetsDir, $programDataDir, $logDir, $startMenuDir)) {
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

$files = @(
    'WinUpdateTool.ps1',
    'WinUpdateCore.psm1',
    'PcNinja.WinUpdateTool.exe',
    'PcNinja.WinUpdateTool.Cli.exe',
    'Launch-WinUpdateTool.vbs',
    'Uninstall-WinUpdateTool.cmd',
    'Uninstall-WinUpdateTool.vbs',
    'Uninstall-WinUpdateTool.ps1',
    'README.md'
)

foreach ($file in $files) {
    $from = Join-Path $sourceDir $file
    $to = Join-Path $installDir $file

    if (-not (Test-Path -LiteralPath $from)) {
        throw "Required file is missing from installer package: $file"
    }

    Copy-Item -LiteralPath $from -Destination $to -Force
}

$sourceAssetsDir = Join-Path $sourceDir 'assets'
if (Test-Path -LiteralPath $sourceAssetsDir) {
    Get-ChildItem -LiteralPath $sourceAssetsDir -Force | Copy-Item -Destination $installAssetsDir -Recurse -Force
}

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$hostExe = Join-Path $installDir 'PcNinja.WinUpdateTool.exe'
$shortcut.TargetPath = if (Test-Path -LiteralPath $hostExe) { $hostExe } else { $wscript }
$shortcut.Arguments = if (Test-Path -LiteralPath $hostExe) { '' } else { '"{0}"' -f (Join-Path $installDir 'Launch-WinUpdateTool.vbs') }
$shortcut.WorkingDirectory = $installDir
$shortcut.IconLocation = if (Test-Path -LiteralPath $appIconPath) { $appIconPath } else { "$env:SystemRoot\System32\shell32.dll,167" }
$shortcut.Save()

if ($CreateDesktopShortcut) {
    $desktopShortcut = $shell.CreateShortcut($desktopShortcutPath)
    $desktopShortcut.TargetPath = if (Test-Path -LiteralPath $hostExe) { $hostExe } else { $wscript }
    $desktopShortcut.Arguments = if (Test-Path -LiteralPath $hostExe) { '' } else { '"{0}"' -f (Join-Path $installDir 'Launch-WinUpdateTool.vbs') }
    $desktopShortcut.WorkingDirectory = $installDir
    $desktopShortcut.IconLocation = if (Test-Path -LiteralPath $appIconPath) { $appIconPath } else { "$env:SystemRoot\System32\shell32.dll,167" }
    $desktopShortcut.Save()
}

$estimatedSizeKb = [int][Math]::Ceiling(((Get-ChildItem -LiteralPath $installDir -Recurse -File | Measure-Object -Property Length -Sum).Sum) / 1KB)
$uninstallCommand = '"{0}" "{1}"' -f $wscript, (Join-Path $installDir 'Uninstall-WinUpdateTool.vbs')
$quietUninstallCommand = '"{0}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}"' -f $powershell, (Join-Path $installDir 'Uninstall-WinUpdateTool.ps1')

if (-not (Test-Path -LiteralPath $uninstallKey)) {
    New-Item -Path $uninstallKey -Force | Out-Null
}

New-ItemProperty -LiteralPath $uninstallKey -Name DisplayName -Value 'PcNinja WinUpdate Tool' -PropertyType String -Force | Out-Null
New-ItemProperty -LiteralPath $uninstallKey -Name DisplayVersion -Value $appVersion -PropertyType String -Force | Out-Null
New-ItemProperty -LiteralPath $uninstallKey -Name Publisher -Value 'PcNinja' -PropertyType String -Force | Out-Null
New-ItemProperty -LiteralPath $uninstallKey -Name InstallLocation -Value $installDir -PropertyType String -Force | Out-Null
New-ItemProperty -LiteralPath $uninstallKey -Name DisplayIcon -Value $appIconPath -PropertyType String -Force | Out-Null
New-ItemProperty -LiteralPath $uninstallKey -Name UninstallString -Value $uninstallCommand -PropertyType String -Force | Out-Null
New-ItemProperty -LiteralPath $uninstallKey -Name QuietUninstallString -Value $quietUninstallCommand -PropertyType String -Force | Out-Null
New-ItemProperty -LiteralPath $uninstallKey -Name URLInfoAbout -Value 'https://www.PcNinja.Pro' -PropertyType String -Force | Out-Null
New-ItemProperty -LiteralPath $uninstallKey -Name HelpLink -Value 'https://www.PcNinja.Pro' -PropertyType String -Force | Out-Null
New-ItemProperty -LiteralPath $uninstallKey -Name InstallDate -Value (Get-Date -Format 'yyyyMMdd') -PropertyType String -Force | Out-Null
New-ItemProperty -LiteralPath $uninstallKey -Name EstimatedSize -Value $estimatedSizeKb -PropertyType DWord -Force | Out-Null
New-ItemProperty -LiteralPath $uninstallKey -Name NoModify -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -LiteralPath $uninstallKey -Name NoRepair -Value 1 -PropertyType DWord -Force | Out-Null

try {
    if (-not [System.Diagnostics.EventLog]::SourceExists('PcNinja WinUpdate Tool')) {
        New-EventLog -LogName Application -Source 'PcNinja WinUpdate Tool'
    }
}
catch {
    Write-Warning "Event Log source could not be created: $($_.Exception.Message)"
}

Write-Host ''
Write-Host 'PcNinja WinUpdate Tool installed successfully.'
Write-Host "Install folder: $installDir"
Write-Host "Logs folder:    $logDir"
Write-Host "Start menu:     $shortcutPath"
Write-Host ''

if ($RunAfterInstall) {
    if (Test-Path -LiteralPath $hostExe) {
        Start-Process -FilePath $hostExe | Out-Null
    }
    else {
        Start-Process -FilePath $powershell -ArgumentList ('-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Mode UI' -f (Join-Path $installDir 'WinUpdateTool.ps1')) -WindowStyle Hidden | Out-Null
    }
}









