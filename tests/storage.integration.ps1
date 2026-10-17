# Explicit opt-in integration test. Only copies are modified; source files remain untouched.
param(
    [Parameter(Mandatory=$true)][string]$SourceDirectory,
    [Parameter(Mandatory=$true)][string]$TestParent,
    [int]$SampleCount=6,
    [string[]]$Extensions=@('.png','.jpg','.jpeg','.webp','.tif','.tiff'),
    [string]$ReportPath
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\runtime.ps1')
$ExifTool=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\exiftool_bin\exiftool.exe'))
$TAG='contains-synthetic-performer'
. (Join-Path $PSScriptRoot '..\metadata.ps1')
Initialize-SynthTagRuntime -Version ([IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\VERSION')).Trim()) -ExifTool $ExifTool
$name='SynthTag-验证-'+[guid]::NewGuid().ToString('N')
$testRoot=[IO.Path]::GetFullPath((Join-Path $TestParent $name))
$parentRoot=[IO.Path]::GetFullPath($TestParent).TrimEnd('\')+'\'
if (-not $testRoot.StartsWith($parentRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Directory]::Exists($testRoot)) { throw 'Invalid or existing integration-test directory.' }
$results=New-Object Collections.Generic.List[object]
$created=$false; $allPassed=$false
try {
    $samples=@(Get-ChildItem -LiteralPath $SourceDirectory -Recurse -File | Where-Object { $_.Extension.ToLowerInvariant() -in $Extensions -and $_.Length -lt 30MB } | Select-Object -First $SampleCount)
    if ($samples.Count -eq 0) { throw 'No image samples found.' }
    $null=[IO.Directory]::CreateDirectory($testRoot); $created=$true
    Write-Output ('Isolated test directory: '+$testRoot)
    foreach ($sample in $samples) {
        $watch=[Diagnostics.Stopwatch]::StartNew()
        $target=Join-Path $testRoot ('[测试] '+$results.Count+' '+$sample.Name)
        $record=[ordered]@{ name=$sample.Name; bytes=$sample.Length; add=$false; backup=$false; remove=$false; sourceUnchanged=$false; warnings=''; error=''; seconds=0 }
        try {
            $sourceHash=Get-SafeFileHash $sample.FullName
            [IO.File]::Copy($sample.FullName,$target,$false)
            $copyHash=Get-SafeFileHash $target
            if ($copyHash -ne $sourceHash) { throw 'Fixture copy hash mismatch.' }
            $add=Set-SafeFileTag -File $target -Mode normalize -KeepBackup $true
            if (-not $add.Success) { throw $add.Error }
            $record.add=$true
            if ((Get-SafeFileHash ($target+'_original')) -ne $copyHash) { throw 'Original backup differs from source.' }
            $record.backup=$true
            # Remove only this test's verified backup, never a source-directory file.
            [IO.File]::Delete($target+'_original')
            $remove=Set-SafeFileTag -File $target -Mode remove -KeepBackup $false
            if (-not $remove.Success) { throw $remove.Error }
            $record.warnings=@($add.Warning,$remove.Warning) -join '; '
            if ($record.warnings -match '临时备份未能删除') { throw $record.warnings }
            $record.remove=$true
            $subjects=Get-Subjects @($target)
            if (-not $subjects.ContainsKey($target.ToLowerInvariant()) -or $subjects[$target.ToLowerInvariant()] -contains $TAG) { throw 'Final tag readback failed.' }
            $record.sourceUnchanged=((Get-SafeFileHash $sample.FullName) -eq $sourceHash)
            if (-not $record.sourceUnchanged) { throw 'Source changed externally during test.' }
            Write-Output ('PASS: '+$sample.Name+' | add / backup / remove / source unchanged')
        } catch {
            $record.error=$_.Exception.Message
            Write-Output ('FAIL: '+$sample.Name+' | '+$record.error)
        }
        $record.seconds=[Math]::Round($watch.Elapsed.TotalSeconds,2)
        $results.Add([pscustomobject]$record)
    }
    $allPassed=(@($results | Where-Object { $_.error }).Count -eq 0)
    if ($ReportPath) { [IO.File]::WriteAllText($ReportPath,(@{ testRoot=$testRoot; completed=[DateTimeOffset]::Now.ToString('o'); allPassed=$allPassed; results=@($results.ToArray()) } | ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false))) }
    Write-Output ('Integration results: '+@($results | Where-Object { -not $_.error }).Count+'/'+$results.Count+' passed.')
    if (-not $allPassed) { throw 'Integration failures: test copies retained for inspection.' }
} finally {
    if ($created -and $allPassed) {
        $resolved=[IO.Path]::GetFullPath($testRoot)
        if (-not $resolved.StartsWith($parentRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -ne $name) { throw 'Unsafe integration cleanup path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
        Write-Output 'Cleaned only the newly-created test copies.'
    }
}
