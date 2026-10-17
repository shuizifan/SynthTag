# Windows PowerShell 5.1 compatible local diagnostics. No network requests.
$script:RuntimeLogHealthy = $false
$script:LastLogError = ''
$script:LogDirectory = ''
$script:LogRetentionDate = ''
$script:RuntimeVersion = 'unknown'
$script:RuntimeExifToolVersion = 'unavailable'
$script:RuntimeStartedAt = [DateTimeOffset]::Now.ToString('o')
$script:RuntimeSessionId = [Guid]::NewGuid().ToString('N')

function Protect-DiagnosticText {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    $value = $Text
    foreach ($privateRoot in @($env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA)) {
        if ($privateRoot) { $value = [regex]::Replace($value, [regex]::Escape($privateRoot), '<user-data>', 'IgnoreCase') }
    }
    # Covers paths belonging to another user, e.g. an exception from a shared workstation.
    $value = [regex]::Replace($value, '(?i)([A-Z]:[\\/]Users[\\/])[^\\/\r\n"<>|:]+', '$1<user>')
    $value = [regex]::Replace($value, '(?i)\bBearer\s+\S+', 'Bearer <redacted>')
    $value = [regex]::Replace($value, '(?i)(["'']?(?:password|passwd|pwd|token|access_token|refresh_token|api[_-]?key|secret|authorization|cookie)["'']?\s*[:=]\s*)(?:"(?:\\.|[^"\\\r\n])*"|''(?:\\.|[^''\\\r\n])*''|[^\s;&,}\r\n]+)', '$1<redacted>')
    $value = [regex]::Replace($value, '(?i)\b(sk-(?:proj-)?[a-z0-9_-]{12,})\b', '<redacted>')
    # Keep the share/path and filename useful; remove any embedded SMB/URL credentials.
    $value = [regex]::Replace($value, '(?i)([a-z][a-z0-9+.-]*://)[^/@\s]+:[^/@\s]+@', '$1<redacted>@')
    return $value
}

function ConvertTo-SafeDiagnosticValue {
    param($Value, [int]$Depth = 0)
    if ($null -eq $Value) { return $null }
    if ($Depth -gt 8) { return '<depth-limit>' }
    if ($Value -is [Management.Automation.ErrorRecord]) {
        return [ordered]@{
            type = $Value.Exception.GetType().FullName
            message = Protect-DiagnosticText $Value.Exception.Message
            innerMessage = if ($Value.Exception.InnerException) { Protect-DiagnosticText $Value.Exception.InnerException.Message } else { $null }
            category = [string]$Value.CategoryInfo.Category
            errorId = Protect-DiagnosticText $Value.FullyQualifiedErrorId
            scriptStackTrace = Protect-DiagnosticText $Value.ScriptStackTrace
        }
    }
    if ($Value -is [Exception]) {
        return [ordered]@{ type = $Value.GetType().FullName; message = Protect-DiagnosticText $Value.Message; stackTrace = Protect-DiagnosticText $Value.StackTrace }
    }
    if ($Value -is [Collections.IDictionary]) {
        $safe = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $safeKey = Protect-DiagnosticText ([string]$key)
            if ([string]$key -match '(?i)(password|passwd|pwd|token|api.?key|secret|authorization|cookie|credential)') {
                $safe[$safeKey] = '<redacted>'
            } else { $safe[$safeKey] = ConvertTo-SafeDiagnosticValue $Value[$key] ($Depth + 1) }
        }
        return $safe
    }
    if ($Value -is [string]) { return Protect-DiagnosticText $Value }
    if ($Value -is [Collections.IEnumerable]) {
        $safeArray = @($Value | ForEach-Object { ConvertTo-SafeDiagnosticValue $_ ($Depth + 1) })
        return ,$safeArray
    }
    if ($Value -is [bool] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [Management.Automation.PSCustomObject]) {
        $properties = @{}
        foreach ($property in $Value.PSObject.Properties) { $properties[$property.Name] = $property.Value }
        return ConvertTo-SafeDiagnosticValue $properties ($Depth + 1)
    }
    return Protect-DiagnosticText ([string]$Value)
}

function Remove-ExpiredAppLogs {
    # Thirty calendar dates: today and the preceding 29 dates, using local time.
    $cutoff = (Get-Date).Date.AddDays(-29)
    foreach ($file in @(Get-ChildItem -LiteralPath $script:LogDirectory -File -ErrorAction Stop)) {
        if ($file.Name -match '^(?:SynthTag-(\d{4}-\d{2}-\d{2})\.jsonl|launcher-(\d{4}-\d{2}-\d{2})\.log)$') {
            $dateText = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
            $date = [DateTime]::MinValue
            if ([DateTime]::TryParseExact($dateText, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$date) -and $date -lt $cutoff) {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            }
        }
    }
    $script:LogRetentionDate = (Get-Date).ToString('yyyy-MM-dd')
}

function Write-AppLog {
    param(
        [ValidateSet('INFO', 'WARNING', 'ERROR')][string]$Level = 'INFO',
        [Parameter(Mandatory = $true)][string]$Message,
        $Data = $null
    )
    try {
        if (-not $script:LogDirectory) { throw 'Runtime log directory is not initialized.' }
        [IO.Directory]::CreateDirectory($script:LogDirectory) | Out-Null
        if ($script:LogRetentionDate -ne (Get-Date).ToString('yyyy-MM-dd')) { Remove-ExpiredAppLogs }
        $record = [ordered]@{
            timestamp = [DateTimeOffset]::Now.ToString('o')
            level = $Level.ToUpperInvariant()
            version = $script:RuntimeVersion
            session = $script:RuntimeSessionId
            processId = $PID
            message = Protect-DiagnosticText $Message
            data = ConvertTo-SafeDiagnosticValue $Data
        }
        $line = ($record | ConvertTo-Json -Depth 12 -Compress) + [Environment]::NewLine
        $file = Join-Path $script:LogDirectory ('SynthTag-' + (Get-Date).ToString('yyyy-MM-dd') + '.jsonl')
        # Readers can export diagnostics; serialize writers to avoid interleaved JSON.
        $stream = $null
        for ($attempt = 0; $attempt -lt 4; $attempt++) {
            try { $stream = [IO.File]::Open($file, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::Write, [IO.FileShare]::Read); break }
            catch [IO.IOException] { if ($attempt -eq 3) { throw }; Start-Sleep -Milliseconds 30 }
        }
        try {
            $stream.Seek(0, [IO.SeekOrigin]::End) | Out-Null
            $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($line)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
        } finally { if ($stream) { $stream.Dispose() } }
        $script:RuntimeLogHealthy = $true
        $script:LastLogError = ''
    } catch {
        # Logging must never abort an image operation. The UI checks this state.
        $script:RuntimeLogHealthy = $false
        $script:LastLogError = Protect-DiagnosticText $_.Exception.Message
    }
}

function Initialize-SynthTagRuntime {
    param([Parameter(Mandatory = $true)][string]$Version, [AllowEmptyString()][string]$ExifTool)
    $script:RuntimeVersion = $Version
    $script:RuntimeExifToolVersion = 'unavailable'
    try {
        $localRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        if ($env:LOCALAPPDATA) { $localRoot = $env:LOCALAPPDATA }
        if (-not $localRoot) { throw 'Windows local application data directory is unavailable.' }
        $script:LogDirectory = Join-Path $localRoot 'SynthTag\Logs'
        [IO.Directory]::CreateDirectory($script:LogDirectory) | Out-Null
        Remove-ExpiredAppLogs
        if ($ExifTool -and [IO.File]::Exists($ExifTool)) {
            $process = New-Object Diagnostics.Process
            try {
                $process.StartInfo.FileName = $ExifTool
                $process.StartInfo.Arguments = '-ver'
                $process.StartInfo.UseShellExecute = $false
                $process.StartInfo.CreateNoWindow = $true
                $process.StartInfo.RedirectStandardOutput = $true
                $process.StartInfo.RedirectStandardError = $true
                $process.Start() | Out-Null
                $stdout = $process.StandardOutput.ReadToEndAsync()
                $stderr = $process.StandardError.ReadToEndAsync()
                if (-not $process.WaitForExit(10000)) { $process.Kill(); throw 'ExifTool version probe timed out.' }
                if ($process.ExitCode -eq 0) { $script:RuntimeExifToolVersion = Protect-DiagnosticText $stdout.Result.Trim() }
                else { Write-AppLog -Level WARNING -Message 'ExifTool version probe failed.' -Data @{ exitCode = $process.ExitCode; stderr = $stderr.Result } }
            } catch {
                Write-AppLog -Level WARNING -Message 'ExifTool version probe was unavailable.' -Data $_
            } finally { $process.Dispose() }
        }
        Write-AppLog -Level INFO -Message 'Application runtime initialized.' -Data @{ exifToolVersion = $script:RuntimeExifToolVersion; retentionDays = 30 }
    } catch {
        $script:RuntimeLogHealthy = $false
        $script:LastLogError = Protect-DiagnosticText $_.Exception.Message
    }
}

function Get-DokanDiagnosticInfo {
    # Inspect local installation metadata only. Never enumerate mounted cloud files.
    $installations = @()
    $registration = @()
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432) | Where-Object { $_ } | Select-Object -Unique
    foreach ($root in $roots) {
        $installPath = Join-Path $root 'Dokan\DokanLibrary-1.5.1'
        if (-not [IO.Directory]::Exists($installPath)) { continue }
        $binaries = @()
        foreach ($relative in @('dokan1.dll', 'x64\dokan1.dll', 'x86\dokan1.dll')) {
            $file = Join-Path $installPath $relative
            if (-not [IO.File]::Exists($file)) { continue }
            $version = $null
            $architecture = 'unknown'
            $reader = $null
            try {
                $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($file).FileVersion
                $reader = New-Object IO.BinaryReader([IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite))
                if ($reader.ReadUInt16() -eq 0x5a4d) {
                    $reader.BaseStream.Seek(0x3c, [IO.SeekOrigin]::Begin) | Out-Null
                    $peOffset = $reader.ReadInt32()
                    if ($peOffset -ge 0 -and $peOffset -lt ($reader.BaseStream.Length - 6)) {
                        $reader.BaseStream.Seek($peOffset, [IO.SeekOrigin]::Begin) | Out-Null
                        if ($reader.ReadUInt32() -eq 0x4550) {
                            $machine = $reader.ReadUInt16()
                            $architecture = switch ($machine) { 0x8664 { 'x64' } 0x014c { 'x86' } 0xaa64 { 'arm64' } default { 'unknown' } }
                        }
                    }
                }
            } catch { $architecture = 'unavailable' }
            finally { if ($reader) { $reader.Dispose() } }
            $binaries += [ordered]@{ filename = $relative; version = $version; architecture = $architecture }
        }
        $installations += [ordered]@{ path = $installPath; directoryVersion = '1.5.1'; binaries = $binaries }
    }
    foreach ($registryRoot in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (-not (Test-Path -LiteralPath $registryRoot -ErrorAction SilentlyContinue)) { continue }
        foreach ($entry in @(Get-ChildItem -LiteralPath $registryRoot -ErrorAction SilentlyContinue)) {
            $displayName = $entry.GetValue('DisplayName')
            if ($displayName -notmatch '(?i)\bDokan\b') { continue }
            # Never collect uninstall commands, usernames, or arbitrary registry values.
            $registration += [ordered]@{ name = $displayName; version = $entry.GetValue('DisplayVersion'); installLocation = $entry.GetValue('InstallLocation'); registryView = if ($registryRoot -match 'WOW6432Node') { '32-bit' } else { 'native' } }
        }
    }
    return ConvertTo-SafeDiagnosticValue ([ordered]@{ present = (($installations.Count + $registration.Count) -gt 0); installations = $installations; registration = $registration; note = 'Installation evidence does not prove that a driver is currently loaded or that a mount uses Dokan.' })
}

function Get-StorageDiagnosticInfo {
    param([ValidateRange(100, 30000)][int]$TimeoutMilliseconds = 5000)
    $drives = @()
    $mappings = @()
    # GetDrives/GetDriveType return root information, with no directory listing.
    foreach ($drive in [IO.DriveInfo]::GetDrives()) {
        $drives += [ordered]@{ root = $drive.Name; driveType = [string]$drive.DriveType; fileSystem = $null; metadataStatus = 'not-probed' }
    }
    # HKCU Network contains persisted mappings. Read only explicit non-secret fields.
    if (Test-Path -LiteralPath 'HKCU:\Network' -ErrorAction SilentlyContinue) {
        foreach ($key in @(Get-ChildItem -LiteralPath 'HKCU:\Network' -ErrorAction SilentlyContinue)) {
            $mappings += [ordered]@{ drive = ($key.PSChildName + ':'); remotePath = $key.GetValue('RemotePath'); provider = $key.GetValue('ProviderName') }
        }
    }
    # An offline SMB/Dokan root may block even a filesystem metadata query.
    # Bound it in a child process; no source files, recursive scans, or credentials.
    $probe = @'
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$result = @()
foreach ($drive in [IO.DriveInfo]::GetDrives()) {
    $item = [ordered]@{ root = $drive.Name; fileSystem = $null; metadataStatus = 'unavailable' }
    try {
        if ($drive.IsReady) { $item.fileSystem = $drive.DriveFormat; $item.metadataStatus = 'available' }
        else { $item.metadataStatus = 'not-ready' }
    } catch { $item.metadataStatus = 'unavailable' }
    $result += $item
}
ConvertTo-Json -InputObject $result -Compress
'@
    $status = 'unavailable'
    $process = New-Object Diagnostics.Process
    try {
        $process.StartInfo.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $process.StartInfo.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.CreateNoWindow = $true
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        $process.StartInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
        $process.Start() | Out-Null
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            $process.Kill()
            $status = 'timed-out'
        } elseif ($process.ExitCode -eq 0) {
            $probeResults = ConvertFrom-Json -InputObject $outputTask.Result
            foreach ($drive in $drives) {
                $match = @(@($probeResults) | Where-Object { $_.root -eq $drive.root })
                if ($match.Count -gt 0) { $drive.fileSystem = $match[0].fileSystem; $drive.metadataStatus = $match[0].metadataStatus }
            }
            $status = 'completed'
        }
    } catch { $status = 'unavailable' }
    finally { $process.Dispose() }
    return ConvertTo-SafeDiagnosticValue ([ordered]@{ drives = $drives; persistedNetworkMappings = $mappings; fileSystemProbeStatus = $status; note = 'Root metadata only; no mounted files are enumerated. Persisted mappings may be disconnected. DriveType alone does not identify a cloud client.' })
}

function Get-WindowsDiagnosticInfo {
    # OSVersion may be a compatibility value in a host without a recent manifest.
    # Read an explicit local registry allowlist and retain those original values.
    $values = [ordered]@{ ProductName=$null; DisplayVersion=$null; CurrentBuildNumber=$null; UBR=$null; EditionID=$null }
    $status = 'unavailable'
    $family = 'unknown'
    $inferred = $false
    try {
        $key = Get-Item -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        foreach ($name in @($values.Keys)) { $values[$name] = $key.GetValue($name) }
        $status = 'available'
        $build = 0
        if ([int]::TryParse([string]$values.CurrentBuildNumber, [ref]$build)) {
            if ([string]$values.ProductName -match '(?i)Server') { $family = 'Windows Server' }
            elseif ($build -ge 22000) { $family = 'Windows 11'; $inferred = $true }
            elseif ($build -ge 10240) { $family = 'Windows 10'; $inferred = $true }
        }
    } catch { $status = 'unavailable' }
    return [ordered]@{ registry=$values; registryStatus=$status; inferredWindowsFamily=$family; inferredFromBuild=$inferred; note='Registry values are preserved verbatim. Windows 11 desktop family is inferred from build >= 22000; the runtime-reported OS version remains separate.' }
}

function New-DiagnosticZipArchive {
    param([IO.Stream]$Stream)
    return New-Object IO.Compression.ZipArchive($Stream, [IO.Compression.ZipArchiveMode]::Create, $true)
}

function Close-DiagnosticResource {
    param($Resource, [string]$Name)
    if ($null -eq $Resource) { return }
    try { $Resource.Dispose() }
    catch { Write-AppLog -Level WARNING -Message 'Diagnostic cleanup could not close a resource.' -Data @{ resource=$Name; error=$_ } }
}

function Export-DiagnosticBundle {
    param([Parameter(Mandatory = $true)][string]$Destination, [hashtable]$Context = @{})
    $staging = $null
    $archiveStream = $null
    $archive = $null
    $createdDestination = $false
    try {
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        if (-not $script:LogDirectory) { throw 'Runtime has not been initialized.' }
        $Destination = [IO.Path]::GetFullPath($Destination)
        if ([IO.Path]::GetExtension($Destination) -ne '.zip') { throw 'Diagnostic destination must have the .zip extension.' }
        if (Test-Path -LiteralPath $Destination) { throw 'Destination already exists. Choose a new ZIP filename.' }
        $staging = Join-Path ([IO.Path]::GetTempPath()) ('SynthTag-diagnostics-' + [Guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory((Join-Path $staging 'Logs')) | Out-Null
        Write-AppLog -Level INFO -Message 'Diagnostic bundle export requested.'
        $healthAtExport = $script:RuntimeLogHealthy
        $errorAtExport = $script:LastLogError
        $environment = [ordered]@{
            generatedAt = [DateTimeOffset]::Now.ToString('o')
            application = [ordered]@{ name = 'SynthTag'; version = $script:RuntimeVersion; exifToolVersion = $script:RuntimeExifToolVersion; session = $script:RuntimeSessionId; startedAt = $script:RuntimeStartedAt }
            system = [ordered]@{
                osVersion = [Environment]::OSVersion.VersionString
                windows = Get-WindowsDiagnosticInfo
                powershellVersion = $PSVersionTable.PSVersion.ToString()
                powershellEdition = if ($PSVersionTable.PSObject -and $PSVersionTable.ContainsKey('PSEdition')) { $PSVersionTable.PSEdition } else { 'Desktop' }
                dotnetVersion = [Environment]::Version.ToString()
                os64Bit = [Environment]::Is64BitOperatingSystem
                process64Bit = [Environment]::Is64BitProcess
                processorArchitecture = $env:PROCESSOR_ARCHITECTURE
                culture = [Globalization.CultureInfo]::CurrentCulture.Name
                timezone = [TimeZoneInfo]::Local.Id
            }
            logging = [ordered]@{ healthy = $healthAtExport; lastError = $errorAtExport; retentionDays = 30 }
            dokan = Get-DokanDiagnosticInfo
            storage = Get-StorageDiagnosticInfo
            context = ConvertTo-SafeDiagnosticValue $Context
        }
        $utf8 = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText((Join-Path $staging 'environment.json'), ($environment | ConvertTo-Json -Depth 12), $utf8)
        $cutoff = (Get-Date).Date.AddDays(-29)
        if (Test-Path -LiteralPath $script:LogDirectory -PathType Container) {
            foreach ($file in @(Get-ChildItem -LiteralPath $script:LogDirectory -File -ErrorAction Stop)) {
                if ($file.Name -notmatch '^(?:SynthTag-(\d{4}-\d{2}-\d{2})\.jsonl|launcher-(\d{4}-\d{2}-\d{2})\.log)$') { continue }
                $dateText = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
                $date = [DateTime]::MinValue
                if (-not [DateTime]::TryParseExact($dateText, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$date)) { continue }
                if ($date -lt $cutoff -or $date -gt (Get-Date).Date) { continue }
                $inputStream = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                try {
                    $reader = New-Object IO.StreamReader($inputStream, [Text.Encoding]::UTF8)
                    # Entries are sanitized before JSON encoding by Write-AppLog.
                    # Applying string redaction to encoded JSON can corrupt its escapes.
                    try { $safeLog = $reader.ReadToEnd() } finally { $reader.Dispose() }
                    if ($file.Extension -eq '.log') { $safeLog = Protect-DiagnosticText $safeLog }
                    [IO.File]::WriteAllText((Join-Path (Join-Path $staging 'Logs') $file.Name), $safeLog, $utf8)
                } finally { $inputStream.Dispose() }
            }
        }
        [IO.File]::WriteAllText((Join-Path $staging 'README.txt'), @'
SynthTag diagnostic bundle
Contains basic OS/runtime/application versions, sanitized context, and local application logs for today and the preceding 29 calendar dates.
Includes read-only drive root/type/filesystem metadata, persisted network mappings, and Dokan installation evidence. Filesystem probing has a timeout; it never enumerates mounted files.
Severity levels: INFO, WARNING, ERROR. Logs include local time offsets and a session ID.
Does not collect source images/videos, image metadata, environment variable dumps, credentials, or directory listings.
User profile paths and recognized credential fields are redacted. Image filenames and share paths may remain for troubleshooting. Review before sharing.
Missing or incomplete logs may be explained by environment.json logging.healthy / logging.lastError.
'@, $utf8)
        # CreateNew prevents accidental overwrites even when two exports race.
        $archiveStream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $createdDestination = $true
        $archive = New-DiagnosticZipArchive $archiveStream
        foreach ($file in @(Get-ChildItem -LiteralPath $staging -Recurse -File)) {
            $entryName = $file.FullName.Substring($staging.Length + 1).Replace('\', '/')
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $entryName, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
        # Detach before disposing: finalization can throw (e.g. disk full). It must
        # enter the failure path without repeatedly disposing the same object.
        $closingArchive = $archive; $archive = $null
        $closingArchive.Dispose()
        $closingStream = $archiveStream; $archiveStream = $null
        $closingStream.Dispose()
        Write-AppLog -Level INFO -Message 'Diagnostic bundle exported.' -Data @{ filename = [IO.Path]::GetFileName($Destination) }
        return $Destination
    } catch {
        $exportError = $_
        Write-AppLog -Level ERROR -Message 'Diagnostic bundle export failed.' -Data $exportError
        $failedArchive = $archive; $archive = $null
        $failedStream = $archiveStream; $archiveStream = $null
        Close-DiagnosticResource $failedArchive 'archive'
        Close-DiagnosticResource $failedStream 'stream'
        if ($createdDestination -and [IO.File]::Exists($Destination)) {
            try { [IO.File]::Delete($Destination) }
            catch { Write-AppLog -Level WARNING -Message 'Diagnostic partial ZIP cleanup failed.' -Data @{ filename=[IO.Path]::GetFileName($Destination); error=$_ } }
        }
        throw $exportError
    } finally {
        $remainingArchive = $archive; $archive = $null
        $remainingStream = $archiveStream; $archiveStream = $null
        Close-DiagnosticResource $remainingArchive 'archive'
        Close-DiagnosticResource $remainingStream 'stream'
        if ($staging -and [IO.Directory]::Exists($staging)) {
            try { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction Stop }
            catch { Write-AppLog -Level WARNING -Message 'Diagnostic staging cleanup failed.' -Data $_ }
        }
    }
}
