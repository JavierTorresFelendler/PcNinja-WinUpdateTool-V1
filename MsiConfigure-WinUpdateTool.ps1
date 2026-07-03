param(
    [string]$MsiData,
    [string]$ConfigFile,
    [string]$EnableSchedule,
    [string]$Frequency,
    [string]$Time,
    [string]$DayOfWeek,
    [string]$MonthlyDay,
    [string]$RunAtStartup,
    [string]$StartupDelayMinutes,
    [string]$RunIfMissed,
    [string]$WakeToRun,
    [string]$AllowFirmware,
    [string]$ShowRebootPrompt,
    [string]$EnableAutoRetry,
    [string]$RetryInitialDelayMinutes,
    [string]$RetryMaxAttempts,
    [string]$RetryBackoffMultiplier,
    [string]$MinimumCooldownMinutes
)

$ErrorActionPreference = 'Stop'

function Test-InstallerValue {
    param([string]$Value)

    return -not [string]::IsNullOrWhiteSpace($Value)
}

function Test-InstallerTrue {
    param([string]$Value)

    return $Value -match '^(?i:true|yes|y|1|on)$'
}

function Test-InstallerFalse {
    param([string]$Value)

    return $Value -match '^(?i:false|no|n|0|off)$'
}

function Add-InstallerSwitch {
    param(
        [System.Collections.Generic.List[string]]$Arguments,
        [string]$Value,
        [string]$EnabledSwitch,
        [string]$DisabledSwitch
    )

    if (-not (Test-InstallerValue -Value $Value)) {
        return
    }

    if (Test-InstallerTrue -Value $Value) {
        $Arguments.Add($EnabledSwitch) | Out-Null
        return
    }

    if (Test-InstallerFalse -Value $Value) {
        $Arguments.Add($DisabledSwitch) | Out-Null
        return
    }

    throw "Boolean installer value '$Value' must be 1/0, true/false, yes/no, or on/off."
}

function Add-InstallerArgument {
    param(
        [System.Collections.Generic.List[string]]$Arguments,
        [string]$Name,
        [string]$Value
    )

    if (-not (Test-InstallerValue -Value $Value)) {
        return
    }

    $Arguments.Add($Name) | Out-Null
    $Arguments.Add($Value) | Out-Null
}

if (Test-InstallerValue -Value $MsiData) {
    $msiValues = [System.Text.RegularExpressions.Regex]::Split($MsiData, '\|')
    if ($msiValues.Count -ge 16) {
        if (-not (Test-InstallerValue -Value $EnableSchedule)) { $EnableSchedule = $msiValues[0] }
        if (-not (Test-InstallerValue -Value $Frequency)) { $Frequency = $msiValues[1] }
        if (-not (Test-InstallerValue -Value $Time)) { $Time = $msiValues[2] }
        if (-not (Test-InstallerValue -Value $DayOfWeek)) { $DayOfWeek = $msiValues[3] }
        if (-not (Test-InstallerValue -Value $MonthlyDay)) { $MonthlyDay = $msiValues[4] }
        if (-not (Test-InstallerValue -Value $RunAtStartup)) { $RunAtStartup = $msiValues[5] }
        if (-not (Test-InstallerValue -Value $StartupDelayMinutes)) { $StartupDelayMinutes = $msiValues[6] }
        if (-not (Test-InstallerValue -Value $RunIfMissed)) { $RunIfMissed = $msiValues[7] }
        if (-not (Test-InstallerValue -Value $WakeToRun)) { $WakeToRun = $msiValues[8] }
        if (-not (Test-InstallerValue -Value $AllowFirmware)) { $AllowFirmware = $msiValues[9] }
        if (-not (Test-InstallerValue -Value $ShowRebootPrompt)) { $ShowRebootPrompt = $msiValues[10] }
        if (-not (Test-InstallerValue -Value $EnableAutoRetry)) { $EnableAutoRetry = $msiValues[11] }
        if (-not (Test-InstallerValue -Value $RetryInitialDelayMinutes)) { $RetryInitialDelayMinutes = $msiValues[12] }
        if (-not (Test-InstallerValue -Value $RetryMaxAttempts)) { $RetryMaxAttempts = $msiValues[13] }
        if (-not (Test-InstallerValue -Value $RetryBackoffMultiplier)) { $RetryBackoffMultiplier = $msiValues[14] }
        if (-not (Test-InstallerValue -Value $MinimumCooldownMinutes)) { $MinimumCooldownMinutes = $msiValues[15] }
    }
}

$installRoot = Split-Path -Parent $PSCommandPath
$cliPath = Join-Path $installRoot 'PcNinja.WinUpdateTool.Cli.exe'
$logRoot = Join-Path $env:ProgramData 'PcNinja\WinUpdateTool\Logs'
$logFile = Join-Path $logRoot 'MsiConfigure.log'

New-Item -ItemType Directory -Path $logRoot -Force | Out-Null

try {
    if (-not (Test-Path -LiteralPath $cliPath -PathType Leaf)) {
        throw "CLI executable was not found: $cliPath"
    }

    $cliArgs = New-Object System.Collections.Generic.List[string]
    $cliArgs.Add('-Mode') | Out-Null
    $cliArgs.Add('Configure') | Out-Null

    Add-InstallerArgument -Arguments $cliArgs -Name '-ConfigFile' -Value $ConfigFile
    Add-InstallerArgument -Arguments $cliArgs -Name '-Frequency' -Value $Frequency
    Add-InstallerArgument -Arguments $cliArgs -Name '-Time' -Value $Time
    Add-InstallerArgument -Arguments $cliArgs -Name '-DayOfWeek' -Value $DayOfWeek
    Add-InstallerArgument -Arguments $cliArgs -Name '-MonthlyDay' -Value $MonthlyDay
    Add-InstallerArgument -Arguments $cliArgs -Name '-StartupDelayMinutes' -Value $StartupDelayMinutes
    Add-InstallerArgument -Arguments $cliArgs -Name '-RetryInitialDelayMinutes' -Value $RetryInitialDelayMinutes
    Add-InstallerArgument -Arguments $cliArgs -Name '-RetryMaxAttempts' -Value $RetryMaxAttempts
    Add-InstallerArgument -Arguments $cliArgs -Name '-RetryBackoffMultiplier' -Value $RetryBackoffMultiplier
    Add-InstallerArgument -Arguments $cliArgs -Name '-MinimumCooldownMinutes' -Value $MinimumCooldownMinutes

    Add-InstallerSwitch -Arguments $cliArgs -Value $EnableSchedule -EnabledSwitch '-EnableSchedule' -DisabledSwitch '-DisableSchedule'
    Add-InstallerSwitch -Arguments $cliArgs -Value $RunAtStartup -EnabledSwitch '-RunAtStartup' -DisabledSwitch '-NoRunAtStartup'
    Add-InstallerSwitch -Arguments $cliArgs -Value $RunIfMissed -EnabledSwitch '-RunIfMissed' -DisabledSwitch '-NoRunIfMissed'
    Add-InstallerSwitch -Arguments $cliArgs -Value $WakeToRun -EnabledSwitch '-WakeToRun' -DisabledSwitch '-NoWakeToRun'
    Add-InstallerSwitch -Arguments $cliArgs -Value $AllowFirmware -EnabledSwitch '-EnableFirmwareUpdates' -DisabledSwitch '-DisableFirmwareUpdates'
    Add-InstallerSwitch -Arguments $cliArgs -Value $ShowRebootPrompt -EnabledSwitch '-EnableRebootPrompt' -DisabledSwitch '-DisableRebootPrompt'
    Add-InstallerSwitch -Arguments $cliArgs -Value $EnableAutoRetry -EnabledSwitch '-EnableAutoRetry' -DisabledSwitch '-DisableAutoRetry'

    if ($cliArgs.Count -le 2) {
        Add-Content -LiteralPath $logFile -Value "$(Get-Date -Format s) No MSI configuration values were supplied. Skipping post-install configuration."
        exit 0
    }

    $cliArgs.Add('-Json') | Out-Null

    Add-Content -LiteralPath $logFile -Value "$(Get-Date -Format s) Running MSI post-install configuration."
    $output = & $cliPath @($cliArgs.ToArray()) 2>&1
    $exitCode = $LASTEXITCODE

    if ($output) {
        Add-Content -LiteralPath $logFile -Value $output
    }

    Add-Content -LiteralPath $logFile -Value "$(Get-Date -Format s) MSI post-install configuration exit code: $exitCode"
    exit $exitCode
}
catch {
    Add-Content -LiteralPath $logFile -Value "$(Get-Date -Format s) MSI post-install configuration failed: $($_.Exception.Message)"
    exit 1
}


