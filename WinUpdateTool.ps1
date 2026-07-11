param(
    [ValidateSet('UI', 'RunUpdates', 'ShowLog', 'DriverReport', 'DriverAudit', 'Status', 'Configure', 'RunOnceTask', 'CollectLogs', 'ResetWindowsUpdate', 'ResetWinUpdate', 'ResetUpdateCache')]
    [string]$Mode = 'UI',

    [switch]$Silent,

    [switch]$AllowStopBackgroundActivity,

    [switch]$ConfirmReset,

    [switch]$ForceReset,

    [ValidateSet('Manual', 'Scheduled', 'Retry', 'Startup', 'Wake')]
    [string]$RunType = 'Manual',

    [switch]$Json,

    [ValidateSet('Daily', 'Weekly', 'Monthly', 'Startup')]
    [string]$Frequency,

    [string]$Time,

    [ValidateSet('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')]
    [string]$DayOfWeek,

    [int]$MonthlyDay,

    [switch]$EnableSchedule,

    [switch]$DisableSchedule,

    [switch]$RunAtStartup,

    [switch]$NoRunAtStartup,

    [int]$StartupDelayMinutes,

    [switch]$RunIfMissed,

    [switch]$NoRunIfMissed,

    [switch]$WakeToRun,

    [switch]$NoWakeToRun,

    [switch]$EnableRebootPrompt,

    [switch]$DisableRebootPrompt,

    [switch]$EnableFirmwareUpdates,

    [switch]$DisableFirmwareUpdates,

    [switch]$EnableAutoRetry,

    [switch]$DisableAutoRetry,

    [int]$RetryInitialDelayMinutes,

    [int]$RetryMaxAttempts,

    [int]$RetryBackoffMultiplier,

    [int]$MinimumCooldownMinutes,

    [string]$ConfigFile,

    [string]$OutputPath,

    [int]$LogTail = 50
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'WinUpdateCore.psm1'
Import-Module $modulePath -Force
$script:PcnToolVersion = '1.1.3.0'
$script:PcnCliBoundParameters = $PSBoundParameters

if ($Json) {
    Set-PcnConsoleLogEnabled -Enabled $false
}

function Invoke-PcnSoftAlertSound {
    param([switch]$Important)

    if (-not $Important) {
        return
    }

    try {
        $soundPath = Join-Path $PSScriptRoot 'assets\PcNinja-SoftAlert.wav'
        if (Test-Path -LiteralPath $soundPath) {
            $player = New-Object System.Media.SoundPlayer $soundPath
            $player.Play()
        }
    }
    catch {
        $null = $_
    }
}

function Show-PcnMessageBox {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [object[]]$Args
    )

    if ($Args.Count -eq 1 -and $Args[0] -is [array]) {
        $Args = @($Args[0])
    }

    $text = if ($Args.Count -ge 1) { [string]$Args[0] } else { '' }
    $caption = if ($Args.Count -ge 2) { [string]$Args[1] } else { 'PcNinja WinUpdate Tool' }
    $buttons = if ($Args.Count -ge 3) { [string]$Args[2] } else { 'OK' }
    $requestedIcon = if ($Args.Count -ge 4) { [string]$Args[3] } else { 'None' }

    $importantIcons = @('Warning', 'Error', 'Question')
    Invoke-PcnSoftAlertSound -Important:($importantIcons -contains $requestedIcon)

    $buttonValue = [System.Windows.Forms.MessageBoxButtons]::OK
    try {
        $buttonValue = [System.Windows.Forms.MessageBoxButtons]::$buttons
    }
    catch {
        $buttonValue = [System.Windows.Forms.MessageBoxButtons]::OK
    }

    return [System.Windows.Forms.MessageBox]::Show(
        $text,
        $caption,
        $buttonValue,
        [System.Windows.Forms.MessageBoxIcon]::None
    )
}

function Test-PcnCliParameter {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return $script:PcnCliBoundParameters.ContainsKey($Name)
}

function Write-PcnCliObject {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,

        [int]$Depth = 8
    )

    if ($Json) {
        $InputObject | ConvertTo-Json -Depth $Depth
        return
    }

    $InputObject | Format-List -Force
}

function Stop-PcnCliError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [int]$ExitCode = 1
    )

    if ($Json) {
        Write-PcnCliObject -InputObject ([pscustomobject]@{
            Result = 'Failed'
            Mode = $Mode
            Message = $Message
            ComputerName = $env:COMPUTERNAME
            Timestamp = (Get-Date).ToString('s')
        }) -Depth 6
    }
    else {
        [Console]::Error.WriteLine($Message)
    }

    exit $ExitCode
}

function Invoke-PcnCliSafe {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock
    )

    try {
        & $ScriptBlock
    }
    catch {
        [pscustomobject]@{
            Error = $_.Exception.Message
        }
    }
}

function Convert-PcnLogTextToLines {
    param(
        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }

    return @($Text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-PcnCliStatus {
    param(
        [int]$Tail = 50,
        [switch]$IncludeLog
    )

    Invoke-PcnCliSafe { Initialize-PcnWinUpdateFolders } | Out-Null
    $recentLogLines = @()

    if ($IncludeLog) {
        $recentLog = Invoke-PcnCliSafe { Get-PcnRecentLog -Tail ([Math]::Max(1, $Tail)) }
        if ($recentLog -is [string]) {
            $recentLogLines = Convert-PcnLogTextToLines -Text $recentLog
        }
        else {
            $recentLogLines = @($recentLog)
        }
    }

    [pscustomobject]@{
        Tool = 'PcNinja WinUpdate Tool'
        Version = $script:PcnToolVersion
        Timestamp = (Get-Date).ToString('s')
        ComputerName = $env:COMPUTERNAME
        UserName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        IsAdministrator = Test-PcnAdministrator
        ScriptPath = $PSCommandPath
        InstallRoot = $PSScriptRoot
        Paths = Invoke-PcnCliSafe { Get-PcnWinUpdatePaths }
        Config = Invoke-PcnCliSafe { Get-PcnWinUpdateConfig }
        State = Invoke-PcnCliSafe { Get-PcnWinUpdateState }
        Tasks = [pscustomobject]@{
            Scheduled = Invoke-PcnCliSafe { Get-PcnScheduledTaskStatus }
            Retry = Invoke-PcnCliSafe { Get-PcnRetryTaskStatus }
            RunOnce = Invoke-PcnCliSafe { Get-PcnRunOnceTaskStatus }
        }
        PendingReboot = Invoke-PcnCliSafe { Test-PcnPendingReboot }
        WindowsUpdateActivity = Invoke-PcnCliSafe { Get-PcnWindowsUpdateActivity }
        DotNetFramework = Invoke-PcnCliSafe { Get-PcnDotNetFrameworkVersion }
        RecentLogLines = $recentLogLines
    }
}

function Assert-PcnCliSwitchPair {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EnableName,

        [Parameter(Mandatory = $true)]
        [string]$DisableName
    )

    if ((Test-PcnCliParameter -Name $EnableName) -and (Test-PcnCliParameter -Name $DisableName)) {
        throw "Use either -$EnableName or -$DisableName, not both."
    }
}

function Set-PcnCliIntegerConfig {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Config,

        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[string]]$Changed,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [int]$Value,

        [int]$Minimum = 0,

        [int]$Maximum = [int]::MaxValue
    )

    if (-not (Test-PcnCliParameter -Name $Name)) {
        return
    }

    if ($Value -lt $Minimum -or $Value -gt $Maximum) {
        throw "-$Name must be between $Minimum and $Maximum."
    }

    $Config.$Name = $Value
    $Changed.Add($Name) | Out-Null
}

function Get-PcnCliJsonProperty {
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    if ($null -eq $InputObject) {
        return [pscustomobject]@{
            Found = $false
            Value = $null
        }
    }

    foreach ($name in $Names) {
        foreach ($property in $InputObject.PSObject.Properties) {
            if ($property.Name -ieq $name) {
                return [pscustomobject]@{
                    Found = $true
                    Value = $property.Value
                }
            }
        }
    }

    [pscustomobject]@{
        Found = $false
        Value = $null
    }
}

function Convert-PcnCliJsonBoolean {
    param(
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    if ($Value -is [int] -or $Value -is [long]) {
        if ([int]$Value -eq 0) { return $false }
        if ([int]$Value -eq 1) { return $true }
    }

    if ($null -ne $Value) {
        switch -Regex ([string]$Value) {
            '^(?i:true|yes|y|1|on)$' { return $true }
            '^(?i:false|no|n|0|off)$' { return $false }
        }
    }

    throw "Config file value '$Name' must be true or false."
}

function Convert-PcnCliJsonInteger {
    param(
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [int]$Minimum = 0,

        [int]$Maximum = [int]::MaxValue
    )

    try {
        $integerValue = [int]$Value
    }
    catch {
        throw "Config file value '$Name' must be an integer."
    }

    if ($integerValue -lt $Minimum -or $integerValue -gt $Maximum) {
        throw "Config file value '$Name' must be between $Minimum and $Maximum."
    }

    $integerValue
}

function Add-PcnCliChangedConfig {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[string]]$Changed,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not $Changed.Contains($Name)) {
        $Changed.Add($Name) | Out-Null
    }
}

function Set-PcnCliJsonStringConfig {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Config,

        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[string]]$Changed,

        [AllowNull()]
        [object]$Source,

        [Parameter(Mandatory = $true)]
        [string[]]$Names,

        [Parameter(Mandatory = $true)]
        [string]$TargetName,

        [string[]]$AllowedValues
    )

    $jsonValue = Get-PcnCliJsonProperty -InputObject $Source -Names $Names
    if (-not $jsonValue.Found) {
        return
    }

    $value = [string]$jsonValue.Value
    if ($AllowedValues -and ($value -notin $AllowedValues)) {
        throw "Config file value '$($Names[0])' must be one of: $($AllowedValues -join ', ')."
    }

    $Config.$TargetName = $value
    Add-PcnCliChangedConfig -Changed $Changed -Name $TargetName
}

function Set-PcnCliJsonBooleanConfig {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Config,

        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[string]]$Changed,

        [AllowNull()]
        [object]$Source,

        [Parameter(Mandatory = $true)]
        [string[]]$Names,

        [Parameter(Mandatory = $true)]
        [string]$TargetName
    )

    $jsonValue = Get-PcnCliJsonProperty -InputObject $Source -Names $Names
    if (-not $jsonValue.Found) {
        return
    }

    $Config.$TargetName = Convert-PcnCliJsonBoolean -Value $jsonValue.Value -Name $Names[0]
    Add-PcnCliChangedConfig -Changed $Changed -Name $TargetName
}

function Set-PcnCliJsonIntegerConfig {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Config,

        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[string]]$Changed,

        [AllowNull()]
        [object]$Source,

        [Parameter(Mandatory = $true)]
        [string[]]$Names,

        [Parameter(Mandatory = $true)]
        [string]$TargetName,

        [int]$Minimum = 0,

        [int]$Maximum = [int]::MaxValue
    )

    $jsonValue = Get-PcnCliJsonProperty -InputObject $Source -Names $Names
    if (-not $jsonValue.Found) {
        return
    }

    $Config.$TargetName = Convert-PcnCliJsonInteger -Value $jsonValue.Value -Name $Names[0] -Minimum $Minimum -Maximum $Maximum
    Add-PcnCliChangedConfig -Changed $Changed -Name $TargetName
}

function Set-PcnCliJsonTimeConfig {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Config,

        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[string]]$Changed,

        [AllowNull()]
        [object]$Source,

        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    $jsonValue = Get-PcnCliJsonProperty -InputObject $Source -Names $Names
    if (-not $jsonValue.Found) {
        return
    }

    try {
        $parsedTime = [TimeSpan]::Parse([string]$jsonValue.Value)
    }
    catch {
        throw "Config file value '$($Names[0])' must be a valid time, for example 03:00."
    }

    if ($parsedTime.TotalMinutes -lt 0 -or $parsedTime.TotalMinutes -ge 1440) {
        throw "Config file value '$($Names[0])' must be inside one day, for example 03:00."
    }

    $Config.Time = '{0:00}:{1:00}' -f [int]$parsedTime.Hours, [int]$parsedTime.Minutes
    Add-PcnCliChangedConfig -Changed $Changed -Name 'Time'
}

function Import-PcnCliConfigurationFile {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Config,

        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[string]]$Changed,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "Config file was not found: $resolvedPath"
    }

    try {
        $configObject = Get-Content -LiteralPath $resolvedPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "Config file is not valid JSON: $($_.Exception.Message)"
    }

    $schedule = (Get-PcnCliJsonProperty -InputObject $configObject -Names @('schedule')).Value
    $updates = (Get-PcnCliJsonProperty -InputObject $configObject -Names @('updates')).Value
    $retry = (Get-PcnCliJsonProperty -InputObject $configObject -Names @('retry')).Value

    Set-PcnCliJsonBooleanConfig -Config $Config -Changed $Changed -Source $schedule -Names @('enabled', 'enableSchedule') -TargetName 'Enabled'
    Set-PcnCliJsonStringConfig -Config $Config -Changed $Changed -Source $schedule -Names @('frequency') -TargetName 'Frequency' -AllowedValues @('Daily', 'Weekly', 'Monthly', 'Startup')
    Set-PcnCliJsonTimeConfig -Config $Config -Changed $Changed -Source $schedule -Names @('time')
    Set-PcnCliJsonStringConfig -Config $Config -Changed $Changed -Source $schedule -Names @('dayOfWeek') -TargetName 'DayOfWeek' -AllowedValues @('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')
    Set-PcnCliJsonIntegerConfig -Config $Config -Changed $Changed -Source $schedule -Names @('monthlyDay') -TargetName 'MonthlyDay' -Minimum 1 -Maximum 28
    Set-PcnCliJsonBooleanConfig -Config $Config -Changed $Changed -Source $schedule -Names @('runAtStartup') -TargetName 'RunAtStartup'
    Set-PcnCliJsonIntegerConfig -Config $Config -Changed $Changed -Source $schedule -Names @('startupDelayMinutes') -TargetName 'StartupDelayMinutes' -Minimum 0 -Maximum 1440
    Set-PcnCliJsonBooleanConfig -Config $Config -Changed $Changed -Source $schedule -Names @('runIfMissed') -TargetName 'RunIfMissed'
    Set-PcnCliJsonBooleanConfig -Config $Config -Changed $Changed -Source $schedule -Names @('wakeToRun', 'wakeComputer') -TargetName 'WakeToRun'

    Set-PcnCliJsonBooleanConfig -Config $Config -Changed $Changed -Source $updates -Names @('showRebootPrompt') -TargetName 'ShowRebootPrompt'
    Set-PcnCliJsonBooleanConfig -Config $Config -Changed $Changed -Source $updates -Names @('allowFirmware', 'installFirmwareUpdates') -TargetName 'InstallFirmwareUpdates'

    Set-PcnCliJsonBooleanConfig -Config $Config -Changed $Changed -Source $retry -Names @('autoRetryEnabled') -TargetName 'AutoRetryEnabled'
    Set-PcnCliJsonIntegerConfig -Config $Config -Changed $Changed -Source $retry -Names @('initialDelayMinutes', 'retryInitialDelayMinutes') -TargetName 'RetryInitialDelayMinutes' -Minimum 1 -Maximum 1440
    Set-PcnCliJsonIntegerConfig -Config $Config -Changed $Changed -Source $retry -Names @('maxAttempts', 'retryMaxAttempts') -TargetName 'RetryMaxAttempts' -Minimum 0 -Maximum 100
    Set-PcnCliJsonIntegerConfig -Config $Config -Changed $Changed -Source $retry -Names @('backoffMultiplier', 'retryBackoffMultiplier') -TargetName 'RetryBackoffMultiplier' -Minimum 1 -Maximum 100
    Set-PcnCliJsonIntegerConfig -Config $Config -Changed $Changed -Source $retry -Names @('minimumCooldownMinutes') -TargetName 'MinimumCooldownMinutes' -Minimum 0 -Maximum 1440

    Add-PcnCliChangedConfig -Changed $Changed -Name 'ConfigFile'
}

function Set-PcnCliConfiguration {
    Assert-PcnCliSwitchPair -EnableName 'EnableSchedule' -DisableName 'DisableSchedule'
    Assert-PcnCliSwitchPair -EnableName 'RunAtStartup' -DisableName 'NoRunAtStartup'
    Assert-PcnCliSwitchPair -EnableName 'RunIfMissed' -DisableName 'NoRunIfMissed'
    Assert-PcnCliSwitchPair -EnableName 'WakeToRun' -DisableName 'NoWakeToRun'
    Assert-PcnCliSwitchPair -EnableName 'EnableRebootPrompt' -DisableName 'DisableRebootPrompt'
    Assert-PcnCliSwitchPair -EnableName 'EnableFirmwareUpdates' -DisableName 'DisableFirmwareUpdates'
    Assert-PcnCliSwitchPair -EnableName 'EnableAutoRetry' -DisableName 'DisableAutoRetry'

    $config = Get-PcnWinUpdateConfig
    $changed = New-Object System.Collections.Generic.List[string]

    if (Test-PcnCliParameter -Name 'ConfigFile') {
        Import-PcnCliConfigurationFile -Config $config -Changed $changed -Path $ConfigFile
    }

    if (Test-PcnCliParameter -Name 'Frequency') {
        $config.Frequency = $Frequency
        $changed.Add('Frequency') | Out-Null
    }

    if (Test-PcnCliParameter -Name 'Time') {
        try {
            $parsedTime = [TimeSpan]::Parse($Time)
        }
        catch {
            throw '-Time must be a valid time, for example 03:00.'
        }

        if ($parsedTime.TotalMinutes -lt 0 -or $parsedTime.TotalMinutes -ge 1440) {
            throw '-Time must be inside one day, for example 03:00.'
        }

        $config.Time = '{0:00}:{1:00}' -f [int]$parsedTime.Hours, [int]$parsedTime.Minutes
        $changed.Add('Time') | Out-Null
    }

    if (Test-PcnCliParameter -Name 'DayOfWeek') {
        $config.DayOfWeek = $DayOfWeek
        $changed.Add('DayOfWeek') | Out-Null
    }

    Set-PcnCliIntegerConfig -Config $config -Changed $changed -Name 'MonthlyDay' -Value $MonthlyDay -Minimum 1 -Maximum 28
    Set-PcnCliIntegerConfig -Config $config -Changed $changed -Name 'StartupDelayMinutes' -Value $StartupDelayMinutes -Minimum 0 -Maximum 1440
    Set-PcnCliIntegerConfig -Config $config -Changed $changed -Name 'RetryInitialDelayMinutes' -Value $RetryInitialDelayMinutes -Minimum 1 -Maximum 1440
    Set-PcnCliIntegerConfig -Config $config -Changed $changed -Name 'RetryMaxAttempts' -Value $RetryMaxAttempts -Minimum 0 -Maximum 100
    Set-PcnCliIntegerConfig -Config $config -Changed $changed -Name 'RetryBackoffMultiplier' -Value $RetryBackoffMultiplier -Minimum 1 -Maximum 100
    Set-PcnCliIntegerConfig -Config $config -Changed $changed -Name 'MinimumCooldownMinutes' -Value $MinimumCooldownMinutes -Minimum 0 -Maximum 1440

    if ($EnableSchedule) {
        $config.Enabled = $true
        $changed.Add('Enabled') | Out-Null
    }

    if ($DisableSchedule) {
        $config.Enabled = $false
        $changed.Add('Enabled') | Out-Null
    }

    if ($RunAtStartup) {
        $config.RunAtStartup = $true
        $changed.Add('RunAtStartup') | Out-Null
    }

    if ($NoRunAtStartup) {
        $config.RunAtStartup = $false
        $changed.Add('RunAtStartup') | Out-Null
    }

    if ($RunIfMissed) {
        $config.RunIfMissed = $true
        $changed.Add('RunIfMissed') | Out-Null
    }

    if ($NoRunIfMissed) {
        $config.RunIfMissed = $false
        $changed.Add('RunIfMissed') | Out-Null
    }

    if ($WakeToRun) {
        $config.WakeToRun = $true
        $changed.Add('WakeToRun') | Out-Null
    }

    if ($NoWakeToRun) {
        $config.WakeToRun = $false
        $changed.Add('WakeToRun') | Out-Null
    }

    if ($EnableRebootPrompt) {
        $config.ShowRebootPrompt = $true
        $changed.Add('ShowRebootPrompt') | Out-Null
    }

    if ($DisableRebootPrompt) {
        $config.ShowRebootPrompt = $false
        $changed.Add('ShowRebootPrompt') | Out-Null
    }

    if ($EnableFirmwareUpdates) {
        $config.InstallFirmwareUpdates = $true
        $changed.Add('InstallFirmwareUpdates') | Out-Null
    }

    if ($DisableFirmwareUpdates) {
        $config.InstallFirmwareUpdates = $false
        $changed.Add('InstallFirmwareUpdates') | Out-Null
    }

    if ($EnableAutoRetry) {
        $config.AutoRetryEnabled = $true
        $changed.Add('AutoRetryEnabled') | Out-Null
    }

    if ($DisableAutoRetry) {
        $config.AutoRetryEnabled = $false
        $changed.Add('AutoRetryEnabled') | Out-Null
    }

    Save-PcnWinUpdateConfig -Config $config

    $scheduleAction = 'Unchanged'
    if ($config.Enabled) {
        Register-PcnWinUpdateScheduledTask -Config $config -ScriptPath $PSCommandPath
        $scheduleAction = 'Registered'
    }
    elseif ($DisableSchedule -or $changed.Contains('Enabled')) {
        Unregister-PcnWinUpdateScheduledTask
        $scheduleAction = 'Removed'
    }

    [pscustomobject]@{
        Result = 'Configured'
        Changed = @($changed)
        ScheduleAction = $scheduleAction
        Config = $config
        ScheduledTask = Get-PcnScheduledTaskStatus
    }
}

function Export-PcnCliTaskXml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskName,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    try {
        Export-ScheduledTask -TaskName $TaskName -TaskPath '\PcNinja\' -ErrorAction Stop |
            Set-Content -LiteralPath $DestinationPath -Encoding UTF8
    }
    catch {
        Set-Content -LiteralPath $DestinationPath -Value "Task not available: $($_.Exception.Message)" -Encoding UTF8
    }
}

function New-PcnCliLogPackage {
    param(
        [string]$DestinationPath,
        [int]$Tail = 100
    )

    $paths = Initialize-PcnWinUpdateFolders
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

    if ([string]::IsNullOrWhiteSpace($DestinationPath)) {
        $destinationDir = Join-Path $paths.DataRoot 'LogPackages'
        $zipPath = Join-Path $destinationDir "PcNinja-WinUpdateTool-Logs-$stamp.zip"
    }
    elseif ([System.IO.Path]::GetExtension($DestinationPath) -ieq '.zip') {
        $zipPath = $DestinationPath
        $destinationDir = Split-Path -Parent $zipPath
        if ([string]::IsNullOrWhiteSpace($destinationDir)) {
            $destinationDir = (Get-Location).Path
            $zipPath = Join-Path $destinationDir $zipPath
        }
    }
    else {
        $destinationDir = $DestinationPath
        $zipPath = Join-Path $destinationDir "PcNinja-WinUpdateTool-Logs-$stamp.zip"
    }

    if (-not (Test-Path -LiteralPath $destinationDir)) {
        New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
    }

    $stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) "PcNinjaWinUpdateTool-$stamp-$PID"

    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }

    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

    try {
        if (Test-Path -LiteralPath $paths.LogRoot) {
            Copy-Item -LiteralPath $paths.LogRoot -Destination (Join-Path $stagingRoot 'Logs') -Recurse -Force
        }

        if (Test-Path -LiteralPath $paths.DriverReportRoot) {
            Copy-Item -LiteralPath $paths.DriverReportRoot -Destination (Join-Path $stagingRoot 'DriverReports') -Recurse -Force
        }

        foreach ($filePath in @($paths.ConfigFile, $paths.StateFile)) {
            if (Test-Path -LiteralPath $filePath) {
                Copy-Item -LiteralPath $filePath -Destination $stagingRoot -Force
            }
        }

        $taskRoot = Join-Path $stagingRoot 'Tasks'
        New-Item -ItemType Directory -Path $taskRoot -Force | Out-Null
        Export-PcnCliTaskXml -TaskName 'PcNinja WinUpdate Tool' -DestinationPath (Join-Path $taskRoot 'ScheduledTask.xml')
        Export-PcnCliTaskXml -TaskName 'PcNinja WinUpdate Tool Retry' -DestinationPath (Join-Path $taskRoot 'RetryTask.xml')
        Export-PcnCliTaskXml -TaskName 'PcNinja WinUpdate Tool Run Once' -DestinationPath (Join-Path $taskRoot 'RunOnceTask.xml')

        Get-PcnCliStatus -Tail $Tail -IncludeLog | ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath (Join-Path $stagingRoot 'status.json') -Encoding UTF8

        if (Test-Path -LiteralPath $zipPath) {
            Remove-Item -LiteralPath $zipPath -Force
        }

        Compress-Archive -Path (Join-Path $stagingRoot '*') -DestinationPath $zipPath -Force

        [pscustomobject]@{
            Result = 'Collected'
            ZipPath = (Resolve-Path $zipPath).Path
            CreatedAt = (Get-Date).ToString('s')
            IncludedRecentLogLines = $Tail
        }
    }
    finally {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Start-PcnElevatedSelf {
    param(
        [string]$TargetMode
    )

    $powershell = Get-PcnPowershellPath
    $arguments = '-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Mode {1}' -f $PSCommandPath, $TargetMode
    Start-Process -FilePath $powershell -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden | Out-Null
}

if ($Mode -eq 'ShowLog') {
    $paths = Initialize-PcnWinUpdateFolders
    if (-not (Test-Path -LiteralPath $paths.LogFile)) {
        Set-Content -LiteralPath $paths.LogFile -Value 'No log entries yet.' -Encoding UTF8
    }

    Start-Process -FilePath notepad.exe -ArgumentList $paths.LogFile | Out-Null
    exit 0
}

if ($Mode -eq 'Status') {
    Write-PcnCliObject -InputObject (Get-PcnCliStatus -Tail $LogTail -IncludeLog) -Depth 10
    exit 0
}

if ($Mode -in @('DriverReport', 'DriverAudit')) {
    try {
        $report = Export-PcnDriverInventoryReport

        if ($Json) {
            Write-PcnCliObject -InputObject $report -Depth 8
            exit 0
        }

        Write-Host "Driver audit report created:"
        Write-Host "CSV:     $($report.CsvPath)"
        Write-Host "JSON:    $($report.JsonPath)"
        Write-Host "Summary: $($report.SummaryPath)"
        exit 0
    }
    catch {
        Stop-PcnCliError -Message $_.Exception.Message
    }
}

if (-not (Test-PcnAdministrator)) {
    if ($Mode -eq 'UI') {
        Add-Type -AssemblyName System.Windows.Forms
        Show-PcnMessageBox(
            'PcNinja WinUpdate Tool needs administrator privileges. Click OK to relaunch it as Administrator.',
            'Administrator Required',
            'OK',
            'Information'
        ) | Out-Null

        Start-PcnElevatedSelf -TargetMode 'UI'
        exit 0
    }

    Stop-PcnCliError -Message "Administrator privileges are required for mode '$Mode'."
}

if ($Mode -in @('ResetWindowsUpdate', 'ResetWinUpdate', 'ResetUpdateCache')) {
    try {
        if (-not $ConfirmReset) {
            Stop-PcnCliError -Message 'Windows Update reset requires -ConfirmReset. This action stops Windows Update services and clears the SoftwareDistribution cache.' -ExitCode 2
        }

        $result = Invoke-PcnWindowsUpdateReset -Force:$ForceReset
        Write-PcnCliObject -InputObject $result -Depth 10

        if ($result.Result -in @('Succeeded', 'SucceededWithWarnings')) {
            exit 0
        }

        exit 1
    }
    catch {
        Stop-PcnCliError -Message $_.Exception.Message
    }
}

if ($Mode -eq 'RunUpdates') {
    try {
        $config = Get-PcnWinUpdateConfig
        $showPrompt = (-not $Silent) -and [bool]$config.ShowRebootPrompt
        $result = Invoke-PcnManagedWindowsUpdateRun -RunType $RunType -ScriptPath $PSCommandPath -Silent:$Silent -ShowRebootPrompt:$showPrompt -AllowStopBackgroundActivity:$AllowStopBackgroundActivity

        if ($Json) {
            Write-PcnCliObject -InputObject $result -Depth 8
        }

        if ($result.Result -in @('Succeeded', 'SucceededWithErrors', 'NoUpdates', 'SkippedInstalling', 'SkippedBackgroundActivity', 'RebootRequired', 'MaxPassesReached', 'RetryScheduled', 'MaxRetriesReached', 'RetryDisabled', 'AlreadyRunning', 'CooldownActive')) {
            exit 0
        }

        exit 1
    }
    catch {
        Stop-PcnCliError -Message $_.Exception.Message
    }
}

if ($Mode -eq 'Configure') {
    try {
        Write-PcnCliObject -InputObject (Set-PcnCliConfiguration) -Depth 10
        exit 0
    }
    catch {
        Stop-PcnCliError -Message $_.Exception.Message
    }
}

if ($Mode -eq 'RunOnceTask') {
    try {
        $taskStatus = Start-PcnWinUpdateRunOnceTask -ScriptPath $PSCommandPath
        Write-PcnCliObject -InputObject ([pscustomobject]@{
            Result = 'RunOnceTaskStarted'
            Task = $taskStatus
            State = Get-PcnWinUpdateState
        }) -Depth 10
        exit 0
    }
    catch {
        Stop-PcnCliError -Message $_.Exception.Message
    }
}

if ($Mode -eq 'CollectLogs') {
    try {
        Write-PcnCliObject -InputObject (New-PcnCliLogPackage -DestinationPath $OutputPath -Tail ([Math]::Max(1, $LogTail))) -Depth 8
        exit 0
    }
    catch {
        Stop-PcnCliError -Message $_.Exception.Message
    }
}

try {
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[void][System.Windows.Forms.Application]::EnableVisualStyles()
Initialize-PcnWinUpdateFolders | Out-Null

$form = New-Object System.Windows.Forms.Form
$form.Text = 'PcNinja WinUpdate Tool'
$workingArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$initialWidth = [Math]::Min(1080, [Math]::Max(980, $workingArea.Width - 40))
$initialHeight = [Math]::Min(860, [Math]::Max(760, $workingArea.Height - 60))
$form.Size = New-Object System.Drawing.Size($initialWidth, $initialHeight)
$form.MinimumSize = New-Object System.Drawing.Size(980, 720)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 11)
$form.AutoScroll = $false

$iconPath = Join-Path $PSScriptRoot 'assets\PcNinja.ico'
if (Test-Path -LiteralPath $iconPath) {
    try {
        $form.Icon = New-Object System.Drawing.Icon($iconPath)
    }
    catch {
        $null = $_
    }
}

$titleFont = New-Object System.Drawing.Font('Segoe UI Semibold', 17, [System.Drawing.FontStyle]::Bold)
$sectionFont = New-Object System.Drawing.Font('Segoe UI Semibold', 12, [System.Drawing.FontStyle]::Bold)
$script:PcnUiCurrentTheme = 'Light'
$script:PcnThemePalette = $null
$script:pcnLoadingUiConfig = $false

function New-PcnColor {
    param(
        [Parameter(Mandatory = $true)]
        [int]$R,

        [Parameter(Mandatory = $true)]
        [int]$G,

        [Parameter(Mandatory = $true)]
        [int]$B
    )

    return [System.Drawing.Color]::FromArgb($R, $G, $B)
}

function Get-PcnUiThemePalette {
    param(
        [ValidateSet('Light', 'Dark')]
        [string]$Theme = 'Light'
    )

    if ($Theme -eq 'Dark') {
        return [pscustomobject]@{
            Name = 'Dark'
            FormBack = New-PcnColor 10 8 22
            HeaderBack = New-PcnColor 22 13 42
            TabBack = New-PcnColor 18 12 34
            TabSelectedBack = New-PcnColor 47 31 92
            TabBorder = New-PcnColor 42 128 196
            Text = New-PcnColor 246 241 255
            MutedText = New-PcnColor 166 148 218
            Accent = New-PcnColor 139 72 246
            Accent2 = New-PcnColor 20 137 220
            PanelBack = New-PcnColor 18 12 34
            PanelAlt = New-PcnColor 22 15 42
            Border = New-PcnColor 42 128 196
            ButtonBack = New-PcnColor 51 35 96
            ButtonText = [System.Drawing.Color]::White
            InputBack = New-PcnColor 12 10 26
            InputText = [System.Drawing.Color]::White
            LogBack = New-PcnColor 8 7 18
            Danger = New-PcnColor 255 67 84
        }
    }

    return [pscustomobject]@{
        Name = 'Light'
        FormBack = [System.Drawing.SystemColors]::Control
        HeaderBack = [System.Drawing.SystemColors]::Control
        TabBack = [System.Drawing.SystemColors]::Control
        TabSelectedBack = [System.Drawing.SystemColors]::Window
        TabBorder = [System.Drawing.Color]::Gainsboro
        Text = [System.Drawing.SystemColors]::ControlText
        MutedText = [System.Drawing.Color]::DimGray
        Accent = New-PcnColor 0 102 204
        Accent2 = New-PcnColor 0 102 204
        PanelBack = [System.Drawing.SystemColors]::Window
        PanelAlt = [System.Drawing.SystemColors]::Control
        Border = [System.Drawing.Color]::Gainsboro
        ButtonBack = [System.Drawing.SystemColors]::Control
        ButtonText = [System.Drawing.SystemColors]::ControlText
        InputBack = [System.Drawing.SystemColors]::Window
        InputText = [System.Drawing.SystemColors]::ControlText
        LogBack = [System.Drawing.SystemColors]::Window
        Danger = [System.Drawing.Color]::Firebrick
    }
}

function Invoke-PcnUiOpenUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    Start-Process -FilePath $Url | Out-Null
}

function Get-PcnWindowsImageDownloadUrl {
    return 'https://win11.pcninja.pro/'
}

function New-PcnUiLinkLabel {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [int]$X,

        [Parameter(Mandatory = $true)]
        [int]$Y,

        [int]$Width = 360,

        [int]$Height = 24
    )

    $link = New-Object System.Windows.Forms.LinkLabel
    $link.Text = $Text
    $link.Tag = $Url
    $link.AutoSize = $false
    $link.Location = New-Object System.Drawing.Point($X, $Y)
    $link.Size = New-Object System.Drawing.Size($Width, $Height)
    $link.LinkColor = [System.Drawing.Color]::FromArgb(0, 102, 204)
    $link.Add_LinkClicked({
        param($sender, $eventArgs)
        Invoke-PcnUiOpenUrl -Url ([string]$sender.Tag)
    })

    return $link
}

function New-PcnUiLinkTile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$DisplayUrl,

        [Parameter(Mandatory = $true)]
        [int]$X,

        [Parameter(Mandatory = $true)]
        [int]$Y,

        [int]$Width = 260,

        [int]$Height = 58,

        [switch]$Plain
    )

    $tile = New-Object System.Windows.Forms.Panel
    $tile.Location = New-Object System.Drawing.Point($X, $Y)
    $tile.Size = New-Object System.Drawing.Size($Width, $Height)
    $tile.BorderStyle = if ($Plain) { 'None' } else { 'FixedSingle' }
    $tile.BackColor = if ($Plain) { [System.Drawing.Color]::Transparent } else { [System.Drawing.SystemColors]::Window }

    $link = New-PcnUiLinkLabel -Text $Text -Url $Url -X 0 -Y 2 -Width $Width -Height 34
    $link.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 14, [System.Drawing.FontStyle]::Regular)
    $link.LinkBehavior = [System.Windows.Forms.LinkBehavior]::AlwaysUnderline
    $link.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    if ($Plain) {
        $link.BackColor = [System.Drawing.Color]::Transparent
    }
    $tile.Controls.Add($link)

    $urlLabel = New-Object System.Windows.Forms.Label
    $urlLabel.Text = $DisplayUrl
    $urlLabel.AutoSize = $false
    $urlLabel.Location = New-Object System.Drawing.Point(0, 50)
    $urlLabel.Size = New-Object System.Drawing.Size($Width, 22)
    $urlLabel.ForeColor = [System.Drawing.Color]::DimGray
    $urlLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $urlLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    if ($Plain) {
        $urlLabel.BackColor = [System.Drawing.Color]::Transparent
    }
    $tile.Controls.Add($urlLabel)

    return $tile
}

$logoPath = Join-Path $PSScriptRoot 'assets\Ninja-DMT.png'
if (Test-Path -LiteralPath $logoPath) {
    $logo = New-Object System.Windows.Forms.PictureBox
    $logo.Image = [System.Drawing.Image]::FromFile($logoPath)
    $logo.SizeMode = 'Zoom'
    $logo.Location = New-Object System.Drawing.Point(18, 10)
    $logo.Size = New-Object System.Drawing.Size(58, 58)
    $form.Controls.Add($logo)
}

$title = New-Object System.Windows.Forms.Label
$title.Text = 'PcNinja WinUpdate Tool'
$title.Font = $titleFont
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(92, 10)
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'Search, download, install, and schedule Windows updates.'
$subtitle.AutoSize = $true
$subtitle.Location = New-Object System.Drawing.Point(94, 42)
$form.Controls.Add($subtitle)

$siteLink = New-Object System.Windows.Forms.LinkLabel
$siteLink.Text = 'wWw.PcNinja.Pro'
$siteLink.AutoSize = $true
$siteLink.Location = New-Object System.Drawing.Point -ArgumentList ($form.ClientSize.Width - 162), 42
$siteLink.Anchor = 'Top,Right'
$siteLink.LinkColor = [System.Drawing.Color]::FromArgb(0, 102, 204)
$siteLink.Add_LinkClicked({
    Start-Process 'https://www.PcNinja.Pro' | Out-Null
})
$form.Controls.Add($siteLink)

$tabControl = New-Object System.Windows.Forms.TabControl
$tabControl.Location = New-Object System.Drawing.Point(18, 78)
$tabControl.Size = New-Object System.Drawing.Size -ArgumentList ([Math]::Max(900, $form.ClientSize.Width - 36)), ([Math]::Max(500, $form.ClientSize.Height - 142))
$tabControl.Anchor = 'Top,Bottom,Left,Right'
$tabControl.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10, [System.Drawing.FontStyle]::Bold)
$tabControl.SizeMode = 'Fixed'
$tabControl.DrawMode = 'OwnerDrawFixed'
$tabControl.Multiline = $false
$form.Controls.Add($tabControl)

$dashboardTab = New-Object System.Windows.Forms.TabPage
$dashboardTab.Text = 'Dashboard'
$updatesTab = New-Object System.Windows.Forms.TabPage
$updatesTab.Text = 'Updates'
$scheduleTab = New-Object System.Windows.Forms.TabPage
$scheduleTab.Text = 'Schedule'
$driverTab = New-Object System.Windows.Forms.TabPage
$driverTab.Text = 'Drivers'
$logsTab = New-Object System.Windows.Forms.TabPage
$logsTab.Text = 'Logs'

$uiTabs = [System.Windows.Forms.TabPage[]]@($dashboardTab, $updatesTab, $scheduleTab, $driverTab, $logsTab)
$tabControl.TabPages.AddRange($uiTabs)

function Set-PcnFullWidthTabs {
    if ($script:pcnUpdatingFullWidthTabs) {
        return
    }

    if ($tabControl.TabPages.Count -lt 1) {
        return
    }

    try {
        $script:pcnUpdatingFullWidthTabs = $true
        $availableWidth = [Math]::Max(100, $tabControl.ClientSize.Width - 4)
        $tabWidth = [Math]::Max(96, [int][Math]::Floor($availableWidth / $tabControl.TabPages.Count))
        $tabHeight = 28

        if (($tabControl.ItemSize.Width -ne $tabWidth) -or ($tabControl.ItemSize.Height -ne $tabHeight)) {
            $tabControl.ItemSize = New-Object System.Drawing.Size($tabWidth, $tabHeight)
        }
    }
    finally {
        $script:pcnUpdatingFullWidthTabs = $false
    }
}

$tabControl.Add_DrawItem({
    param($sender, $eventArgs)

    $tabPage = $sender.TabPages[$eventArgs.Index]
    $tabRect = $sender.GetTabRect($eventArgs.Index)
    $isSelected = ($sender.SelectedIndex -eq $eventArgs.Index)
    $palette = if ($script:PcnThemePalette) { $script:PcnThemePalette } else { Get-PcnUiThemePalette -Theme 'Light' }
    $backColor = if ($isSelected) { $palette.TabSelectedBack } else { $palette.TabBack }
    $borderColor = $palette.TabBorder
    $textColor = if ($isSelected -and $palette.Name -eq 'Dark') { [System.Drawing.Color]::White } else { $palette.Text }

    $backgroundBrush = New-Object System.Drawing.SolidBrush($backColor)
    $borderPen = New-Object System.Drawing.Pen($borderColor)

    try {
        $eventArgs.Graphics.FillRectangle($backgroundBrush, $tabRect)
        $eventArgs.Graphics.DrawRectangle($borderPen, $tabRect.X, $tabRect.Y, ($tabRect.Width - 1), ($tabRect.Height - 1))

        if ($isSelected -and $palette.Name -eq 'Dark') {
            $accentPen = New-Object System.Drawing.Pen($palette.Accent2, 3)
            try {
                $eventArgs.Graphics.DrawLine($accentPen, $tabRect.Left + 2, $tabRect.Bottom - 2, $tabRect.Right - 3, $tabRect.Bottom - 2)
            }
            finally {
                $accentPen.Dispose()
            }
        }

        $textFlags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor `
            [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor `
            [System.Windows.Forms.TextFormatFlags]::EndEllipsis
        [System.Windows.Forms.TextRenderer]::DrawText($eventArgs.Graphics, $tabPage.Text, $sender.Font, $tabRect, $textColor, $textFlags)
    }
    finally {
        $backgroundBrush.Dispose()
        $borderPen.Dispose()
    }
})

$tabControl.Add_Paint({
    param($sender, $eventArgs)

    if ($script:PcnUiCurrentTheme -ne 'Dark' -or -not $script:PcnThemePalette) {
        return
    }

    $displayRect = $sender.DisplayRectangle
    $displayRect.Inflate(1, 1)
    $pen = New-Object System.Drawing.Pen($script:PcnThemePalette.TabBorder, 2)
    try {
        $eventArgs.Graphics.DrawRectangle($pen, $displayRect.X, $displayRect.Y, ($displayRect.Width - 1), ($displayRect.Height - 1))
    }
    finally {
        $pen.Dispose()
    }
})

$tabControl.Add_Resize({
    Set-PcnFullWidthTabs
})

Set-PcnFullWidthTabs

foreach ($uiTabPage in $uiTabs) {
    $uiTabPage.BackColor = [System.Drawing.SystemColors]::Window
    $uiTabPage.Font = $form.Font
    $uiTabPage.Padding = New-Object System.Windows.Forms.Padding -ArgumentList 12
    $uiTabPage.AutoScroll = $true
}

$logsTab.Padding = New-Object System.Windows.Forms.Padding -ArgumentList 0
$logsTab.AutoScroll = $false

$dashboardSummaryBox = New-Object System.Windows.Forms.GroupBox
$dashboardSummaryBox.Text = 'System Update Overview'
$dashboardSummaryBox.Font = $sectionFont
$dashboardSummaryBox.Location = New-Object System.Drawing.Point(18, 14)
$dashboardSummaryBox.Size = New-Object System.Drawing.Size(984, 210)
$dashboardSummaryBox.Anchor = 'Top,Left,Right'
$dashboardTab.Controls.Add($dashboardSummaryBox)

$dashboardLastRun = New-Object System.Windows.Forms.Label
$dashboardLastRun.Text = 'Last run: checking...'
$dashboardLastRun.AutoSize = $false
$dashboardLastRun.Font = $form.Font
$dashboardLastRun.Location = New-Object System.Drawing.Point(20, 30)
$dashboardLastRun.Size = New-Object System.Drawing.Size(944, 28)
$dashboardLastRun.Anchor = 'Top,Left,Right'
$dashboardSummaryBox.Controls.Add($dashboardLastRun)

$dashboardActivity = New-Object System.Windows.Forms.Label
$dashboardActivity.Text = 'Windows Update activity: checking...'
$dashboardActivity.AutoSize = $false
$dashboardActivity.Font = $form.Font
$dashboardActivity.Location = New-Object System.Drawing.Point(20, 60)
$dashboardActivity.Size = New-Object System.Drawing.Size(944, 28)
$dashboardActivity.Anchor = 'Top,Left,Right'
$dashboardSummaryBox.Controls.Add($dashboardActivity)

$dashboardReboot = New-Object System.Windows.Forms.Label
$dashboardReboot.Text = 'Restart: checking...'
$dashboardReboot.AutoSize = $false
$dashboardReboot.Font = $form.Font
$dashboardReboot.Location = New-Object System.Drawing.Point(20, 90)
$dashboardReboot.Size = New-Object System.Drawing.Size(944, 28)
$dashboardReboot.Anchor = 'Top,Left,Right'
$dashboardSummaryBox.Controls.Add($dashboardReboot)

$dashboardSchedule = New-Object System.Windows.Forms.Label
$dashboardSchedule.Text = 'Schedule: checking...'
$dashboardSchedule.AutoSize = $false
$dashboardSchedule.Font = $form.Font
$dashboardSchedule.Location = New-Object System.Drawing.Point(20, 120)
$dashboardSchedule.Size = New-Object System.Drawing.Size(944, 28)
$dashboardSchedule.Anchor = 'Top,Left,Right'
$dashboardSummaryBox.Controls.Add($dashboardSchedule)

$dashboardRetry = New-Object System.Windows.Forms.Label
$dashboardRetry.Text = 'Retry: checking...'
$dashboardRetry.AutoSize = $false
$dashboardRetry.Font = $form.Font
$dashboardRetry.Location = New-Object System.Drawing.Point(20, 150)
$dashboardRetry.Size = New-Object System.Drawing.Size(944, 28)
$dashboardRetry.Anchor = 'Top,Left,Right'
$dashboardSummaryBox.Controls.Add($dashboardRetry)

$dashboardDriverAudit = New-Object System.Windows.Forms.Label
$dashboardDriverAudit.Text = 'Driver audit: checking...'
$dashboardDriverAudit.AutoSize = $false
$dashboardDriverAudit.Font = $form.Font
$dashboardDriverAudit.Location = New-Object System.Drawing.Point(20, 180)
$dashboardDriverAudit.Size = New-Object System.Drawing.Size(944, 28)
$dashboardDriverAudit.Anchor = 'Top,Left,Right'
$dashboardSummaryBox.Controls.Add($dashboardDriverAudit)

$dashboardActionsBox = New-Object System.Windows.Forms.GroupBox
$dashboardActionsBox.Text = 'Quick Actions'
$dashboardActionsBox.Font = $sectionFont
$dashboardActionsBox.Location = New-Object System.Drawing.Point(18, 238)
$dashboardActionsBox.Size = New-Object System.Drawing.Size(984, 84)
$dashboardActionsBox.Anchor = 'Top,Left,Right'
$dashboardTab.Controls.Add($dashboardActionsBox)

$dashboardRunButton = New-Object System.Windows.Forms.Button
$dashboardRunButton.Text = 'Run Update Now'
$dashboardRunButton.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11, [System.Drawing.FontStyle]::Bold)
$dashboardRunButton.Location = New-Object System.Drawing.Point(20, 32)
$dashboardRunButton.Size = New-Object System.Drawing.Size(160, 36)
$dashboardActionsBox.Controls.Add($dashboardRunButton)

$dashboardDriverAuditButton = New-Object System.Windows.Forms.Button
$dashboardDriverAuditButton.Text = 'Create Audit'
$dashboardDriverAuditButton.Location = New-Object System.Drawing.Point(196, 32)
$dashboardDriverAuditButton.Size = New-Object System.Drawing.Size(130, 36)
$dashboardActionsBox.Controls.Add($dashboardDriverAuditButton)

$dashboardOpenLogsButton = New-Object System.Windows.Forms.Button
$dashboardOpenLogsButton.Text = 'Open Logs'
$dashboardOpenLogsButton.Location = New-Object System.Drawing.Point(342, 32)
$dashboardOpenLogsButton.Size = New-Object System.Drawing.Size(120, 36)
$dashboardActionsBox.Controls.Add($dashboardOpenLogsButton)

$dashboardRefreshButton = New-Object System.Windows.Forms.Button
$dashboardRefreshButton.Text = 'Refresh'
$dashboardRefreshButton.Location = New-Object System.Drawing.Point(478, 32)
$dashboardRefreshButton.Size = New-Object System.Drawing.Size(110, 36)
$dashboardActionsBox.Controls.Add($dashboardRefreshButton)

$dashboardRunOptionsBox = New-Object System.Windows.Forms.GroupBox
$dashboardRunOptionsBox.Text = 'Run Options'
$dashboardRunOptionsBox.Font = $sectionFont
$dashboardRunOptionsBox.Location = New-Object System.Drawing.Point(18, 340)
$dashboardRunOptionsBox.Size = New-Object System.Drawing.Size(984, 82)
$dashboardRunOptionsBox.Anchor = 'Top,Left,Right'
$dashboardTab.Controls.Add($dashboardRunOptionsBox)

$dashboardRepairBox = New-Object System.Windows.Forms.GroupBox
$dashboardRepairBox.Text = 'Repair Tools'
$dashboardRepairBox.Font = $sectionFont
$dashboardRepairBox.Location = New-Object System.Drawing.Point(18, 492)
$dashboardRepairBox.Size = New-Object System.Drawing.Size(984, 128)
$dashboardRepairBox.Anchor = 'Top,Left,Right'
$dashboardTab.Controls.Add($dashboardRepairBox)

$dashboardResetWuNote = New-Object System.Windows.Forms.Label
$dashboardResetWuNote.Text = 'Reset Windows Update if scanning or downloads appear stuck. This stops update services and clears the local Windows Update cache.'
$dashboardResetWuNote.AutoSize = $false
$dashboardResetWuNote.Font = $form.Font
$dashboardResetWuNote.Location = New-Object System.Drawing.Point(20, 32)
$dashboardResetWuNote.Size = New-Object System.Drawing.Size(620, 52)
$dashboardResetWuNote.Anchor = 'Top,Left,Right'
$dashboardRepairBox.Controls.Add($dashboardResetWuNote)

$dashboardResetWuButton = New-Object System.Windows.Forms.Button
$dashboardResetWuButton.Text = 'Reset Windows Update'
$dashboardResetWuButton.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11, [System.Drawing.FontStyle]::Bold)
$dashboardResetWuButton.Location = New-Object System.Drawing.Point(690, 42)
$dashboardResetWuButton.Size = New-Object System.Drawing.Size(220, 42)
$dashboardResetWuButton.Anchor = 'Top,Right'
$dashboardRepairBox.Controls.Add($dashboardResetWuButton)

$themeLabel = New-Object System.Windows.Forms.Label
$themeLabel.Text = 'Theme'
$themeLabel.AutoSize = $true
$themeLabel.Location = New-Object System.Drawing.Point(690, 36)

$themeCombo = New-Object System.Windows.Forms.ComboBox
$themeCombo.DropDownStyle = 'DropDownList'
[void]$themeCombo.Items.Add('Light')
[void]$themeCombo.Items.Add('Dark')
$themeCombo.SelectedItem = 'Light'
$themeCombo.Location = New-Object System.Drawing.Point(750, 31)
$themeCombo.Size = New-Object System.Drawing.Size(130, 28)

$dashboardFeatureUpdateBox = New-Object System.Windows.Forms.GroupBox
$dashboardFeatureUpdateBox.Text = 'Windows Image Downloads'
$dashboardFeatureUpdateBox.Font = $sectionFont
$dashboardFeatureUpdateBox.Location = New-Object System.Drawing.Point(18, 188)
$dashboardFeatureUpdateBox.Size = New-Object System.Drawing.Size(880, 220)
$dashboardFeatureUpdateBox.Anchor = 'Top,Left,Right'

$featureUpdateNote = New-Object System.Windows.Forms.Label
$featureUpdateNote.Text = 'Open PcNinja Windows image downloads.'
$featureUpdateNote.AutoSize = $false
$featureUpdateNote.Font = $form.Font
$featureUpdateNote.Location = New-Object System.Drawing.Point(20, 34)
$featureUpdateNote.Size = New-Object System.Drawing.Size(820, 44)
$featureUpdateNote.Anchor = 'Top,Left,Right'
$dashboardFeatureUpdateBox.Controls.Add($featureUpdateNote)

$featureUpdateButton = New-Object System.Windows.Forms.Button
$featureUpdateButton.Text = 'Open PcNinja Images'
$featureUpdateButton.Location = New-Object System.Drawing.Point(270, 86)
$featureUpdateButton.Size = New-Object System.Drawing.Size(340, 40)
$featureUpdateButton.Anchor = 'Top,Left'
$dashboardFeatureUpdateBox.Controls.Add($featureUpdateButton)

$featureUpdateSubNote = New-Object System.Windows.Forms.Label
$featureUpdateSubNote.Text = 'The tool opens the website only; it does not download or mount images automatically.'
$featureUpdateSubNote.AutoSize = $false
$featureUpdateSubNote.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$featureUpdateSubNote.Location = New-Object System.Drawing.Point(20, 132)
$featureUpdateSubNote.Size = New-Object System.Drawing.Size(820, 34)
$featureUpdateSubNote.Anchor = 'Top,Left,Right'
$dashboardFeatureUpdateBox.Controls.Add($featureUpdateSubNote)

$pcNinjaClassesBox = New-Object System.Windows.Forms.GroupBox
$pcNinjaClassesBox.Text = 'PcNinja Classes'
$pcNinjaClassesBox.Font = $sectionFont
$pcNinjaClassesBox.Location = New-Object System.Drawing.Point(18, 428)
$pcNinjaClassesBox.Size = New-Object System.Drawing.Size(880, 168)
$pcNinjaClassesBox.Anchor = 'Top,Left,Right'

$pcNinjaClassesNote = New-Object System.Windows.Forms.Label
$pcNinjaClassesNote.Text = 'Private VOD classes, lectures, and online videos with download access.'
$pcNinjaClassesNote.AutoSize = $false
$pcNinjaClassesNote.Font = $form.Font
$pcNinjaClassesNote.Location = New-Object System.Drawing.Point(20, 34)
$pcNinjaClassesNote.Size = New-Object System.Drawing.Size(820, 44)
$pcNinjaClassesNote.Anchor = 'Top,Left,Right'
$pcNinjaClassesBox.Controls.Add($pcNinjaClassesNote)

$pcNinjaClassesButton = New-Object System.Windows.Forms.Button
$pcNinjaClassesButton.Text = 'Open PcNinja Classes'
$pcNinjaClassesButton.Location = New-Object System.Drawing.Point(270, 88)
$pcNinjaClassesButton.Size = New-Object System.Drawing.Size(340, 40)
$pcNinjaClassesButton.Anchor = 'Top,Left'
$pcNinjaClassesBox.Controls.Add($pcNinjaClassesButton)

$manualBox = New-Object System.Windows.Forms.GroupBox
$manualBox.Text = 'Manual Update'
$manualBox.Font = $sectionFont
$manualBox.Location = New-Object System.Drawing.Point(18, 112)
$manualBox.Size = New-Object System.Drawing.Size(420, 190)
$manualBox.Anchor = 'Top,Left'
$form.Controls.Add($manualBox)

$runButton = New-Object System.Windows.Forms.Button
$runButton.Text = 'Run Update Now'
$runButton.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 12, [System.Drawing.FontStyle]::Bold)
$runButton.Size = New-Object System.Drawing.Size(175, 42)
$runButton.Location = New-Object System.Drawing.Point(18, 32)
$manualBox.Controls.Add($runButton)

$rebootPrompt = New-Object System.Windows.Forms.CheckBox
$rebootPrompt.Text = 'Show reboot prompt after manual runs'
$rebootPrompt.AutoSize = $true
$rebootPrompt.Location = New-Object System.Drawing.Point(20, 138)
$manualBox.Controls.Add($rebootPrompt)

$firmwareUpdates = New-Object System.Windows.Forms.CheckBox
$firmwareUpdates.Text = 'Allow firmware/BIOS updates'
$firmwareUpdates.AutoSize = $true
$firmwareUpdates.Location = New-Object System.Drawing.Point(20, 162)
$manualBox.Controls.Add($firmwareUpdates)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(210, 40)
$progress.Size = New-Object System.Drawing.Size(185, 24)
$progress.Style = 'Blocks'
$manualBox.Controls.Add($progress)

$restartButton = New-Object System.Windows.Forms.Button
$restartButton.Text = 'Restart Now'
$restartButton.Location = New-Object System.Drawing.Point(18, 88)
$restartButton.Size = New-Object System.Drawing.Size(130, 34)
$restartButton.Enabled = $false
$manualBox.Controls.Add($restartButton)

$rebootState = New-Object System.Windows.Forms.Label
$rebootState.Text = 'Restart status: checking...'
$rebootState.AutoSize = $false
$rebootState.Location = New-Object System.Drawing.Point(160, 92)
$rebootState.Size = New-Object System.Drawing.Size(240, 28)
$manualBox.Controls.Add($rebootState)

$scheduleBox = New-Object System.Windows.Forms.GroupBox
$scheduleBox.Text = 'Automatic Schedule'
$scheduleBox.Font = $sectionFont
$scheduleBox.Location = New-Object System.Drawing.Point(456, 112)
$scheduleBox.Size = New-Object System.Drawing.Size(466, 300)
$scheduleBox.Anchor = 'Top,Left,Right'
$form.Controls.Add($scheduleBox)

$uiEnableSchedule = New-Object System.Windows.Forms.CheckBox
$uiEnableSchedule.Text = 'Enable scheduled updates'
$uiEnableSchedule.AutoSize = $true
$uiEnableSchedule.Location = New-Object System.Drawing.Point(18, 32)
$scheduleBox.Controls.Add($uiEnableSchedule)

$freqLabel = New-Object System.Windows.Forms.Label
$freqLabel.Text = 'Frequency'
$freqLabel.AutoSize = $true
$freqLabel.Location = New-Object System.Drawing.Point(18, 70)
$scheduleBox.Controls.Add($freqLabel)

$uiFrequency = New-Object System.Windows.Forms.ComboBox
$uiFrequency.DropDownStyle = 'DropDownList'
$uiFrequency.Items.AddRange(@('Daily', 'Weekly', 'Monthly', 'Startup'))
$uiFrequency.Location = New-Object System.Drawing.Point(120, 66)
$uiFrequency.Size = New-Object System.Drawing.Size(140, 30)
$scheduleBox.Controls.Add($uiFrequency)

$timeLabel = New-Object System.Windows.Forms.Label
$timeLabel.Text = 'Time'
$timeLabel.AutoSize = $true
$timeLabel.Location = New-Object System.Drawing.Point(18, 108)
$scheduleBox.Controls.Add($timeLabel)

$timePicker = New-Object System.Windows.Forms.DateTimePicker
$timePicker.Format = 'Time'
$timePicker.ShowUpDown = $true
$timePicker.Location = New-Object System.Drawing.Point(120, 104)
$timePicker.Size = New-Object System.Drawing.Size(140, 30)
$scheduleBox.Controls.Add($timePicker)

$dayLabel = New-Object System.Windows.Forms.Label
$dayLabel.Text = 'Day'
$dayLabel.AutoSize = $true
$dayLabel.Location = New-Object System.Drawing.Point(18, 146)
$scheduleBox.Controls.Add($dayLabel)

$dayCombo = New-Object System.Windows.Forms.ComboBox
$dayCombo.DropDownStyle = 'DropDownList'
$dayCombo.Items.AddRange(@('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'))
$dayCombo.Location = New-Object System.Drawing.Point(120, 142)
$dayCombo.Size = New-Object System.Drawing.Size(140, 30)
$scheduleBox.Controls.Add($dayCombo)

$monthlyDayLabel = New-Object System.Windows.Forms.Label
$monthlyDayLabel.Text = 'Month day'
$monthlyDayLabel.AutoSize = $true
$monthlyDayLabel.Location = New-Object System.Drawing.Point(18, 184)
$scheduleBox.Controls.Add($monthlyDayLabel)

$uiMonthlyDay = New-Object System.Windows.Forms.NumericUpDown
$uiMonthlyDay.Minimum = 1
$uiMonthlyDay.Maximum = 28
$uiMonthlyDay.Location = New-Object System.Drawing.Point(120, 180)
$uiMonthlyDay.Size = New-Object System.Drawing.Size(82, 30)
$uiMonthlyDay.TextAlign = 'Center'
$scheduleBox.Controls.Add($uiMonthlyDay)

$uiRunAtStartup = New-Object System.Windows.Forms.CheckBox
$uiRunAtStartup.Text = 'Also run after startup'
$uiRunAtStartup.AutoSize = $true
$uiRunAtStartup.Location = New-Object System.Drawing.Point(18, 218)
$scheduleBox.Controls.Add($uiRunAtStartup)

$uiRunIfMissed = New-Object System.Windows.Forms.CheckBox
$uiRunIfMissed.Text = 'Run if missed'
$uiRunIfMissed.AutoSize = $true
$uiRunIfMissed.Location = New-Object System.Drawing.Point(250, 218)
$scheduleBox.Controls.Add($uiRunIfMissed)

$uiWakeToRun = New-Object System.Windows.Forms.CheckBox
$uiWakeToRun.Text = 'Wake the computer to run this task'
$uiWakeToRun.AutoSize = $true
$uiWakeToRun.Location = New-Object System.Drawing.Point(250, 246)
$scheduleBox.Controls.Add($uiWakeToRun)

$startupDelayLabel = New-Object System.Windows.Forms.Label
$startupDelayLabel.Text = 'Startup delay'
$startupDelayLabel.AutoSize = $true
$startupDelayLabel.Location = New-Object System.Drawing.Point(18, 246)
$scheduleBox.Controls.Add($startupDelayLabel)

$startupDelay = New-Object System.Windows.Forms.NumericUpDown
$startupDelay.Minimum = 0
$startupDelay.Maximum = 240
$startupDelay.Increment = 5
$startupDelay.Location = New-Object System.Drawing.Point(120, 242)
$startupDelay.Size = New-Object System.Drawing.Size(82, 30)
$startupDelay.TextAlign = 'Center'
$scheduleBox.Controls.Add($startupDelay)

$startupDelayUnit = New-Object System.Windows.Forms.Label
$startupDelayUnit.Text = 'min'
$startupDelayUnit.AutoSize = $true
$startupDelayUnit.Location = New-Object System.Drawing.Point(208, 246)
$scheduleBox.Controls.Add($startupDelayUnit)

$saveSchedule = New-Object System.Windows.Forms.Button
$saveSchedule.Text = 'Save Schedule'
$saveSchedule.Location = New-Object System.Drawing.Point(330, 66)
$saveSchedule.Size = New-Object System.Drawing.Size(105, 34)
$scheduleBox.Controls.Add($saveSchedule)

$removeSchedule = New-Object System.Windows.Forms.Button
$removeSchedule.Text = 'Remove'
$removeSchedule.Location = New-Object System.Drawing.Point(330, 106)
$removeSchedule.Size = New-Object System.Drawing.Size(105, 34)
$scheduleBox.Controls.Add($removeSchedule)

$driverBox = New-Object System.Windows.Forms.GroupBox
$driverBox.Text = 'Driver Audit'
$driverBox.Font = $sectionFont
$driverBox.Location = New-Object System.Drawing.Point(18, 18)
$driverBox.Size = New-Object System.Drawing.Size(984, 96)
$driverBox.Anchor = 'Top,Left,Right'
$driverTab.Controls.Add($driverBox)

$driverReportButton = New-Object System.Windows.Forms.Button
$driverReportButton.Text = 'Create Audit'
$driverReportButton.Location = New-Object System.Drawing.Point(22, 32)
$driverReportButton.Size = New-Object System.Drawing.Size(138, 34)
$driverBox.Controls.Add($driverReportButton)

$openDriverReports = New-Object System.Windows.Forms.Button
$openDriverReports.Text = 'Open Reports'
$openDriverReports.Location = New-Object System.Drawing.Point(176, 32)
$openDriverReports.Size = New-Object System.Drawing.Size(138, 34)
$driverBox.Controls.Add($openDriverReports)

$driverReportNote = New-Object System.Windows.Forms.Label
$driverReportNote.Text = 'Report-only'
$driverReportNote.AutoSize = $false
$driverReportNote.Location = New-Object System.Drawing.Point(340, 35)
$driverReportNote.Size = New-Object System.Drawing.Size(120, 28)
$driverBox.Controls.Add($driverReportNote)

$pcNinjaToolsBox = New-Object System.Windows.Forms.Panel
$pcNinjaToolsBox.Font = $sectionFont
$pcNinjaToolsBox.Location = New-Object System.Drawing.Point(18, 176)
$pcNinjaToolsBox.Size = New-Object System.Drawing.Size(984, 184)
$pcNinjaToolsBox.Anchor = 'Top,Left,Right'
$driverTab.Controls.Add($pcNinjaToolsBox)

$pcNinjaToolsTitle = New-Object System.Windows.Forms.Label
$pcNinjaToolsTitle.Text = 'PcNinja Tools'
$pcNinjaToolsTitle.Font = $sectionFont
$pcNinjaToolsTitle.AutoSize = $false
$pcNinjaToolsTitle.Location = New-Object System.Drawing.Point(0, 0)
$pcNinjaToolsTitle.Size = New-Object System.Drawing.Size(220, 26)
$pcNinjaToolsBox.Controls.Add($pcNinjaToolsTitle)

$pcNinjaToolLinks = @(
    @{ Text = 'PcNinja Drivers Updater'; Url = 'https://driver.pcninja.pro'; DisplayUrl = 'https://driver.pcninja.pro'; X = 42 },
    @{ Text = 'PcNinja Office Installer'; Url = 'https://office.pcninja.pro'; DisplayUrl = 'https://office.pcninja.pro'; X = 352 },
    @{ Text = 'PcNinja Activation'; Url = 'https://active.pcninja.pro'; DisplayUrl = 'https://active.pcninja.pro'; X = 662 }
)

$pcNinjaToolY = 34

for ($pcNinjaToolIndex = 0; $pcNinjaToolIndex -lt $pcNinjaToolLinks.Count; $pcNinjaToolIndex++) {
    $pcNinjaToolLink = $pcNinjaToolLinks[$pcNinjaToolIndex]
    $pcNinjaToolsBox.Controls.Add((New-PcnUiLinkTile -Text $pcNinjaToolLink['Text'] -Url $pcNinjaToolLink['Url'] -DisplayUrl $pcNinjaToolLink['DisplayUrl'] -X $pcNinjaToolLink['X'] -Y $pcNinjaToolY -Width 280 -Height 92 -Plain))
}

$pcNinjaPasswordLabel = New-Object System.Windows.Forms.Label
$pcNinjaPasswordLabel.Text = 'PcNinja file password:'
$pcNinjaPasswordLabel.AutoSize = $false
$pcNinjaPasswordLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10, [System.Drawing.FontStyle]::Bold)
$pcNinjaPasswordLabel.Location = New-Object System.Drawing.Point(348, 142)
$pcNinjaPasswordLabel.Size = New-Object System.Drawing.Size(180, 28)
$pcNinjaPasswordLabel.Anchor = 'Top,Left'
$pcNinjaToolsBox.Controls.Add($pcNinjaPasswordLabel)

$pcNinjaPasswordTextBox = New-Object System.Windows.Forms.TextBox
$pcNinjaPasswordTextBox.Text = 'JavierTorres'
$pcNinjaPasswordTextBox.ReadOnly = $true
$pcNinjaPasswordTextBox.BorderStyle = 'FixedSingle'
$pcNinjaPasswordTextBox.BackColor = [System.Drawing.SystemColors]::Window
$pcNinjaPasswordTextBox.TextAlign = 'Center'
$pcNinjaPasswordTextBox.Location = New-Object System.Drawing.Point(540, 138)
$pcNinjaPasswordTextBox.Size = New-Object System.Drawing.Size(150, 28)
$pcNinjaPasswordTextBox.Anchor = 'Top,Left'
$pcNinjaToolsBox.Controls.Add($pcNinjaPasswordTextBox)

$driverSourcesBox = New-Object System.Windows.Forms.GroupBox
$driverSourcesBox.Text = 'Manufacturer Driver Sources'
$driverSourcesBox.Font = $sectionFont
$driverSourcesBox.Location = New-Object System.Drawing.Point(18, 296)
$driverSourcesBox.Size = New-Object System.Drawing.Size(984, 194)
$driverSourcesBox.Anchor = 'Top,Left,Right'
$driverTab.Controls.Add($driverSourcesBox)

$driverSourceLinks = @(
    @{ Text = 'Dell Drivers Downloads'; Url = 'https://www.dell.com/support/home/en-us?app=drivers' },
    @{ Text = 'HP Image Assistant'; Url = 'https://ftp.ext.hp.com/pub/caps-softpaq/cmit/HPIA.html' },
    @{ Text = 'ASUS Download Center'; Url = 'https://www.asus.com/support/download-center/' },
    @{ Text = 'Lenovo System Update'; Url = 'https://support.lenovo.com/us/en/solutions/ht003029-lenovo-system-update-update-drivers-bios-and-applications' },
    @{ Text = 'Microsoft Surface drivers'; Url = 'https://support.microsoft.com/en-us/surface/drivers-firmware/download-drivers-and-firmware-for-surface' },
    @{ Text = 'Intel Driver Support Assistant'; Url = 'https://www.intel.com/content/www/us/en/support/detect.html' },
    @{ Text = 'AMD Drivers and Support'; Url = 'https://www.amd.com/en/support/download/drivers.html' },
    @{ Text = 'NVIDIA official drivers'; Url = 'https://www.nvidia.com/en-us/drivers/' },
    @{ Text = 'Logitech Support + Download'; Url = 'https://support.logi.com/hc/en-us' }
)

$driverLinkX = 22
$driverLinkY = 36
$driverLinkColumnWidth = 328
$driverLinkRowHeight = 31

for ($driverLinkIndex = 0; $driverLinkIndex -lt $driverSourceLinks.Count; $driverLinkIndex++) {
    $driverLink = $driverSourceLinks[$driverLinkIndex]
    $column = [Math]::Floor($driverLinkIndex / 3)
    $row = $driverLinkIndex % 3
    $x = $driverLinkX + ($column * $driverLinkColumnWidth)
    $y = $driverLinkY + ($row * $driverLinkRowHeight)

    $driverSourcesBox.Controls.Add((New-PcnUiLinkLabel -Text $driverLink['Text'] -Url $driverLink['Url'] -X $x -Y $y -Width 260 -Height 24))
}

$retryBox = New-Object System.Windows.Forms.GroupBox
$retryBox.Text = 'Retry Policy'
$retryBox.Font = $sectionFont
$retryBox.Location = New-Object System.Drawing.Point(18, 400)
$retryBox.Size = New-Object System.Drawing.Size(944, 104)
$retryBox.Anchor = 'Top,Left,Right'
$form.Controls.Add($retryBox)

$autoRetry = New-Object System.Windows.Forms.CheckBox
$autoRetry.Text = 'Auto retry when Windows Update is busy or network is unavailable'
$autoRetry.AutoSize = $true
$autoRetry.Location = New-Object System.Drawing.Point(18, 30)
$retryBox.Controls.Add($autoRetry)

$retryDelayLabel = New-Object System.Windows.Forms.Label
$retryDelayLabel.Text = 'First delay'
$retryDelayLabel.AutoSize = $true
$retryDelayLabel.Location = New-Object System.Drawing.Point(18, 68)
$retryBox.Controls.Add($retryDelayLabel)

$retryDelay = New-Object System.Windows.Forms.NumericUpDown
$retryDelay.Minimum = 5
$retryDelay.Maximum = 240
$retryDelay.Increment = 5
$retryDelay.Location = New-Object System.Drawing.Point(104, 64)
$retryDelay.Size = New-Object System.Drawing.Size(82, 26)
$retryDelay.TextAlign = 'Center'
$retryBox.Controls.Add($retryDelay)

$retryDelayUnit = New-Object System.Windows.Forms.Label
$retryDelayUnit.Text = 'min'
$retryDelayUnit.AutoSize = $true
$retryDelayUnit.Location = New-Object System.Drawing.Point(192, 68)
$retryBox.Controls.Add($retryDelayUnit)

$retryMaxLabel = New-Object System.Windows.Forms.Label
$retryMaxLabel.Text = 'Max retries'
$retryMaxLabel.AutoSize = $true
$retryMaxLabel.Location = New-Object System.Drawing.Point(246, 68)
$retryBox.Controls.Add($retryMaxLabel)

$retryMax = New-Object System.Windows.Forms.NumericUpDown
$retryMax.Minimum = 0
$retryMax.Maximum = 10
$retryMax.Location = New-Object System.Drawing.Point(338, 64)
$retryMax.Size = New-Object System.Drawing.Size(70, 26)
$retryMax.TextAlign = 'Center'
$retryBox.Controls.Add($retryMax)

$retryCooldownLabel = New-Object System.Windows.Forms.Label
$retryCooldownLabel.Text = 'Cooldown'
$retryCooldownLabel.AutoSize = $true
$retryCooldownLabel.Location = New-Object System.Drawing.Point(446, 68)
$retryBox.Controls.Add($retryCooldownLabel)

$retryCooldown = New-Object System.Windows.Forms.NumericUpDown
$retryCooldown.Minimum = 0
$retryCooldown.Maximum = 240
$retryCooldown.Increment = 5
$retryCooldown.Location = New-Object System.Drawing.Point(528, 64)
$retryCooldown.Size = New-Object System.Drawing.Size(82, 26)
$retryCooldown.TextAlign = 'Center'
$retryBox.Controls.Add($retryCooldown)

$retryCooldownUnit = New-Object System.Windows.Forms.Label
$retryCooldownUnit.Text = 'min'
$retryCooldownUnit.AutoSize = $true
$retryCooldownUnit.Location = New-Object System.Drawing.Point(616, 68)
$retryBox.Controls.Add($retryCooldownUnit)

$retryStateLabel = New-Object System.Windows.Forms.Label
$retryStateLabel.Text = 'Next retry: none'
$retryStateLabel.AutoSize = $false
$retryStateLabel.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$retryStateLabel.Location = New-Object System.Drawing.Point(670, 26)
$retryStateLabel.Size = New-Object System.Drawing.Size(250, 72)
$retryStateLabel.Anchor = 'Top,Left,Right'
$retryBox.Controls.Add($retryStateLabel)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = 'Scheduled task: checking...'
$statusLabel.AutoSize = $false
$statusLabel.Location = New-Object System.Drawing.Point(18, 516)
$statusLabel.Size = New-Object System.Drawing.Size(944, 44)
$statusLabel.Anchor = 'Top,Left,Right'
$form.Controls.Add($statusLabel)

$refreshLog = New-Object System.Windows.Forms.Button
$refreshLog.Text = 'Refresh'
$refreshLog.Location = New-Object System.Drawing.Point(688, 570)
$refreshLog.Size = New-Object System.Drawing.Size(92, 32)
$refreshLog.Anchor = 'Top,Right'
$form.Controls.Add($refreshLog)

$openLog = New-Object System.Windows.Forms.Button
$openLog.Text = 'Open Log'
$openLog.Location = New-Object System.Drawing.Point(790, 570)
$openLog.Size = New-Object System.Drawing.Size(92, 32)
$openLog.Anchor = 'Top,Right'
$form.Controls.Add($openLog)

$openFolder = New-Object System.Windows.Forms.Button
$openFolder.Text = 'Folder'
$openFolder.Location = New-Object System.Drawing.Point(892, 570)
$openFolder.Size = New-Object System.Drawing.Size(70, 32)
$openFolder.Anchor = 'Top,Right'
$form.Controls.Add($openFolder)

$logBottomButton = New-Object System.Windows.Forms.Button
$logBottomButton.Text = 'Bottom'
$logBottomButton.Location = New-Object System.Drawing.Point(586, 570)
$logBottomButton.Size = New-Object System.Drawing.Size(92, 32)
$logBottomButton.Anchor = 'Top,Right'
$form.Controls.Add($logBottomButton)

$loadLogsButton = New-Object System.Windows.Forms.Button
$loadLogsButton.Text = 'Load Logs'
$loadLogsButton.Location = New-Object System.Drawing.Point(484, 570)
$loadLogsButton.Size = New-Object System.Drawing.Size(92, 32)
$loadLogsButton.Anchor = 'Top,Right'
$form.Controls.Add($loadLogsButton)

$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.ReadOnly = $true
$logBox.DetectUrls = $false
$logBox.WordWrap = $true
$logBox.ScrollBars = 'ForcedVertical'
$logBox.BorderStyle = 'None'
$logBox.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)
$logBox.HideSelection = $false
$logBox.Font = New-Object System.Drawing.Font('Consolas', 8)
$logBox.Location = New-Object System.Drawing.Point(2, 2)
$logBox.Size = New-Object System.Drawing.Size(940, 100)
$logBox.Anchor = 'Top,Bottom,Left,Right'
$logBox.Text = "Logs are not loaded during app startup.`r`n`r`nClick Load Logs to open the live log view."

$logFrame = New-Object System.Windows.Forms.Panel
$logFrame.Location = New-Object System.Drawing.Point(18, 610)
$logFrame.Size = New-Object System.Drawing.Size(944, 104)
$logFrame.Anchor = 'Top,Bottom,Left,Right'
$logFrame.BorderStyle = 'None'
$logFrame.Controls.Add($logBox)
$logFrame.Add_Paint({
    param($sender, $eventArgs)

    if ($script:PcnUiCurrentTheme -ne 'Dark' -or -not $script:PcnThemePalette) {
        return
    }

    $pen = New-Object System.Drawing.Pen($script:PcnThemePalette.Border, 2)
    try {
        $eventArgs.Graphics.DrawRectangle($pen, 0, 0, ($sender.ClientSize.Width - 1), ($sender.ClientSize.Height - 1))
    }
    finally {
        $pen.Dispose()
    }
})
$form.Controls.Add($logFrame)

$footer = New-Object System.Windows.Forms.Label
$footer.Text = 'Ready.'
$footer.AutoSize = $false
$footer.Location = New-Object System.Drawing.Point -ArgumentList 18, ($form.ClientSize.Height - 38)
$footer.Size = New-Object System.Drawing.Size -ArgumentList ($form.ClientSize.Width - 136), 24
$footer.Anchor = 'Bottom,Left,Right'
$form.Controls.Add($footer)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = 'Exit'
$closeButton.Location = New-Object System.Drawing.Point -ArgumentList ($form.ClientSize.Width - 104), ($form.ClientSize.Height - 44)
$closeButton.Size = New-Object System.Drawing.Size(86, 34)
$closeButton.Anchor = 'Bottom,Right'
$form.Controls.Add($closeButton)

$manualBox.Location = New-Object System.Drawing.Point(240, 18)
$manualBox.Size = New-Object System.Drawing.Size(540, 150)
$manualBox.Anchor = 'Top'
$updatesTab.Controls.Add($manualBox)

$dashboardFeatureUpdateBox.Location = New-Object System.Drawing.Point(70, 188)
$dashboardFeatureUpdateBox.Size = New-Object System.Drawing.Size(880, 168)
$dashboardFeatureUpdateBox.Anchor = 'Top'
$updatesTab.Controls.Add($dashboardFeatureUpdateBox)

$pcNinjaClassesBox.Location = New-Object System.Drawing.Point(70, 428)
$pcNinjaClassesBox.Size = New-Object System.Drawing.Size(880, 168)
$pcNinjaClassesBox.Anchor = 'Top'
$updatesTab.Controls.Add($pcNinjaClassesBox)

$runButton.Location = New-Object System.Drawing.Point(20, 34)
$runButton.Size = New-Object System.Drawing.Size(180, 40)
$progress.Location = New-Object System.Drawing.Point(220, 42)
$progress.Size = New-Object System.Drawing.Size(280, 24)
$restartButton.Location = New-Object System.Drawing.Point(20, 94)
$restartButton.Size = New-Object System.Drawing.Size(130, 34)
$rebootState.Location = New-Object System.Drawing.Point(166, 98)
$rebootState.Size = New-Object System.Drawing.Size(330, 28)

$scheduleBox.Location = New-Object System.Drawing.Point(210, 18)
$scheduleBox.Size = New-Object System.Drawing.Size(600, 300)
$scheduleBox.Anchor = 'Top'
$scheduleTab.Controls.Add($scheduleBox)

$retryBox.Location = New-Object System.Drawing.Point(70, 338)
$retryBox.Size = New-Object System.Drawing.Size(880, 118)
$retryBox.Anchor = 'Top'
$scheduleTab.Controls.Add($retryBox)

$statusLabel.Location = New-Object System.Drawing.Point(70, 476)
$statusLabel.Size = New-Object System.Drawing.Size(880, 64)
$statusLabel.Anchor = 'Top'
$scheduleTab.Controls.Add($statusLabel)

$driverBox.Location = New-Object System.Drawing.Point(18, 18)
$driverBox.Size = New-Object System.Drawing.Size(984, 96)
$driverBox.Anchor = 'Top,Left,Right'
$driverTab.Controls.Add($driverBox)

$driverReportButton.Location = New-Object System.Drawing.Point(286, 32)
$driverReportButton.Size = New-Object System.Drawing.Size(150, 36)
$openDriverReports.Location = New-Object System.Drawing.Point(476, 32)
$openDriverReports.Size = New-Object System.Drawing.Size(150, 36)
$driverReportNote.Location = New-Object System.Drawing.Point(656, 36)
$driverReportNote.Size = New-Object System.Drawing.Size(120, 28)

$loadLogsButton.Location = New-Object System.Drawing.Point(392, 462)
$loadLogsButton.Anchor = 'Bottom,Right'
$logsTab.Controls.Add($loadLogsButton)
$logBottomButton.Location = New-Object System.Drawing.Point(494, 462)
$logBottomButton.Anchor = 'Bottom,Right'
$logsTab.Controls.Add($logBottomButton)
$refreshLog.Location = New-Object System.Drawing.Point(596, 462)
$refreshLog.Anchor = 'Bottom,Right'
$logsTab.Controls.Add($refreshLog)
$openLog.Location = New-Object System.Drawing.Point(698, 462)
$openLog.Anchor = 'Bottom,Right'
$logsTab.Controls.Add($openLog)
$openFolder.Location = New-Object System.Drawing.Point(800, 462)
$openFolder.Anchor = 'Bottom,Right'
$logsTab.Controls.Add($openFolder)
$logFrame.Location = New-Object System.Drawing.Point(18, 18)
$logFrame.Size = New-Object System.Drawing.Size(858, 436)
$logFrame.Anchor = 'Top,Bottom,Left,Right'
$logsTab.Controls.Add($logFrame)

function Set-PcnCenteredControl {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.Control]$Control,

        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.Control]$Parent,

        [Parameter(Mandatory = $true)]
        [int]$Y,

        [Parameter(Mandatory = $true)]
        [int]$PreferredWidth,

        [Parameter(Mandatory = $true)]
        [int]$Height,

        [int]$Margin = 18
    )

    $availableWidth = [Math]::Max(320, $Parent.ClientSize.Width - ($Margin * 2))
    $width = [Math]::Min($PreferredWidth, $availableWidth)
    $x = [Math]::Max($Margin, [int][Math]::Floor(($Parent.ClientSize.Width - $width) / 2))
    $Control.Location = New-Object System.Drawing.Point($x, $Y)
    $Control.Size = New-Object System.Drawing.Size($width, $Height)
}

function Resize-PcnCenteredTabs {
    Set-PcnCenteredControl -Control $dashboardSummaryBox -Parent $dashboardTab -Y 64 -PreferredWidth 984 -Height 210
    Set-PcnCenteredControl -Control $dashboardActionsBox -Parent $dashboardTab -Y 288 -PreferredWidth 984 -Height 84
    Set-PcnCenteredControl -Control $dashboardRunOptionsBox -Parent $dashboardTab -Y 390 -PreferredWidth 984 -Height 82
    Set-PcnCenteredControl -Control $dashboardRepairBox -Parent $dashboardTab -Y 504 -PreferredWidth 984 -Height 128

    Set-PcnCenteredControl -Control $manualBox -Parent $updatesTab -Y 70 -PreferredWidth 540 -Height 150
    Set-PcnCenteredControl -Control $dashboardFeatureUpdateBox -Parent $updatesTab -Y 245 -PreferredWidth 880 -Height 168
    Set-PcnCenteredControl -Control $pcNinjaClassesBox -Parent $updatesTab -Y 450 -PreferredWidth 880 -Height 168

    Set-PcnCenteredControl -Control $scheduleBox -Parent $scheduleTab -Y 58 -PreferredWidth 600 -Height 300
    Set-PcnCenteredControl -Control $retryBox -Parent $scheduleTab -Y 405 -PreferredWidth 880 -Height 118
    Set-PcnCenteredControl -Control $statusLabel -Parent $scheduleTab -Y 545 -PreferredWidth 880 -Height 64

    Set-PcnCenteredControl -Control $driverBox -Parent $driverTab -Y 60 -PreferredWidth 984 -Height 96
    Set-PcnCenteredControl -Control $pcNinjaToolsBox -Parent $driverTab -Y 176 -PreferredWidth 984 -Height 184
    Set-PcnCenteredControl -Control $driverSourcesBox -Parent $driverTab -Y 388 -PreferredWidth 984 -Height 194
}

function Resize-PcnLogsTab {
    $margin = 18
    $buttonGap = 8
    $buttonTop = [Math]::Max($margin, $logsTab.ClientSize.Height - $margin - $refreshLog.Height)

    $openFolderLeft = [Math]::Max($margin, $logsTab.ClientSize.Width - $margin - $openFolder.Width)
    $openLogLeft = [Math]::Max($margin, $openFolderLeft - $buttonGap - $openLog.Width)
    $refreshLeft = [Math]::Max($margin, $openLogLeft - $buttonGap - $refreshLog.Width)
    $bottomLeft = [Math]::Max($margin, $refreshLeft - $buttonGap - $logBottomButton.Width)
    $loadLeft = [Math]::Max($margin, $bottomLeft - $buttonGap - $loadLogsButton.Width)

    $loadLogsButton.Location = New-Object System.Drawing.Point -ArgumentList $loadLeft, $buttonTop
    $logBottomButton.Location = New-Object System.Drawing.Point -ArgumentList $bottomLeft, $buttonTop
    $refreshLog.Location = New-Object System.Drawing.Point -ArgumentList $refreshLeft, $buttonTop
    $openLog.Location = New-Object System.Drawing.Point -ArgumentList $openLogLeft, $buttonTop
    $openFolder.Location = New-Object System.Drawing.Point -ArgumentList $openFolderLeft, $buttonTop

    $logFrame.Location = New-Object System.Drawing.Point -ArgumentList $margin, $margin
    $logFrame.Size = New-Object System.Drawing.Size -ArgumentList `
        ([Math]::Max(320, $logsTab.ClientSize.Width - ($margin * 2))), `
        ([Math]::Max(160, $buttonTop - ($margin * 2)))
    $logBox.Location = New-Object System.Drawing.Point -ArgumentList 2, 2
    $logBox.Size = New-Object System.Drawing.Size -ArgumentList `
        ([Math]::Max(316, $logFrame.ClientSize.Width - 4)), `
        ([Math]::Max(156, $logFrame.ClientSize.Height - 4))
}

$logsTab.Add_Resize({
    Resize-PcnLogsTab
})

Resize-PcnLogsTab

$dashboardTab.Add_Resize({
    Resize-PcnCenteredTabs
})

$updatesTab.Add_Resize({
    Resize-PcnCenteredTabs
})

$scheduleTab.Add_Resize({
    Resize-PcnCenteredTabs
})

$driverTab.Add_Resize({
    Resize-PcnCenteredTabs
})

Resize-PcnCenteredTabs

$tabControl.Add_SelectedIndexChanged({
    if ($tabControl.SelectedTab -eq $logsTab) {
        if (-not $script:uiLogsLoaded) {
            $footer.Text = 'Ready.'
            return
        }

        if ($script:uiLogRefreshPending -or (((Get-Date) - $script:lastUiLogRefresh).TotalSeconds -ge 5)) {
            $footer.Text = 'Loading logs...'
        }

        $script:pendingTabRefresh = 'Logs'
        $deferredUiRefreshTimer.Stop()
        $deferredUiRefreshTimer.Start()
        return
    }

    if ($tabControl.SelectedTab -eq $dashboardTab) {
        if ($script:dashboardRefreshPending -or (((Get-Date) - $script:lastDashboardRefresh).TotalSeconds -ge 60)) {
            $footer.Text = 'Loading dashboard...'
        }

        $script:pendingTabRefresh = 'Dashboard'
        $deferredUiRefreshTimer.Stop()
        $deferredUiRefreshTimer.Start()
    }
})

$rebootPrompt.Location = New-Object System.Drawing.Point(20, 34)
$rebootPrompt.Font = $form.Font
$dashboardRunOptionsBox.Controls.Add($rebootPrompt)
$firmwareUpdates.Location = New-Object System.Drawing.Point(360, 34)
$firmwareUpdates.Font = $form.Font
$dashboardRunOptionsBox.Controls.Add($firmwareUpdates)
$themeLabel.Font = $form.Font
$dashboardRunOptionsBox.Controls.Add($themeLabel)
$dashboardRunOptionsBox.Controls.Add($themeCombo)

$tabControl.SelectedTab = $dashboardTab

$script:runningProcess = $null
$script:lastUiRetryLaunch = $null
$script:lastUiLogRefresh = [DateTime]::MinValue
$script:lastDashboardRefresh = [DateTime]::MinValue
$script:uiLogRefreshPending = $true
$script:dashboardRefreshPending = $true
$script:pendingTabRefresh = $null
$script:startupRefreshStep = 0
$script:pcnUiStatusCache = @{}
$script:uiLogsLoaded = $false

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000

$retryMonitorTimer = New-Object System.Windows.Forms.Timer
$retryMonitorTimer.Interval = 30000

$deferredUiRefreshTimer = New-Object System.Windows.Forms.Timer
$deferredUiRefreshTimer.Interval = 150

$startupRefreshTimer = New-Object System.Windows.Forms.Timer
$startupRefreshTimer.Interval = 90

function Get-PcnUiCachedValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Loader,

        [int]$MaxAgeSeconds = 30,

        [switch]$Force
    )

    $now = Get-Date

    if (-not $Force -and $script:pcnUiStatusCache.ContainsKey($Key)) {
        $entry = $script:pcnUiStatusCache[$Key]
        if ($entry -and (($now - $entry.Timestamp).TotalSeconds -lt $MaxAgeSeconds)) {
            return $entry.Value
        }
    }

    $value = & $Loader
    $script:pcnUiStatusCache[$Key] = [pscustomobject]@{
        Value = $value
        Timestamp = $now
    }

    return $value
}

function Clear-PcnUiStatusCache {
    $script:pcnUiStatusCache.Clear()
}

function Set-PcnControlTheme {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.Control]$Control,

        [Parameter(Mandatory = $true)]
        [psobject]$Palette
    )

    $isDark = ($Palette.Name -eq 'Dark')

    if ($Control -is [System.Windows.Forms.Form]) {
        $Control.BackColor = $Palette.FormBack
        $Control.ForeColor = $Palette.Text
    }
    elseif ($Control -is [System.Windows.Forms.TabPage]) {
        $Control.BackColor = $Palette.FormBack
        $Control.ForeColor = $Palette.Text
    }
    elseif ($Control -is [System.Windows.Forms.TabControl]) {
        $Control.BackColor = $Palette.TabBack
        $Control.ForeColor = $Palette.Text
    }
    elseif ($Control -is [System.Windows.Forms.GroupBox]) {
        if ($isDark) {
            $Control.FlatStyle = 'Flat'
        }
        $Control.BackColor = $Palette.FormBack
        $Control.ForeColor = if ($isDark) { $Palette.MutedText } else { $Palette.Text }
    }
    elseif ($Control -is [System.Windows.Forms.Panel]) {
        if ($Control.BorderStyle -eq 'None') {
            $Control.BackColor = [System.Drawing.Color]::Transparent
        }
        else {
            $Control.BackColor = $Palette.PanelBack
        }
        $Control.ForeColor = $Palette.Text
    }
    elseif ($Control -is [System.Windows.Forms.LinkLabel]) {
        $Control.BackColor = [System.Drawing.Color]::Transparent
        $Control.ForeColor = $Palette.Text
        $Control.LinkColor = if ($isDark) { $Palette.Accent } else { $Palette.Accent2 }
        $Control.ActiveLinkColor = $Palette.Accent2
        $Control.VisitedLinkColor = if ($isDark) { $Palette.Accent } else { $Palette.Accent2 }
    }
    elseif ($Control -is [System.Windows.Forms.Button]) {
        $Control.FlatStyle = if ($isDark) { 'Flat' } else { 'Standard' }
        $Control.BackColor = $Palette.ButtonBack
        $Control.ForeColor = $Palette.ButtonText
        if ($isDark) {
            $Control.FlatAppearance.BorderColor = $Palette.Accent
            $Control.FlatAppearance.MouseOverBackColor = $Palette.TabSelectedBack
            $Control.FlatAppearance.MouseDownBackColor = $Palette.Accent
        }
    }
    elseif ($Control -is [System.Windows.Forms.TextBox] -or
        $Control -is [System.Windows.Forms.RichTextBox] -or
        $Control -is [System.Windows.Forms.ComboBox] -or
        $Control -is [System.Windows.Forms.NumericUpDown] -or
        $Control -is [System.Windows.Forms.DateTimePicker]) {
        $Control.BackColor = $Palette.InputBack
        $Control.ForeColor = $Palette.InputText

        if ($isDark -and $Control -is [System.Windows.Forms.ComboBox]) {
            $Control.FlatStyle = 'Flat'
        }
    }
    elseif ($Control -is [System.Windows.Forms.ProgressBar]) {
        $null = $Control
    }
    elseif ($Control -is [System.Windows.Forms.Label] -or $Control -is [System.Windows.Forms.CheckBox]) {
        $Control.BackColor = [System.Drawing.Color]::Transparent
        $Control.ForeColor = $Palette.Text
    }
    else {
        $Control.BackColor = $Palette.FormBack
        $Control.ForeColor = $Palette.Text
    }

    foreach ($child in $Control.Controls) {
        Set-PcnControlTheme -Control $child -Palette $Palette
    }
}

function Register-PcnDarkAccentBox {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.Control]$Control,

        [ValidateSet('Blue', 'Red')]
        [string]$Accent = 'Blue',

        [switch]$Fill
    )

    $accentName = $Accent
    $fillPanel = [bool]$Fill

    $Control.Add_Paint({
        param($sender, $eventArgs)

        if ($script:PcnUiCurrentTheme -ne 'Dark' -or -not $script:PcnThemePalette) {
            return
        }

        $palette = $script:PcnThemePalette
        $accentColor = if ($accentName -eq 'Red') { $palette.Danger } else { $palette.Border }
        $clientWidth = [Math]::Max(1, $sender.ClientSize.Width)
        $clientHeight = [Math]::Max(1, $sender.ClientSize.Height)
        $top = 14
        $left = 1
        $right = [Math]::Max($left, $clientWidth - 3)
        $bottom = [Math]::Max($top, $clientHeight - 3)
        $rect = New-Object System.Drawing.Rectangle -ArgumentList $left, $top, ($right - $left), ($bottom - $top)
        $pen = New-Object System.Drawing.Pen($accentColor, 2)

        try {
            $backBrush = New-Object System.Drawing.SolidBrush($sender.BackColor)
            try {
                $eventArgs.Graphics.FillRectangle($backBrush, 0, ($top - 3), $clientWidth, 7)
                $eventArgs.Graphics.FillRectangle($backBrush, 0, $top, 5, ($bottom - $top + 3))
                $eventArgs.Graphics.FillRectangle($backBrush, ($clientWidth - 5), $top, 5, ($bottom - $top + 3))
                $eventArgs.Graphics.FillRectangle($backBrush, 0, ($bottom - 3), $clientWidth, 6)
            }
            finally {
                $backBrush.Dispose()
            }

            if ($fillPanel) {
                $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(32, $accentColor))
                try {
                    $eventArgs.Graphics.FillRectangle($brush, $rect)
                }
                finally {
                    $brush.Dispose()
                }
            }

            $titleGapStart = 8
            $titleGapEnd = $titleGapStart
            if (-not [string]::IsNullOrWhiteSpace($sender.Text)) {
                $titleSize = [System.Windows.Forms.TextRenderer]::MeasureText($sender.Text, $sender.Font)
                $titleGapEnd = [Math]::Min(($right - 10), ($titleGapStart + $titleSize.Width + 10))
            }
            if ($titleGapStart -gt $left) {
                $eventArgs.Graphics.DrawLine($pen, $left, $top, $titleGapStart, $top)
            }
            if ($titleGapEnd -lt $right) {
                $eventArgs.Graphics.DrawLine($pen, $titleGapEnd, $top, $right, $top)
            }
            $eventArgs.Graphics.DrawLine($pen, $left, $top, $left, $bottom)
            $eventArgs.Graphics.DrawLine($pen, $right, $top, $right, $bottom)
            $eventArgs.Graphics.DrawLine($pen, $left, $bottom, $right, $bottom)
        }
        finally {
            $pen.Dispose()
        }
    }.GetNewClosure())
}

function Register-PcnDarkAccentStyles {
    Register-PcnDarkAccentBox -Control $dashboardSummaryBox -Accent Blue
    Register-PcnDarkAccentBox -Control $dashboardActionsBox -Accent Blue
    Register-PcnDarkAccentBox -Control $dashboardRunOptionsBox -Accent Blue
    Register-PcnDarkAccentBox -Control $dashboardRepairBox -Accent Blue
    Register-PcnDarkAccentBox -Control $manualBox -Accent Blue
    Register-PcnDarkAccentBox -Control $dashboardFeatureUpdateBox -Accent Blue
    Register-PcnDarkAccentBox -Control $pcNinjaClassesBox -Accent Blue
    Register-PcnDarkAccentBox -Control $scheduleBox -Accent Blue
    Register-PcnDarkAccentBox -Control $retryBox -Accent Blue
    Register-PcnDarkAccentBox -Control $driverBox -Accent Blue
    Register-PcnDarkAccentBox -Control $driverSourcesBox -Accent Blue
}

function Set-PcnDarkButtonAccents {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Palette
    )

    $blueButtons = @(
        $runButton,
        $dashboardRunButton,
        $dashboardDriverAuditButton,
        $dashboardOpenLogsButton,
        $dashboardRefreshButton,
        $featureUpdateButton,
        $pcNinjaClassesButton,
        $saveSchedule,
        $driverReportButton,
        $openDriverReports,
        $refreshLog,
        $openLog,
        $openFolder,
        $loadLogsButton,
        $logBottomButton
    )

    foreach ($button in $blueButtons) {
        if ($button) {
            $button.FlatAppearance.BorderColor = $Palette.Accent2
            $button.FlatAppearance.MouseOverBackColor = $Palette.TabSelectedBack
        }
    }

    foreach ($button in @($removeSchedule, $restartButton, $dashboardResetWuButton, $closeButton)) {
        if ($button) {
            $button.FlatAppearance.BorderColor = $Palette.Danger
            $button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(72, 40, 42)
        }
    }
}

function Update-PcnDarkAccentInvalidation {
    foreach ($control in @(
        $dashboardSummaryBox,
        $dashboardActionsBox,
        $dashboardRunOptionsBox,
        $dashboardRepairBox,
        $manualBox,
        $dashboardFeatureUpdateBox,
        $pcNinjaClassesBox,
        $scheduleBox,
        $retryBox,
        $driverBox,
        $driverSourcesBox,
        $logFrame
    )) {
        if ($control) {
            $control.Invalidate()
        }
    }
}

function Apply-PcnUiTheme {
    param(
        [ValidateSet('Light', 'Dark')]
        [string]$Theme = 'Light'
    )

    $script:PcnUiCurrentTheme = $Theme
    $script:PcnThemePalette = Get-PcnUiThemePalette -Theme $Theme
    $palette = $script:PcnThemePalette

    Set-PcnControlTheme -Control $form -Palette $palette

    $tabControl.BackColor = $palette.TabBack
    $tabControl.ForeColor = $palette.Text

    if ($Theme -eq 'Dark') {
        $logBox.BackColor = $palette.LogBack
        $logBox.ForeColor = $palette.Text
        $pcNinjaPasswordTextBox.BorderStyle = 'FixedSingle'
        Set-PcnDarkButtonAccents -Palette $palette
    }

    Update-PcnDarkAccentInvalidation
    $tabControl.Invalidate()
}

Register-PcnDarkAccentStyles

function Convert-PcnUiLogLine {
    param(
        [AllowNull()]
        [string]$Line
    )

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return ''
    }

    if ($Line -match '^(\d{4})-(\d{2})-(\d{2})\s+(\d{2}:\d{2})(?::\d{2})?\s+\[(INFORMATION|WARNING|ERROR)\]\s+(.*)$') {
        $level = switch ($matches[5]) {
            'INFORMATION' { 'INFO' }
            'WARNING' { 'WARN' }
            'ERROR' { 'ERR' }
            default { $matches[5] }
        }

        return '{0}-{1} {2} [{3}] {4}' -f $matches[2], $matches[3], $matches[4], $level, $matches[6]
    }

    return $Line
}

function Scroll-PcnUiLogToBottom {
    if ([string]::IsNullOrEmpty($logBox.Text)) {
        return
    }

    try {
        $logBox.SelectionStart = $logBox.TextLength
        $logBox.SelectionLength = 0
        $logBox.ScrollToCaret()
    }
    catch {
        $null = $_
    }
}

function Refresh-PcnUiLog {
    param(
        [switch]$Force
    )

    if (-not $script:uiLogsLoaded) {
        $script:uiLogRefreshPending = $false
        if ($logBox.Text -notmatch 'Logs are not loaded') {
            $logBox.Text = "Logs are not loaded during app startup.`r`n`r`nClick Load Logs to open the live log view."
        }
        return
    }

    if (-not $Force -and $tabControl.SelectedTab -ne $logsTab) {
        $script:uiLogRefreshPending = $true
        return
    }

    $now = Get-Date
    if (-not $Force -and (($now - $script:lastUiLogRefresh).TotalSeconds -lt 5)) {
        $script:uiLogRefreshPending = $true
        return
    }

    $rawLog = Get-PcnRecentLog -Tail 500
    $lines = @($rawLog -split "`r?`n" | ForEach-Object { Convert-PcnUiLogLine -Line $_ })

    if ($lines.Count -eq 0) {
        $lines = @('No log entries yet.')
    }

    try {
        $logBox.SuspendLayout()
        $logBox.Text = ($lines -join [Environment]::NewLine)
    }
    finally {
        $logBox.ResumeLayout()
    }

    $logBox.Refresh()
    $script:lastUiLogRefresh = $now
    $script:uiLogRefreshPending = $false

    Scroll-PcnUiLogToBottom
}

function Start-PcnUiUpdateRun {
    param(
        [ValidateSet('Manual', 'Retry')]
        [string]$RunType = 'Manual',

        [switch]$AllowStopBackgroundActivity
    )

    if ($script:runningProcess -and -not $script:runningProcess.HasExited) {
        return $false
    }

    $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Mode RunUpdates -Silent -RunType {1}' -f $PSCommandPath, $RunType

    if ($AllowStopBackgroundActivity) {
        $arguments = $arguments + ' -AllowStopBackgroundActivity'
    }

    $footer.Text = if ($RunType -eq 'Retry') { 'Automatic retry started. This may take a while.' } else { 'Windows Update run started. This may take a while.' }
    $runButton.Enabled = $false
    $dashboardRunButton.Enabled = $false
    $dashboardResetWuButton.Enabled = $false
    $progress.Style = 'Marquee'
    $progress.MarqueeAnimationSpeed = 35

    $script:runningProcessKind = 'Update'
    $script:runningProcess = Start-Process -FilePath (Get-PcnPowershellPath) -ArgumentList $arguments -WindowStyle Hidden -PassThru
    $timer.Start()
    return $true
}

function Start-PcnUiWindowsUpdateReset {
    if ($script:runningProcess -and -not $script:runningProcess.HasExited) {
        return $false
    }

    $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Mode ResetWindowsUpdate -ConfirmReset -Json' -f $PSCommandPath

    $footer.Text = 'Windows Update reset started. This may take a while.'
    $runButton.Enabled = $false
    $dashboardRunButton.Enabled = $false
    $dashboardResetWuButton.Enabled = $false
    $progress.Style = 'Marquee'
    $progress.MarqueeAnimationSpeed = 35

    $script:runningProcessKind = 'ResetWindowsUpdate'
    $script:runningProcess = Start-Process -FilePath (Get-PcnPowershellPath) -ArgumentList $arguments -WindowStyle Hidden -PassThru
    $timer.Start()
    return $true
}

function Request-PcnUiRetry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Reason
    )

    $config = Get-PcnUiConfig
    Save-PcnWinUpdateConfig -Config $config

    if (-not [bool]$config.AutoRetryEnabled) {
        $footer.Text = 'Auto retry is disabled. Run skipped.'
        Refresh-PcnRetryStatus
        Refresh-PcnUiLog
        Refresh-PcnDashboard
        return $false
    }

    if ([bool]$config.InstallFirmwareUpdates) {
        $answer = Show-PcnMessageBox(
            "Firmware/BIOS updates are enabled for the automatic retry.`r`n`r`nContinue only if the machine is on reliable power and you are comfortable letting Windows Update install firmware packages when the retry starts.",
            'Firmware Updates Enabled',
            'YesNo',
            'Warning'
        )

        if ($answer -ne 'Yes') {
            $footer.Text = 'Automatic retry cancelled.'
            Refresh-PcnUiLog
            return $false
        }
    }

    $retry = Request-PcnWinUpdateRetry -ScriptPath $PSCommandPath -Config $config -Reason $Reason
    $state = Get-PcnWinUpdateState
    $state.LastRunFinished = (Get-Date).ToString('s')
    $state.LastRunType = 'Manual'
    $state.LastResult = $retry.Result
    $state.LastMessage = $retry.Message
    $state.LastRebootRequired = $false
    Save-PcnWinUpdateState -State $state

    $footer.Text = $retry.Message
    Clear-PcnUiStatusCache
    Refresh-PcnUiStatus -Force
    Refresh-PcnRetryStatus
    Refresh-PcnUiLog
    Refresh-PcnDashboard -Force
    $retryMonitorTimer.Start()
    return [bool]$retry.Scheduled
}

function Refresh-PcnUiStatus {
    param(
        [switch]$Force
    )

    $status = Get-PcnUiCachedValue -Key 'ScheduledTaskStatus' -Force:$Force -Loader {
        Get-PcnScheduledTaskStatus
    }

    if ($status.Exists) {
        $nextRun = if ($status.NextRunTime) { $status.NextRunTime.ToString('yyyy-MM-dd HH:mm') } else { 'not scheduled' }
        $lastRun = if ($status.LastRunTime) { $status.LastRunTime.ToString('yyyy-MM-dd HH:mm') } else { 'never' }
        $statusLabel.Text = "Scheduled task: Installed`r`nState: $($status.State) | Next: $nextRun | Last: $lastRun | Result: $($status.LastTaskResult)"
    }
    else {
        $statusLabel.Text = 'Scheduled task: Not installed'
    }
}

function Convert-PcnRetryReasonForUi {
    param(
        [AllowNull()]
        [string]$Reason
    )

    if ([string]::IsNullOrWhiteSpace($Reason)) {
        return 'Waiting'
    }

    if ($Reason -match 'actively installing|servicing appears') {
        return 'Windows Update is busy'
    }

    if ($Reason -match 'background|scanning|downloading') {
        return 'Background update activity'
    }

    if ($Reason -match 'network|dns|https|connect') {
        return 'Network not ready'
    }

    if ($Reason.Length -gt 34) {
        return $Reason.Substring(0, 31) + '...'
    }

    return $Reason
}

function Refresh-PcnRetryStatus {
    $state = Get-PcnWinUpdateState
    $nextRetry = Get-PcnDateOrNull -Value $state.LastRetryScheduled

    if ($nextRetry -and $nextRetry -gt (Get-Date)) {
        $reason = Convert-PcnRetryReasonForUi -Reason $state.LastRetryReason
        $retryStateLabel.Text = "Next retry: $($nextRetry.ToString('yyyy-MM-dd HH:mm'))`r`nAttempt: $($state.RetryCount)`r`nReason: $reason"
    }
    else {
        $retryStateLabel.Text = "Next retry: none`r`nLast result: $($state.LastResult)"
    }
}

function Refresh-PcnDashboard {
    param(
        [switch]$Force
    )

    if (-not $Force -and $tabControl.SelectedTab -ne $dashboardTab) {
        $script:dashboardRefreshPending = $true
        return
    }

    $now = Get-Date
    if (-not $Force -and (($now - $script:lastDashboardRefresh).TotalSeconds -lt 60)) {
        return
    }

    try {
        $state = Get-PcnWinUpdateState
        $lastFinished = Get-PcnDateOrNull -Value $state.LastRunFinished
        $lastResult = if ([string]::IsNullOrWhiteSpace([string]$state.LastResult)) { 'No result yet' } else { [string]$state.LastResult }
        $lastRunType = if ([string]::IsNullOrWhiteSpace([string]$state.LastRunType)) { 'Unknown' } else { [string]$state.LastRunType }

        if ($lastFinished) {
            $dashboardLastRun.Text = "Last run: $($lastFinished.ToString('yyyy-MM-dd HH:mm')) | Type: $lastRunType | Result: $lastResult"
        }
        else {
            $dashboardLastRun.Text = "Last run: never | Result: $lastResult"
        }

        $activity = Get-PcnUiCachedValue -Key 'WindowsUpdateActivity' -Force:$Force -Loader {
            Get-PcnWindowsUpdateActivity
        }
        $dashboardActivity.Text = "Windows Update activity: $($activity.Status) | $($activity.Message)"

        $pending = Get-PcnUiCachedValue -Key 'PendingReboot' -Force:$Force -Loader {
            Test-PcnPendingReboot
        }
        if ($pending.Pending) {
            $dashboardReboot.Text = 'Restart: required'
        }
        elseif ($pending.PSObject.Properties['Warnings'] -and @($pending.Warnings).Count -gt 0) {
            $dashboardReboot.Text = "Restart: not blocking | Warnings: $(@($pending.Warnings).Count)"
        }
        else {
            $dashboardReboot.Text = 'Restart: not required'
        }

        $scheduleStatus = Get-PcnUiCachedValue -Key 'ScheduledTaskStatus' -Force:$Force -Loader {
            Get-PcnScheduledTaskStatus
        }
        if ($scheduleStatus.Exists) {
            $nextRun = if ($scheduleStatus.NextRunTime) { $scheduleStatus.NextRunTime.ToString('yyyy-MM-dd HH:mm') } else { 'not scheduled' }
            $dashboardSchedule.Text = "Schedule: installed | State: $($scheduleStatus.State) | Next: $nextRun"
        }
        else {
            $dashboardSchedule.Text = 'Schedule: not installed'
        }

        $nextRetry = Get-PcnDateOrNull -Value $state.LastRetryScheduled
        if ($nextRetry -and $nextRetry -gt (Get-Date)) {
            $reason = Convert-PcnRetryReasonForUi -Reason $state.LastRetryReason
            $dashboardRetry.Text = "Retry: $($nextRetry.ToString('yyyy-MM-dd HH:mm')) | Attempt: $($state.RetryCount) | $reason"
        }
        else {
            $dashboardRetry.Text = "Retry: none | Last result: $lastResult"
        }

        $paths = Initialize-PcnWinUpdateFolders
        $latestAudit = Get-ChildItem -LiteralPath $paths.DriverReportRoot -Filter 'DriverAudit-*.txt' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if ($latestAudit) {
            $dashboardDriverAudit.Text = "Driver audit: $($latestAudit.LastWriteTime.ToString('yyyy-MM-dd HH:mm')) | $($latestAudit.Name)"
        }
        else {
            $dashboardDriverAudit.Text = 'Driver audit: no report yet'
        }

        $script:lastDashboardRefresh = $now
        $script:dashboardRefreshPending = $false
    }
    catch {
        $dashboardActivity.Text = "Dashboard refresh warning: $($_.Exception.Message)"
    }
}

function Refresh-PcnDashboardQuick {
    try {
        $state = Get-PcnWinUpdateState
        $lastFinished = Get-PcnDateOrNull -Value $state.LastRunFinished
        $lastResult = if ([string]::IsNullOrWhiteSpace([string]$state.LastResult)) { 'No result yet' } else { [string]$state.LastResult }
        $lastRunType = if ([string]::IsNullOrWhiteSpace([string]$state.LastRunType)) { 'Unknown' } else { [string]$state.LastRunType }

        if ($lastFinished) {
            $dashboardLastRun.Text = "Last run: $($lastFinished.ToString('yyyy-MM-dd HH:mm')) | Type: $lastRunType | Result: $lastResult"
        }
        else {
            $dashboardLastRun.Text = "Last run: never | Result: $lastResult"
        }

        $dashboardActivity.Text = 'Windows Update activity: loading...'
        $dashboardReboot.Text = 'Restart: loading...'
        $dashboardSchedule.Text = 'Schedule: loading...'

        $nextRetry = Get-PcnDateOrNull -Value $state.LastRetryScheduled
        if ($nextRetry -and $nextRetry -gt (Get-Date)) {
            $reason = Convert-PcnRetryReasonForUi -Reason $state.LastRetryReason
            $dashboardRetry.Text = "Retry: $($nextRetry.ToString('yyyy-MM-dd HH:mm')) | Attempt: $($state.RetryCount) | $reason"
        }
        else {
            $dashboardRetry.Text = "Retry: none | Last result: $lastResult"
        }

        $paths = Initialize-PcnWinUpdateFolders
        $latestAudit = Get-ChildItem -LiteralPath $paths.DriverReportRoot -Filter 'DriverAudit-*.txt' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if ($latestAudit) {
            $dashboardDriverAudit.Text = "Driver audit: $($latestAudit.LastWriteTime.ToString('yyyy-MM-dd HH:mm')) | $($latestAudit.Name)"
        }
        else {
            $dashboardDriverAudit.Text = 'Driver audit: no report yet'
        }
    }
    catch {
        $dashboardActivity.Text = "Dashboard quick load warning: $($_.Exception.Message)"
    }
}

function Refresh-PcnRebootState {
    param(
        [switch]$Force
    )

    $pending = Get-PcnUiCachedValue -Key 'PendingReboot' -Force:$Force -Loader {
        Test-PcnPendingReboot
    }

    if ($pending.Pending) {
        $rebootState.Text = 'Restart required'
        $restartButton.Enabled = $true
        return $true
    }

    if ($pending.PSObject.Properties['Warnings'] -and $pending.Warnings.Count -gt 0) {
        $rebootState.Text = 'Restart not blocking'
        $restartButton.Enabled = $false
        return $false
    }

    $rebootState.Text = 'Restart not required'
    $restartButton.Enabled = $false
    return $false
}

function Invoke-PcnRestartPrompt {
    $pending = Refresh-PcnRebootState -Force

    if (-not $pending) {
        return
    }

    $answer = Show-PcnMessageBox(
        'Windows reports that a restart is required. Restart this machine now?',
        'Restart Required',
        'YesNo',
        'Question'
    )

    if ($answer -eq 'Yes') {
        Restart-PcnComputerNow
    }
}

function Set-PcnUiScheduleFields {
    $isWeekly = ($uiFrequency.SelectedItem -eq 'Weekly')
    $isMonthly = ($uiFrequency.SelectedItem -eq 'Monthly')
    $isStartupOnly = ($uiFrequency.SelectedItem -eq 'Startup')
    $usesStartup = $isStartupOnly -or $uiRunAtStartup.Checked

    $timeLabel.Enabled = -not $isStartupOnly
    $timePicker.Enabled = -not $isStartupOnly

    $dayLabel.Enabled = $isWeekly
    $dayCombo.Enabled = $isWeekly

    $monthlyDayLabel.Enabled = $isMonthly
    $uiMonthlyDay.Enabled = $isMonthly

    $uiRunAtStartup.Enabled = -not $isStartupOnly
    $startupDelayLabel.Enabled = $usesStartup
    $startupDelay.Enabled = $usesStartup
    $startupDelayUnit.Enabled = $usesStartup

    if ($isStartupOnly) {
        $uiRunAtStartup.Checked = $true
    }
}

function Get-PcnUiConfig {
    [pscustomobject]@{
        ConfigVersion = 10
        Enabled = [bool]$uiEnableSchedule.Checked
        Frequency = [string]$uiFrequency.SelectedItem
        Time = $timePicker.Value.ToString('HH:mm')
        DayOfWeek = [string]$dayCombo.SelectedItem
        MonthlyDay = [int]$uiMonthlyDay.Value
        RunAtStartup = [bool]($uiRunAtStartup.Checked -or ($uiFrequency.SelectedItem -eq 'Startup'))
        StartupDelayMinutes = [int]$startupDelay.Value
        RunIfMissed = [bool]$uiRunIfMissed.Checked
        WakeToRun = [bool]$uiWakeToRun.Checked
        ShowRebootPrompt = [bool]$rebootPrompt.Checked
        InstallFirmwareUpdates = [bool]$firmwareUpdates.Checked
        AutoRetryEnabled = [bool]$autoRetry.Checked
        RetryInitialDelayMinutes = [int]$retryDelay.Value
        RetryMaxAttempts = [int]$retryMax.Value
        RetryBackoffMultiplier = 2
        MinimumCooldownMinutes = [int]$retryCooldown.Value
        DisplayTheme = [string]$themeCombo.SelectedItem
        LastSaved = $null
    }
}

function Load-PcnUiConfig {
    $config = Get-PcnWinUpdateConfig
    $script:pcnLoadingUiConfig = $true

    try {
        $uiEnableSchedule.Checked = [bool]$config.Enabled
        $uiFrequency.SelectedItem = [string]$config.Frequency
        $dayCombo.SelectedItem = [string]$config.DayOfWeek
        $uiMonthlyDay.Value = [Math]::Min($uiMonthlyDay.Maximum, [Math]::Max($uiMonthlyDay.Minimum, [int]$config.MonthlyDay))
        $uiRunAtStartup.Checked = [bool]$config.RunAtStartup
        $startupDelay.Value = [Math]::Min($startupDelay.Maximum, [Math]::Max($startupDelay.Minimum, [int]$config.StartupDelayMinutes))
        $uiRunIfMissed.Checked = [bool]$config.RunIfMissed
        $uiWakeToRun.Checked = [bool]$config.WakeToRun
        $rebootPrompt.Checked = [bool]$config.ShowRebootPrompt
        $firmwareUpdates.Checked = [bool]$config.InstallFirmwareUpdates
        $autoRetry.Checked = [bool]$config.AutoRetryEnabled
        $retryDelay.Value = [Math]::Min($retryDelay.Maximum, [Math]::Max($retryDelay.Minimum, [int]$config.RetryInitialDelayMinutes))
        $retryMax.Value = [Math]::Min($retryMax.Maximum, [Math]::Max($retryMax.Minimum, [int]$config.RetryMaxAttempts))
        $retryCooldown.Value = [Math]::Min($retryCooldown.Maximum, [Math]::Max($retryCooldown.Minimum, [int]$config.MinimumCooldownMinutes))

        $theme = if ($config.PSObject.Properties['DisplayTheme'] -and [string]$config.DisplayTheme -eq 'Dark') { 'Dark' } else { 'Light' }
        $themeCombo.SelectedItem = $theme
        Apply-PcnUiTheme -Theme $theme

        try {
            $timePicker.Value = [DateTime]::Today.Add([TimeSpan]::Parse($config.Time))
        }
        catch {
            $timePicker.Value = [DateTime]::Today.AddHours(3)
        }
    }
    finally {
        $script:pcnLoadingUiConfig = $false
    }

    Set-PcnUiScheduleFields
}

function Show-PcnWindowsUpdateSnoozeDialog {
    param(
        [string]$ActivityMessage = 'Windows Update or Windows servicing is active.'
    )

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'Windows Update Is Active'
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MinimizeBox = $false
    $dialog.MaximizeBox = $false
    $dialog.ShowInTaskbar = $false
    $dialog.ClientSize = New-Object System.Drawing.Size(620, 260)
    $dialog.Font = $form.Font
    $dialog.Tag = 'Cancel'

    if ($form.Icon) {
        $dialog.Icon = $form.Icon
    }

    $iconBox = New-Object System.Windows.Forms.PictureBox
    $iconBox.Image = ([System.Drawing.SystemIcons]::Warning).ToBitmap()
    $iconBox.Location = New-Object System.Drawing.Point(24, 28)
    $iconBox.Size = New-Object System.Drawing.Size(36, 36)
    $iconBox.SizeMode = 'CenterImage'
    $dialog.Controls.Add($iconBox)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = 'Windows Update is active'
    $titleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
    $titleLabel.Location = New-Object System.Drawing.Point(74, 28)
    $titleLabel.Size = New-Object System.Drawing.Size(510, 30)
    $dialog.Controls.Add($titleLabel)

    $messageLabel = New-Object System.Windows.Forms.Label
    $messageLabel.Text = "$ActivityMessage`r`n`r`nSnooz to run temporarily stops Windows Update services, runs PcNinja, then starts them again.`r`n`r`nChoosing retry leaves Windows Update alone and schedules a retry in 5 minutes."
    $messageLabel.Location = New-Object System.Drawing.Point(76, 72)
    $messageLabel.Size = New-Object System.Drawing.Size(510, 100)
    $dialog.Controls.Add($messageLabel)

    $snoozeButton = New-Object System.Windows.Forms.Button
    $snoozeButton.Text = 'Snooz to run'
    $snoozeButton.Location = New-Object System.Drawing.Point(138, 190)
    $snoozeButton.Size = New-Object System.Drawing.Size(112, 34)
    $snoozeButton.Add_Click({
        $dialog.Tag = 'Snooze'
        $dialog.Close()
    })
    $dialog.Controls.Add($snoozeButton)
    $dialog.AcceptButton = $snoozeButton

    $retryButton = New-Object System.Windows.Forms.Button
    $retryButton.Text = 'Retry in 5 min'
    $retryButton.Location = New-Object System.Drawing.Point(272, 190)
    $retryButton.Size = New-Object System.Drawing.Size(112, 34)
    $retryButton.Add_Click({
        $dialog.Tag = 'Retry'
        $dialog.Close()
    })
    $dialog.Controls.Add($retryButton)

    $cancelChoiceButton = New-Object System.Windows.Forms.Button
    $cancelChoiceButton.Text = 'Cancel'
    $cancelChoiceButton.Location = New-Object System.Drawing.Point(406, 190)
    $cancelChoiceButton.Size = New-Object System.Drawing.Size(86, 34)
    $cancelChoiceButton.Add_Click({
        $dialog.Tag = 'Cancel'
        $dialog.Close()
    })
    $dialog.Controls.Add($cancelChoiceButton)
    $dialog.CancelButton = $cancelChoiceButton

    $dialog.ShowDialog($form) | Out-Null
    return [string]$dialog.Tag
}

function Invoke-PcnUiManualUpdate {
    try {
        if ($script:runningProcess -and -not $script:runningProcess.HasExited) {
            return
        }

        $activity = Get-PcnWindowsUpdateActivity
        $uiAllowStopBackgroundActivity = $false
        $config = Get-PcnUiConfig

        if ($activity.IsInstalling -or $activity.HasBackgroundActivity) {
            $choice = Show-PcnWindowsUpdateSnoozeDialog -ActivityMessage $activity.Message

            if ($choice -eq 'Retry') {
                Request-PcnUiRetry -Reason $activity.Message | Out-Null
                return
            }

            if ($choice -eq 'Snooze') {
                $uiAllowStopBackgroundActivity = $true
                $footer.Text = 'Snoozing Windows Update activity.'
            }
            else {
                $footer.Text = 'Manual run cancelled.'
                Refresh-PcnUiLog
                Refresh-PcnDashboard
                return
            }
        }

        if ([bool]$config.InstallFirmwareUpdates) {
            $answer = Show-PcnMessageBox(
                "Firmware/BIOS updates are enabled for this run.`r`n`r`nContinue only if the machine is on reliable power and you are comfortable letting Windows Update install firmware packages.",
                'Firmware Updates Enabled',
                'YesNo',
                'Warning'
            )

            if ($answer -ne 'Yes') {
                $footer.Text = 'Manual run cancelled.'
                Refresh-PcnUiLog
                Refresh-PcnDashboard
                return
            }
        }

        Save-PcnWinUpdateConfig -Config $config
        Start-PcnUiUpdateRun -RunType Manual -AllowStopBackgroundActivity:$uiAllowStopBackgroundActivity | Out-Null
    }
    catch {
        $progress.Style = 'Blocks'
        $runButton.Enabled = $true
        $dashboardRunButton.Enabled = $true
        $dashboardResetWuButton.Enabled = $true
        Show-PcnMessageBox($_.Exception.Message, 'Run Error', 'OK', 'Error') | Out-Null
    }
}

function Invoke-PcnUiDriverAudit {
    try {
        $driverReportButton.Enabled = $false
        $dashboardDriverAuditButton.Enabled = $false
        $footer.Text = 'Creating driver audit report...'
        [System.Windows.Forms.Application]::DoEvents()

        $report = Export-PcnDriverInventoryReport
        $footer.Text = "Driver audit created. Audit candidates: $($report.AuditCandidateDevices)"
        Refresh-PcnUiLog
        Refresh-PcnDashboard

        $answer = Show-PcnMessageBox(
            "Driver audit report created.`r`n`r`nCSV:`r`n$($report.CsvPath)`r`n`r`nAudit candidates: $($report.AuditCandidateDevices)`r`nHigh priority: $($report.HighPriorityAuditCandidates)`r`nTotal driver entries: $($report.TotalDevices)`r`n`r`nOpen the report folder?",
            'Driver Audit Created',
            'YesNo',
            'Information'
        )

        if ($answer -eq 'Yes') {
            $paths = Initialize-PcnWinUpdateFolders
            Start-Process -FilePath explorer.exe -ArgumentList $paths.DriverReportRoot | Out-Null
        }
    }
    catch {
        $footer.Text = 'Could not create driver audit.'
        Show-PcnMessageBox($_.Exception.Message, 'Driver Audit Error', 'OK', 'Error') | Out-Null
    }
    finally {
        $driverReportButton.Enabled = $true
        $dashboardDriverAuditButton.Enabled = $true
    }
}

function Invoke-PcnUiWindowsUpdateReset {
    try {
        if ($script:runningProcess -and -not $script:runningProcess.HasExited) {
            return
        }

        $answer = Show-PcnMessageBox(
            "Reset Windows Update will stop Windows Update services, delete the local cache folder, recreate it, and start the services again:`r`n`r`nC:\Windows\SoftwareDistribution`r`n`r`nUse this when Windows Update appears stuck scanning or downloading. Continue?",
            'Reset Windows Update',
            'YesNo',
            'Warning'
        )

        if ($answer -ne 'Yes') {
            $footer.Text = 'Windows Update reset cancelled.'
            return
        }

        Start-PcnUiWindowsUpdateReset | Out-Null
    }
    catch {
        $footer.Text = 'Could not start Windows Update reset.'
        Show-PcnMessageBox($_.Exception.Message, 'Reset Error', 'OK', 'Error') | Out-Null
    }
}

$uiFrequency.Add_SelectedIndexChanged({
    Set-PcnUiScheduleFields
})

$uiRunAtStartup.Add_CheckedChanged({
    Set-PcnUiScheduleFields
})

$themeCombo.Add_SelectedIndexChanged({
    if ($script:pcnLoadingUiConfig) {
        return
    }

    $selectedTheme = if ([string]$themeCombo.SelectedItem -eq 'Dark') { 'Dark' } else { 'Light' }
    Apply-PcnUiTheme -Theme $selectedTheme

    try {
        $config = Get-PcnUiConfig
        Save-PcnWinUpdateConfig -Config $config
        $footer.Text = "Theme changed to $selectedTheme."
    }
    catch {
        $footer.Text = "Theme changed, but could not save it: $($_.Exception.Message)"
    }
})

$saveSchedule.Add_Click({
    try {
        $config = Get-PcnUiConfig

        if ($config.Enabled -and [bool]$config.InstallFirmwareUpdates) {
            $answer = Show-PcnMessageBox(
                "Firmware/BIOS updates are enabled.`r`n`r`nScheduled runs may install firmware without another prompt. Continue saving this schedule?",
                'Firmware Updates Enabled',
                'YesNo',
                'Warning'
            )

            if ($answer -ne 'Yes') {
                $footer.Text = 'Schedule save cancelled.'
                return
            }
        }

        Save-PcnWinUpdateConfig -Config $config

        if (-not $config.AutoRetryEnabled) {
            Unregister-PcnWinUpdateRetryTask
            $state = Get-PcnWinUpdateState
            $state.LastRetryScheduled = $null
            $state.LastRetryReason = $null
            $state.RetryCount = 0
            Save-PcnWinUpdateState -State $state
        }

        if ($config.Enabled) {
            Register-PcnWinUpdateScheduledTask -Config $config -ScriptPath $PSCommandPath
            $footer.Text = 'Schedule saved.'
        }
        else {
            Unregister-PcnWinUpdateScheduledTask
            $footer.Text = 'Schedule disabled.'
        }

        Clear-PcnUiStatusCache
        Refresh-PcnUiStatus -Force
        Refresh-PcnRetryStatus
        Refresh-PcnUiLog
        Refresh-PcnDashboard -Force
    }
    catch {
        $footer.Text = 'Could not save schedule.'
        Show-PcnMessageBox($_.Exception.Message, 'Schedule Error', 'OK', 'Error') | Out-Null
    }
})

$removeSchedule.Add_Click({
    try {
        Unregister-PcnWinUpdateScheduledTask
        Unregister-PcnWinUpdateRetryTask
        $config = Get-PcnUiConfig
        $config.Enabled = $false
        Save-PcnWinUpdateConfig -Config $config
        $state = Get-PcnWinUpdateState
        $state.LastRetryScheduled = $null
        $state.LastRetryReason = $null
        $state.RetryCount = 0
        Save-PcnWinUpdateState -State $state
        $uiEnableSchedule.Checked = $false
        $footer.Text = 'Schedule removed.'
        Clear-PcnUiStatusCache
        Refresh-PcnUiStatus -Force
        Refresh-PcnRetryStatus
        Refresh-PcnUiLog
        Refresh-PcnDashboard -Force
    }
    catch {
        Show-PcnMessageBox($_.Exception.Message, 'Remove Schedule Error', 'OK', 'Error') | Out-Null
    }
})

$runButton.Add_Click({
    Invoke-PcnUiManualUpdate
})

$timer.Add_Tick({
    Refresh-PcnUiLog

    if ($script:runningProcess -and $script:runningProcess.HasExited) {
        $exitCode = $script:runningProcess.ExitCode
        $processKind = [string]$script:runningProcessKind
        $timer.Stop()
        $progress.Style = 'Blocks'
        $progress.Value = 0
        $runButton.Enabled = $true
        $dashboardRunButton.Enabled = $true
        $dashboardResetWuButton.Enabled = $true
        if ($processKind -eq 'ResetWindowsUpdate') {
            $footer.Text = "Windows Update reset finished. Exit code: $exitCode"
        }
        else {
            $footer.Text = "Windows Update run finished. Exit code: $exitCode"
        }
        $script:runningProcessKind = $null
        Clear-PcnUiStatusCache
        Refresh-PcnUiStatus -Force
        Refresh-PcnRetryStatus
        Refresh-PcnUiLog
        Refresh-PcnRebootState -Force | Out-Null
        Refresh-PcnDashboard -Force

        if ($processKind -ne 'ResetWindowsUpdate' -and $rebootPrompt.Checked) {
            Invoke-PcnRestartPrompt
        }
    }
})

$retryMonitorTimer.Add_Tick({
    try {
        if ($tabControl.SelectedTab -eq $scheduleTab) {
            Refresh-PcnUiStatus
            Refresh-PcnRetryStatus
        }
        elseif ($tabControl.SelectedTab -eq $dashboardTab) {
            Refresh-PcnRetryStatus
            Refresh-PcnDashboard
        }

        if ($script:runningProcess -and -not $script:runningProcess.HasExited) {
            return
        }

        $state = Get-PcnWinUpdateState
        $nextRetry = Get-PcnDateOrNull -Value $state.LastRetryScheduled

        if (-not $nextRetry) {
            return
        }

        if ($nextRetry -gt (Get-Date)) {
            return
        }

        if ($state.LastResult -ne 'RetryScheduled') {
            return
        }

        if ($script:lastUiRetryLaunch -and (((Get-Date) - $script:lastUiRetryLaunch).TotalMinutes -lt 2)) {
            return
        }

        $script:lastUiRetryLaunch = Get-Date
        Start-PcnUiUpdateRun -RunType Retry | Out-Null
    }
    catch {
        $footer.Text = "Retry monitor warning: $($_.Exception.Message)"
    }
})

$deferredUiRefreshTimer.Add_Tick({
    $deferredUiRefreshTimer.Stop()
    $target = $script:pendingTabRefresh
    $script:pendingTabRefresh = $null

    if ($target -eq 'Logs') {
        if ($script:uiLogsLoaded) {
            Refresh-PcnUiLog -Force
        }
        return
    }

    if ($target -eq 'Dashboard') {
        if ($script:dashboardRefreshPending -or (((Get-Date) - $script:lastDashboardRefresh).TotalSeconds -ge 60)) {
            Refresh-PcnDashboard
        }
    }
})

$startupRefreshTimer.Add_Tick({
    $startupRefreshTimer.Stop()

    try {
        switch ($script:startupRefreshStep) {
            0 {
                $footer.Text = 'Loading settings...'
                Load-PcnUiConfig
                Refresh-PcnDashboardQuick
            }
            1 {
                $footer.Text = 'Loading schedule...'
                Refresh-PcnUiStatus -Force
                Refresh-PcnRetryStatus
            }
            2 {
                $footer.Text = 'Checking restart state...'
                Refresh-PcnRebootState -Force | Out-Null
            }
            3 {
                $footer.Text = 'Loading dashboard...'
                Refresh-PcnDashboard
            }
            default {
                if (-not ($script:runningProcess -and -not $script:runningProcess.HasExited)) {
                    $progress.Style = 'Blocks'
                    $progress.Value = 0
                    $footer.Text = 'Ready.'
                }

                $retryMonitorTimer.Start()
                return
            }
        }

        $script:startupRefreshStep++
        $startupRefreshTimer.Start()
    }
    catch {
        $progress.Style = 'Blocks'
        $progress.Value = 0
        $footer.Text = "Startup refresh warning: $($_.Exception.Message)"
        $retryMonitorTimer.Start()
    }
})

$restartButton.Add_Click({
    Invoke-PcnRestartPrompt
})

$driverReportButton.Add_Click({
    Invoke-PcnUiDriverAudit
})

$openDriverReports.Add_Click({
    $paths = Initialize-PcnWinUpdateFolders
    Start-Process -FilePath explorer.exe -ArgumentList $paths.DriverReportRoot | Out-Null
})

$refreshLog.Add_Click({
    $script:uiLogsLoaded = $true
    Refresh-PcnUiLog -Force
})

$loadLogsButton.Add_Click({
    $script:uiLogsLoaded = $true
    $footer.Text = 'Loading logs...'
    Refresh-PcnUiLog -Force
    $footer.Text = 'Ready.'
})

$logBottomButton.Add_Click({
    Scroll-PcnUiLogToBottom
})

$dashboardRunButton.Add_Click({
    Invoke-PcnUiManualUpdate
})

$dashboardDriverAuditButton.Add_Click({
    Invoke-PcnUiDriverAudit
})

$dashboardOpenLogsButton.Add_Click({
    $tabControl.SelectedTab = $logsTab
    Refresh-PcnUiLog -Force
})

$dashboardRefreshButton.Add_Click({
    Clear-PcnUiStatusCache
    $footer.Text = 'Refreshing status...'
    Refresh-PcnUiStatus -Force
    Refresh-PcnRetryStatus
    Refresh-PcnRebootState -Force | Out-Null
    Refresh-PcnDashboard -Force
    $footer.Text = 'Ready.'
})

$dashboardResetWuButton.Add_Click({
    Invoke-PcnUiWindowsUpdateReset
})

$featureUpdateButton.Add_Click({
    Invoke-PcnUiOpenUrl -Url (Get-PcnWindowsImageDownloadUrl)
})

$pcNinjaClassesButton.Add_Click({
    Invoke-PcnUiOpenUrl -Url 'https://class.pcninja.pro'
})

$openLog.Add_Click({
    $paths = Initialize-PcnWinUpdateFolders
    if (-not (Test-Path -LiteralPath $paths.LogFile)) {
        Set-Content -LiteralPath $paths.LogFile -Value 'No log entries yet.' -Encoding UTF8
    }

    Start-Process -FilePath notepad.exe -ArgumentList $paths.LogFile | Out-Null
})

$openFolder.Add_Click({
    $paths = Initialize-PcnWinUpdateFolders
    Start-Process -FilePath explorer.exe -ArgumentList $paths.LogRoot | Out-Null
})

$closeButton.Add_Click({
    $form.Close()
})

$form.Add_FormClosed({
    $timer.Stop()
    $retryMonitorTimer.Stop()
    $deferredUiRefreshTimer.Stop()
    $startupRefreshTimer.Stop()
})

$form.Add_Shown({
    $footer.Text = 'Loading interface...'
    $progress.Style = 'Marquee'
    $progress.MarqueeAnimationSpeed = 20
    Refresh-PcnDashboardQuick
    $script:startupRefreshStep = 0
    $form.BeginInvoke([System.Action]{
        $startupRefreshTimer.Start()
    }) | Out-Null
})

[void][System.Windows.Forms.Application]::Run($form)
}
catch {
    $message = "GUI startup failed: $($_.Exception.Message)"

    try {
        $paths = Initialize-PcnWinUpdateFolders
        $diagnosticPath = Join-Path $paths.LogRoot 'GuiStartup.log'
        $details = @(
            ('{0} [ERROR] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $message),
            "Script: $PSCommandPath",
            "Mode: $Mode",
            "User: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)",
            "Stack:",
            ($_.ScriptStackTrace)
        )
        Add-Content -LiteralPath $diagnosticPath -Value $details -Encoding UTF8
        Write-PcnWinUpdateLog -Message $message -EntryType Error -EventID 1090
    }
    catch {
        $null = $_
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms
        Show-PcnMessageBox(
            "$message`r`n`r`nA diagnostic log was written to:`r`nC:\ProgramData\PcNinja\WinUpdateTool\Logs\GuiStartup.log",
            'PcNinja WinUpdate Tool',
            'OK',
            'Error'
        ) | Out-Null
    }
    catch {
        [Console]::Error.WriteLine($message)
    }

    exit 1
}









