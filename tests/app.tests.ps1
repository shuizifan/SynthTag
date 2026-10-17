param([string]$RenderDirectory)
$ErrorActionPreference='Stop'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('SynthTag-app-test-'+[guid]::NewGuid().ToString('N'))
$oldCulture=[Threading.Thread]::CurrentThread.CurrentCulture
$oldUICulture=[Threading.Thread]::CurrentThread.CurrentUICulture
function Assert([bool]$Value,[string]$Message) { if (-not $Value) { throw $Message } }
try {
    [Threading.Thread]::CurrentThread.CurrentCulture=New-Object Globalization.CultureInfo('zh-CN')
    [Threading.Thread]::CurrentThread.CurrentUICulture=New-Object Globalization.CultureInfo('zh-CN')
    $null=[IO.Directory]::CreateDirectory($fixtureRoot)
    . (Join-Path $PSScriptRoot '..\app.ps1') -NoUI
    $script:RuntimeRoot=Join-Path $fixtureRoot 'runtime'
    Assert ($form.Text -eq 'SynthTag（打AI标签） v1.1.0') 'Title/version mismatch.'
    Assert ($btnSettings.Text -eq '设置…') 'Settings entry missing.'
    $path=Join-Path $fixtureRoot '中文[测试] 图.png'
    $badPath=Join-Path $fixtureRoot '损坏图片.png'
    $bmp=New-Object Drawing.Bitmap(8,8)
    try { $bmp.Save($path,[Drawing.Imaging.ImageFormat]::Png) } finally { $bmp.Dispose() }
    [IO.File]::WriteAllBytes($badPath,[byte[]]@())
    Add-Paths @($path,$badPath)
    Assert ($list.Items.Count -eq 2) 'Both fixture paths must appear.'
    Assert ((Get-ItemState $script:Items[$path.ToLowerInvariant()]) -eq 'untagged') 'Valid PNG must be pending tag.'
    Assert ((Get-ItemState $script:Items[$badPath.ToLowerInvariant()]) -eq 'unreadable') 'Broken PNG must show read failure.'
    Assert ($script:Items[$badPath.ToLowerInvariant()].ToolTipText -match 'empty|空') 'Failure tooltip lacks actual reason.'
    Assert ($script:CountSummary -match '待打标签 1.*异常 1') 'Counts falsely treat broken file as readable.'
    $counts=@{}
    $bar.Maximum=2; $bar.Value=0
    Invoke-Chunked @($path) 'add' 'added' ([ref]$counts)
    Assert ($counts.added -eq 1) 'UI write action did not report a verified add.'
    $counts=@{}
    Invoke-Chunked @($path) 'remove' 'removed' ([ref]$counts)
    Assert ($counts.removed -eq 1) 'UI remove action failed.'
    Update-Counts
    Assert ($btnAdd.Enabled -and $script:CountSummary -match '待打标签 1') 'Removed image cannot be tagged again.'
    $settings=New-SettingsDialog
    try {
        Assert ($settings.Controls.Count -eq 3) 'Diagnostic settings controls missing.'
        Assert ($settings.Controls[0].Text -match '30天' -and $settings.Controls[0].Text -match '不包含图片') 'Settings missing retention/privacy explanation.'
        if ($RenderDirectory) {
            $null=[IO.Directory]::CreateDirectory($RenderDirectory)
            foreach ($view in @(@($form,'main.png'),@($settings,'settings.png'))) {
                $window=$view[0]
                $window.Show()
                [Windows.Forms.Application]::DoEvents()
                $render=New-Object Drawing.Bitmap($window.Width,$window.Height)
                try { $window.DrawToBitmap($render,(New-Object Drawing.Rectangle(0,0,$window.Width,$window.Height))); $render.Save((Join-Path $RenderDirectory $view[1]),[Drawing.Imaging.ImageFormat]::Png) }
                finally { $render.Dispose(); $window.Hide() }
            }
        }
    } finally { $settings.Dispose() }
    Write-Output 'PASS: Chinese Windows UI flow, mixed healthy/broken input, tooltips, add/remove/re-add, settings and version.'
} finally {
    [Threading.Thread]::CurrentThread.CurrentCulture=$oldCulture
    [Threading.Thread]::CurrentThread.CurrentUICulture=$oldUICulture
    if ($form) { $form.Dispose() }
    $resolved=[IO.Path]::GetFullPath($fixtureRoot)
    $expected=[IO.Path]::GetTempPath().TrimEnd('\')+'\SynthTag-app-test-'
    if (-not $resolved.StartsWith($expected,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup.' }
    if ([IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
