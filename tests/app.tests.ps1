param([string]$RenderDirectory)
$ErrorActionPreference='Stop'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('SynthTag-app-test-'+[guid]::NewGuid().ToString('N'))
$oldCulture=[Threading.Thread]::CurrentThread.CurrentCulture
$oldUICulture=[Threading.Thread]::CurrentThread.CurrentUICulture
$oldLocalAppData=$env:LOCALAPPDATA
function Assert([bool]$Value,[string]$Message) { if (-not $Value) { throw $Message } }
function Get-ControlTree($Root) {
    $Root
    foreach ($child in $Root.Controls) { Get-ControlTree $child }
}
function New-FixtureImage([string]$Name) {
    $file=Join-Path $fixtureRoot $Name
    $bmp=New-Object Drawing.Bitmap(8,8)
    try { $bmp.Save($file,[Drawing.Imaging.ImageFormat]::Png) } finally { $bmp.Dispose() }
    return $file
}
function Assert-CountChip($Control,[int]$Expected,[string]$Message) {
    Assert ($Control.Text -match ('(^|\D)'+$Expected+'(\D|$)')) ($Message+' Actual: '+$Control.Text)
}
try {
    [Threading.Thread]::CurrentThread.CurrentCulture=New-Object Globalization.CultureInfo('zh-CN')
    [Threading.Thread]::CurrentThread.CurrentUICulture=New-Object Globalization.CultureInfo('zh-CN')
    $null=[IO.Directory]::CreateDirectory($fixtureRoot)
    $env:LOCALAPPDATA=$fixtureRoot
    . (Join-Path $PSScriptRoot '..\app.ps1') -NoUI
    $script:RuntimeRoot=Join-Path $fixtureRoot 'runtime'
    $expectedVersion=([IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\VERSION'))).Trim()
    Assert ($form.Text -match [regex]::Escape($expectedVersion)) 'Current software version is missing from window title.'
    Assert ($form.Text -match 'SynthTag.*打AI标签') 'Software name is missing from window title.'
    foreach ($controlName in @('Form','List','Add','Scan','Remove','Files','Folder','Paste','Clear','Settings','Export','Backup','Bar','Status','DetailTitle','DetailBody','CopyDetails','EmptyPanel','TotalCount','PendingCount','TaggedCount','IssueCount','ProgressText')) {
        Assert ($null -ne $ui.$controlName) ('Main interface is missing '+$controlName+'.')
    }
    Assert ($btnSettings.Enabled -and [bool]$btnSettings.Text) 'Settings entry is unavailable.'
    Assert (-not $list.ShowItemToolTips) 'Long row tooltips must stay disabled so they do not obscure the file list.'
    # Show briefly so native ListView selection and Visible properties reflect
    # real WinForms behavior. -NoUI suppresses startup recovery dialogs.
    $form.ShowInTaskbar=$false
    $form.Show()
    [Windows.Forms.Application]::DoEvents()
    $normalSize=$form.Size
    $form.Size=$form.MinimumSize
    $form.PerformLayout(); [Windows.Forms.Application]::DoEvents()
    foreach ($control in @($ui.Files,$ui.Folder,$ui.Paste,$ui.Clear,$ui.Settings,$ui.Scan,$ui.Remove,$ui.Export,$ui.Add)) {
        Assert ($control.Left -ge 0 -and $control.Right -le $control.Parent.ClientSize.Width) ('Action is clipped at minimum window width: '+$control.Text)
    }
    Assert (-not $ui.Remove.Bounds.IntersectsWith($ui.Export.Bounds)) 'Secondary actions overlap when the window is narrow.'
    Assert (-not $ui.Export.Bounds.IntersectsWith($ui.Add.Bounds)) 'Primary action overlaps export when the window is narrow.'
    $form.Size=$normalSize; $form.PerformLayout(); [Windows.Forms.Application]::DoEvents()
    Assert $ui.EmptyPanel.Visible 'Empty list must explain how to add images.'
    Assert-CountChip $ui.TotalCount 0 'Empty total count is incorrect.'
    $path=New-FixtureImage '中文[测试] 图.png'
    $badPath=Join-Path $fixtureRoot '损坏图片.png'
    [IO.File]::WriteAllBytes($badPath,[byte[]]@())
    Add-Paths @($path,$badPath)
    Assert ($list.Items.Count -eq 2) 'Both fixture paths must appear.'
    Assert ((Get-ItemState $script:Items[$path.ToLowerInvariant()]) -eq 'untagged') 'Valid PNG must be pending tag.'
    Assert ((Get-ItemState $script:Items[$badPath.ToLowerInvariant()]) -eq 'unreadable') 'Broken PNG must show read failure.'
    Assert ($script:Items[$badPath.ToLowerInvariant()].SubItems[2].Text -eq '文件检查异常') 'File validation failure is mislabeled as a thumbnail read failure.'
    Assert ($script:Items[$badPath.ToLowerInvariant()].ToolTipText -match 'empty|空') 'Failure tooltip lacks actual reason.'
    Assert (-not $ui.EmptyPanel.Visible) 'Empty-state instructions obscure the populated list.'
    Assert-CountChip $ui.TotalCount 2 'Total must count both fixtures.'
    Assert-CountChip $ui.PendingCount 1 'Only the healthy image is pending.'
    Assert-CountChip $ui.TaggedCount 0 'No image has been tagged yet.'
    Assert-CountChip $ui.IssueCount 1 'Broken image must remain visible in issue count.'
    $previewTimer=[Diagnostics.Stopwatch]::StartNew()
    do {
        $list.Refresh(); [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 30
        $previewState=$list.GetThumbnailState($path)
    } while ($previewState -in @('pending','missing') -and $previewTimer.Elapsed.TotalSeconds -lt 20)
    Assert ($previewState -eq 'ready') ('Healthy listed PNG lacks a real thumbnail: '+$previewState)
    Add-Paths @($path,$badPath)
    Assert ($list.Items.Count -eq 2 -and $lblStatus.Text -notmatch '正在' -and $lblStatus.Text -match '已在列表') 'Duplicate-only drop leaves a false processing indicator.'
    $brokenItem=$script:Items[$badPath.ToLowerInvariant()]
    foreach ($selected in @($list.SelectedItems)) { $selected.Selected=$false }
    $brokenItem.Selected=$true; $brokenItem.Focused=$true
    [Windows.Forms.Application]::DoEvents()
    $details=$ui.DetailTitle.Text+' '+$ui.DetailBody.Text
    Assert ($details -match [regex]::Escape([IO.Path]::GetFileName($badPath))) 'Selection details omit the affected filename.'
    Assert ($details -match 'empty|空') 'Selection details omit the actual error reason.'
    Assert ($details -match '文件.*(读取|校验)' -and $details -match '不代表缩略图加载失败') 'File-check explanation must distinguish file/tag validation from preview loading.'
    $originalDiagnostic=$script:LastFileErrors[$badPath.ToLowerInvariant()]
    Assert ($details.Contains($originalDiagnostic)) 'Chinese explanation discarded the original diagnostic text.'
    Assert $ui.CopyDetails.Enabled 'Detailed error cannot be copied.'
    # The enabled Copy Details action uses these same title/body values; leave
    # the user's global Windows clipboard untouched during automated tests.
    Assert ($ui.DetailTitle.Text.Contains('文件检查异常') -and $ui.DetailBody.Text.Contains($originalDiagnostic) -and $ui.DetailBody.Text.Contains('不代表缩略图加载失败')) 'Copy-ready details omit the Chinese explanation or original diagnostic.'
    # Display copy can change without changing the logical processing state.
    $displayText=$brokenItem.SubItems[2].Text
    $brokenItem.SubItems[2].Text='测试显示文本'
    Assert ((Get-ItemState $brokenItem) -eq 'unreadable') 'Logical state must not depend on translated status text.'
    $brokenItem.SubItems[2].Text=$displayText
    $script:Busy=$true
    Set-Buttons $false
    $bar.Value=0; $bar.Maximum=8
    Assert ($ui.ProgressText.Text -eq '0 / 8') 'Progress total is stale before the first completed file.'
    Update-Counts
    foreach ($control in @($ui.Add,$ui.Scan,$ui.Remove,$ui.Files,$ui.Folder,$ui.Paste,$ui.Clear,$ui.Backup)) {
        Assert (-not $control.Enabled) 'File-changing controls must be disabled while a batch is running.'
    }
    $duringBatch=New-FixtureImage '处理中不应插入.png'
    Add-Paths @($duringBatch)
    Assert ($list.Items.Count -eq 2) 'File-drop events must not mutate the list during a running batch.'
    $script:Busy=$false
    Set-Buttons $true
    Update-Counts
    $counts=@{}
    $bar.Maximum=2; $bar.Value=0
    Invoke-Chunked @($path) 'add' 'added' ([ref]$counts)
    Assert ($counts.added -eq 1) 'UI write action did not report a verified add.'
    $counts=@{}
    Invoke-Chunked @($path) 'remove' 'removed' ([ref]$counts)
    Assert ($counts.removed -eq 1) 'UI remove action failed.'
    Update-Counts
    Assert $btnAdd.Enabled 'Removed image cannot be tagged again.'
    Assert-CountChip $ui.PendingCount 1 'Removed image must return to pending count.'
    $counts=@{}
    Invoke-Chunked @($path) 'add' 'added' ([ref]$counts)
    Assert ($counts.added -eq 1) 'A removed image must actually support tagging again.'
    Update-Counts
    Assert (-not $script:Items[$path.ToLowerInvariant()].Font.Strikeout) 'Tagged filenames must remain readable without strikeout.'
    Assert-CountChip $ui.TaggedCount 1 'Tagged count does not reflect re-add.'
    $backupPath=New-FixtureImage '保留备份[测试].png'
    $beforeBackup=(Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash
    # Processing a new drop must append without discarding prior results/errors.
    $script:OpDone=$true
    Add-Paths @($backupPath)
    Assert ($list.Items.Count -eq 3) 'Adding after completion must append and preserve existing results.'
    Assert ($script:Items.ContainsKey($badPath.ToLowerInvariant())) 'New drop discarded the earlier error record.'
    $chkBackup.Checked=$true
    $counts=@{}
    $bar.Maximum=3
    Invoke-Chunked @($backupPath) 'add' 'added' ([ref]$counts)
    Assert ($counts.added -eq 1) 'Backup-enabled UI operation failed.'
    Assert ((Get-FileHash -LiteralPath ($backupPath+'_original') -Algorithm SHA256).Hash -eq $beforeBackup) 'UI backup option does not preserve exact original bytes.'
    $chkBackup.Checked=$false
    Update-Counts
    # A completed removal with a cleanup warning must still be eligible for add.
    $warningPath=New-FixtureImage '已移除有警告.png'
    Add-Paths @($warningPath)
    $originalWriter=${function:Set-SafeFileTag}
    try {
        function Set-SafeFileTag { param($File,$Mode,$KeepBackup) [pscustomobject]@{ Success=$true; Warning='测试：清理备份失败，原始副本保留'; Error=''; RecoveryPath='' } }
        $counts=@{}; $bar.Maximum=4; $bar.Value=0
        Invoke-Chunked @($warningPath) 'remove' 'removed' ([ref]$counts)
        Assert ($counts.removed -eq 1 -and $counts.warning -eq 1) 'Warning must count as both completed action and warning, not hide a successful removal.'
    } finally { ${function:Set-SafeFileTag}=$originalWriter }
    Update-Counts
    $warningItem=$script:Items[$warningPath.ToLowerInvariant()]
    Assert ((Get-ItemState $warningItem) -eq 'warning' -and (Get-LogicalState $warningItem) -eq 'removed') 'Warning lost the actual removal outcome.'
    Assert ($warningItem.SubItems[2].Text -match '已移除') 'Warning text hides that tag removal completed.'
    Assert $ui.Add.Enabled 'A completed removal with a warning cannot be tagged again.'
    Assert-CountChip $ui.PendingCount 1 'Removal warning is missing from pending count.'
    Assert-CountChip $ui.IssueCount 2 'Warning is missing from issue count.'
    $list.SelectedItems.Clear(); [Windows.Forms.Application]::DoEvents()
    Assert (-not $ui.CopyDetails.Enabled -and $ui.DetailBody.Text -notmatch 'File is empty') 'Clearing selection leaves stale error details.'
    $brokenItem.Selected=$true; $warningItem.Selected=$true; [Windows.Forms.Application]::DoEvents()
    Assert ($ui.DetailTitle.Text -match '2' -and -not $ui.CopyDetails.Enabled) 'Multi-selection displays stale single-file details.'
    $warningItem.Selected=$false; [Windows.Forms.Application]::DoEvents()
    $lblStatus.Text='处理完成。共 4 个文件，2 个已有标签，2 个需关注。'
    $settings=New-SettingsDialog
    try {
        $settingsControls=@(Get-ControlTree $settings)
        $settingsText=($settingsControls | ForEach-Object Text) -join ' '
        Assert ($settingsText -match [regex]::Escape($expectedVersion)) 'Settings omit the current software version.'
        Assert ($settingsText -match '30\s*天') 'Settings omit the log retention period.'
        Assert ($settingsText -match '(不包含|不含|不会包含|不会打包).*(图片|原图|文件内容)') 'Settings omit image privacy explanation.'
        $settingsButtons=@($settingsControls | Where-Object { $_ -is [Windows.Forms.Button] })
        Assert (@($settingsButtons | Where-Object { $_.Text -match '日志' -and $_.Enabled }).Count -gt 0) 'Settings omit an accessible log-directory action.'
        Assert (@($settingsButtons | Where-Object { $_.Text -match '诊断|压缩包' -and $_.Enabled }).Count -gt 0) 'Settings omit an accessible diagnostic-export action.'
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
    $form.Show()
    $ui.Clear.PerformClick()
    [Windows.Forms.Application]::DoEvents()
    Assert ($list.Items.Count -eq 0) 'Clear action leaves stale list entries.'
    Assert $ui.EmptyPanel.Visible 'Clear action does not restore empty-state instructions.'
    Assert-CountChip $ui.TotalCount 0 'Clear action leaves a stale total count.'
    Assert-CountChip $ui.IssueCount 0 'Clear action leaves a stale issue count.'
    Assert ($list.CachedThumbnailCount -eq 0) 'UI clear action retained thumbnail cache.'
    Assert ([IO.File]::Exists($path) -and [IO.File]::Exists($badPath) -and [IO.File]::Exists($backupPath+'_original')) 'Clearing the list must not delete source images or backups.'
    if ($RenderDirectory) {
        $render=New-Object Drawing.Bitmap($form.Width,$form.Height)
        try { $form.DrawToBitmap($render,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height))); $render.Save((Join-Path $RenderDirectory 'empty.png'),[Drawing.Imaging.ImageFormat]::Png) }
        finally { $render.Dispose() }
    }
    Write-Output 'PASS: current-version Chinese UI, empty state, mixed input, counts, error details, explicit state, busy guards, add/remove/re-add, append, exact backups, settings and rendering.'
} finally {
    [Threading.Thread]::CurrentThread.CurrentCulture=$oldCulture
    [Threading.Thread]::CurrentThread.CurrentUICulture=$oldUICulture
    $env:LOCALAPPDATA=$oldLocalAppData
    if ($form) { $form.Dispose() }
    $resolved=[IO.Path]::GetFullPath($fixtureRoot)
    $expected=[IO.Path]::GetTempPath().TrimEnd('\')+'\SynthTag-app-test-'
    if (-not $resolved.StartsWith($expected,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup.' }
    if ([IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
