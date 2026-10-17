$ErrorActionPreference='Stop'
function Assert-Thumbnail([bool]$Value,[string]$Message) { if (-not $Value) { throw $Message } }
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('SynthTag-thumbnail-test-'+[guid]::NewGuid().ToString('N'))
$workerTemp=Join-Path $fixtureRoot ('SynthTag\ThumbnailWork\'+[guid]::NewGuid().ToString('N'))
$workerPath=Join-Path $PSScriptRoot '..\thumbnail-worker.ps1'
$process=$null
$longRoot=$null
function Request-Thumbnail([string]$Path) {
    $process.StandardInput.WriteLine([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Path)))
    $task=$process.StandardOutput.ReadLineAsync()
    Assert-Thumbnail ($task.Wait(15000)) 'Worker response exceeded test timeout.'
    Assert-Thumbnail ([bool]$task.Result) 'Worker unexpectedly exited or emitted an empty response.'
    return $task.Result
}
function Read-Thumbnail([string]$Line) {
    Assert-Thumbnail ($Line.StartsWith('OK|')) ('Expected image response, received '+$Line)
    $memory=New-Object IO.MemoryStream(,[Convert]::FromBase64String($Line.Substring(3)))
    try {
        $image=[Drawing.Image]::FromStream($memory)
        try { return New-Object Drawing.Bitmap($image) } finally { $image.Dispose() }
    } finally { $memory.Dispose() }
}
try {
    Assert-Thumbnail (Test-Path -LiteralPath $workerPath) 'Thumbnail worker exists.'
    Add-Type -AssemblyName System.Drawing
    $null=[IO.Directory]::CreateDirectory($workerTemp)
    $keep=Join-Path $workerTemp 'parent-owned-do-not-delete.txt'
    [IO.File]::WriteAllText($keep,'This belongs to the parent, not the worker.')
    $fixtures=@()
    foreach ($format in @('png','jpg','tiff')) {
        $path=Join-Path $fixtureRoot (([char]0x4e2d)+[string][char]0x6587+'[color].'+$format)
        $bitmap=New-Object Drawing.Bitmap(80,40)
        $graphics=[Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.Clear([Drawing.Color]::Red)
            $graphics.FillRectangle([Drawing.Brushes]::Blue,40,0,40,40)
            $imageFormat=switch($format) { 'png' {[Drawing.Imaging.ImageFormat]::Png} 'jpg' {[Drawing.Imaging.ImageFormat]::Jpeg} 'tiff' {[Drawing.Imaging.ImageFormat]::Tiff} }
            $bitmap.Save($path,$imageFormat)
        } finally { $graphics.Dispose(); $bitmap.Dispose() }
        $fixtures+=@{path=$path;format=$format;hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}
    }
    $jpeg=@($fixtures | Where-Object { $_.format -eq 'jpg' })[0].path
    $exiftool=Join-Path $PSScriptRoot '..\exiftool_bin\exiftool.exe'
    $seedArgs=Join-Path $fixtureRoot 'seed.args'
    [IO.File]::WriteAllLines($seedArgs,@('-charset','filename=utf8','-overwrite_original','-Orientation#=6',$jpeg),(New-Object Text.UTF8Encoding($false)))
    $seed=New-Object Diagnostics.Process
    try {
        $seed.StartInfo.FileName=[IO.Path]::GetFullPath($exiftool); $seed.StartInfo.Arguments='-@ "'+$seedArgs+'"'
        $seed.StartInfo.UseShellExecute=$false; $seed.StartInfo.CreateNoWindow=$true
        $seed.StartInfo.RedirectStandardOutput=$true; $seed.StartInfo.RedirectStandardError=$true
        foreach ($locale in @('LANG','LC_ALL','LC_CTYPE')) { $seed.StartInfo.EnvironmentVariables[$locale]='C' }
        $null=$seed.Start(); $null=$seed.StandardOutput.ReadToEnd(); $seedError=$seed.StandardError.ReadToEnd(); $seed.WaitForExit()
        Assert-Thumbnail ($seed.ExitCode -eq 0) ('JPEG orientation fixture was written: '+$seedError)
    } finally { $seed.Dispose() }
    @($fixtures | Where-Object { $_.format -eq 'jpg' })[0].hash=(Get-FileHash -LiteralPath $jpeg -Algorithm SHA256).Hash
    $process=New-Object Diagnostics.Process
    $process.StartInfo.FileName=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $process.StartInfo.Arguments='-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "'+[IO.Path]::GetFullPath($workerPath)+'" -Worker -TempDirectory "'+$workerTemp+'"'
    $process.StartInfo.UseShellExecute=$false; $process.StartInfo.CreateNoWindow=$true
    $process.StartInfo.RedirectStandardInput=$true; $process.StartInfo.RedirectStandardOutput=$true; $process.StartInfo.RedirectStandardError=$true
    $null=$process.Start()
    $stderr=$process.StandardError.ReadToEndAsync()
    foreach ($fixture in $fixtures) {
        $sharedLease=[IO.File]::Open($fixture.path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try { $response=Request-Thumbnail $fixture.path } finally { $sharedLease.Dispose() }
        $image=Read-Thumbnail $response
        try {
            Assert-Thumbnail ($image.Width -eq 40 -and $image.Height -eq 40) 'Thumbnail is exactly 40 by 40.'
            if ($fixture.format -eq 'jpg') {
                Assert-Thumbnail ($image.GetPixel(0,20).A -eq 0) 'Rotated portrait has transparent side padding.'
                Assert-Thumbnail ($image.GetPixel(20,5).R -gt 180 -and $image.GetPixel(20,35).B -gt 180) 'JPEG EXIF orientation is applied correctly.'
            } else {
                Assert-Thumbnail ($image.GetPixel(20,0).A -eq 0) 'Landscape has transparent top padding.'
                Assert-Thumbnail ($image.GetPixel(5,20).R -gt 180 -and $image.GetPixel(35,20).B -gt 180) 'Aspect ratio and actual colors are preserved.'
            }
        } finally { $image.Dispose() }
        $exclusive=[IO.File]::Open($fixture.path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $exclusive.Dispose()
        Assert-Thumbnail ((Get-FileHash -LiteralPath $fixture.path -Algorithm SHA256).Hash -eq $fixture.hash) 'Worker never changes source bytes.'
    }
    $longRoot=Join-Path $fixtureRoot 'long-path'
    $nested=$longRoot
    foreach ($index in 1..6) { $nested=Join-Path $nested ('segment-'+('x'*28)) }
    $null=[IO.Directory]::CreateDirectory('\\?\'+$nested)
    $longPath=Join-Path $nested 'long-image.png'
    Assert-Thumbnail ($longPath.Length -gt 260) 'Long-path fixture actually exceeds the traditional Windows path limit.'
    [IO.File]::WriteAllBytes(('\\?\'+$longPath),[IO.File]::ReadAllBytes($fixtures[0].path))
    $image=Read-Thumbnail (Request-Thumbnail $longPath)
    try { Assert-Thumbnail ($image.Width -eq 40 -and $image.Height -eq 40) 'Long source paths can produce previews.' }
    finally { $image.Dispose() }
    $exclusive=[IO.File]::Open(('\\?\'+$longPath),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None); $exclusive.Dispose()
    $corrupt=Join-Path $fixtureRoot 'corrupt.webp'; [IO.File]::WriteAllText($corrupt,'not an image')
    $line=Request-Thumbnail $corrupt
    Assert-Thumbnail ($line.StartsWith('ERROR|')) 'Unsupported/corrupt content returns an explicit error rather than an icon.'
    $errorText=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($line.Substring(6)))
    Assert-Thumbnail ([bool]$errorText -and $errorText.Length -le 240) 'Errors use short UTF8 Base64 protocol text.'
    $exclusive=[IO.File]::Open($corrupt,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None); $exclusive.Dispose()
    Assert-Thumbnail ((Request-Thumbnail $fixtures[0].path).StartsWith('OK|')) 'A failed job does not stop the next request.'
    $webp=Join-Path $fixtureRoot 'real-webp.webp'
    # Same tiny lossless RGB fixture as metadata.tests.ps1; no codec dependency in tests.
    [IO.File]::WriteAllBytes($webp,[Convert]::FromBase64String('UklGRiQAAABXRUJQVlA4TBcAAAAvB8ABAA8Q8x/zHwYFaRuwKDsR/Q8cAAA='))
    $webpHash=(Get-FileHash -LiteralPath $webp -Algorithm SHA256).Hash
    $webpLine=Request-Thumbnail $webp
    if ($webpLine.StartsWith('OK|')) {
        $image=Read-Thumbnail $webpLine
        try { Assert-Thumbnail ($image.Width -eq 40 -and $image.Height -eq 40) 'Shell fallback creates a normalized 40 by 40 PNG.' }
        finally { $image.Dispose() }
        Write-Output 'PASS: real WebP decoded through the available Windows codec.'
    } else {
        Assert-Thumbnail ($webpLine.StartsWith('ERROR|')) 'Unavailable WebP codec has an explicit error placeholder.'
        Write-Output 'INFO: Windows WebP thumbnail codec unavailable; explicit error placeholder verified.'
    }
    $exclusive=[IO.File]::Open($webp,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None); $exclusive.Dispose()
    Assert-Thumbnail ((Get-FileHash -LiteralPath $webp -Algorithm SHA256).Hash -eq $webpHash) 'Shell preview cannot change original WebP bytes.'
    $large=Join-Path $fixtureRoot 'over-limit.png'
    $largeStream=[IO.File]::Open($large,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $largeStream.SetLength(64L*1024*1024+1) } finally { $largeStream.Dispose() }
    $line=Request-Thumbnail $large
    Assert-Thumbnail ($line.StartsWith('ERROR|') -and [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($line.Substring(6))).Contains('64 MB')) 'Refuses inputs larger than the preview memory budget.'
    $largeDimensions=Join-Path $fixtureRoot 'oversized-dimensions.jpg'
    $jpegBytes=[IO.File]::ReadAllBytes($jpeg)
    $offset=2; $changed=$false
    while ($offset -lt $jpegBytes.Length-8) {
        Assert-Thumbnail ($jpegBytes[$offset] -eq 0xff) 'Fixture JPEG segment structure is valid.'
        $marker=$jpegBytes[$offset+1]
        if ($marker -in @(0xc0,0xc1,0xc2)) {
            # Change only the dimensions in SOF: 9000 x 9000 > 60 MP.
            $jpegBytes[$offset+5]=0x23; $jpegBytes[$offset+6]=0x28
            $jpegBytes[$offset+7]=0x23; $jpegBytes[$offset+8]=0x28
            $changed=$true; break
        }
        $length=([int]$jpegBytes[$offset+2]*256)+$jpegBytes[$offset+3]
        $offset+=2+$length
    }
    Assert-Thumbnail $changed 'Oversized header fixture includes JPEG SOF dimensions.'
    [IO.File]::WriteAllBytes($largeDimensions,$jpegBytes)
    $line=Request-Thumbnail $largeDimensions
    Assert-Thumbnail ($line.StartsWith('ERROR|') -and [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($line.Substring(6))).Contains('60 megapixel')) 'Refuses oversized pixel dimensions before thumbnail rendering.'
    $process.StandardInput.WriteLine('not base64!')
    $line=$process.StandardOutput.ReadLine()
    Assert-Thumbnail ($line.StartsWith('ERROR|')) 'Malformed protocol request is contained to its job.'
    Assert-Thumbnail ((Request-Thumbnail $fixtures[0].path).StartsWith('OK|')) 'Worker recovers after malformed input.'
    $process.StandardInput.Close()
    Assert-Thumbnail ($process.WaitForExit(15000)) 'Worker exits promptly on EOF.'
    Assert-Thumbnail ($process.ExitCode -eq 0) ('Worker exits successfully: '+$stderr.Result)
    Assert-Thumbnail ([string]::IsNullOrWhiteSpace($stderr.Result)) ('Worker emits no unsolicited stderr: '+$stderr.Result)
    $remaining=@(Get-ChildItem -LiteralPath $workerTemp -File)
    Assert-Thumbnail ($remaining.Count -eq 1 -and $remaining[0].Name -eq 'parent-owned-do-not-delete.txt') 'EOF cleans only worker snapshots and preserves parent-owned content and directory.'
    Write-Output 'PASS: actual PNG/JPEG/TIFF, orientation, aspect ratio, transparent padding, Chinese/bracket and >260 character paths, 64 MB/60 MP limits, shared source unlock/immutability, per-job recovery, EOF cleanup.'
} finally {
    if ($process) { if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }; $process.Dispose() }
    if ($longRoot -and [IO.Directory]::Exists('\\?\'+$longRoot)) { [IO.Directory]::Delete(('\\?\'+$longRoot),$true) }
    $resolved=[IO.Path]::GetFullPath($fixtureRoot)
    $expected=[IO.Path]::GetTempPath().TrimEnd('\')+'\SynthTag-thumbnail-test-'
    if (-not $resolved.StartsWith($expected,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup target.' }
    if ([IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
