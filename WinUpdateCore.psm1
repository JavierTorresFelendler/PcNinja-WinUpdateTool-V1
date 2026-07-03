Set-StrictMode -Version 2.0

$script:PcnEventSource = 'PcNinja WinUpdate Tool'
$script:PcnEventLog = 'Application'
$script:PcnTaskName = 'PcNinja WinUpdate Tool'
$script:PcnRetryTaskName = 'PcNinja WinUpdate Tool Retry'
$script:PcnRunOnceTaskName = 'PcNinja WinUpdate Tool Run Once'
$script:PcnTaskPath = '\PcNinja\'
$script:PcnConsoleLogEnabled = $true

function Test-PcnAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Set-PcnConsoleLogEnabled {
    param(
        [bool]$Enabled
    )

    $script:PcnConsoleLogEnabled = $Enabled
}

function Get-PcnWinUpdatePaths {
    $dataRoot = Join-Path $env:ProgramData 'PcNinja\WinUpdateTool'
    $logRoot = Join-Path $dataRoot 'Logs'

    [pscustomobject]@{
        DataRoot = $dataRoot
        LogRoot = $logRoot
        DriverReportRoot = Join-Path $dataRoot 'DriverReports'
        ConfigFile = Join-Path $dataRoot 'config.json'
        StateFile = Join-Path $dataRoot 'state.json'
        LockFile = Join-Path $dataRoot 'run.lock'
        LogFile = Join-Path $logRoot 'WinUpdateTool.log'
    }
}

function Initialize-PcnWinUpdateFolders {
    $paths = Get-PcnWinUpdatePaths

    foreach ($path in @($paths.DataRoot, $paths.LogRoot, $paths.DriverReportRoot)) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }

    return $paths
}

function Get-PcnPowershellPath {
    return Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
}

function Convert-PcnUpdateResultCode {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ResultCode
    )

    switch ($ResultCode) {
        0 { 'NotStarted' }
        1 { 'InProgress' }
        2 { 'Succeeded' }
        3 { 'SucceededWithErrors' }
        4 { 'Failed' }
        5 { 'Aborted' }
        default { "Unknown($ResultCode)" }
    }
}

function Convert-PcnExceptionMessage {
    param(
        [Parameter(Mandatory = $true)]
        [System.Exception]$Exception
    )

    $hresult = $Exception.HResult
    $hex = $null

    if ($hresult -ne 0) {
        $unsigned = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$hresult), 0)
        $hex = '0x{0:X8}' -f $unsigned
    }

    $friendly = switch ($hex) {
        '0x8024402C' { 'Network, DNS, proxy, or firewall problem while contacting Windows Update.' }
        '0x8024401C' { 'Windows Update service request timed out.' }
        '0x80244022' { 'Windows Update service is temporarily unavailable or overloaded.' }
        '0x8024001E' { 'Windows Update service stopped while the operation was running.' }
        '0x8024000E' { 'Windows Update data store error.' }
        '0x80072EE2' { 'Network timeout while contacting an update service.' }
        '0x80072EFD' { 'Could not connect to the update service.' }
        '0x80072EFE' { 'The connection to the update service was interrupted.' }
        default { $null }
    }

    if ($friendly) {
        return '{0} ({1}) - {2}' -f $Exception.Message, $hex, $friendly
    }

    if ($hex) {
        return '{0} ({1})' -f $Exception.Message, $hex
    }

    return $Exception.Message
}

function Convert-PcnUpdateKbList {
    param(
        [Parameter(Mandatory = $true)]
        $Update
    )

    $kbList = @()

    try {
        foreach ($kb in $Update.KBArticleIDs) {
            if ($kb) {
                $kbList += "KB$kb"
            }
        }
    }
    catch {
        $null = $_
    }

    if ($kbList.Count -eq 0) {
        return 'No KB listed'
    }

    return ($kbList | Select-Object -Unique) -join ', '
}

function Convert-PcnUpdateCategoryList {
    param(
        [Parameter(Mandatory = $true)]
        $Update
    )

    $categories = @()

    try {
        foreach ($category in $Update.Categories) {
            if ($category.Name) {
                $categories += $category.Name
            }
        }
    }
    catch {
        $null = $_
    }

    if ($categories.Count -eq 0) {
        return 'No category listed'
    }

    return ($categories | Select-Object -Unique) -join ', '
}

function Get-PcnUpdateTypeName {
    param(
        [Parameter(Mandatory = $true)]
        $Update
    )

    try {
        switch ([int]$Update.Type) {
            1 { return 'Software' }
            2 { return 'Driver' }
            default { return "Unknown($($Update.Type))" }
        }
    }
    catch {
        return 'Unknown'
    }
}

function Convert-PcnUpdateFlagList {
    param(
        [Parameter(Mandatory = $true)]
        $Update
    )

    $flags = @()

    try {
        $flags += "BrowseOnly=$([bool]$Update.BrowseOnly)"
    }
    catch {
        $null = $_
    }

    try {
        $flags += "AutoSelectOnWebSites=$([bool]$Update.AutoSelectOnWebSites)"
    }
    catch {
        $null = $_
    }

    try {
        $flags += "IsMandatory=$([bool]$Update.IsMandatory)"
    }
    catch {
        $null = $_
    }

    if ($flags.Count -eq 0) {
        return 'No update flags listed'
    }

    return ($flags | Select-Object -Unique) -join ', '
}

function Get-PcnUpdateIdentityKey {
    param(
        [Parameter(Mandatory = $true)]
        $Update
    )

    try {
        $identity = $Update.Identity
        if ($identity -and $identity.UpdateID) {
            return '{0}|{1}' -f $identity.UpdateID, $identity.RevisionNumber
        }
    }
    catch {
        $null = $_
    }

    $title = ''
    try {
        $title = [string]$Update.Title
    }
    catch {
        $null = $_
    }

    return 'fallback|{0}|{1}' -f (Get-PcnUpdateTypeName -Update $Update), $title
}

function Test-PcnFirmwareUpdate {
    param(
        [Parameter(Mandatory = $true)]
        $Update
    )

    $terms = @()

    try {
        if ($Update.Title) {
            $terms += [string]$Update.Title
        }
    }
    catch {
        $null = $_
    }

    try {
        foreach ($category in $Update.Categories) {
            if ($category.Name) {
                $terms += [string]$category.Name
            }
        }
    }
    catch {
        $null = $_
    }

    if ($terms.Count -eq 0) {
        return $false
    }

    $text = $terms -join ' '
    return ($text -match '\bfirmware\b|\bbios\b|\buefi\b|system firmware')
}

function Add-PcnMergedUpdate {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Map,

        [Parameter(Mandatory = $true)]
        [System.Collections.IList]$Order,

        [Parameter(Mandatory = $true)]
        $Update,

        [Parameter(Mandatory = $true)]
        [string]$Source
    )

    $key = Get-PcnUpdateIdentityKey -Update $Update

    if (-not $Map.ContainsKey($key)) {
        $sources = New-Object System.Collections.Generic.List[string]
        $sources.Add($Source) | Out-Null

        $Map[$key] = [pscustomobject]@{
            Key = $key
            Update = $Update
            Sources = $sources
        }

        $Order.Add($key) | Out-Null
        return
    }

    $entry = $Map[$key]
    if (-not ($entry.Sources -contains $Source)) {
        $entry.Sources.Add($Source) | Out-Null
    }
}

function Get-PcnMergedUpdateList {
    param(
        [Parameter(Mandatory = $true)]
        [array]$SearchBuckets
    )

    $map = @{}
    $order = New-Object System.Collections.ArrayList

    foreach ($bucket in $SearchBuckets) {
        if ($null -eq $bucket.Result) {
            continue
        }

        for ($index = 0; $index -lt $bucket.Result.Updates.Count; $index++) {
            Add-PcnMergedUpdate -Map $map -Order $order -Update $bucket.Result.Updates.Item($index) -Source $bucket.Source
        }
    }

    $list = New-Object System.Collections.Generic.List[object]
    foreach ($key in $order) {
        $list.Add($map[$key]) | Out-Null
    }

    return ,$list
}

function Write-PcnUpdateDiscoveryLog {
    param(
        [Parameter(Mandatory = $true)]
        $SearchResult,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    Write-PcnWinUpdateLog -Message "$Label discovered $($SearchResult.Updates.Count) missing, non-hidden update(s)." -EventID 1080

    for ($index = 0; $index -lt $SearchResult.Updates.Count; $index++) {
        $update = $SearchResult.Updates.Item($index)
        $kbList = Convert-PcnUpdateKbList -Update $update
        $typeName = Get-PcnUpdateTypeName -Update $update
        $categories = Convert-PcnUpdateCategoryList -Update $update
        $flags = Convert-PcnUpdateFlagList -Update $update
        $firmwareCandidate = if (Test-PcnFirmwareUpdate -Update $update) { 'Yes' } else { 'No' }
        Write-PcnWinUpdateLog -Message "$Label item $($index + 1): $($update.Title) | $kbList | Type: $typeName | Categories: $categories | Flags: $flags | FirmwareCandidate: $firmwareCandidate" -EventID 1081
    }
}

function Invoke-PcnUpdateSearchBucket {
    param(
        [Parameter(Mandatory = $true)]
        $Searcher,

        [Parameter(Mandatory = $true)]
        [string]$Criteria,

        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    try {
        $result = $Searcher.Search($Criteria)
        Write-PcnUpdateDiscoveryLog -SearchResult $result -Label $Label

        return [pscustomobject]@{
            Source = $Source
            Criteria = $Criteria
            Result = $result
            Error = $null
        }
    }
    catch {
        $friendlyMessage = Convert-PcnExceptionMessage -Exception $_.Exception
        Write-PcnWinUpdateLog -Message "$Label failed. Criteria: $Criteria. $friendlyMessage" -EntryType Warning -EventID 1086

        return [pscustomobject]@{
            Source = $Source
            Criteria = $Criteria
            Result = $null
            Error = $friendlyMessage
        }
    }
}

function Enable-PcnMicrosoftUpdate {
    if (-not (Test-PcnAdministrator)) {
        throw 'Administrator privileges are required to enable Microsoft Update.'
    }

    $microsoftUpdateServiceId = '7971f918-a847-4430-9279-4a52d1efe18d'

    try {
        $serviceManager = New-Object -ComObject Microsoft.Update.ServiceManager
        $serviceManager.ClientApplicationID = 'PcNinja WinUpdate Tool'
        $registered = $false

        foreach ($service in $serviceManager.Services) {
            if ([string]$service.ServiceID -eq $microsoftUpdateServiceId) {
                $registered = $true
                break
            }
        }

        if ($registered) {
            Write-PcnWinUpdateLog -Message 'Microsoft Update service is already registered.' -EventID 1082
            return $true
        }

        Write-PcnWinUpdateLog -Message 'Registering Microsoft Update service for broader update coverage.' -EventID 1083
        $serviceManager.AddService2($microsoftUpdateServiceId, 7, '') | Out-Null
        Write-PcnWinUpdateLog -Message 'Microsoft Update service registration completed.' -EventID 1084
        return $true
    }
    catch {
        $friendlyMessage = Convert-PcnExceptionMessage -Exception $_.Exception
        Write-PcnWinUpdateLog -Message "Microsoft Update registration skipped or failed: $friendlyMessage" -EntryType Warning -EventID 1085
        return $false
    }
}

function Test-PcnNetworkReadiness {
    $dnsResult = 'Not checked'
    $httpsResult = 'Not checked'
    $ready = $true

    try {
        [System.Net.Dns]::GetHostAddresses('download.windowsupdate.com') | Out-Null
        $dnsResult = 'OK'
    }
    catch {
        $ready = $false
        $dnsResult = $_.Exception.Message
    }

    try {
        $request = [System.Net.WebRequest]::Create('https://www.microsoft.com/')
        $request.Method = 'HEAD'
        $request.Timeout = 5000
        $request.UserAgent = 'PcNinja WinUpdate Tool'
        $response = $request.GetResponse()
        $httpsResult = 'OK'
        $response.Close()
    }
    catch {
        $ready = $false
        $httpsResult = $_.Exception.Message
    }

    [pscustomobject]@{
        Ready = $ready
        Dns = $dnsResult
        Https = $httpsResult
        Message = "DNS: $dnsResult | HTTPS: $httpsResult"
    }
}

function Initialize-PcnWindowsUpdateServices {
    $serviceNames = @('wuauserv', 'bits', 'UsoSvc', 'dosvc', 'cryptsvc')

    foreach ($serviceName in $serviceNames) {
        try {
            $service = Get-Service -Name $serviceName -ErrorAction Stop

            if ($service.Status -ne 'Running') {
                Write-PcnWinUpdateLog -Message "Starting service: $serviceName" -EventID 1060
                Start-Service -Name $serviceName -ErrorAction Stop
            }
        }
        catch {
            Write-PcnWinUpdateLog -Message "Service check skipped for $serviceName`: $($_.Exception.Message)" -EntryType Warning -EventID 1061
        }
    }
}

function Get-PcnWindowsUpdateActivity {
    $installProcessNames = @('TrustedInstaller', 'TiWorker', 'WindowsUpdateBox', 'SetupHost')
    $backgroundProcessNames = @('MoUsoCoreWorker', 'UsoClient', 'wuauclt', 'MusNotification', 'MusNotificationUx')
    $serviceNames = @('TrustedInstaller', 'wuauserv', 'bits', 'UsoSvc', 'dosvc')

    $installProcesses = @()
    $backgroundProcesses = @()
    $services = @()
    $bitsJobs = @()

    foreach ($name in $installProcessNames) {
        $installProcesses += @(Get-Process -Name $name -ErrorAction SilentlyContinue)
    }

    foreach ($name in $backgroundProcessNames) {
        $backgroundProcesses += @(Get-Process -Name $name -ErrorAction SilentlyContinue)
    }

    foreach ($serviceName in $serviceNames) {
        try {
            $service = Get-Service -Name $serviceName -ErrorAction Stop
            $services += [pscustomobject]@{
                Name = $serviceName
                Status = [string]$service.Status
            }
        }
        catch {
            $services += [pscustomobject]@{
                Name = $serviceName
                Status = 'Not found'
            }
        }
    }

    try {
        if (Get-Command Get-BitsTransfer -ErrorAction SilentlyContinue) {
            $bitsJobs = @(Get-BitsTransfer -AllUsers -ErrorAction Stop | Where-Object {
                $_.JobState -in @('Connecting', 'Transferring', 'TransientError') -and
                ($_.DisplayName -match 'Windows|Update|Microsoft')
            })
        }
    }
    catch {
        $bitsJobs = @()
    }

    $trustedInstallerService = $services | Where-Object { $_.Name -eq 'TrustedInstaller' } | Select-Object -First 1
    $isInstalling = ($installProcesses.Count -gt 0) -or ($trustedInstallerService -and $trustedInstallerService.Status -eq 'Running')
    $hasBackgroundActivity = ($backgroundProcesses.Count -gt 0) -or ($bitsJobs.Count -gt 0)

    if ($isInstalling) {
        $status = 'Installing'
        $message = 'Windows Update or Windows servicing appears to be actively installing. The tool will not interrupt it.'
    }
    elseif ($hasBackgroundActivity) {
        $status = 'BackgroundActivity'
        $message = 'Windows Update appears to be scanning or downloading in the background.'
    }
    else {
        $status = 'Idle'
        $message = 'No active Windows Update operation was detected.'
    }

    [pscustomobject]@{
        Status = $status
        IsInstalling = $isInstalling
        HasBackgroundActivity = $hasBackgroundActivity
        InstallProcesses = @($installProcesses | Select-Object -ExpandProperty ProcessName -Unique)
        BackgroundProcesses = @($backgroundProcesses | Select-Object -ExpandProperty ProcessName -Unique)
        BitsJobs = @($bitsJobs | Select-Object -ExpandProperty DisplayName -Unique)
        Services = @($services)
        Message = $message
    }
}

function Stop-PcnWindowsUpdateBackgroundActivity {
    if (-not (Test-PcnAdministrator)) {
        throw 'Administrator privileges are required to stop background Windows Update activity.'
    }

    $serviceNames = @('UsoSvc', 'wuauserv', 'bits', 'dosvc', 'cryptsvc')

    foreach ($serviceName in $serviceNames) {
        try {
            $service = Get-Service -Name $serviceName -ErrorAction Stop

            if ($service.Status -ne 'Stopped') {
                Write-PcnWinUpdateLog -Message "Stopping background update service: $serviceName" -EntryType Warning -EventID 1062
                Stop-Service -Name $serviceName -Force -ErrorAction Stop
            }
        }
        catch {
            Write-PcnWinUpdateLog -Message "Could not stop $serviceName`: $($_.Exception.Message)" -EntryType Warning -EventID 1063
        }
    }

    Start-Sleep -Seconds 3
}

function Get-PcnWindowsUpdateResetServiceStatus {
    $serviceNames = @('wuauserv', 'bits', 'UsoSvc', 'dosvc', 'cryptsvc')
    $statuses = New-Object System.Collections.Generic.List[object]

    foreach ($serviceName in $serviceNames) {
        try {
            $service = Get-Service -Name $serviceName -ErrorAction Stop
            $statuses.Add([pscustomobject]@{
                Name = $serviceName
                Status = [string]$service.Status
                Running = ($service.Status -eq 'Running')
            }) | Out-Null
        }
        catch {
            $statuses.Add([pscustomobject]@{
                Name = $serviceName
                Status = 'Not found'
                Running = $false
                Error = $_.Exception.Message
            }) | Out-Null
        }
    }

    $statuses.ToArray()
}

function Reset-PcnWindowsUpdateSoftwareDistribution {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    $targetFullPath = [System.IO.Path]::GetFullPath($TargetPath).TrimEnd('\')
    $expectedFullPath = [System.IO.Path]::GetFullPath((Join-Path $env:SystemRoot 'SoftwareDistribution')).TrimEnd('\')

    if (-not $targetFullPath.Equals($expectedFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to reset Windows Update cache. Unexpected target path: $targetFullPath"
    }

    $existedBefore = Test-Path -LiteralPath $targetFullPath -PathType Container
    $deleted = $false
    $deleteError = $null

    if (-not (Test-Path -LiteralPath $targetFullPath -PathType Container)) {
        New-Item -ItemType Directory -Path $targetFullPath -Force | Out-Null

        return [pscustomobject]@{
            Name = 'SoftwareDistribution'
            Path = $targetFullPath
            ExistedBefore = $false
            Deleted = $false
            Recreated = (Test-Path -LiteralPath $targetFullPath -PathType Container)
            RemainingItems = 0
            Message = 'Folder was missing and was recreated.'
        }
    }

    try {
        Remove-Item -LiteralPath $targetFullPath -Recurse -Force -ErrorAction Stop
        $deleted = $true
    }
    catch {
        $deleteError = $_.Exception.Message
    }

    New-Item -ItemType Directory -Path $targetFullPath -Force | Out-Null

    $remainingItems = 0
    try {
        $remainingItems = @((Get-ChildItem -LiteralPath $targetFullPath -Force -ErrorAction Stop)).Count
    }
    catch {
        $remainingItems = -1
    }

    [pscustomobject]@{
        Name = 'SoftwareDistribution'
        Path = $targetFullPath
        ExistedBefore = $existedBefore
        Deleted = $deleted
        DeleteError = $deleteError
        Recreated = (Test-Path -LiteralPath $targetFullPath -PathType Container)
        RemainingItems = $remainingItems
        Message = if ($deleted) { 'SoftwareDistribution was deleted and recreated.' } else { "SoftwareDistribution was recreated, but delete reported: $deleteError" }
    }
}

function Invoke-PcnWindowsUpdateReset {
    param(
        [switch]$Force
    )

    if (-not (Test-PcnAdministrator)) {
        throw 'Administrator privileges are required to reset Windows Update.'
    }

    $lock = New-PcnRunLock -RunType 'ResetWindowsUpdate'
    if (-not $lock.Acquired) {
        return [pscustomobject]@{
            Result = 'AlreadyRunning'
            Message = 'Another PcNinja WinUpdate Tool operation is already running.'
            ResetTargets = @()
            Timestamp = (Get-Date).ToString('s')
        }
    }

    $servicesStopped = $false

    try {
        $activity = Get-PcnWindowsUpdateActivity
        Write-PcnWinUpdateLog -Message "Windows Update reset requested. Activity: $($activity.Status). $($activity.Message)" -EntryType Warning -EventID 1080

        Write-PcnWinUpdateLog -Message 'Reset uses Snooz behavior: stopping Windows Update services before rebuilding SoftwareDistribution.' -EntryType Warning -EventID 1081
        Stop-PcnWindowsUpdateBackgroundActivity
        $servicesStopped = $true

        $cacheRoot = Join-Path $env:SystemRoot 'SoftwareDistribution'
        Write-PcnWinUpdateLog -Message "Deleting and recreating Windows Update cache folder: $cacheRoot" -EntryType Warning -EventID 1082
        $cacheResult = $null
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            if ($attempt -gt 1) {
                Write-PcnWinUpdateLog -Message "Retrying SoftwareDistribution reset, attempt $attempt of 3." -EntryType Warning -EventID 1086
                Stop-PcnWindowsUpdateBackgroundActivity
                Start-Sleep -Seconds 2
            }

            $cacheResult = Reset-PcnWindowsUpdateSoftwareDistribution -TargetPath $cacheRoot

            if ($cacheResult.Deleted -or -not $cacheResult.ExistedBefore -or -not $cacheResult.DeleteError) {
                break
            }

            Start-Sleep -Seconds 2
        }

        Initialize-PcnWindowsUpdateServices
        $servicesStopped = $false
        $serviceStatuses = Get-PcnWindowsUpdateResetServiceStatus
        $servicesRunning = -not [bool](@($serviceStatuses | Where-Object { -not $_.Running }) | Select-Object -First 1)
        $cacheResetComplete = (($cacheResult.Deleted -or -not $cacheResult.ExistedBefore) -and $cacheResult.Recreated)

        if (-not $cacheResetComplete -or -not $servicesRunning) {
            $message = "Windows Update reset completed with warnings. Folder recreated: $($cacheResult.Recreated). Services running: $servicesRunning."
            Write-PcnWinUpdateLog -Message $message -EntryType Warning -EventID 1083

            return [pscustomobject]@{
                Result = 'SucceededWithWarnings'
                Message = $message
                Activity = $activity
                Cache = $cacheResult
                Services = @($serviceStatuses)
                Timestamp = (Get-Date).ToString('s')
            }
        }

        $message = "Windows Update reset completed. SoftwareDistribution was recreated and update services are running."
        Write-PcnWinUpdateLog -Message $message -EntryType Warning -EventID 1084

        [pscustomobject]@{
            Result = 'Succeeded'
            Message = $message
            Activity = $activity
            Cache = $cacheResult
            Services = @($serviceStatuses)
            Timestamp = (Get-Date).ToString('s')
        }
    }
    catch {
        $message = "Windows Update reset failed: $($_.Exception.Message)"
        Write-PcnWinUpdateLog -Message $message -EntryType Error -EventID 1085
        throw
    }
    finally {
        if ($servicesStopped) {
            Initialize-PcnWindowsUpdateServices
        }

        Remove-PcnRunLock
    }
}

function Invoke-PcnWindowsUpdatePreflight {
    param(
        [switch]$AllowStopBackgroundActivity
    )

    $activity = Get-PcnWindowsUpdateActivity

    Write-PcnWinUpdateLog -Message "Windows Update activity check: $($activity.Status). $($activity.Message)" -EventID 1064

    if ($activity.InstallProcesses.Count -gt 0) {
        Write-PcnWinUpdateLog -Message "Install-related process(es): $($activity.InstallProcesses -join ', ')" -EventID 1065
    }

    if ($activity.BackgroundProcesses.Count -gt 0) {
        Write-PcnWinUpdateLog -Message "Background update process(es): $($activity.BackgroundProcesses -join ', ')" -EventID 1066
    }

    if ($activity.BitsJobs.Count -gt 0) {
        Write-PcnWinUpdateLog -Message "Background BITS job(s): $($activity.BitsJobs -join ', ')" -EventID 1066
    }

    if ($activity.IsInstalling -or $activity.HasBackgroundActivity) {
        if ($AllowStopBackgroundActivity) {
            Write-PcnWinUpdateLog -Message 'Snooz to run selected. Temporarily stopping Windows Update services before starting PcNinja update run.' -EntryType Warning -EventID 1067
            Stop-PcnWindowsUpdateBackgroundActivity
            Initialize-PcnWindowsUpdateServices

            return [pscustomobject]@{
                CanContinue = $true
                Result = 'WindowsUpdateSnoozed'
                Message = 'Windows Update activity was snoozed and services were restarted.'
            }
        }

        if ($activity.IsInstalling) {
            return [pscustomobject]@{
                CanContinue = $false
                Result = 'SkippedInstalling'
                Message = $activity.Message
            }
        }

        return [pscustomobject]@{
            CanContinue = $false
            Result = 'SkippedBackgroundActivity'
            Message = $activity.Message
        }
    }

    [pscustomobject]@{
        CanContinue = $true
        Result = 'Idle'
        Message = $activity.Message
    }
}

function Write-PcnWinUpdateLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('Information', 'Warning', 'Error')]
        [string]$EntryType = 'Information',

        [int]$EventID = 1000
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $EntryType.ToUpperInvariant(), $Message
    $paths = $null
    $logWritten = $false

    try {
        $paths = Initialize-PcnWinUpdateFolders
        Add-Content -LiteralPath $paths.LogFile -Value $line -Encoding UTF8
        $logWritten = $true
    }
    catch {
        if ($script:PcnConsoleLogEnabled) {
            Write-Warning "File log write skipped: $($_.Exception.Message)"
        }
    }

    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($script:PcnEventSource)) {
            New-EventLog -LogName $script:PcnEventLog -Source $script:PcnEventSource
        }

        Write-EventLog -LogName $script:PcnEventLog -Source $script:PcnEventSource -EntryType $EntryType -EventId $EventID -Message $Message
    }
    catch {
        $eventLine = '{0} [WARNING] Event Log write skipped: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message

        if ($logWritten -and $paths) {
            try {
                Add-Content -LiteralPath $paths.LogFile -Value $eventLine -Encoding UTF8
            }
            catch {
                $null = $_
            }
        }
    }

    if ($script:PcnConsoleLogEnabled) {
        Write-Host $Message
    }
}

function Get-PcnDotNetFrameworkVersion {
    $regPath = 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full'

    if (-not (Test-Path -LiteralPath $regPath)) {
        return 'Not found'
    }

    $release = (Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue).Release

    if (-not $release) {
        return 'Not installed'
    }

    switch ($release) {
        { $_ -ge 533320 } { return '4.8.1' }
        { $_ -ge 528040 } { return '4.8' }
        { $_ -ge 461808 } { return '4.7.2' }
        { $_ -ge 461308 } { return '4.7.1' }
        { $_ -ge 460798 } { return '4.7' }
        { $_ -ge 394802 } { return '4.6.2' }
        { $_ -ge 394254 } { return '4.6.1' }
        { $_ -ge 393295 } { return '4.6' }
        { $_ -ge 379893 } { return '4.5.2' }
        { $_ -ge 378675 } { return '4.5.1' }
        { $_ -ge 378389 } { return '4.5' }
        default { return 'Unknown or older than 4.5' }
    }
}

function Get-PcnDefaultConfig {
    [pscustomobject]@{
        ConfigVersion = 10
        Enabled = $false
        Frequency = 'Daily'
        Time = '03:00'
        DayOfWeek = 'Sunday'
        MonthlyDay = 15
        RunAtStartup = $false
        StartupDelayMinutes = 15
        RunIfMissed = $true
        WakeToRun = $false
        ShowRebootPrompt = $true
        InstallFirmwareUpdates = $false
        AutoRetryEnabled = $true
        RetryInitialDelayMinutes = 5
        RetryMaxAttempts = 3
        RetryBackoffMultiplier = 2
        MinimumCooldownMinutes = 5
        DisplayTheme = 'Light'
        LastSaved = $null
    }
}

function Merge-PcnWinUpdateConfig {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Config
    )

    $default = Get-PcnDefaultConfig
    $needsRc8TimingMigration = ($null -eq $Config.PSObject.Properties['ConfigVersion'])

    foreach ($property in $default.PSObject.Properties) {
        if ($null -eq $Config.PSObject.Properties[$property.Name]) {
            Add-Member -InputObject $Config -MemberType NoteProperty -Name $property.Name -Value $property.Value
        }
    }

    if ($needsRc8TimingMigration) {
        if ([int]$Config.StartupDelayMinutes -eq 30) {
            $Config.StartupDelayMinutes = 15
        }

        if ([int]$Config.RetryInitialDelayMinutes -eq 30) {
            $Config.RetryInitialDelayMinutes = 15
        }

        if ([int]$Config.MinimumCooldownMinutes -eq 30) {
            $Config.MinimumCooldownMinutes = 15
        }

        $Config.ConfigVersion = 8
    }

    try {
        if ([int]$Config.ConfigVersion -lt 10) {
            if ([int]$Config.RetryInitialDelayMinutes -eq 15) {
                $Config.RetryInitialDelayMinutes = 5
            }

            if ([int]$Config.MinimumCooldownMinutes -eq 15) {
                $Config.MinimumCooldownMinutes = 5
            }

            $Config.ConfigVersion = 10
        }
    }
    catch {
        $Config.ConfigVersion = 10
    }

    return $Config
}

function Get-PcnWinUpdateConfig {
    $paths = Initialize-PcnWinUpdateFolders

    if (-not (Test-Path -LiteralPath $paths.ConfigFile)) {
        return Get-PcnDefaultConfig
    }

    try {
        $raw = Get-Content -LiteralPath $paths.ConfigFile -Raw -ErrorAction Stop
        $config = $raw | ConvertFrom-Json
        return Merge-PcnWinUpdateConfig -Config $config
    }
    catch {
        Write-PcnWinUpdateLog -Message "Could not read config file. Using defaults. $($_.Exception.Message)" -EntryType Warning -EventID 1040
        return Get-PcnDefaultConfig
    }
}

function Save-PcnWinUpdateConfig {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Config
    )

    $paths = Initialize-PcnWinUpdateFolders
    $Config.LastSaved = (Get-Date).ToString('s')
    $Config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $paths.ConfigFile -Encoding UTF8
    Write-PcnWinUpdateLog -Message 'Configuration saved.' -EventID 1041
}

function Get-PcnDefaultState {
    [pscustomobject]@{
        LastRunStarted = $null
        LastRunFinished = $null
        LastRunType = $null
        LastResult = $null
        LastMessage = $null
        LastSuccessfulRun = $null
        LastRetryScheduled = $null
        LastRetryReason = $null
        RetryCount = 0
        LastRebootRequired = $false
    }
}

function Merge-PcnWinUpdateState {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$State
    )

    $default = Get-PcnDefaultState

    foreach ($property in $default.PSObject.Properties) {
        if ($null -eq $State.PSObject.Properties[$property.Name]) {
            Add-Member -InputObject $State -MemberType NoteProperty -Name $property.Name -Value $property.Value
        }
    }

    return $State
}

function Get-PcnWinUpdateState {
    $paths = Initialize-PcnWinUpdateFolders

    if (-not (Test-Path -LiteralPath $paths.StateFile)) {
        return Get-PcnDefaultState
    }

    try {
        $raw = Get-Content -LiteralPath $paths.StateFile -Raw -ErrorAction Stop
        $state = $raw | ConvertFrom-Json
        return Merge-PcnWinUpdateState -State $state
    }
    catch {
        Write-PcnWinUpdateLog -Message "Could not read state file. Using defaults. $($_.Exception.Message)" -EntryType Warning -EventID 1050
        return Get-PcnDefaultState
    }
}

function Save-PcnWinUpdateState {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$State
    )

    $paths = Initialize-PcnWinUpdateFolders
    $State | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $paths.StateFile -Encoding UTF8
}

function Get-PcnDateOrNull {
    param(
        [object]$Value
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }

    try {
        return [datetime]::Parse([string]$Value)
    }
    catch {
        return $null
    }
}

function New-PcnRunLock {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunType,

        [int]$StaleAfterHours = 6
    )

    $paths = Initialize-PcnWinUpdateFolders
    $now = Get-Date

    if (Test-Path -LiteralPath $paths.LockFile) {
        $removeStaleLock = $false

        try {
            $lock = Get-Content -LiteralPath $paths.LockFile -Raw | ConvertFrom-Json
            $started = Get-PcnDateOrNull -Value $lock.Started
            $pidValue = [int]$lock.ProcessId
            $processStillRunning = $false

            if ($pidValue -gt 0) {
                $processStillRunning = [bool](Get-Process -Id $pidValue -ErrorAction SilentlyContinue)
            }

            if ((-not $started) -or (($now - $started).TotalHours -ge $StaleAfterHours) -or (-not $processStillRunning)) {
                $removeStaleLock = $true
            }
        }
        catch {
            $removeStaleLock = $true
        }

        if ($removeStaleLock) {
            Write-PcnWinUpdateLog -Message 'Removing stale run lock.' -EntryType Warning -EventID 1051
            Remove-Item -LiteralPath $paths.LockFile -Force -ErrorAction SilentlyContinue
        }
        else {
            Write-PcnWinUpdateLog -Message 'Another PcNinja WinUpdate Tool run is already active. This run will exit.' -EntryType Warning -EventID 1052
            return [pscustomobject]@{
                Acquired = $false
                LockFile = $paths.LockFile
            }
        }
    }

    $lockData = [pscustomobject]@{
        ProcessId = $PID
        RunType = $RunType
        Started = $now.ToString('s')
    }

    try {
        $json = $lockData | ConvertTo-Json -Depth 3
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $stream = [System.IO.File]::Open($paths.LockFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
        }
        finally {
            $stream.Close()
        }

        Write-PcnWinUpdateLog -Message "Run lock acquired for $RunType run." -EventID 1053
        return [pscustomobject]@{
            Acquired = $true
            LockFile = $paths.LockFile
        }
    }
    catch {
        Write-PcnWinUpdateLog -Message "Could not acquire run lock: $($_.Exception.Message)" -EntryType Warning -EventID 1054
        return [pscustomobject]@{
            Acquired = $false
            LockFile = $paths.LockFile
        }
    }
}

function Remove-PcnRunLock {
    $paths = Initialize-PcnWinUpdateFolders

    if (-not (Test-Path -LiteralPath $paths.LockFile)) {
        return
    }

    try {
        $lock = Get-Content -LiteralPath $paths.LockFile -Raw | ConvertFrom-Json
        if ([int]$lock.ProcessId -ne $PID) {
            return
        }
    }
    catch {
        $null = $_
    }

    Remove-Item -LiteralPath $paths.LockFile -Force -ErrorAction SilentlyContinue
    Write-PcnWinUpdateLog -Message 'Run lock released.' -EventID 1055
}

function Get-PcnRetryDelayMinutes {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Config,

        [Parameter(Mandatory = $true)]
        [int]$RetryNumber
    )

    $baseDelay = [Math]::Max(1, [int]$Config.RetryInitialDelayMinutes)
    $multiplier = [Math]::Max(1, [int]$Config.RetryBackoffMultiplier)
    $power = [Math]::Max(0, $RetryNumber - 1)
    $delay = [int]($baseDelay * [Math]::Pow($multiplier, $power))
    return [Math]::Min($delay, 360)
}

function Unregister-PcnWinUpdateRetryTask {
    try {
        Unregister-ScheduledTask -TaskName $script:PcnRetryTaskName -TaskPath $script:PcnTaskPath -Confirm:$false -ErrorAction Stop
        Write-PcnWinUpdateLog -Message 'Retry task removed.' -EventID 1056
    }
    catch {
        $null = $_
    }
}

function Register-PcnWinUpdateRetryTask {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $true)]
        [psobject]$Config,

        [Parameter(Mandatory = $true)]
        [string]$Reason,

        [Parameter(Mandatory = $true)]
        [int]$RetryNumber
    )

    if (-not (Test-PcnAdministrator)) {
        throw 'Administrator privileges are required to create the retry scheduled task.'
    }

    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        throw "Script path was not found: $ScriptPath"
    }

    $delayMinutes = Get-PcnRetryDelayMinutes -Config $Config -RetryNumber $RetryNumber
    $runAt = (Get-Date).AddMinutes($delayMinutes)
    $powershell = Get-PcnPowershellPath
    $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Mode RunUpdates -Silent -RunType Retry' -f $ScriptPath

    $trigger = New-ScheduledTaskTrigger -Once -At $runAt
    $action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -Compatibility Win8 -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 6)

    Register-ScheduledTask `
        -TaskName $script:PcnRetryTaskName `
        -TaskPath $script:PcnTaskPath `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description "One-time retry for PcNinja WinUpdate Tool. Reason: $Reason" `
        -Force | Out-Null

    $state = Get-PcnWinUpdateState
    $state.LastRetryScheduled = $runAt.ToString('s')
    $state.LastRetryReason = $Reason
    $state.RetryCount = $RetryNumber
    Save-PcnWinUpdateState -State $state

    Write-PcnWinUpdateLog -Message "Retry $RetryNumber scheduled for $($runAt.ToString('yyyy-MM-dd HH:mm')) after $delayMinutes minute(s). Reason: $Reason" -EntryType Warning -EventID 1057

    return [pscustomobject]@{
        Scheduled = $true
        RunAt = $runAt
        RetryNumber = $RetryNumber
        Reason = $Reason
    }
}

function Request-PcnWinUpdateRetry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $true)]
        [psobject]$Config,

        [Parameter(Mandatory = $true)]
        [string]$Reason
    )

    if (-not [bool]$Config.AutoRetryEnabled) {
        Write-PcnWinUpdateLog -Message "Auto retry disabled. Retry not scheduled. Reason: $Reason" -EntryType Warning -EventID 1058
        return [pscustomobject]@{
            Scheduled = $false
            Result = 'RetryDisabled'
            Message = $Reason
        }
    }

    $state = Get-PcnWinUpdateState
    $nextRetry = [int]$state.RetryCount + 1
    $maxRetries = [Math]::Max(0, [int]$Config.RetryMaxAttempts)

    if ($nextRetry -gt $maxRetries) {
        Write-PcnWinUpdateLog -Message "Auto retry limit reached ($maxRetries). Retry not scheduled. Reason: $Reason" -EntryType Warning -EventID 1059
        return [pscustomobject]@{
            Scheduled = $false
            Result = 'MaxRetriesReached'
            Message = $Reason
        }
    }

    $retry = Register-PcnWinUpdateRetryTask -ScriptPath $ScriptPath -Config $Config -Reason $Reason -RetryNumber $nextRetry

    return [pscustomobject]@{
        Scheduled = $retry.Scheduled
        Result = 'RetryScheduled'
        Message = "Retry scheduled for $($retry.RunAt.ToString('yyyy-MM-dd HH:mm'))"
        RunAt = $retry.RunAt
        RetryNumber = $retry.RetryNumber
    }
}

function Get-PcnScheduledTaskStatusByName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskName
    )

    try {
        $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $script:PcnTaskPath -ErrorAction Stop
        $info = $task | Get-ScheduledTaskInfo

        [pscustomobject]@{
            Exists = $true
            TaskName = $TaskName
            TaskPath = $script:PcnTaskPath
            State = $task.State
            LastRunTime = $info.LastRunTime
            NextRunTime = $info.NextRunTime
            LastTaskResult = $info.LastTaskResult
        }
    }
    catch {
        [pscustomobject]@{
            Exists = $false
            TaskName = $TaskName
            TaskPath = $script:PcnTaskPath
            State = 'Not installed'
            LastRunTime = $null
            NextRunTime = $null
            LastTaskResult = $null
        }
    }
}

function Get-PcnScheduledTaskStatus {
    Get-PcnScheduledTaskStatusByName -TaskName $script:PcnTaskName
}

function Get-PcnRetryTaskStatus {
    Get-PcnScheduledTaskStatusByName -TaskName $script:PcnRetryTaskName
}

function Get-PcnRunOnceTaskStatus {
    Get-PcnScheduledTaskStatusByName -TaskName $script:PcnRunOnceTaskName
}

function Convert-PcnPendingRenamePath {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    $text = [string]$Value
    $text = $text -replace '^[!*]', ''
    $text = $text -replace '^\d+(?=\\\?\?\\)', ''
    $text = $text -replace '^\\\?\?\\', ''
    $text = $text -replace '^\\SystemRoot\\', "$env:SystemRoot\"
    return $text
}

function Test-PcnBlockingPendingFileRename {
    param(
        [AllowNull()]
        [string]$Source,

        [AllowNull()]
        [string]$Destination
    )

    $combined = ("$Source`n$Destination").ToLowerInvariant()

    $blockingPatterns = @(
        '\\windows\\winsxs\\',
        '\\windows\\servicing\\',
        '\\windows\\softwaredistribution\\',
        '\\windows\\system32\\catroot',
        '\\windows\\system32\\drivers\\',
        '\\windows\\system32\\driverstore\\',
        '\\windows\\inf\\',
        'pending\.xml',
        '\\windows\\system32\\wu',
        '\\windows\\system32\\uso',
        '\\windows\\system32\\mus'
    )

    foreach ($pattern in $blockingPatterns) {
        if ($combined -match $pattern) {
            return $true
        }
    }

    return $false
}

function Convert-PcnPendingFileRenameOperations {
    param(
        [AllowNull()]
        [string[]]$Entries
    )

    $operations = New-Object System.Collections.Generic.List[object]

    if ($null -eq $Entries) {
        return @()
    }

    for ($index = 0; $index -lt $Entries.Count; $index += 2) {
        $rawSource = [string]$Entries[$index]
        $rawDestination = ''

        if (($index + 1) -lt $Entries.Count) {
            $rawDestination = [string]$Entries[$index + 1]
        }

        $source = Convert-PcnPendingRenamePath -Value $rawSource
        $destination = Convert-PcnPendingRenamePath -Value $rawDestination

        if ([string]::IsNullOrWhiteSpace($source) -and [string]::IsNullOrWhiteSpace($destination)) {
            continue
        }

        $action = if ([string]::IsNullOrWhiteSpace($destination)) { 'Delete' } else { 'Rename' }
        $blocking = Test-PcnBlockingPendingFileRename -Source $source -Destination $destination

        $operations.Add([pscustomobject]@{
            Source = $source
            Destination = $destination
            Action = $action
            BlocksWindowsUpdateRun = $blocking
        }) | Out-Null
    }

    return $operations.ToArray()
}

function Write-PcnPendingRebootDiagnosticLog {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$PendingState
    )

    if ($PendingState.PSObject.Properties['Warnings'] -and $PendingState.Warnings.Count -gt 0) {
        Write-PcnWinUpdateLog -Message "Pending reboot warning ignored for update flow: $($PendingState.Warnings -join '; ')" -EntryType Warning -EventID 1073
    }

    if ($PendingState.PSObject.Properties['FileRenameOperations'] -and $PendingState.FileRenameOperations.Count -gt 0) {
        $sample = @($PendingState.FileRenameOperations | Select-Object -First 5 | ForEach-Object {
            $target = if ([string]::IsNullOrWhiteSpace($_.Destination)) { $_.Source } else { "$($_.Source) -> $($_.Destination)" }
            "$($_.Action): $target | BlocksUpdateRun=$($_.BlocksWindowsUpdateRun)"
        })

        Write-PcnWinUpdateLog -Message "Pending file rename sample: $($sample -join '; ')" -EntryType Warning -EventID 1074
    }
}

function Test-PcnPendingReboot {
    $reasons = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $fileRenameOperations = @()
    $blockingFileRenameOperations = @()

    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )

    foreach ($key in $keys) {
        if (Test-Path -LiteralPath $key) {
            $reasons.Add($key) | Out-Null
        }
    }

    try {
        $pendingFileRename = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop).PendingFileRenameOperations

        if ($pendingFileRename) {
            $fileRenameOperations = @(Convert-PcnPendingFileRenameOperations -Entries $pendingFileRename)
            $blockingFileRenameOperations = @($fileRenameOperations | Where-Object { $_.BlocksWindowsUpdateRun })

            if ($blockingFileRenameOperations.Count -gt 0) {
                $reasons.Add('Pending file rename operations that affect Windows servicing or drivers') | Out-Null
            }
            elseif ($fileRenameOperations.Count -gt 0) {
                $warnings.Add('Generic pending file rename operations are present, but they do not match Windows Update, servicing, or driver paths.') | Out-Null
            }
        }
    }
    catch {
        $warnings.Add("Could not inspect pending file rename operations: $($_.Exception.Message)") | Out-Null
    }

    try {
        $computerName = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -ErrorAction Stop).ComputerName
        $activeComputerName = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -ErrorAction Stop).ComputerName

        if ($computerName -and $activeComputerName -and ($computerName -ne $activeComputerName)) {
            $reasons.Add('Pending computer rename') | Out-Null
        }
    }
    catch {
        $null = $_
    }

    [pscustomobject]@{
        Pending = ($reasons.Count -gt 0)
        Reasons = @($reasons)
        Warnings = @($warnings)
        FileRenameOperations = @($fileRenameOperations)
        BlockingFileRenameOperations = @($blockingFileRenameOperations)
    }
}

function Restart-PcnComputerNow {
    if (-not (Test-PcnAdministrator)) {
        throw 'Administrator privileges are required to restart this computer.'
    }

    Write-PcnWinUpdateLog -Message 'Restart requested from PcNinja WinUpdate Tool.' -EventID 1070
    Restart-Computer -Force
}

function Convert-PcnXmlEscape {
    param(
        [AllowNull()]
        [object]$Value
    )

    return [System.Security.SecurityElement]::Escape([string]$Value)
}

function Get-PcnIsoDurationMinutes {
    param(
        [int]$Minutes
    )

    $safeMinutes = [Math]::Max(0, $Minutes)

    if ($safeMinutes -eq 0) {
        return 'PT0M'
    }

    return "PT$($safeMinutes)M"
}

function New-PcnScheduleCalendarTriggerXml {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Config
    )

    $time = [TimeSpan]::Parse($Config.Time)
    $startBoundary = [DateTime]::Today.Add($time).ToString('s')

    switch ([string]$Config.Frequency) {
        'Daily' {
            return @"
    <CalendarTrigger>
      <StartBoundary>$startBoundary</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay>
        <DaysInterval>1</DaysInterval>
      </ScheduleByDay>
    </CalendarTrigger>
"@
        }
        'Weekly' {
            $day = Convert-PcnXmlEscape $Config.DayOfWeek
            return @"
    <CalendarTrigger>
      <StartBoundary>$startBoundary</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByWeek>
        <WeeksInterval>1</WeeksInterval>
        <DaysOfWeek>
          <$day />
        </DaysOfWeek>
      </ScheduleByWeek>
    </CalendarTrigger>
"@
        }
        'Monthly' {
            $dayOfMonth = [Math]::Min(28, [Math]::Max(1, [int]$Config.MonthlyDay))
            return @"
    <CalendarTrigger>
      <StartBoundary>$startBoundary</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByMonth>
        <DaysOfMonth>
          <Day>$dayOfMonth</Day>
        </DaysOfMonth>
        <Months>
          <January />
          <February />
          <March />
          <April />
          <May />
          <June />
          <July />
          <August />
          <September />
          <October />
          <November />
          <December />
        </Months>
      </ScheduleByMonth>
    </CalendarTrigger>
"@
        }
        default {
            return ''
        }
    }
}

function New-PcnScheduleBootTriggerXml {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Config
    )

    $delay = Get-PcnIsoDurationMinutes -Minutes ([int]$Config.StartupDelayMinutes)

    return @"
    <BootTrigger>
      <Enabled>true</Enabled>
      <Delay>$delay</Delay>
    </BootTrigger>
"@
}

function New-PcnScheduledTaskXml {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Config,

        [Parameter(Mandatory = $true)]
        [string]$ScriptPath
    )

    $powershell = Convert-PcnXmlEscape (Get-PcnPowershellPath)
    $scriptDirectory = Convert-PcnXmlEscape (Split-Path -Parent $ScriptPath)
    $arguments = Convert-PcnXmlEscape ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Mode RunUpdates -Silent -RunType Scheduled' -f $ScriptPath)
    $description = Convert-PcnXmlEscape 'Runs PcNinja WinUpdate Tool to search, download, and install Windows updates.'
    $now = (Get-Date).ToString('s')
    $startWhenAvailable = if ([bool]$Config.RunIfMissed) { 'true' } else { 'false' }
    $wakeToRun = if ([bool]$Config.WakeToRun) { 'true' } else { 'false' }

    $triggers = New-Object System.Collections.Generic.List[string]

    if ([string]$Config.Frequency -ne 'Startup') {
        $calendarTrigger = New-PcnScheduleCalendarTriggerXml -Config $Config

        if (-not [string]::IsNullOrWhiteSpace($calendarTrigger)) {
            $triggers.Add($calendarTrigger) | Out-Null
        }
    }

    if ([string]$Config.Frequency -eq 'Startup' -or [bool]$Config.RunAtStartup) {
        $triggers.Add((New-PcnScheduleBootTriggerXml -Config $Config)) | Out-Null
    }

    if ($triggers.Count -eq 0) {
        throw 'No valid scheduled task trigger was selected.'
    }

    $triggerXml = ($triggers -join [Environment]::NewLine)

    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Date>$now</Date>
    <Author>PcNinja</Author>
    <Description>$description</Description>
  </RegistrationInfo>
  <Triggers>
$triggerXml
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>$startWhenAvailable</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>$wakeToRun</WakeToRun>
    <ExecutionTimeLimit>PT6H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$powershell</Command>
      <Arguments>$arguments</Arguments>
      <WorkingDirectory>$scriptDirectory</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@
}

function Register-PcnWinUpdateScheduledTask {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Config,

        [Parameter(Mandatory = $true)]
        [string]$ScriptPath
    )

    if (-not (Test-PcnAdministrator)) {
        throw 'Administrator privileges are required to create the scheduled task.'
    }

    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        throw "Script path was not found: $ScriptPath"
    }

    $taskXml = New-PcnScheduledTaskXml -Config $Config -ScriptPath $ScriptPath

    Register-ScheduledTask `
        -TaskName $script:PcnTaskName `
        -TaskPath $script:PcnTaskPath `
        -Xml $taskXml `
        -Force | Out-Null

    $startupText = if ([string]$Config.Frequency -eq 'Startup' -or [bool]$Config.RunAtStartup) { " with startup delay $($Config.StartupDelayMinutes) minute(s)" } else { '' }
    Write-PcnWinUpdateLog -Message "Scheduled task saved: $($Config.Frequency) at $($Config.Time)$startupText." -EventID 1042
}

function Unregister-PcnWinUpdateScheduledTask {
    if (-not (Test-PcnAdministrator)) {
        throw 'Administrator privileges are required to remove the scheduled task.'
    }

    try {
        Unregister-ScheduledTask -TaskName $script:PcnTaskName -TaskPath $script:PcnTaskPath -Confirm:$false -ErrorAction Stop
        Write-PcnWinUpdateLog -Message 'Scheduled task removed.' -EventID 1043
    }
    catch {
        Write-PcnWinUpdateLog -Message "Scheduled task was not removed: $($_.Exception.Message)" -EntryType Warning -EventID 1044
    }
}

function Start-PcnWinUpdateRunOnceTask {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath
    )

    if (-not (Test-PcnAdministrator)) {
        throw 'Administrator privileges are required to start a run-once task.'
    }

    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        throw "Script path was not found: $ScriptPath"
    }

    $powershell = Get-PcnPowershellPath
    $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Mode RunUpdates -Silent -RunType Manual' -f $ScriptPath
    $action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments -WorkingDirectory (Split-Path -Parent $ScriptPath)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -Compatibility Win8 -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 6)

    Register-ScheduledTask `
        -TaskName $script:PcnRunOnceTaskName `
        -TaskPath $script:PcnTaskPath `
        -Action $action `
        -Principal $principal `
        -Settings $settings `
        -Description 'One-off remote/admin launch for PcNinja WinUpdate Tool.' `
        -Force | Out-Null

    Start-ScheduledTask -TaskName $script:PcnRunOnceTaskName -TaskPath $script:PcnTaskPath
    Write-PcnWinUpdateLog -Message 'Run-once task started.' -EventID 1080

    return Get-PcnRunOnceTaskStatus
}

function Unregister-PcnWinUpdateRunOnceTask {
    if (-not (Test-PcnAdministrator)) {
        throw 'Administrator privileges are required to remove the run-once task.'
    }

    try {
        Unregister-ScheduledTask -TaskName $script:PcnRunOnceTaskName -TaskPath $script:PcnTaskPath -Confirm:$false -ErrorAction Stop
        Write-PcnWinUpdateLog -Message 'Run-once task removed.' -EventID 1081
    }
    catch {
        Write-PcnWinUpdateLog -Message "Run-once task was not removed: $($_.Exception.Message)" -EntryType Warning -EventID 1082
    }
}

function Get-PcnObjectPropertyValue {
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowNull()]
        [object]$Default = $null
    )

    if ($null -eq $InputObject) {
        return $Default
    }

    if ($InputObject -is [System.Array]) {
        $firstObject = @($InputObject | Where-Object { $null -ne $_ } | Select-Object -First 1)

        if ($firstObject.Count -eq 0) {
            return $Default
        }

        $InputObject = $firstObject[0]
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $Default
    }

    return $property.Value
}

function Convert-PcnStringArray {
    param(
        [AllowNull()]
        [object]$Value
    )

    $items = New-Object System.Collections.Generic.List[string]

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Array]) {
        foreach ($item in $Value) {
            if (-not [string]::IsNullOrWhiteSpace([string]$item)) {
                $items.Add(([string]$item).Trim()) | Out-Null
            }
        }
    }
    else {
        foreach ($item in ([string]$Value -split "`0|`r?`n")) {
            if (-not [string]::IsNullOrWhiteSpace($item)) {
                $items.Add($item.Trim()) | Out-Null
            }
        }
    }

    return @($items | Select-Object -Unique)
}

function Get-PcnRegistryStringArray {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    try {
        $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        return @(Convert-PcnStringArray -Value (Get-PcnObjectPropertyValue -InputObject $item -Name $Name))
    }
    catch {
        return @()
    }
}

function Convert-PcnWmiDate {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return ''
    }

    if ($Value -is [System.Array]) {
        $firstValue = @($Value | Where-Object { $null -ne $_ } | Select-Object -First 1)

        if ($firstValue.Count -eq 0) {
            return ''
        }

        $Value = $firstValue[0]
    }

    try {
        if ($Value -is [DateTime]) {
            return ([DateTime]$Value).ToString('yyyy-MM-dd')
        }

        $text = $Value.ToString()
        if ([string]::IsNullOrWhiteSpace($text)) {
            return ''
        }

        if ($text -match '^\d{14}\.') {
            return ([System.Management.ManagementDateTimeConverter]::ToDateTime($text)).ToString('yyyy-MM-dd')
        }

        return ([DateTime]::Parse($text)).ToString('yyyy-MM-dd')
    }
    catch {
        try {
            return $Value.ToString()
        }
        catch {
            return ''
        }
    }
}

function Join-PcnReportList {
    param(
        [AllowNull()]
        [object[]]$Values
    )

    $items = @($Values | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)

    if ($items.Count -eq 0) {
        return ''
    }

    return ($items -join ' | ')
}

function Convert-PcnDisplayString {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return ''
    }

    $items = New-Object System.Collections.Generic.List[string]

    if ($Value -is [System.Array]) {
        foreach ($item in $Value) {
            if ($null -eq $item) {
                continue
            }

            try {
                $text = $item.ToString().Trim()
                if (-not [string]::IsNullOrWhiteSpace($text)) {
                    $items.Add($text) | Out-Null
                }
            }
            catch {
                $null = $_
            }
        }
    }
    else {
        try {
            $text = $Value.ToString().Trim()
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $items.Add($text) | Out-Null
            }
        }
        catch {
            $null = $_
        }
    }

    if ($items.Count -eq 0) {
        return ''
    }

    return (@($items | Select-Object -Unique) -join ' | ')
}

function Get-PcnDeviceEnumerator {
    param(
        [AllowNull()]
        [string]$DeviceId
    )

    if ([string]::IsNullOrWhiteSpace($DeviceId)) {
        return ''
    }

    if ($DeviceId -match '^([^\\]+)\\') {
        return $matches[1].ToUpperInvariant()
    }

    return ''
}

function Get-PcnDriverAuditSourceCatalog {
    @(
        [pscustomobject]@{
            Id = 'OEM_DELL'
            Scope = 'OEM'
            MatchPattern = 'DELL'
            SourceName = 'Dell Command | Update / Dell Drivers & Downloads'
            SourceUrl = 'https://www.dell.com/support/home/en-us?app=drivers'
            Notes = 'Best first source for Dell client systems because packages are matched to the Service Tag or exact model.'
        },
        [pscustomobject]@{
            Id = 'OEM_LENOVO'
            Scope = 'OEM'
            MatchPattern = 'LENOVO|THINKPAD|THINKCENTRE'
            SourceName = 'Lenovo System Update / Lenovo Support'
            SourceUrl = 'https://support.lenovo.com/us/en/solutions/ht003029-lenovo-system-update-update-drivers-bios-and-applications'
            Notes = 'Best first source for Lenovo systems because it uses Lenovo model-specific packages.'
        },
        [pscustomobject]@{
            Id = 'OEM_HP'
            Scope = 'OEM'
            MatchPattern = '(^|\b)(HP|HEWLETT-PACKARD)(\b|$)'
            SourceName = 'HP Image Assistant / HP Support'
            SourceUrl = 'https://ftp.ext.hp.com/pub/caps-softpaq/cmit/HPIA.html'
            Notes = 'Best first source for supported HP business systems and SoftPaq recommendations.'
        },
        [pscustomobject]@{
            Id = 'OEM_SURFACE'
            Scope = 'OEM'
            MatchPattern = 'MICROSOFT.*SURFACE|SURFACE'
            SourceName = 'Microsoft Surface drivers and firmware'
            SourceUrl = 'https://support.microsoft.com/en-us/surface/drivers-firmware/download-drivers-and-firmware-for-surface'
            Notes = 'Best first source for Surface driver and firmware packages when Windows Update is not enough.'
        },
        [pscustomobject]@{
            Id = 'OEM_ASUS'
            Scope = 'OEM'
            MatchPattern = 'ASUSTEK|ASUS'
            SourceName = 'ASUS Download Center'
            SourceUrl = 'https://www.asus.com/support/download-center/'
            Notes = 'Use the exact ASUS model or serial number before comparing component drivers.'
        },
        [pscustomobject]@{
            Id = 'COMPONENT_INTEL'
            Scope = 'Component'
            MatchPattern = 'VEN_8086|VID_8087|INTEL'
            SourceName = 'Intel Driver & Support Assistant'
            SourceUrl = 'https://www.intel.com/content/www/us/en/support/detect.html'
            Notes = 'Useful for Intel graphics, chipset, wireless, Bluetooth, and network components.'
        },
        [pscustomobject]@{
            Id = 'COMPONENT_NVIDIA'
            Scope = 'Component'
            MatchPattern = 'VEN_10DE|NVIDIA'
            SourceName = 'NVIDIA official drivers'
            SourceUrl = 'https://www.nvidia.com/en-us/drivers/'
            Notes = 'Useful for NVIDIA display drivers. Prefer OEM packages on laptops when stability matters.'
        },
        [pscustomobject]@{
            Id = 'COMPONENT_AMD'
            Scope = 'Component'
            MatchPattern = 'VEN_1002|VEN_1022|AMD|ADVANCED MICRO DEVICES|RADEON'
            SourceName = 'AMD Drivers and Support'
            SourceUrl = 'https://www.amd.com/en/support/download/drivers.html'
            Notes = 'Useful for AMD graphics and chipset packages. Prefer OEM packages on laptops when stability matters.'
        },
        [pscustomobject]@{
            Id = 'COMPONENT_LOGITECH'
            Scope = 'Component'
            MatchPattern = 'VID_046D|LOGITECH|LOGI '
            SourceName = 'Logitech Support + Download'
            SourceUrl = 'https://support.logi.com/hc/en-us'
            Notes = 'Useful for Logitech USB receivers, keyboards, mice, webcams, and related software. Search by exact product model when possible.'
        }
    )
}

function Get-PcnDriverAuditSourceByScope {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Scope,

        [Parameter(Mandatory = $true)]
        [string]$Evidence
    )

    foreach ($source in (Get-PcnDriverAuditSourceCatalog | Where-Object { $_.Scope -eq $Scope })) {
        if ($Evidence -match $source.MatchPattern) {
            return $source
        }
    }

    return $null
}

function Get-PcnDriverAuditHardwareIdentity {
    param(
        [AllowNull()]
        [string]$DeviceId,

        [AllowNull()]
        [string[]]$HardwareIds = @(),

        [AllowNull()]
        [string[]]$CompatibleIds = @()
    )

    $values = @(@($DeviceId) + @($HardwareIds) + @($CompatibleIds) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $text = ($values -join ' ').ToUpperInvariant()

    $identity = [ordered]@{
        Bus = ''
        VendorId = ''
        DeviceId = ''
        ProductId = ''
        RawMatch = ''
    }

    if ($text -match 'PCI\\VEN_([0-9A-F]{4})&DEV_([0-9A-F]{4})') {
        $identity.Bus = 'PCI'
        $identity.VendorId = $matches[1]
        $identity.DeviceId = $matches[2]
        $identity.RawMatch = $matches[0]
    }
    elseif ($text -match 'USB\\VID_([0-9A-F]{4})&PID_([0-9A-F]{4})') {
        $identity.Bus = 'USB'
        $identity.VendorId = $matches[1]
        $identity.ProductId = $matches[2]
        $identity.RawMatch = $matches[0]
    }
    elseif ($text -match 'HID\\VID_([0-9A-F]{4})&PID_([0-9A-F]{4})') {
        $identity.Bus = 'HID'
        $identity.VendorId = $matches[1]
        $identity.ProductId = $matches[2]
        $identity.RawMatch = $matches[0]
    }
    elseif ($text -match 'HDAUDIO\\FUNC_[0-9A-F]{2}&VEN_([0-9A-F]{4})&DEV_([0-9A-F]{4})') {
        $identity.Bus = 'HDAUDIO'
        $identity.VendorId = $matches[1]
        $identity.DeviceId = $matches[2]
        $identity.RawMatch = $matches[0]
    }

    return [pscustomobject]$identity
}

function Get-PcnDriverAuditRecommendation {
    param(
        [bool]$UpdateCandidate,

        [AllowNull()]
        [string]$DeviceName,

        [AllowNull()]
        [string]$DeviceClass,

        [AllowNull()]
        [string]$Manufacturer,

        [AllowNull()]
        [string]$DriverProviderName,

        [AllowNull()]
        [string]$SystemManufacturer,

        [AllowNull()]
        [string]$SystemModel,

        [AllowNull()]
        [string]$DeviceId,

        [AllowNull()]
        [string[]]$HardwareIds = @(),

        [AllowNull()]
        [string[]]$CompatibleIds = @()
    )

    $evidence = (@($DeviceName, $DeviceClass, $Manufacturer, $DriverProviderName, $SystemManufacturer, $SystemModel, $DeviceId) + @($HardwareIds) + @($CompatibleIds) |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ' '
    $evidence = $evidence.ToUpperInvariant()
    $oemEvidence = (@($SystemManufacturer, $SystemModel) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ' '
    $oemSource = Get-PcnDriverAuditSourceByScope -Scope 'OEM' -Evidence ($oemEvidence.ToUpperInvariant())
    $componentSource = Get-PcnDriverAuditSourceByScope -Scope 'Component' -Evidence $evidence
    $hardwareIdentity = Get-PcnDriverAuditHardwareIdentity -DeviceId $DeviceId -HardwareIds $HardwareIds -CompatibleIds $CompatibleIds

    if (-not $UpdateCandidate) {
        return [pscustomobject]@{
            AuditCandidate = $false
            AuditPriority = 'Low'
            AuditAction = 'No vendor audit suggested'
            PrimarySourceName = ''
            PrimarySourceUrl = ''
            SecondarySourceName = ''
            SecondarySourceUrl = ''
            SourceConfidence = 'Low'
            AuditReason = 'Filtered or generic device. Keep Windows Update as the source unless there is a specific device problem.'
            HardwareBus = $hardwareIdentity.Bus
            HardwareVendorId = $hardwareIdentity.VendorId
            HardwareDeviceId = $hardwareIdentity.DeviceId
            HardwareProductId = $hardwareIdentity.ProductId
        }
    }

    $isDisplay = ([string]$DeviceClass -match 'DISPLAY') -or ($evidence -match 'DISPLAY|GRAPHICS|VIDEO|GPU|NVIDIA|RADEON|INTEL\(R\).*GRAPHICS')
    $isNetwork = ([string]$DeviceClass -match 'NET') -or ($evidence -match 'WIRELESS|WIFI|WI-FI|ETHERNET|BLUETOOTH')
    $isStorage = ([string]$DeviceClass -match 'SCSIADAPTER|HDC|STORAGE') -or ($evidence -match 'NVME|SATA|RAID|STORAGE')
    $isExternalPeripheral = ($hardwareIdentity.Bus -in @('USB', 'HID')) -or ([string]$DeviceClass -match 'HIDCLASS|IMAGE|CAMERA')
    $oemUsbVendorIds = @('413C', '03F0', '17EF', '045E', '0B05')

    $priority = 'Medium'
    if ($isDisplay -or $isNetwork -or $isStorage) {
        $priority = 'High'
    }

    $primary = $oemSource
    $secondary = $componentSource
    $reason = 'Compare this hardware ID with the OEM support source for the exact machine model. Report-only: this does not mean the installed driver is outdated.'
    $confidence = if ($oemSource) { 'Medium' } else { 'Low' }

    if ($isExternalPeripheral -and $componentSource) {
        $primary = $componentSource
        $secondary = $null
        $reason = 'External USB/HID peripheral. Compare only with the device manufacturer support source, not a generic driver database.'
        $confidence = 'Medium'
    }
    elseif ($isExternalPeripheral -and $oemSource -and $hardwareIdentity.VendorId -notin $oemUsbVendorIds) {
        $primary = $null
        $secondary = $null
        $reason = 'External USB/HID peripheral with no known responsible source rule. Use manual review by exact device model.'
        $confidence = 'Low'
    }
    elseif ($isDisplay -and $componentSource) {
        $primary = $componentSource
        $secondary = $oemSource
        $reason = 'Display/GPU driver candidate. Compare the installed version with the component vendor and OEM source; prefer OEM packages on laptops if stability is more important than newest features.'
        $confidence = 'High'
    }
    elseif (($isNetwork -or $isStorage) -and $componentSource -and -not $oemSource) {
        $primary = $componentSource
        $reason = 'Network/storage candidate with a recognized component vendor. Compare only through the official vendor source.'
        $confidence = 'Medium'
    }
    elseif (-not $primary -and $componentSource) {
        $primary = $componentSource
        $reason = 'Recognized component vendor. Compare through the official vendor source; do not auto-install from generic driver databases.'
        $confidence = 'Medium'
    }

    if (-not $primary) {
        return [pscustomobject]@{
            AuditCandidate = $true
            AuditPriority = 'Low'
            AuditAction = 'Manual review only'
            PrimarySourceName = 'OEM support site for exact model'
            PrimarySourceUrl = ''
            SecondarySourceName = ''
            SecondarySourceUrl = ''
            SourceConfidence = 'Low'
            AuditReason = 'High-confidence hardware ID exists, but no known responsible source rule matched. Use the OEM support site for the exact model.'
            HardwareBus = $hardwareIdentity.Bus
            HardwareVendorId = $hardwareIdentity.VendorId
            HardwareDeviceId = $hardwareIdentity.DeviceId
            HardwareProductId = $hardwareIdentity.ProductId
        }
    }

    return [pscustomobject]@{
        AuditCandidate = $true
        AuditPriority = $priority
        AuditAction = 'Compare version with official source'
        PrimarySourceName = $primary.SourceName
        PrimarySourceUrl = $primary.SourceUrl
        SecondarySourceName = if ($secondary) { $secondary.SourceName } else { '' }
        SecondarySourceUrl = if ($secondary) { $secondary.SourceUrl } else { '' }
        SourceConfidence = $confidence
        AuditReason = $reason
        HardwareBus = $hardwareIdentity.Bus
        HardwareVendorId = $hardwareIdentity.VendorId
        HardwareDeviceId = $hardwareIdentity.DeviceId
        HardwareProductId = $hardwareIdentity.ProductId
    }
}

function Get-PcnDriverCandidateAssessment {
    param(
        [AllowNull()]
        [string]$DeviceId,

        [AllowNull()]
        [string[]]$HardwareIds = @(),

        [AllowNull()]
        [string[]]$CompatibleIds = @()
    )

    $values = New-Object System.Collections.Generic.List[string]

    foreach ($value in @($DeviceId) + @($HardwareIds) + @($CompatibleIds)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            $values.Add(([string]$value).ToUpperInvariant()) | Out-Null
        }
    }

    if ($values.Count -eq 0) {
        return [pscustomobject]@{
            UpdateCandidate = $false
            Category = 'Unknown'
            Reason = 'No hardware ID was available.'
        }
    }

    $text = $values -join ' '
    $excludeRules = @(
        @{ Pattern = 'USBSTOR\\'; Reason = 'USB storage devices are intentionally ignored.' },
        @{ Pattern = 'GENCDROM|GENERIC.*CDROM'; Reason = 'Generic optical drive entry.' },
        @{ Pattern = 'GENDISK|STORAGE\\VOLUME|^VOLUME\\'; Reason = 'Generic disk or volume entry.' },
        @{ Pattern = 'HID_DEVICE|HID\\VID_0000|HID\\{'; Reason = 'Generic HID entry.' },
        @{ Pattern = 'ACPIAPIC|ACPI\\FIXEDBUTTON|ACPI\\PNP0C0C|ACPI\\PNP0C0D|ACPI\\PNP0C0E'; Reason = 'Generic ACPI/platform control entry.' },
        @{ Pattern = '^ROOT\\| ROOT\\|^SWD\\| SWD\\|HTREE\\ROOT'; Reason = 'Software/root enumerated device.' },
        @{ Pattern = 'DISPLAY\\DEFAULT_MONITOR|MONITOR\\DEFAULT_MONITOR'; Reason = 'Default monitor placeholder.' }
    )

    foreach ($rule in $excludeRules) {
        if ($text -match $rule['Pattern']) {
            return [pscustomobject]@{
                UpdateCandidate = $false
                Category = 'Filtered'
                Reason = $rule['Reason']
            }
        }
    }

    $includeRules = @(
        @{ Category = 'PCI'; Pattern = 'PCI\\VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4}'; Reason = 'PCI vendor/device hardware ID.' },
        @{ Category = 'HDAUDIO'; Pattern = 'HDAUDIO\\FUNC_[0-9A-F]{2}&VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4}'; Reason = 'High Definition Audio hardware ID.' },
        @{ Category = 'USB'; Pattern = 'USB\\VID_[0-9A-F]{4}&PID_[0-9A-F]{4}'; Reason = 'USB vendor/product hardware ID.' },
        @{ Category = 'HID'; Pattern = 'HID\\VID_[0-9A-F]{4}&PID_[0-9A-F]{4}'; Reason = 'HID vendor/product hardware ID.' },
        @{ Category = 'SCSI'; Pattern = 'SCSI\\.{24,}'; Reason = 'SCSI hardware ID with enough vendor/model detail.' }
    )

    foreach ($rule in $includeRules) {
        if ($text -match $rule['Pattern']) {
            return [pscustomobject]@{
                UpdateCandidate = $true
                Category = $rule['Category']
                Reason = $rule['Reason']
            }
        }
    }

    return [pscustomobject]@{
        UpdateCandidate = $false
        Category = 'Other'
        Reason = 'No high-confidence vendor/device hardware ID matched the report filter.'
    }
}

function Get-PcnDriverInventoryReport {
    $reportTime = Get-Date
    Write-PcnWinUpdateLog -Message 'Starting driver audit report. No drivers will be downloaded or installed.' -EventID 1100

    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
    $baseBoard = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction SilentlyContinue
    $drivers = @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop)
    $entities = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue)
    $systemManufacturerText = Convert-PcnDisplayString -Value (Get-PcnObjectPropertyValue -InputObject $computer -Name 'Manufacturer' -Default '')
    $systemModelText = Convert-PcnDisplayString -Value (Get-PcnObjectPropertyValue -InputObject $computer -Name 'Model' -Default '')

    $entityByDeviceId = @{}
    foreach ($entity in $entities) {
        $entityDeviceId = Convert-PcnDisplayString -Value (Get-PcnObjectPropertyValue -InputObject $entity -Name 'PNPDeviceID' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($entityDeviceId) -and -not $entityByDeviceId.ContainsKey($entityDeviceId)) {
            $entityByDeviceId[$entityDeviceId] = $entity
        }
    }

    $devices = New-Object System.Collections.Generic.List[object]

    foreach ($driver in ($drivers | Sort-Object DeviceName, DeviceID)) {
        $deviceId = Convert-PcnDisplayString -Value (Get-PcnObjectPropertyValue -InputObject $driver -Name 'DeviceID' -Default '')
        $entity = $null

        if (-not [string]::IsNullOrWhiteSpace($deviceId) -and $entityByDeviceId.ContainsKey($deviceId)) {
            $entity = $entityByDeviceId[$deviceId]
        }

        $registryPath = if (-not [string]::IsNullOrWhiteSpace($deviceId)) { "HKLM:\SYSTEM\CurrentControlSet\Enum\$deviceId" } else { '' }
        $hardwareIds = @()
        $compatibleIds = @()

        if (-not [string]::IsNullOrWhiteSpace($registryPath)) {
            $hardwareIds += @(Get-PcnRegistryStringArray -Path $registryPath -Name 'HardwareID')
            $compatibleIds += @(Get-PcnRegistryStringArray -Path $registryPath -Name 'CompatibleIDs')
        }

        $hardwareIds += @(Convert-PcnStringArray -Value (Get-PcnObjectPropertyValue -InputObject $driver -Name 'HardWareID'))
        $compatibleIds += @(Convert-PcnStringArray -Value (Get-PcnObjectPropertyValue -InputObject $driver -Name 'CompatID'))
        $hardwareIds = @($hardwareIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
        $compatibleIds = @($compatibleIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)

        $assessment = Get-PcnDriverCandidateAssessment -DeviceId $deviceId -HardwareIds $hardwareIds -CompatibleIds $compatibleIds
        $deviceName = Convert-PcnDisplayString -Value (Get-PcnObjectPropertyValue -InputObject $driver -Name 'DeviceName' -Default '')
        $friendlyName = Convert-PcnDisplayString -Value (Get-PcnObjectPropertyValue -InputObject $entity -Name 'Name' -Default '')
        $deviceClass = Convert-PcnDisplayString -Value (Get-PcnObjectPropertyValue -InputObject $driver -Name 'DeviceClass' -Default '')
        $manufacturer = Convert-PcnDisplayString -Value (Get-PcnObjectPropertyValue -InputObject $driver -Name 'Manufacturer' -Default '')
        $driverProviderName = Convert-PcnDisplayString -Value (Get-PcnObjectPropertyValue -InputObject $driver -Name 'DriverProviderName' -Default '')
        $audit = Get-PcnDriverAuditRecommendation `
            -UpdateCandidate ([bool]$assessment.UpdateCandidate) `
            -DeviceName $deviceName `
            -DeviceClass $deviceClass `
            -Manufacturer $manufacturer `
            -DriverProviderName $driverProviderName `
            -SystemManufacturer $systemManufacturerText `
            -SystemModel $systemModelText `
            -DeviceId $deviceId `
            -HardwareIds $hardwareIds `
            -CompatibleIds $compatibleIds

        $devices.Add([pscustomobject]@{
            UpdateCandidate = [bool]$assessment.UpdateCandidate
            AuditCandidate = [bool]$audit.AuditCandidate
            AuditPriority = (Convert-PcnDisplayString -Value $audit.AuditPriority)
            AuditAction = (Convert-PcnDisplayString -Value $audit.AuditAction)
            AuditReason = (Convert-PcnDisplayString -Value $audit.AuditReason)
            SourceConfidence = (Convert-PcnDisplayString -Value $audit.SourceConfidence)
            PrimarySourceName = (Convert-PcnDisplayString -Value $audit.PrimarySourceName)
            PrimarySourceUrl = (Convert-PcnDisplayString -Value $audit.PrimarySourceUrl)
            SecondarySourceName = (Convert-PcnDisplayString -Value $audit.SecondarySourceName)
            SecondarySourceUrl = (Convert-PcnDisplayString -Value $audit.SecondarySourceUrl)
            HardwareBus = (Convert-PcnDisplayString -Value $audit.HardwareBus)
            HardwareVendorId = (Convert-PcnDisplayString -Value $audit.HardwareVendorId)
            HardwareDeviceId = (Convert-PcnDisplayString -Value $audit.HardwareDeviceId)
            HardwareProductId = (Convert-PcnDisplayString -Value $audit.HardwareProductId)
            CandidateCategory = (Convert-PcnDisplayString -Value $assessment.Category)
            FilterReason = (Convert-PcnDisplayString -Value $assessment.Reason)
            DeviceName = $deviceName
            FriendlyName = $friendlyName
            DeviceClass = $deviceClass
            Manufacturer = $manufacturer
            DriverProviderName = $driverProviderName
            DriverVersion = (Convert-PcnDisplayString -Value (Get-PcnObjectPropertyValue -InputObject $driver -Name 'DriverVersion' -Default ''))
            DriverDate = (Convert-PcnWmiDate -Value (Get-PcnObjectPropertyValue -InputObject $driver -Name 'DriverDate'))
            InfName = (Convert-PcnDisplayString -Value (Get-PcnObjectPropertyValue -InputObject $driver -Name 'InfName' -Default ''))
            IsSigned = (Convert-PcnDisplayString -Value (Get-PcnObjectPropertyValue -InputObject $driver -Name 'IsSigned' -Default ''))
            Signer = (Convert-PcnDisplayString -Value (Get-PcnObjectPropertyValue -InputObject $driver -Name 'Signer' -Default ''))
            Status = (Convert-PcnDisplayString -Value (Get-PcnObjectPropertyValue -InputObject $entity -Name 'Status' -Default ''))
            ConfigManagerErrorCode = (Convert-PcnDisplayString -Value (Get-PcnObjectPropertyValue -InputObject $entity -Name 'ConfigManagerErrorCode' -Default ''))
            Service = (Convert-PcnDisplayString -Value (Get-PcnObjectPropertyValue -InputObject $entity -Name 'Service' -Default ''))
            ClassGuid = (Convert-PcnDisplayString -Value (Get-PcnObjectPropertyValue -InputObject $entity -Name 'ClassGuid' -Default ''))
            Enumerator = (Get-PcnDeviceEnumerator -DeviceId $deviceId)
            DeviceID = $deviceId
            HardwareIDs = (Join-PcnReportList -Values $hardwareIds)
            CompatibleIDs = (Join-PcnReportList -Values $compatibleIds)
        }) | Out-Null
    }

    $candidateDevices = @($devices | Where-Object { $_.UpdateCandidate })
    $candidateByCategory = @($candidateDevices | Group-Object CandidateCategory | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{
            Category = $_.Name
            Count = $_.Count
        }
    })

    $candidateByProvider = @($candidateDevices | Group-Object DriverProviderName | Sort-Object Count -Descending | Select-Object -First 20 | ForEach-Object {
        [pscustomobject]@{
            Provider = if ([string]::IsNullOrWhiteSpace($_.Name)) { '(blank)' } else { $_.Name }
            Count = $_.Count
        }
    })

    $auditCandidates = @($devices | Where-Object { $_.AuditCandidate })
    $auditByPriority = @($auditCandidates | Group-Object AuditPriority | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{
            Priority = $_.Name
            Count = $_.Count
        }
    })

    $auditBySource = @($auditCandidates | Group-Object PrimarySourceName | Sort-Object Count -Descending | Select-Object -First 20 | ForEach-Object {
        [pscustomobject]@{
            Source = if ([string]::IsNullOrWhiteSpace($_.Name)) { '(manual review)' } else { $_.Name }
            Count = $_.Count
        }
    })

    $topAuditCandidates = @($auditCandidates |
        Sort-Object @{ Expression = {
            switch ($_.AuditPriority) {
                'High' { 0 }
                'Medium' { 1 }
                default { 2 }
            }
        } }, DeviceClass, DeviceName |
        Select-Object -First 20 DeviceName, DeviceClass, DriverProviderName, DriverVersion, AuditPriority, PrimarySourceName, HardwareVendorId, HardwareDeviceId, HardwareProductId)

    $biosVersionText = ''
    $biosReleaseDateText = ''

    try {
        if ($null -ne $bios -and $null -ne $bios.BIOSVersion) {
            $biosVersionItems = @($bios.BIOSVersion | Where-Object { -not [string]::IsNullOrWhiteSpace($_.ToString()) } | ForEach-Object { $_.ToString().Trim() } | Select-Object -Unique)
            $biosVersionText = $biosVersionItems -join ' | '
        }
    }
    catch {
        $biosVersionText = ''
    }

    try {
        if ($null -ne $bios) {
            $biosReleaseDateText = Convert-PcnWmiDate -Value $bios.ReleaseDate
        }
    }
    catch {
        $biosReleaseDateText = ''
    }

    $systemInfo = New-Object psobject
    $systemInfo | Add-Member -MemberType NoteProperty -Name ComputerName -Value (Convert-PcnDisplayString -Value (Get-PcnObjectPropertyValue -InputObject $computer -Name 'Name' -Default $env:COMPUTERNAME))
    $systemInfo | Add-Member -MemberType NoteProperty -Name Manufacturer -Value (Convert-PcnDisplayString -Value (Get-PcnObjectPropertyValue -InputObject $computer -Name 'Manufacturer' -Default ''))
    $systemInfo | Add-Member -MemberType NoteProperty -Name Model -Value (Convert-PcnDisplayString -Value (Get-PcnObjectPropertyValue -InputObject $computer -Name 'Model' -Default ''))
    $systemInfo | Add-Member -MemberType NoteProperty -Name SystemType -Value (Convert-PcnDisplayString -Value (Get-PcnObjectPropertyValue -InputObject $computer -Name 'SystemType' -Default ''))
    $systemInfo | Add-Member -MemberType NoteProperty -Name SystemSKUNumber -Value (Convert-PcnDisplayString -Value (Get-PcnObjectPropertyValue -InputObject $computer -Name 'SystemSKUNumber' -Default ''))
    $systemInfo | Add-Member -MemberType NoteProperty -Name BaseBoardManufacturer -Value (Convert-PcnDisplayString -Value (Get-PcnObjectPropertyValue -InputObject $baseBoard -Name 'Manufacturer' -Default ''))
    $systemInfo | Add-Member -MemberType NoteProperty -Name BaseBoardProduct -Value (Convert-PcnDisplayString -Value (Get-PcnObjectPropertyValue -InputObject $baseBoard -Name 'Product' -Default ''))
    $systemInfo | Add-Member -MemberType NoteProperty -Name BiosManufacturer -Value (Convert-PcnDisplayString -Value (Get-PcnObjectPropertyValue -InputObject $bios -Name 'Manufacturer' -Default ''))
    $systemInfo | Add-Member -MemberType NoteProperty -Name BiosVersion -Value $biosVersionText
    $systemInfo | Add-Member -MemberType NoteProperty -Name BiosReleaseDate -Value $biosReleaseDateText
    $systemInfo | Add-Member -MemberType NoteProperty -Name OsCaption -Value (Convert-PcnDisplayString -Value (Get-PcnObjectPropertyValue -InputObject $os -Name 'Caption' -Default ''))
    $systemInfo | Add-Member -MemberType NoteProperty -Name OsVersion -Value (Convert-PcnDisplayString -Value (Get-PcnObjectPropertyValue -InputObject $os -Name 'Version' -Default ''))
    $systemInfo | Add-Member -MemberType NoteProperty -Name OsBuildNumber -Value (Convert-PcnDisplayString -Value (Get-PcnObjectPropertyValue -InputObject $os -Name 'BuildNumber' -Default ''))

    $summaryInfo = New-Object psobject
    $summaryInfo | Add-Member -MemberType NoteProperty -Name TotalDevices -Value $devices.Count
    $summaryInfo | Add-Member -MemberType NoteProperty -Name CandidateDevices -Value $candidateDevices.Count
    $summaryInfo | Add-Member -MemberType NoteProperty -Name AuditCandidateDevices -Value $auditCandidates.Count
    $summaryInfo | Add-Member -MemberType NoteProperty -Name HighPriorityAuditCandidates -Value (@($auditCandidates | Where-Object { $_.AuditPriority -eq 'High' }).Count)
    $summaryInfo | Add-Member -MemberType NoteProperty -Name FilteredOrOtherDevices -Value ($devices.Count - $candidateDevices.Count)
    $summaryInfo | Add-Member -MemberType NoteProperty -Name CandidateByCategory -Value @($candidateByCategory | ForEach-Object { $_ })
    $summaryInfo | Add-Member -MemberType NoteProperty -Name CandidateByProvider -Value @($candidateByProvider | ForEach-Object { $_ })
    $summaryInfo | Add-Member -MemberType NoteProperty -Name AuditByPriority -Value @($auditByPriority | ForEach-Object { $_ })
    $summaryInfo | Add-Member -MemberType NoteProperty -Name AuditBySource -Value @($auditBySource | ForEach-Object { $_ })
    $summaryInfo | Add-Member -MemberType NoteProperty -Name TopAuditCandidates -Value @($topAuditCandidates | ForEach-Object { $_ })
    $summaryInfo | Add-Member -MemberType NoteProperty -Name SourceCatalog -Value @(Get-PcnDriverAuditSourceCatalog | ForEach-Object { $_ })
    $summaryInfo | Add-Member -MemberType NoteProperty -Name Note -Value 'Driver Audit is report-only. AuditCandidate means the device has a high-confidence hardware ID worth comparing against responsible official sources. It does not mean the installed driver is outdated.'

    $reportObject = New-Object psobject
    $reportObject | Add-Member -MemberType NoteProperty -Name ReportSchemaVersion -Value 2
    $reportObject | Add-Member -MemberType NoteProperty -Name ReportTime -Value $reportTime.ToString('s')
    $reportObject | Add-Member -MemberType NoteProperty -Name System -Value $systemInfo
    $reportObject | Add-Member -MemberType NoteProperty -Name Summary -Value $summaryInfo
    $reportObject | Add-Member -MemberType NoteProperty -Name Devices -Value @($devices | ForEach-Object { $_ })

    return $reportObject
}

function Export-PcnDriverInventoryReport {
    $paths = Initialize-PcnWinUpdateFolders
    $report = Get-PcnDriverInventoryReport
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $basePath = Join-Path $paths.DriverReportRoot "DriverAudit-$stamp"
    $csvPath = "$basePath.csv"
    $jsonPath = "$basePath.json"
    $summaryPath = "$basePath.txt"

    $report.Devices | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    $summaryLines = New-Object System.Collections.Generic.List[string]
    $summaryLines.Add('PcNinja WinUpdate Tool - Driver Audit Report') | Out-Null
    $summaryLines.Add('Report-only. No third-party drivers were downloaded or installed.') | Out-Null
    $summaryLines.Add("Generated: $($report.ReportTime)") | Out-Null
    $summaryLines.Add("Computer: $($report.System.ComputerName)") | Out-Null
    $summaryLines.Add("System: $($report.System.Manufacturer) $($report.System.Model)") | Out-Null
    $summaryLines.Add("BIOS: $($report.System.BiosManufacturer) $($report.System.BiosVersion) $($report.System.BiosReleaseDate)") | Out-Null
    $summaryLines.Add("OS: $($report.System.OsCaption) $($report.System.OsVersion) build $($report.System.OsBuildNumber)") | Out-Null
    $summaryLines.Add('') | Out-Null
    $summaryLines.Add("Total signed driver entries: $($report.Summary.TotalDevices)") | Out-Null
    $summaryLines.Add("Vendor-driver comparison candidates: $($report.Summary.CandidateDevices)") | Out-Null
    $summaryLines.Add("Audit candidates: $($report.Summary.AuditCandidateDevices)") | Out-Null
    $summaryLines.Add("High-priority audit candidates: $($report.Summary.HighPriorityAuditCandidates)") | Out-Null
    $summaryLines.Add("Filtered/other entries: $($report.Summary.FilteredOrOtherDevices)") | Out-Null
    $summaryLines.Add('') | Out-Null
    $summaryLines.Add('Candidates by category:') | Out-Null

    foreach ($item in $report.Summary.CandidateByCategory) {
        $summaryLines.Add("  $($item.Category): $($item.Count)") | Out-Null
    }

    $summaryLines.Add('') | Out-Null
    $summaryLines.Add('Top candidate providers:') | Out-Null

    foreach ($item in $report.Summary.CandidateByProvider) {
        $summaryLines.Add("  $($item.Provider): $($item.Count)") | Out-Null
    }

    $summaryLines.Add('') | Out-Null
    $summaryLines.Add('Audit candidates by priority:') | Out-Null

    foreach ($item in $report.Summary.AuditByPriority) {
        $summaryLines.Add("  $($item.Priority): $($item.Count)") | Out-Null
    }

    $summaryLines.Add('') | Out-Null
    $summaryLines.Add('Audit candidates by primary source:') | Out-Null

    foreach ($item in $report.Summary.AuditBySource) {
        $summaryLines.Add("  $($item.Source): $($item.Count)") | Out-Null
    }

    $summaryLines.Add('') | Out-Null
    $summaryLines.Add('Top audit candidates:') | Out-Null

    foreach ($item in $report.Summary.TopAuditCandidates) {
        $hardware = @($item.HardwareVendorId, $item.HardwareDeviceId, $item.HardwareProductId) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
        $summaryLines.Add("  [$($item.AuditPriority)] $($item.DeviceName) | $($item.DeviceClass) | $($item.DriverProviderName) $($item.DriverVersion) | Source: $($item.PrimarySourceName) | HW: $($hardware -join '/')") | Out-Null
    }

    $summaryLines.Add('') | Out-Null
    $summaryLines.Add('Responsible source catalog:') | Out-Null

    foreach ($source in $report.Summary.SourceCatalog) {
        $summaryLines.Add("  $($source.SourceName): $($source.SourceUrl)") | Out-Null
    }

    $summaryLines.Add('') | Out-Null
    $summaryLines.Add($report.Summary.Note) | Out-Null
    $summaryLines.Add('') | Out-Null
    $summaryLines.Add("CSV: $csvPath") | Out-Null
    $summaryLines.Add("JSON: $jsonPath") | Out-Null

    Set-Content -LiteralPath $summaryPath -Value $summaryLines -Encoding UTF8

    Write-PcnWinUpdateLog -Message "Driver audit report created. Audit candidates: $($report.Summary.AuditCandidateDevices). CSV: $csvPath" -EventID 1101

    [pscustomobject]@{
        CsvPath = $csvPath
        JsonPath = $jsonPath
        SummaryPath = $summaryPath
        TotalDevices = $report.Summary.TotalDevices
        CandidateDevices = $report.Summary.CandidateDevices
        AuditCandidateDevices = $report.Summary.AuditCandidateDevices
        HighPriorityAuditCandidates = $report.Summary.HighPriorityAuditCandidates
    }
}

function Get-PcnRecentLog {
    param(
        [int]$Tail = 200
    )

    $paths = Initialize-PcnWinUpdateFolders

    if (-not (Test-Path -LiteralPath $paths.LogFile)) {
        return 'No log entries yet.'
    }

    return (Get-Content -LiteralPath $paths.LogFile -Tail $Tail) -join [Environment]::NewLine
}

function Start-PcnWindowsUpdateInstall {
    param(
        [switch]$Silent,
        [switch]$ShowRebootPrompt,
        [switch]$AllowStopBackgroundActivity,
        [switch]$InstallFirmwareUpdates,
        [ValidateRange(1, 10)]
        [int]$MaxPasses = 3
    )

    if (-not (Test-PcnAdministrator)) {
        throw 'Administrator privileges are required to install Windows updates.'
    }

    try {
        $dotNetVersion = Get-PcnDotNetFrameworkVersion
        Write-PcnWinUpdateLog -Message "Installed .NET Framework version: $dotNetVersion" -EventID 1001

        $preflight = Invoke-PcnWindowsUpdatePreflight -AllowStopBackgroundActivity:$AllowStopBackgroundActivity
        if (-not $preflight.CanContinue) {
            Write-PcnWinUpdateLog -Message "Windows Update run skipped: $($preflight.Message)" -EntryType Warning -EventID 1068
            return [pscustomobject]@{
                Result = $preflight.Result
                UpdatesFound = 0
                PassesCompleted = 0
                RebootRequired = $false
                Message = $preflight.Message
            }
        }

        $network = Test-PcnNetworkReadiness
        if ($network.Ready) {
            Write-PcnWinUpdateLog -Message "Network pre-check passed. $($network.Message)" -EventID 1002
        }
        else {
            Write-PcnWinUpdateLog -Message "Network pre-check warning. $($network.Message)" -EntryType Warning -EventID 1002
        }

        Initialize-PcnWindowsUpdateServices
        Enable-PcnMicrosoftUpdate | Out-Null

        if ($InstallFirmwareUpdates) {
            Write-PcnWinUpdateLog -Message 'Firmware/BIOS update installation is enabled for this run.' -EntryType Warning -EventID 1087
        }
        else {
            Write-PcnWinUpdateLog -Message 'Firmware/BIOS candidates will be detected and logged, but skipped unless firmware installation is enabled.' -EventID 1087
        }

        $totalUpdatesFound = 0
        $lastInstallStatus = 'NoUpdates'
        $passesCompleted = 0

        for ($pass = 1; $pass -le $MaxPasses; $pass++) {
            $pendingBeforePass = Test-PcnPendingReboot
            Write-PcnPendingRebootDiagnosticLog -PendingState $pendingBeforePass

            if ($pendingBeforePass.Pending) {
                Write-PcnWinUpdateLog -Message "Update pass $pass stopped before scanning because a restart is already pending. Reasons: $($pendingBeforePass.Reasons -join '; ')" -EntryType Warning -EventID 1016
                return [pscustomobject]@{
                    Result = 'RebootRequired'
                    UpdatesFound = $totalUpdatesFound
                    PassesCompleted = $passesCompleted
                    RebootRequired = $true
                    Message = 'Restart required before continuing update scan.'
                }
            }

            Write-PcnWinUpdateLog -Message "Starting Windows Update pass $pass of $MaxPasses." -EventID 1002
            $updateSession = New-Object -ComObject Microsoft.Update.Session
            $updateSession.ClientApplicationID = 'PcNinja WinUpdate Tool'
            $updateSearcher = $updateSession.CreateUpdateSearcher()

            $searchBuckets = @(
                (Invoke-PcnUpdateSearchBucket -Searcher $updateSearcher -Criteria 'IsInstalled=0 and IsHidden=0' -Source 'Broad' -Label "Pass $pass broad discovery"),
                (Invoke-PcnUpdateSearchBucket -Searcher $updateSearcher -Criteria "IsInstalled=0 and IsHidden=0 and Type='Driver'" -Source 'Driver' -Label "Pass $pass explicit driver discovery"),
                (Invoke-PcnUpdateSearchBucket -Searcher $updateSearcher -Criteria 'IsInstalled=0 and IsHidden=0 and BrowseOnly=1' -Source 'Optional' -Label "Pass $pass explicit optional discovery")
            )

            $usableBuckets = @($searchBuckets | Where-Object { $null -ne $_.Result })
            if ($usableBuckets.Count -eq 0) {
                $errors = @($searchBuckets | Where-Object { $_.Error } | Select-Object -ExpandProperty Error)
                throw "Windows Update search returned no usable results. $($errors -join ' | ')"
            }

            $mergedUpdates = Get-PcnMergedUpdateList -SearchBuckets $usableBuckets
            Write-PcnWinUpdateLog -Message "Pass $pass merged Windows, optional, and driver candidate count: $($mergedUpdates.Count)." -EventID 1004

            if ($mergedUpdates.Count -eq 0) {
                $message = if ($passesCompleted -eq 0) {
                    'No applicable Windows, optional, or driver updates found.'
                }
                else {
                    "No remaining applicable Windows, optional, or driver updates after $passesCompleted completed pass(es)."
                }

                Write-PcnWinUpdateLog -Message $message -EntryType Information -EventID 1003
                return [pscustomobject]@{
                    Result = if ($passesCompleted -eq 0) { 'NoUpdates' } else { $lastInstallStatus }
                    UpdatesFound = $totalUpdatesFound
                    PassesCompleted = $passesCompleted
                    RebootRequired = $false
                    Message = $message
                }
            }

            $updateCollection = New-Object -ComObject Microsoft.Update.UpdateColl
            $skippedFirmwareCount = 0

            foreach ($entry in $mergedUpdates) {
                $update = $entry.Update
                $sources = $entry.Sources -join ', '
                $isFirmware = Test-PcnFirmwareUpdate -Update $update

                if ($isFirmware -and -not $InstallFirmwareUpdates) {
                    $skippedFirmwareCount++
                    Write-PcnWinUpdateLog -Message "Pass $pass skipping firmware/BIOS candidate because firmware installation is disabled: $($update.Title) | Sources: $sources" -EntryType Warning -EventID 1088
                    continue
                }

                if (-not $update.EulaAccepted) {
                    Write-PcnWinUpdateLog -Message "Accepting EULA for update: $($update.Title)" -EventID 1005
                    $update.AcceptEula()
                }

                $kbList = Convert-PcnUpdateKbList -Update $update
                $typeName = Get-PcnUpdateTypeName -Update $update
                $categories = Convert-PcnUpdateCategoryList -Update $update
                $flags = Convert-PcnUpdateFlagList -Update $update
                $firmwareCandidate = if ($isFirmware) { 'Yes' } else { 'No' }
                Write-PcnWinUpdateLog -Message "Pass $pass queueing update: $($update.Title) | $kbList | Type: $typeName | Categories: $categories | Flags: $flags | Sources: $sources | FirmwareCandidate: $firmwareCandidate" -EventID 1006
                $updateCollection.Add($update) | Out-Null
            }

            $totalUpdatesFound += $updateCollection.Count

            if ($updateCollection.Count -eq 0) {
                $message = if ($skippedFirmwareCount -gt 0) {
                    "Only firmware/BIOS candidate update(s) were found ($skippedFirmwareCount), and firmware installation is disabled."
                }
                else {
                    'No installable Windows, optional, or driver updates remained after filtering.'
                }

                Write-PcnWinUpdateLog -Message $message -EntryType Warning -EventID 1003
                return [pscustomobject]@{
                    Result = if ($passesCompleted -eq 0) { 'NoUpdates' } else { $lastInstallStatus }
                    UpdatesFound = $totalUpdatesFound
                    PassesCompleted = $passesCompleted
                    RebootRequired = $false
                    Message = $message
                }
            }

            Write-PcnWinUpdateLog -Message "Pass $pass downloading $($updateCollection.Count) update(s) as one Windows Update batch. Firmware skipped: $skippedFirmwareCount." -EventID 1007
            $downloader = $updateSession.CreateUpdateDownloader()
            $downloader.Updates = $updateCollection
            $downloadResult = $downloader.Download()
            $downloadStatus = Convert-PcnUpdateResultCode -ResultCode $downloadResult.ResultCode
            Write-PcnWinUpdateLog -Message "Pass $pass download result: $downloadStatus" -EventID 1008

            if ($downloadResult.ResultCode -notin @(2, 3)) {
                Write-PcnWinUpdateLog -Message "Pass $pass download did not complete successfully. Result: $downloadStatus" -EntryType Error -EventID 1009
                return [pscustomobject]@{
                    Result = $downloadStatus
                    UpdatesFound = $totalUpdatesFound
                    PassesCompleted = $passesCompleted
                    RebootRequired = $false
                    Message = "Download did not complete successfully. Result: $downloadStatus"
                }
            }

            $installCollection = New-Object -ComObject Microsoft.Update.UpdateColl
            foreach ($update in $updateCollection) {
                if ($update.IsDownloaded) {
                    $installCollection.Add($update) | Out-Null
                }
                else {
                    Write-PcnWinUpdateLog -Message "Pass $pass skipping install because update was not downloaded: $($update.Title)" -EntryType Warning -EventID 1010
                }
            }

            if ($installCollection.Count -eq 0) {
                Write-PcnWinUpdateLog -Message "Pass $pass had no successfully downloaded updates to install." -EntryType Error -EventID 1010
                return [pscustomobject]@{
                    Result = 'NoDownloadedUpdates'
                    UpdatesFound = $totalUpdatesFound
                    PassesCompleted = $passesCompleted
                    RebootRequired = $false
                    Message = 'No updates were downloaded successfully.'
                }
            }

            Write-PcnWinUpdateLog -Message "Pass $pass installing $($installCollection.Count) update(s)." -EventID 1010
            $installer = $updateSession.CreateUpdateInstaller()
            $installer.Updates = $installCollection
            $installResult = $installer.Install()
            $installStatus = Convert-PcnUpdateResultCode -ResultCode $installResult.ResultCode
            $lastInstallStatus = $installStatus
            $passesCompleted = $pass

            switch ($installResult.ResultCode) {
                2 {
                    Write-PcnWinUpdateLog -Message "Pass $pass installation completed successfully." -EntryType Information -EventID 1011
                }
                3 {
                    Write-PcnWinUpdateLog -Message "Pass $pass installation completed with errors." -EntryType Warning -EventID 1012
                }
                4 {
                    Write-PcnWinUpdateLog -Message "Pass $pass installation failed." -EntryType Error -EventID 1013
                }
                5 {
                    Write-PcnWinUpdateLog -Message "Pass $pass installation was aborted." -EntryType Error -EventID 1014
                }
                default {
                    Write-PcnWinUpdateLog -Message "Pass $pass returned unknown installation result: $($installResult.ResultCode)" -EntryType Warning -EventID 1015
                }
            }

            $verificationSession = New-Object -ComObject Microsoft.Update.Session
            $verificationSession.ClientApplicationID = 'PcNinja WinUpdate Tool'
            $verificationSearcher = $verificationSession.CreateUpdateSearcher()
            $verificationResult = $verificationSearcher.Search('IsInstalled=0 and IsHidden=0')
            Write-PcnUpdateDiscoveryLog -SearchResult $verificationResult -Label "Post-pass $pass verification"

            $pendingAfterPass = Test-PcnPendingReboot
            Write-PcnPendingRebootDiagnosticLog -PendingState $pendingAfterPass

            if ($installResult.RebootRequired -or $pendingAfterPass.Pending) {
                Write-PcnWinUpdateLog -Message "Pass $pass reached a reboot boundary. Remaining updates may appear after restart." -EntryType Warning -EventID 1016

                if ($pendingAfterPass.Pending) {
                    Write-PcnWinUpdateLog -Message "Pending reboot reasons: $($pendingAfterPass.Reasons -join '; ')" -EntryType Warning -EventID 1016
                }

                if ($ShowRebootPrompt -and -not $Silent) {
                    try {
                        Add-Type -AssemblyName PresentationFramework
                        [System.Windows.MessageBox]::Show(
                            "Updates have been installed. A restart is required before the next update scan can continue.`nPlease save your work and restart as soon as possible.",
                            'PcNinja Update Notice',
                            'OK',
                            'Information'
                        ) | Out-Null
                    }
                    catch {
                        Write-PcnWinUpdateLog -Message "Could not display reboot prompt: $($_.Exception.Message)" -EntryType Warning -EventID 1017
                    }
                }

                return [pscustomobject]@{
                    Result = 'RebootRequired'
                    UpdatesFound = $totalUpdatesFound
                    PassesCompleted = $passesCompleted
                    RebootRequired = $true
                    Message = 'Restart required before continuing update scan.'
                }
            }

            if ($installResult.ResultCode -notin @(2, 3)) {
                return [pscustomobject]@{
                    Result = $installStatus
                    UpdatesFound = $totalUpdatesFound
                    PassesCompleted = $passesCompleted
                    RebootRequired = $false
                    Message = "Installation result: $installStatus"
                }
            }
        }

        Write-PcnWinUpdateLog -Message "Maximum update passes reached ($MaxPasses). Run again after reviewing the verification log, or restart if Windows requests it." -EntryType Warning -EventID 1019
        return [pscustomobject]@{
            Result = 'MaxPassesReached'
            UpdatesFound = $totalUpdatesFound
            PassesCompleted = $passesCompleted
            RebootRequired = $false
            Message = "Maximum update passes reached: $MaxPasses"
        }
    }
    catch {
        $friendlyMessage = Convert-PcnExceptionMessage -Exception $_.Exception
        Write-PcnWinUpdateLog -Message "Windows Update run failed: $friendlyMessage" -EntryType Error -EventID 1099
        throw
    }
}

function Test-PcnRetryableException {
    param(
        [Parameter(Mandatory = $true)]
        [System.Exception]$Exception
    )

    $hresult = $Exception.HResult

    if ($hresult -eq 0) {
        return $false
    }

    $unsigned = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$hresult), 0)
    $hex = '0x{0:X8}' -f $unsigned

    return ($hex -in @(
        '0x8024402C',
        '0x8024401C',
        '0x80244022',
        '0x80072EE2',
        '0x80072EFD',
        '0x80072EFE'
    ))
}

function Complete-PcnManagedRunState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunType,

        [Parameter(Mandatory = $true)]
        [string]$Result,

        [string]$Message = '',

        [bool]$RebootRequired = $false,

        [bool]$ClearRetry = $false
    )

    $state = Get-PcnWinUpdateState
    $state.LastRunFinished = (Get-Date).ToString('s')
    $state.LastRunType = $RunType
    $state.LastResult = $Result
    $state.LastMessage = $Message
    $state.LastRebootRequired = $RebootRequired

    if ($Result -in @('Succeeded', 'SucceededWithErrors', 'NoUpdates')) {
        $state.LastSuccessfulRun = (Get-Date).ToString('s')
    }

    if ($ClearRetry) {
        $state.LastRetryScheduled = $null
        $state.LastRetryReason = $null
        $state.RetryCount = 0
        Unregister-PcnWinUpdateRetryTask
    }

    Save-PcnWinUpdateState -State $state
}

function Invoke-PcnManagedWindowsUpdateRun {
    param(
        [ValidateSet('Manual', 'Scheduled', 'Retry', 'Startup', 'Wake')]
        [string]$RunType = 'Scheduled',

        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [switch]$Silent,

        [switch]$ShowRebootPrompt,

        [switch]$AllowStopBackgroundActivity
    )

    $config = Get-PcnWinUpdateConfig
    $previousState = Get-PcnWinUpdateState
    $lock = New-PcnRunLock -RunType $RunType

    if (-not $lock.Acquired) {
        return [pscustomobject]@{
            Result = 'AlreadyRunning'
            UpdatesFound = 0
            PassesCompleted = 0
            RebootRequired = $false
            Message = 'Another run is already active.'
        }
    }

    try {
        if ($RunType -notin @('Manual', 'Retry')) {
            $cooldownMinutes = [Math]::Max(0, [int]$config.MinimumCooldownMinutes)
            $lastRunFinished = Get-PcnDateOrNull -Value $previousState.LastRunFinished

            if ($cooldownMinutes -gt 0 -and $lastRunFinished) {
                $minutesSinceLastRun = ((Get-Date) - $lastRunFinished).TotalMinutes

                if ($minutesSinceLastRun -lt $cooldownMinutes) {
                    $message = "Cooldown active. Last run finished $([int]$minutesSinceLastRun) minute(s) ago; minimum cooldown is $cooldownMinutes minute(s)."
                    Write-PcnWinUpdateLog -Message $message -EntryType Warning -EventID 1071
                    Complete-PcnManagedRunState -RunType $RunType -Result 'CooldownActive' -Message $message
                    return [pscustomobject]@{
                        Result = 'CooldownActive'
                        UpdatesFound = 0
                        PassesCompleted = 0
                        RebootRequired = $false
                        Message = $message
                    }
                }
            }
        }

        $state = Get-PcnWinUpdateState
        $state.LastRunStarted = (Get-Date).ToString('s')
        $state.LastRunType = $RunType
        $state.LastResult = 'Running'
        $state.LastMessage = ''

        if ($RunType -ne 'Retry') {
            $state.RetryCount = 0
            $state.LastRetryScheduled = $null
            $state.LastRetryReason = $null
            Unregister-PcnWinUpdateRetryTask
        }

        Save-PcnWinUpdateState -State $state

        $pendingReboot = Test-PcnPendingReboot
        Write-PcnPendingRebootDiagnosticLog -PendingState $pendingReboot

        if ($pendingReboot.Pending) {
            $message = "Restart is already pending. Reasons: $($pendingReboot.Reasons -join '; ')"
            Write-PcnWinUpdateLog -Message $message -EntryType Warning -EventID 1072
            Complete-PcnManagedRunState -RunType $RunType -Result 'RebootRequired' -Message $message -RebootRequired $true -ClearRetry $true
            return [pscustomobject]@{
                Result = 'RebootRequired'
                UpdatesFound = 0
                PassesCompleted = 0
                RebootRequired = $true
                Message = $message
            }
        }

        $network = Test-PcnNetworkReadiness
        if (-not $network.Ready) {
            $retry = Request-PcnWinUpdateRetry -ScriptPath $ScriptPath -Config $config -Reason "Network not ready. $($network.Message)"
            Complete-PcnManagedRunState -RunType $RunType -Result $retry.Result -Message $retry.Message
            return [pscustomobject]@{
                Result = $retry.Result
                UpdatesFound = 0
                PassesCompleted = 0
                RebootRequired = $false
                Message = $retry.Message
            }
        }

        $activity = Get-PcnWindowsUpdateActivity
        $canSnoozeWindowsUpdate = ($RunType -eq 'Manual' -and $AllowStopBackgroundActivity)
        if ($activity.IsInstalling -and -not $canSnoozeWindowsUpdate) {
            $retry = Request-PcnWinUpdateRetry -ScriptPath $ScriptPath -Config $config -Reason $activity.Message
            Complete-PcnManagedRunState -RunType $RunType -Result $retry.Result -Message $retry.Message
            return [pscustomobject]@{
                Result = $retry.Result
                UpdatesFound = 0
                PassesCompleted = 0
                RebootRequired = $false
                Message = $retry.Message
            }
        }

        if ($activity.HasBackgroundActivity -and -not $canSnoozeWindowsUpdate) {
            $retry = Request-PcnWinUpdateRetry -ScriptPath $ScriptPath -Config $config -Reason $activity.Message
            Complete-PcnManagedRunState -RunType $RunType -Result $retry.Result -Message $retry.Message
            return [pscustomobject]@{
                Result = $retry.Result
                UpdatesFound = 0
                PassesCompleted = 0
                RebootRequired = $false
                Message = $retry.Message
            }
        }

        if ($RunType -ne 'Retry') {
            $state = Get-PcnWinUpdateState
            $state.RetryCount = 0
            $state.LastRetryScheduled = $null
            $state.LastRetryReason = $null
            Save-PcnWinUpdateState -State $state
            Unregister-PcnWinUpdateRetryTask
        }

        $result = Start-PcnWindowsUpdateInstall -Silent:$Silent -ShowRebootPrompt:$ShowRebootPrompt -AllowStopBackgroundActivity:$AllowStopBackgroundActivity -InstallFirmwareUpdates:([bool]$config.InstallFirmwareUpdates)

        if ($result.Result -in @('SkippedInstalling', 'SkippedBackgroundActivity')) {
            $retry = Request-PcnWinUpdateRetry -ScriptPath $ScriptPath -Config $config -Reason $result.Message
            Complete-PcnManagedRunState -RunType $RunType -Result $retry.Result -Message $retry.Message
            $result.Result = $retry.Result
            $result.Message = $retry.Message
            return $result
        }

        $clearRetry = ($result.Result -in @('Succeeded', 'SucceededWithErrors', 'NoUpdates', 'RebootRequired', 'MaxPassesReached'))
        Complete-PcnManagedRunState -RunType $RunType -Result $result.Result -Message $result.Message -RebootRequired ([bool]$result.RebootRequired) -ClearRetry:$clearRetry
        return $result
    }
    catch {
        $friendlyMessage = Convert-PcnExceptionMessage -Exception $_.Exception

        if (Test-PcnRetryableException -Exception $_.Exception) {
            $retry = Request-PcnWinUpdateRetry -ScriptPath $ScriptPath -Config $config -Reason $friendlyMessage
            Complete-PcnManagedRunState -RunType $RunType -Result $retry.Result -Message $retry.Message
            return [pscustomobject]@{
                Result = $retry.Result
                UpdatesFound = 0
                PassesCompleted = 0
                RebootRequired = $false
                Message = $retry.Message
            }
        }

        Complete-PcnManagedRunState -RunType $RunType -Result 'Failed' -Message $friendlyMessage
        throw
    }
    finally {
        Remove-PcnRunLock
    }
}

Export-ModuleMember -Function `
    Set-PcnConsoleLogEnabled, `
    Test-PcnAdministrator, `
    Get-PcnWinUpdatePaths, `
    Initialize-PcnWinUpdateFolders, `
    Get-PcnPowershellPath, `
    Convert-PcnExceptionMessage, `
    Convert-PcnUpdateKbList, `
    Convert-PcnUpdateCategoryList, `
    Get-PcnUpdateTypeName, `
    Write-PcnUpdateDiscoveryLog, `
    Enable-PcnMicrosoftUpdate, `
    Test-PcnNetworkReadiness, `
    Initialize-PcnWindowsUpdateServices, `
    Get-PcnWindowsUpdateActivity, `
    Stop-PcnWindowsUpdateBackgroundActivity, `
    Invoke-PcnWindowsUpdateReset, `
    Invoke-PcnWindowsUpdatePreflight, `
    Write-PcnWinUpdateLog, `
    Get-PcnDotNetFrameworkVersion, `
    Get-PcnWinUpdateConfig, `
    Save-PcnWinUpdateConfig, `
    Get-PcnWinUpdateState, `
    Save-PcnWinUpdateState, `
    Get-PcnDateOrNull, `
    New-PcnRunLock, `
    Remove-PcnRunLock, `
    Get-PcnRetryDelayMinutes, `
    New-PcnScheduledTaskXml, `
    Register-PcnWinUpdateRetryTask, `
    Unregister-PcnWinUpdateRetryTask, `
    Request-PcnWinUpdateRetry, `
    Get-PcnScheduledTaskStatusByName, `
    Get-PcnScheduledTaskStatus, `
    Get-PcnRetryTaskStatus, `
    Get-PcnRunOnceTaskStatus, `
    Test-PcnPendingReboot, `
    Restart-PcnComputerNow, `
    Register-PcnWinUpdateScheduledTask, `
    Unregister-PcnWinUpdateScheduledTask, `
    Start-PcnWinUpdateRunOnceTask, `
    Unregister-PcnWinUpdateRunOnceTask, `
    Get-PcnDriverInventoryReport, `
    Export-PcnDriverInventoryReport, `
    Get-PcnRecentLog, `
    Start-PcnWindowsUpdateInstall, `
    Invoke-PcnManagedWindowsUpdateRun


