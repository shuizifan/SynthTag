param([switch]$StressCache,[string]$RenderDirectory)
$ErrorActionPreference='Stop'
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('SynthTag-thumbnail-test-'+[guid]::NewGuid().ToString('N'))
$oldLocalAppData=$env:LOCALAPPDATA
function Assert([bool]$Value,[string]$Message) { if (-not $Value) { throw $Message } }
function New-ColorFixture([string]$Name,[int]$Width,[int]$Height,[Drawing.Color]$Color,[string]$Format='png') {
    $path=Join-Path $fixtureRoot $Name
    $bitmap=New-Object Drawing.Bitmap($Width,$Height)
    $graphics=[Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear($Color)
        $encoding=if ($Format -eq 'jpeg') { [Drawing.Imaging.ImageFormat]::Jpeg } else { [Drawing.Imaging.ImageFormat]::Png }
        $bitmap.Save($path,$encoding)
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
    return $path
}
function Add-PreviewRow([string]$Path,[string]$State='untagged') {
    $item=New-Object Windows.Forms.ListViewItem([IO.Path]::GetFileName($Path))
    $kind=if ([IO.Path]::GetExtension($Path) -in @('.mp4','.mov','.m4v','.3gp')) { '视频' } else { '图片' }
    $null=$item.SubItems.Add($kind); $null=$item.SubItems.Add($State); $null=$item.SubItems.Add([IO.Path]::GetDirectoryName($Path))
    $item.Tag=$Path; $item.SubItems[2].Tag=$State
    $null=$list.Items.Add($item)
    $script:Items[$Path.ToLowerInvariant()]=$item
    Set-ItemStatus $Path $State
    return $item
}
function Pump-Previews([int]$Milliseconds=100) {
    $timer=[Diagnostics.Stopwatch]::StartNew()
    do { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 20 } while ($timer.ElapsedMilliseconds -lt $Milliseconds)
}
function Wait-Preview([string]$Path,[string[]]$Expected,[int]$TimeoutSeconds=20) {
    $row=$script:Items[$Path.ToLowerInvariant()]
    if ($row -and $row.ListView) { $row.EnsureVisible() }
    $timer=[Diagnostics.Stopwatch]::StartNew()
    do {
        $list.Invalidate(); $list.Update(); Pump-Previews 50
        $state=$list.GetThumbnailState($Path)
        if ($state -in $Expected) { return $state }
        if ($state -in @('failed','unsupported') -and $state -notin $Expected) { throw ('Unexpected preview state '+$state+' for '+$Path) }
    } while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw ('Preview timed out at '+$state+' for '+$Path)
}
function Assert-ExclusiveOpen([string]$Path) {
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $stream.Dispose()
}
function Assert-ColorAndAspect([string]$Path,[string]$Color,[double]$Ratio) {
    $copy=$list.GetThumbnailCopy($Path)
    Assert ($null -ne $copy) 'Ready preview must provide a caller-owned bitmap copy.'
    try {
        Assert ($copy.Width -gt 0 -and $copy.Width -le 40 -and $copy.Height -gt 0 -and $copy.Height -le 40) 'Preview exceeds its 40x40 image area.'
        $left=$copy.Width; $top=$copy.Height; $right=-1; $bottom=-1
        for ($y=0;$y -lt $copy.Height;$y++) {
            for ($x=0;$x -lt $copy.Width;$x++) {
                $pixel=$copy.GetPixel($x,$y)
                $match=if ($Color -eq 'red') { $pixel.A -gt 0 -and $pixel.R -gt 180 -and $pixel.G -lt 80 -and $pixel.B -lt 80 } else { $pixel.A -gt 0 -and $pixel.B -gt 180 -and $pixel.R -lt 80 -and $pixel.G -lt 80 }
                if ($match) { $left=[Math]::Min($left,$x); $right=[Math]::Max($right,$x); $top=[Math]::Min($top,$y); $bottom=[Math]::Max($bottom,$y) }
            }
        }
        Assert ($right -ge $left -and $bottom -ge $top) 'Preview lost the actual source image color.'
        $actual=($right-$left+1)/[double]($bottom-$top+1)
        Assert ([Math]::Abs($actual-$Ratio) -lt 0.25) ('Preview stretched the source aspect ratio: '+$actual)
    } finally { $copy.Dispose() }
    Assert ($list.GetThumbnailState($Path) -eq 'ready') 'Disposing a caller-owned copy invalidated the cached thumbnail.'
}
function Child-ProcessIds {
    return @(Get-CimInstance Win32_Process -Filter ('ParentProcessId='+$PID) | ForEach-Object { [int]$_.ProcessId })
}
function Wait-SlowReader([string]$Path) {
    $timer=[Diagnostics.Stopwatch]::StartNew()
    do {
        Pump-Previews 50
        $markers=@(Get-ChildItem -LiteralPath (Join-Path $fixtureRoot 'SynthTag\ThumbnailWork') -Filter reader-open.txt -File -Recurse -ErrorAction SilentlyContinue)
        foreach ($marker in $markers) {
            if ([IO.File]::ReadAllText($marker.FullName) -eq $Path) { return }
        }
    } while ($timer.Elapsed.TotalSeconds -lt 5)
    throw 'Slow worker did not actually acquire its source handle.'
}
try {
    $null=[IO.Directory]::CreateDirectory($fixtureRoot)
    $env:LOCALAPPDATA=$fixtureRoot
    . (Join-Path $PSScriptRoot '..\app.ps1') -NoUI
    $script:RuntimeRoot=Join-Path $fixtureRoot 'runtime'
    foreach ($method in @('GetThumbnailState','PauseThumbnailLoading','ResumeThumbnailLoading','ClearThumbnails','GetThumbnailCopy')) {
        Assert ($null -ne $list.PSObject.Methods[$method]) ('Preview contract is missing '+$method+'.')
    }
    Assert ($null -ne $list.PSObject.Properties['CachedThumbnailCount']) 'Preview cache count is unavailable.'
    Assert (-not $list.ShowItemToolTips) 'Thumbnail rows must not enable long floating file diagnostics.'
    $landscape=New-ColorFixture '横向 红色[01].png' 80 40 ([Drawing.Color]::Red)
    $portrait=New-ColorFixture '纵向 蓝色[02].jpg' 40 80 ([Drawing.Color]::Blue) 'jpeg'
    $broken=Join-Path $fixtureRoot '损坏预览.png'; [IO.File]::WriteAllBytes($broken,[byte[]]@())
    $video=Join-Path $fixtureRoot '视频占位.mp4'; [IO.File]::WriteAllBytes($video,[byte[]]@())
    $hashes=@{}
    foreach ($file in @($landscape,$portrait,$broken,$video)) { $hashes[$file]=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash }
    $null=Add-PreviewRow $broken 'unreadable'
    $null=Add-PreviewRow $landscape
    $null=Add-PreviewRow $portrait
    $null=Add-PreviewRow $video 'unreadable'
    Update-Counts
    $form.ShowInTaskbar=$false; $form.Show(); Pump-Previews 100
    Assert ((Wait-Preview $landscape @('ready')) -eq 'ready') 'Visible PNG preview did not load.'
    Assert ((Wait-Preview $portrait @('ready')) -eq 'ready') 'Visible JPEG preview did not load.'
    Assert ((Wait-Preview $broken @('failed','unsupported')) -in @('failed','unsupported')) 'Broken image lacks a safe placeholder.'
    Assert ((Wait-Preview $video @('unsupported')) -eq 'unsupported') 'Video should use an explicit unsupported-preview placeholder.'
    Assert-ColorAndAspect $landscape 'red' 2.0
    Assert-ColorAndAspect $portrait 'blue' 0.5
    Assert ((Get-ItemState $script:Items[$broken.ToLowerInvariant()]) -eq 'unreadable') 'Preview failure overwrote the file-processing error state.'
    Assert ((Get-ItemState $script:Items[$landscape.ToLowerInvariant()]) -eq 'untagged') 'Preview success changed tag-processing state.'
    foreach ($file in @($landscape,$portrait,$broken,$video)) {
        Assert ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -eq $hashes[$file]) 'Preview generation changed source bytes.'
        Assert-ExclusiveOpen $file
    }
    Assert ($list.CachedThumbnailCount -ge 2 -and $list.CachedThumbnailCount -le 256) 'Preview cache count is outside its bound.'
    Write-Output 'PASS: visible PNG/JPEG color, aspect ratio, placeholders, processing state, original bytes and released source handles.'
    $metadataIssue=New-ColorFixture '可解码但文件检查异常.png' 80 40 ([Drawing.Color]::Blue)
    $metadataHash=(Get-FileHash -LiteralPath $metadataIssue -Algorithm SHA256).Hash
    $script:LastFileErrors[$metadataIssue.ToLowerInvariant()]='Original metadata validation diagnostic remains unchanged.'
    $metadataRow=Add-PreviewRow $metadataIssue 'unreadable'
    $list.Items.Remove($metadataRow); $null=$list.Items.Insert(0,$metadataRow)
    Update-Counts
    Assert ((Wait-Preview $metadataIssue @('ready')) -eq 'ready') 'File-validation status incorrectly prevented an actually decodable image preview.'
    Assert-ColorAndAspect $metadataIssue 'blue' 2.0
    Assert ((Get-ItemState $metadataRow) -eq 'unreadable' -and $metadataRow.SubItems[2].Text -eq '文件检查异常') 'A successful preview erased the independent file-validation state.'
    Assert ((Get-FileHash -LiteralPath $metadataIssue -Algorithm SHA256).Hash -eq $metadataHash) 'Previewing a validation-failed row changed the source image.'
    Assert-ExclusiveOpen $metadataIssue
    Write-Output 'PASS: a genuinely decodable image previews even with an independent file-validation error; source and processing state remain unchanged.'
    if ($RenderDirectory) {
        $null=[IO.Directory]::CreateDirectory($RenderDirectory)
        $list.Items[0].EnsureVisible(); Pump-Previews 100
        $render=New-Object Drawing.Bitmap($form.Width,$form.Height)
        try { $form.DrawToBitmap($render,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height))); $render.Save((Join-Path $RenderDirectory 'thumbs.png'),[Drawing.Imaging.ImageFormat]::Png) }
        finally { $render.Dispose() }
    }

    Assert ($list.GetThumbnailState($broken) -eq 'failed') 'Broken image must have a cached failure before external repair.'
    $null=New-ColorFixture ([IO.Path]::GetFileName($broken)) 80 40 ([Drawing.Color]::Red)
    Refresh-FileList
    Assert ((Get-ItemState $script:Items[$broken.ToLowerInvariant()]) -eq 'untagged') 'Refresh failed to recognize an externally repaired image at the same path.'
    Assert ((Wait-Preview $broken @('ready')) -eq 'ready') 'Refresh retained a stale failed thumbnail after source repair.'
    Assert-ColorAndAspect $broken 'red' 2.0
    Write-Output 'PASS: refreshing an externally repaired image clears stale errors and loads its actual preview at the same path.'

    $offscreen=New-ColorFixture '屏幕外不主动读取.png' 80 40 ([Drawing.Color]::Red)
    for ($i=0;$i -lt 12;$i++) {
        $filler=Join-Path $fixtureRoot ('占位-'+$i+'.mp4'); [IO.File]::WriteAllBytes($filler,[byte[]]@()); $null=Add-PreviewRow $filler 'unreadable'
    }
    $null=Add-PreviewRow $offscreen
    $list.Items[0].EnsureVisible(); $list.Refresh(); Pump-Previews 200
    Assert ($list.GetThumbnailState($offscreen) -eq 'missing') 'An offscreen row started reading its source before becoming visible.'
    Assert ((Wait-Preview $offscreen @('ready')) -eq 'ready') 'Scrolling the image into view did not request its preview.'
    Write-Output 'PASS: offscreen rows wait until visible before requesting a source preview.'

    $pausedFile=New-ColorFixture '暂停时不得读取.png' 80 40 ([Drawing.Color]::Red)
    $stopwatch=[Diagnostics.Stopwatch]::StartNew()
    Assert ($list.PauseThumbnailLoading()) 'Preview pause could not stop all source readers.'
    Assert ($stopwatch.ElapsedMilliseconds -le 2200) 'Preview pause exceeded the two-second worker termination bound.'
    $beforeChildren=Child-ProcessIds
    $beforeCount=$list.CachedThumbnailCount
    $null=Add-PreviewRow $pausedFile
    $initialState=$list.GetThumbnailState($pausedFile)
    $list.Items[$list.Items.Count-1].EnsureVisible(); $list.Refresh(); Pump-Previews 500
    Assert ($list.GetThumbnailState($pausedFile) -eq $initialState) 'Paused painting advanced a thumbnail request.'
    Assert ($list.CachedThumbnailCount -eq $beforeCount) 'Paused loading mutated the thumbnail cache.'
    $newChildren=@(Child-ProcessIds | Where-Object { $_ -notin $beforeChildren })
    Assert ($newChildren.Count -eq 0) 'Painting while paused created a new worker process.'
    foreach ($file in @($landscape,$portrait,$pausedFile)) { Assert-ExclusiveOpen $file }
    $list.ResumeThumbnailLoading(); $list.Refresh()
    Assert ((Wait-Preview $pausedFile @('ready')) -eq 'ready') 'Preview loading did not recover after resume.'
    Write-Output 'PASS: pause stops readers within two seconds, prevents new workers and preserves cache until resumed.'

    # A real isolated child intentionally holds a source open without replying.
    # This tests cancellation/timeout rather than a provider implementation mock.
    $slowWorker=Join-Path $fixtureRoot 'slow-thumbnail-worker.ps1'
    $slowSource=@'
param([switch]$Worker,[string]$TempDirectory)
$ErrorActionPreference='Stop'
while ($null -ne ($line=[Console]::ReadLine())) {
    $path=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($line))
    $reader=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        [IO.File]::WriteAllText((Join-Path $TempDirectory 'reader-open.txt'),$path)
        Start-Sleep -Seconds 30
    } finally { $reader.Dispose() }
}
'@
    [IO.File]::WriteAllText($slowWorker,$slowSource,(New-Object Text.UTF8Encoding($true)))
    $realWorker=$list.ThumbnailWorkerScript
    try {
        $null=$list.PauseThumbnailLoading(); $list.Items.Clear(); $list.ClearThumbnails()
        $list.ThumbnailWorkerScript=$slowWorker
        $slowPath=New-ColorFixture '必须中止的源读取.png' 80 40 ([Drawing.Color]::Red)
        $slowHash=(Get-FileHash -LiteralPath $slowPath -Algorithm SHA256).Hash
        $null=Add-PreviewRow $slowPath
        $list.ResumeThumbnailLoading(); $list.Refresh()
        Wait-SlowReader $slowPath
        $locked=$false
        try { Assert-ExclusiveOpen $slowPath } catch [IO.IOException] { $locked=$true }
        Assert $locked 'Slow-worker fixture did not reproduce a real open source handle.'
        $stopwatch=[Diagnostics.Stopwatch]::StartNew()
        Assert ($list.PauseThumbnailLoading()) 'Pause failed while a child actively held the source open.'
        Assert ($stopwatch.ElapsedMilliseconds -le 2200) 'Active source-reader cancellation exceeded two seconds.'
        Assert-ExclusiveOpen $slowPath
        Assert ($list.GetThumbnailState($slowPath) -eq 'missing') 'Canceled worker published a stale preview result.'
        Assert ((Get-FileHash -LiteralPath $slowPath -Algorithm SHA256).Hash -eq $slowHash) 'Canceling a preview changed source bytes.'
        Assert (@(Child-ProcessIds).Count -eq 0) 'Canceled source reader remains running.'
        Write-Output 'PASS: pause kills a real child holding an open source handle within two seconds.'

        $list.Items.Clear(); $list.ClearThumbnails()
        $timeoutPath=New-ColorFixture '八秒超时源.png' 80 40 ([Drawing.Color]::Red)
        $timeoutRow=Add-PreviewRow $timeoutPath
        $timeoutRow.ToolTipText=$timeoutPath+"`n原标签诊断必须保留"
        $originalTooltip=$timeoutRow.ToolTipText
        $script:LastFileWarnings[$timeoutPath.ToLowerInvariant()]='原标签诊断必须保留'
        $list.ResumeThumbnailLoading(); $list.Refresh()
        Wait-SlowReader $timeoutPath
        $timeoutTimer=[Diagnostics.Stopwatch]::StartNew()
        Assert ((Wait-Preview $timeoutPath @('failed') 15) -eq 'failed') 'Non-responding source reader did not time out.'
        Assert ($timeoutTimer.Elapsed.TotalSeconds -ge 6 -and $timeoutTimer.Elapsed.TotalSeconds -lt 12) 'Source-reader timeout is outside the configured eight-second bound.'
        Assert-ExclusiveOpen $timeoutPath
        Assert ((Get-ItemState $script:Items[$timeoutPath.ToLowerInvariant()]) -eq 'untagged') 'Thumbnail timeout changed tag-processing state.'
        Pump-Previews 600
        Assert ($timeoutRow.ToolTipText -eq $originalTooltip) 'Preview timeout mutated the disabled row tooltip.'
        $list.SelectedItems.Clear(); $timeoutRow.Selected=$true; $timeoutRow.Focused=$true
        [Windows.Forms.Application]::DoEvents()
        Assert ($ui.DetailBody.Text.Contains('原标签诊断必须保留') -and $ui.DetailBody.Text.Contains('缩略图暂不可用')) 'Preview timeout details omit the original tag diagnostic or independent preview explanation.'
        $logRecords=@(Get-ChildItem -LiteralPath $script:LogDirectory -Filter '*.jsonl' | Get-Content -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
        Assert (@($logRecords | Where-Object { $_.level -eq 'WARNING' -and $_.message -eq 'Thumbnail unavailable' -and $_.data.reason -match '8|超时' }).Count -gt 0) 'Preview timeout did not reach the application WARNING log.'
        $list.ThumbnailWorkerScript=$realWorker
        $afterTimeout=New-ColorFixture '超时后仍可预览.jpg' 40 80 ([Drawing.Color]::Blue) 'jpeg'
        $null=Add-PreviewRow $afterTimeout
        Assert ((Wait-Preview $afterTimeout @('ready')) -eq 'ready') 'A timed-out source blocked following healthy images.'
        Assert-ColorAndAspect $afterTimeout 'blue' 0.5
        Write-Output 'PASS: real eight-second worker timeout releases source handles and healthy requests continue.'
    } finally {
        $null=$list.PauseThumbnailLoading()
        $list.ThumbnailWorkerScript=$realWorker
        $list.ResumeThumbnailLoading()
    }

    if ($StressCache) {
        # Actual visible-row requests, rather than a cache implementation mock.
        # This takes longer because each image is processed in isolation.
        $null=$list.PauseThumbnailLoading(); $list.Items.Clear(); $list.ClearThumbnails()
        $bulk=New-Object 'Collections.Generic.List[string]'
        for ($i=0;$i -lt 260;$i++) {
            $path=Join-Path $fixtureRoot ('缓存-'+$i.ToString('000')+'.png')
            [IO.File]::Copy($landscape,$path,$false); $bulk.Add($path); $null=Add-PreviewRow $path
        }
        $list.ResumeThumbnailLoading()
        foreach ($file in $bulk) {
            $index=$bulk.IndexOf($file); $list.Items[$index].EnsureVisible(); $list.Refresh()
            $null=Wait-Preview $file @('ready')
            Assert ($list.CachedThumbnailCount -le 256) 'Preview LRU cache exceeded 256 items.'
        }
        Assert ($list.CachedThumbnailCount -le 256) 'Cache bound failed after 260 distinct images.'
        Write-Output 'PASS: 260 real visible-row preview requests keep the cache at or below 256.'
    }
    # Clear while another visible request can still be queued/running. Removing
    # rows first prevents a legitimate repaint from requesting them again.
    $clearPending=New-ColorFixture '清空时取消预览.png' 80 40 ([Drawing.Color]::Red)
    $null=Add-PreviewRow $clearPending
    $list.Items[$list.Items.Count-1].EnsureVisible(); $list.Refresh(); Pump-Previews 20
    $list.Items.Clear()
    $list.ClearThumbnails()
    Pump-Previews 100
    Assert ($list.CachedThumbnailCount -eq 0) 'ClearThumbnails retained decoded image cache.'
    Assert ($list.GetThumbnailState($landscape) -eq 'missing') 'ClearThumbnails retained a stale ready state.'
    Assert (@(Child-ProcessIds).Count -eq 0) 'Clearing the list left a thumbnail worker running.'
    $disposePending=New-ColorFixture '关闭时取消预览.png' 80 40 ([Drawing.Color]::Red)
    $null=Add-PreviewRow $disposePending
    $list.ResumeThumbnailLoading(); $list.Refresh(); Pump-Previews 20
    $form.Dispose()
    Assert ($list.CachedThumbnailCount -eq 0) 'Disposal retained decoded image cache.'
    Pump-Previews 100
    Assert (@(Child-ProcessIds).Count -eq 0) 'Disposal left a thumbnail worker running.'
    foreach ($file in @($landscape,$portrait,$pausedFile,$clearPending,$disposePending)) { Assert-ExclusiveOpen $file }
    Write-Output 'PASS: clear/dispose release image cache, worker processes and source handles.'
} finally {
    $env:LOCALAPPDATA=$oldLocalAppData
    if ($form -and -not $form.IsDisposed) { $form.Dispose() }
    $resolved=[IO.Path]::GetFullPath($fixtureRoot)
    $prefix=[IO.Path]::GetTempPath().TrimEnd('\')+'\SynthTag-thumbnail-test-'
    if (-not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe thumbnail fixture cleanup.' }
    if ([IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
