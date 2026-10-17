$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('SynthTag-runtime-test-' + [Guid]::NewGuid().ToString('N'))
$previousLocalAppData = $env:LOCALAPPDATA
$previousProgramFiles = $env:ProgramFiles
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
try {
    $env:LOCALAPPDATA = $testRoot
    $runtimeFile = Join-Path $PSScriptRoot '..\runtime.ps1'
    Assert-True (Test-Path -LiteralPath $runtimeFile) 'Runtime module exists.'
    . $runtimeFile
    $spacedProfile = Protect-DiagnosticText 'C:\Users\Test User\secret.png'
    Assert-True (-not $spacedProfile.Contains('Test') -and -not $spacedProfile.Contains('User\')) 'Redacts a complete profile folder containing spaces.'
    Assert-True ($spacedProfile.Contains('secret.png')) 'Profile redaction preserves the filename.'
    $escapedPassword = Protect-DiagnosticText 'password="abc\"suffix"'
    Assert-True (-not $escapedPassword.Contains('abc') -and -not $escapedPassword.Contains('suffix')) 'Redacts the complete quoted secret including escaped quotes.'
    $escapedJsonPassword = Protect-DiagnosticText '{"password":"abc\"suffix","file":"sample.png"}'
    Assert-True (-not $escapedJsonPassword.Contains('suffix') -and $escapedJsonPassword.Contains('sample.png')) 'Redacts an escaped JSON password without discarding useful filenames.'
    $dokanRoot = Join-Path $testRoot 'program-files\Dokan\DokanLibrary-1.5.1'
    [IO.Directory]::CreateDirectory($dokanRoot) | Out-Null
    $env:ProgramFiles = Join-Path $testRoot 'program-files'
    $binary = New-Object byte[] 256
    $binary[0] = 0x4d; $binary[1] = 0x5a; $binary[0x3c] = 0x80
    $binary[0x80] = 0x50; $binary[0x81] = 0x45
    $binary[0x84] = 0x64; $binary[0x85] = 0x86
    [IO.File]::WriteAllBytes((Join-Path $dokanRoot 'dokan1.dll'), $binary)
    Assert-True ([bool](Get-Command Get-DokanDiagnosticInfo -ErrorAction SilentlyContinue)) 'Dokan diagnostic collector exists.'
    $dokan = Get-DokanDiagnosticInfo
    Assert-True $dokan.present 'Finds the specified Dokan 1.5.1 installation directory.'
    $detectedInstall = @($dokan.installations | Where-Object { $_.path -eq (Protect-DiagnosticText $dokanRoot) })
    Assert-True ($detectedInstall.Count -eq 1) 'Collects installation path without scanning cloud files.'
    Assert-True ($detectedInstall[0].binaries[0].architecture -eq 'x64') 'Detects DLL architecture from its PE header.'
    Initialize-SynthTagRuntime -Version 'test-1.2.3' -ExifTool ''
    Assert-True $script:RuntimeLogHealthy 'Runtime can write to local app data.'
    Assert-True ($script:LogDirectory -eq (Join-Path $testRoot 'SynthTag\Logs')) 'Uses Windows per-user local app data.'
    $today = (Get-Date).Date
    $oldFile = Join-Path $script:LogDirectory ('SynthTag-' + $today.AddDays(-30).ToString('yyyy-MM-dd') + '.jsonl')
    $boundaryFile = Join-Path $script:LogDirectory ('SynthTag-' + $today.AddDays(-29).ToString('yyyy-MM-dd') + '.jsonl')
    [IO.File]::WriteAllText($oldFile, 'too old')
    [IO.File]::WriteAllText($boundaryFile, 'retained')
    $oldLauncher = Join-Path $script:LogDirectory ('launcher-' + $today.AddDays(-30).ToString('yyyy-MM-dd') + '.log')
    $retainedLauncher = Join-Path $script:LogDirectory ('launcher-' + $today.AddDays(-29).ToString('yyyy-MM-dd') + '.log')
    $unrelatedLog = Join-Path $script:LogDirectory 'other-2000-01-01.log'
    [IO.File]::WriteAllText($oldLauncher, 'too old')
    [IO.File]::WriteAllText($retainedLauncher, 'INFO password=launcher-password')
    [IO.File]::WriteAllText($unrelatedLog, 'not application owned')
    Initialize-SynthTagRuntime -Version 'test-1.2.3' -ExifTool ''
    Assert-True (-not (Test-Path -LiteralPath $oldFile)) 'Deletes the thirtieth previous date.'
    Assert-True (Test-Path -LiteralPath $boundaryFile) 'Keeps the twenty-ninth previous date.'
    Assert-True (-not (Test-Path -LiteralPath $oldLauncher)) 'Applies retention to launcher logs.'
    Assert-True (Test-Path -LiteralPath $retainedLauncher) 'Keeps launcher logs on retention boundary.'
    Assert-True (Test-Path -LiteralPath $unrelatedLog) 'Never removes unrelated files in the log directory.'
    Write-AppLog -Level INFO -Message 'Batch started' -Data @{ path = ($env:USERPROFILE + '\Pictures\sample.png'); token = 'secret-token-value'; detail = 'password=secret-password; Bearer abc123secret' }
    Write-AppLog -Level WARNING -Message 'Retry required' -Data @{ file = '\\server\share\sample.png' }
    try { throw [IO.IOException]::new('Image verification failed') } catch { Write-AppLog -Level ERROR -Message 'Write failed' -Data $_ }
    $currentFile = Join-Path $script:LogDirectory ('SynthTag-' + $today.ToString('yyyy-MM-dd') + '.jsonl')
    $content = [IO.File]::ReadAllText($currentFile)
    $records = @(Get-Content -LiteralPath $currentFile -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True (@($records | Where-Object level -eq 'ERROR').Count -eq 1) 'Records error severity.'
    Assert-True ($content.Contains('Image verification failed')) 'Preserves exception diagnostics.'
    Assert-True ($content.Contains('sample.png')) 'Preserves useful filenames.'
    Assert-True (-not $content.Contains('secret-token-value')) 'Redacts sensitive structured fields.'
    Assert-True (-not $content.Contains('secret-password')) 'Redacts password values in text.'
    Assert-True (-not $content.Contains('abc123secret')) 'Redacts bearer tokens.'
    Assert-True (-not $content.Contains($env:USERPROFILE.Replace('\', '\\'))) 'Redacts the user profile directory.'
    $destination = Join-Path $testRoot 'diagnostics.zip'
    $result = Export-DiagnosticBundle -Destination $destination -Context @{ pending = 3; password = 'private-password' }
    Assert-True ($result -eq $destination) 'Returns the resulting bundle path.'
    $zip = [IO.Compression.ZipFile]::OpenRead($destination)
    try {
        $names = @($zip.Entries | ForEach-Object FullName)
        Assert-True ($names -contains 'environment.json') 'Contains environment information.'
        Assert-True ($names -contains 'README.txt') 'Contains diagnostic explanation.'
        Assert-True (@($names | Where-Object { $_ -match 'Logs[/\\]SynthTag-.*\.jsonl$' }).Count -eq 2) 'Contains only logs in retention window.'
        $reader = New-Object IO.StreamReader($zip.GetEntry('environment.json').Open())
        try { $environmentText = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $environment = $environmentText | ConvertFrom-Json
        Assert-True ($environment.application.version -eq 'test-1.2.3') 'Includes software version.'
        Assert-True ([bool]$environment.system.powershellVersion) 'Includes PowerShell environment.'
        Assert-True ([bool]$environment.system.osVersion) 'Preserves the OS version reported by the host runtime.'
        Assert-True ([bool]$environment.system.windows.registry.PSObject.Properties['ProductName']) 'Includes the Windows registry product name without replacing its original value.'
        Assert-True ([bool]$environment.system.windows.registry.PSObject.Properties['CurrentBuildNumber']) 'Includes the actual Windows registry build number.'
        $windowsKey = Get-Item -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        Assert-True ($environment.system.windows.registry.CurrentBuildNumber -eq $windowsKey.GetValue('CurrentBuildNumber')) 'Preserves the exact registry build value.'
        if ([int]$windowsKey.GetValue('CurrentBuildNumber') -ge 22000 -and $windowsKey.GetValue('ProductName') -notmatch 'Server') {
            Assert-True ($environment.system.windows.inferredWindowsFamily -eq 'Windows 11') 'Recognizes Windows 11 from its build despite compatibility-version reporting.'
            Assert-True $environment.system.windows.inferredFromBuild 'Clearly labels Windows family detection as a build-based inference.'
        }
        Assert-True $environment.dokan.present 'Includes Dokan presence in the diagnostic bundle.'
        Assert-True (@($environment.storage.drives).Count -gt 0) 'Includes basic drive roots and types.'
        Assert-True ([bool]$environment.storage.drives[0].root) 'Drive diagnostics contain root path.'
        Assert-True ([bool]$environment.storage.drives[0].driveType) 'Drive diagnostics contain drive type.'
        Assert-True ([bool]$environment.storage.drives[0].PSObject.Properties['fileSystem']) 'Drive diagnostics contain file system status.'
        foreach ($drive in @($environment.storage.drives | Where-Object { $_.metadataStatus -eq 'available' })) {
            Assert-True ($drive.fileSystem -is [string]) 'Each drive receives one filesystem value rather than a nested JSON array.'
            Assert-True ($drive.fileSystem -eq ([IO.DriveInfo]::new($drive.root)).DriveFormat) 'Filesystem metadata is matched to the correct drive root.'
        }
        Assert-True (@($names | Where-Object { $_ -match 'Logs/launcher-.*\.log$' }).Count -eq 1) 'Includes retained launcher logs.'
        Assert-True (-not ($names -contains 'Logs/other-2000-01-01.log')) 'Diagnostic export ignores unrelated log files.'
        $launcherEntry = $zip.GetEntry('Logs/' + [IO.Path]::GetFileName($retainedLauncher))
        $reader = New-Object IO.StreamReader($launcherEntry.Open())
        try { $launcherText = $reader.ReadToEnd() } finally { $reader.Dispose() }
        Assert-True (-not $launcherText.Contains('launcher-password')) 'Sanitizes plaintext launcher logs during export.'
        Assert-True (-not $environmentText.Contains('private-password')) 'Context values are sanitized.'
        $entry = $zip.GetEntry('Logs/' + [IO.Path]::GetFileName($currentFile))
        $reader = New-Object IO.StreamReader($entry.Open(), [Text.Encoding]::UTF8)
        try { $exportedLog = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $exportedRecords = @($exportedLog -split '\r?\n' | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        Assert-True (@($exportedRecords | Where-Object level -eq 'ERROR').Count -eq 1) 'Export preserves valid JSON log entries.'
        Assert-True (@($names | Where-Object { $_ -match '\.(png|exe|key|env)$' }).Count -eq 0) 'Never includes images, binaries, or credential files.'
    } finally { $zip.Dispose() }
    $savedDirectory = $script:LogDirectory
    $script:LogDirectory = Join-Path $destination 'invalid-folder'
    Write-AppLog -Level ERROR -Message 'Must not crash when disk is unavailable'
    Assert-True (-not $script:RuntimeLogHealthy) 'Exposes failure state when logging cannot write.'
    Assert-True ([bool]$script:LastLogError) 'Exposes actionable logging error.'
    $script:LogDirectory = $savedDirectory
    Write-AppLog -Level INFO -Message 'Recovered'
    Assert-True $script:RuntimeLogHealthy 'Recovers logging health on the next successful write.'
    $thrown = $false
    try { Export-DiagnosticBundle -Destination $destination -Context @{} } catch { $thrown = $true }
    Assert-True $thrown 'Does not overwrite an existing diagnostic ZIP.'
    Add-Type -ReferencedAssemblies ([IO.Compression.ZipArchive].Assembly.Location) -TypeDefinition @'
using System;
using System.IO;
using System.IO.Compression;
namespace SynthTag.Tests {
    public class ThrowingZipArchive : ZipArchive {
        public static int DisposeCalls;
        public ThrowingZipArchive(Stream stream) : base(stream, ZipArchiveMode.Create, true) { }
        protected override void Dispose(bool disposing) {
            DisposeCalls++;
            base.Dispose(disposing);
            throw new IOException("Simulated central-directory flush failure");
        }
    }
}
'@
    $factory = ${function:New-DiagnosticZipArchive}
    Assert-True ([bool]$factory) 'Archive factory is available for a real failing-disposal test.'
    $failedZip = Join-Path $testRoot 'dispose-failure.zip'
    $disposeError = ''
    try {
        function New-DiagnosticZipArchive {
            param([IO.Stream]$Stream)
            New-Object SynthTag.Tests.ThrowingZipArchive($Stream)
        }
        try { $null = Export-DiagnosticBundle -Destination $failedZip } catch { $disposeError = $_.Exception.ToString() }
    } finally { ${function:New-DiagnosticZipArchive} = $factory }
    Assert-True ($disposeError.Contains('Simulated central-directory flush failure')) 'Preserves the initial disposal failure as the reported error.'
    Assert-True ([SynthTag.Tests.ThrowingZipArchive]::DisposeCalls -eq 1) 'Never repeatedly disposes an archive that failed to close.'
    Assert-True (-not [IO.File]::Exists($failedZip)) 'Still closes the underlying stream and removes the partial ZIP after archive disposal fails.'
    $script:ArchiveCleanupAttempts = 0
    $script:invalidArchive = [pscustomobject]@{ InvalidArchive = $true }
    $script:invalidArchive | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
        $script:ArchiveCleanupAttempts++
        throw 'Secondary archive cleanup failure'
    }
    $failedZip = Join-Path $testRoot 'primary-and-cleanup-failure.zip'
    $primaryError = ''
    try {
        function New-DiagnosticZipArchive { param([IO.Stream]$Stream) return $script:invalidArchive }
        try { $null = Export-DiagnosticBundle -Destination $failedZip } catch { $primaryError = $_.Exception.ToString() }
    } finally { ${function:New-DiagnosticZipArchive} = $factory }
    Assert-True ($primaryError.Contains('CreateEntryFromFile') -and -not $primaryError.Contains('Secondary archive cleanup failure')) 'Cleanup errors cannot replace the primary export error.'
    Assert-True ($script:ArchiveCleanupAttempts -eq 1) 'Best-effort catch/finally cleanup closes each resource once.'
    Assert-True (-not [IO.File]::Exists($failedZip)) 'Archive cleanup failure cannot skip stream close and partial-file deletion.'
    $realExifTool = Join-Path $PSScriptRoot '..\exiftool_bin\exiftool.exe'
    if (Test-Path -LiteralPath $realExifTool) {
        Initialize-SynthTagRuntime -Version 'test-1.2.3' -ExifTool $realExifTool
        Assert-True ($script:RuntimeExifToolVersion -match '^\d+\.\d+') 'Reads actual bundled ExifTool version.'
    }
    Write-Output 'PASS: runtime retention, severity, exceptions, redaction, diagnostic ZIP, and write failure recovery.'
} finally {
    $env:LOCALAPPDATA = $previousLocalAppData
    $env:ProgramFiles = $previousProgramFiles
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
