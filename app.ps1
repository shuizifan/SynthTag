# -*- coding: utf-8-bom -*-
# AI 人物标签批量工具（开箱即用版）
# Windows 自带 PowerShell + 内置 ExifTool，无需安装任何软件。
# 功能：批量写入/体检/移除 XMP dc:subject 中的 contains-synthetic-performer

param([switch]$NoUI)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------- 任务栏身份 ----------------
# 宿主进程是 powershell.exe，若不显式声明 AppUserModelID，
# 任务栏会沿用 PowerShell 的图标。必须在创建任何窗口之前调用。
try {
    Add-Type -Namespace SynthTag -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int SetCurrentProcessExplicitAppUserModelID(string AppID);

[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr SendMessage(System.IntPtr hWnd, int Msg, System.IntPtr wParam, System.IntPtr lParam);
'@ -ErrorAction Stop
    $null = [SynthTag.Native]::SetCurrentProcessExplicitAppUserModelID('Vincent.SynthTag')
    $script:HasNative = $true
} catch {
    $script:HasNative = $false   # 无 C# 编译器时降级，不影响功能
}

# ---------------- 常量 ----------------
$TAG  = 'contains-synthetic-performer'
$EXTS = @('.jpg','.jpeg','.png','.tif','.tiff','.webp','.mp4','.mov','.m4v','.3gp')
$VIDEO_EXTS = @('.mp4','.mov','.m4v','.3gp')
# 分块大小固定为 100（写死在循环里，避免与 $slice 等变量名冲突）

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ExifTool  = Join-Path $ScriptDir 'exiftool_bin\exiftool.exe'
$AppVersion = ([IO.File]::ReadAllText((Join-Path $ScriptDir 'VERSION'))).Trim()
. (Join-Path $ScriptDir 'runtime.ps1')
Initialize-SynthTagRuntime -Version $AppVersion -ExifTool $ExifTool
[Windows.Forms.Application]::SetUnhandledExceptionMode([Windows.Forms.UnhandledExceptionMode]::CatchException)
[Windows.Forms.Application]::add_ThreadException({
    param($sender,$eventArgs)
    Write-AppLog -Level ERROR -Message 'Unhandled UI exception' -Data $eventArgs.Exception
    [Windows.Forms.MessageBox]::Show('发生未处理异常：'+$eventArgs.Exception.Message+"`n请在设置中导出诊断包。",'SynthTag','OK','Error') | Out-Null
})
if (-not (Test-Path $ExifTool)) {
    [System.Windows.Forms.MessageBox]::Show(
        "未找到 exiftool_bin\exiftool.exe`n请确保 exiftool_bin 文件夹与本程序在同一目录。",
        '缺少组件', 'OK', 'Error') | Out-Null
    exit 1
}

$STATUS_TEXT = @{
    pending='待处理'; tagged='√ 已打标签'; untagged='× 未打标签'
    duplicate='! 重复标签'; unreadable='× 读取失败'; added='√ 已添加'
    warning='! 已写入，有警告'; fixed_duplicate='√ 已去重'; skipped='— 跳过'; removed='√ 已移除'; failed='× 失败'
}
$PROBLEM = @('untagged','duplicate','unreadable','failed','warning')

# 独立的日志与安全文件处理模块（单文件版也随包解压）
. (Join-Path $ScriptDir 'metadata.ps1')

# ---------------- 界面 ----------------
$form = New-Object Windows.Forms.Form
$form.Text = "SynthTag（打AI标签） v$AppVersion"
$form.Size = New-Object Drawing.Size(900, 640)
$form.MinimumSize = New-Object Drawing.Size(720, 500)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
$form.AllowDrop = $true
# 窗口/任务栏图标（单文件版解压到同目录，文件夹版在 assets\ 下）
$script:AppIcon = $null
foreach ($p in @((Join-Path $ScriptDir 'SynthTag.ico'), (Join-Path $ScriptDir 'assets\SynthTag.ico'))) {
    if (Test-Path -LiteralPath $p) {
        try {
            $script:AppIcon = New-Object Drawing.Icon($p)
            $form.Icon = $script:AppIcon
        } catch { }
        break
    }
}
# 窗口句柄创建后再显式发一次 WM_SETICON，确保任务栏拿到大小两种图标
$form.Add_Shown({
    if ($script:HasNative -and $script:AppIcon) {
        try {
            $h = $script:AppIcon.Handle
            $null = [SynthTag.Native]::SendMessage($form.Handle, 0x0080, [IntPtr]1, $h)  # ICON_BIG
            $null = [SynthTag.Native]::SendMessage($form.Handle, 0x0080, [IntPtr]0, $h)  # ICON_SMALL
        } catch { }
    }
})

$lblHint = New-Object Windows.Forms.Label
$lblHint.Text = '拖入文件/文件夹，或按 Ctrl+V 粘贴路径（子目录自动递归；选中后按 Delete 移出列表）'
$lblHint.ForeColor = [Drawing.Color]::DimGray
$lblHint.Location = New-Object Drawing.Point(12, 10)
$lblHint.AutoSize = $true

$btnFiles  = New-Object Windows.Forms.Button
$btnFiles.Text = '添加文件…';   $btnFiles.Location = New-Object Drawing.Point(12, 34);  $btnFiles.Size = New-Object Drawing.Size(90, 28)
$btnFolder = New-Object Windows.Forms.Button
$btnFolder.Text = '添加文件夹…'; $btnFolder.Location = New-Object Drawing.Point(108, 34); $btnFolder.Size = New-Object Drawing.Size(100, 28)
$btnClear  = New-Object Windows.Forms.Button
$btnClear.Text = '清空列表';     $btnClear.Location = New-Object Drawing.Point(214, 34);  $btnClear.Size = New-Object Drawing.Size(80, 28)

$btnSettings = New-Object Windows.Forms.Button
$btnSettings.Text = '设置…'; $btnSettings.Location = New-Object Drawing.Point(310,34); $btnSettings.Size = New-Object Drawing.Size(80,28)

$chkBackup = New-Object Windows.Forms.CheckBox
$chkBackup.Text = '保留 _original 备份'
$chkBackup.Checked = $false
$chkBackup.AutoSize = $true
$chkBackup.Location = New-Object Drawing.Point(720, 40)
$chkBackup.Anchor = 'Top,Right'

$list = New-Object Windows.Forms.ListView
$list.View = 'Details'
$list.FullRowSelect = $true
$list.GridLines = $true
$list.HideSelection = $false
$list.ShowItemToolTips = $true
$list.Location = New-Object Drawing.Point(12, 70)
$list.Size = New-Object Drawing.Size(860, 420)
$list.Anchor = 'Top,Bottom,Left,Right'
$null = $list.Columns.Add('文件名', 260)
$null = $list.Columns.Add('类型', 55)
$null = $list.Columns.Add('状态', 120)
$null = $list.Columns.Add('所在文件夹', 400)
$list.AllowDrop = $true

# 右键菜单（借鉴文件管理类软件的常用操作）
$menu = New-Object Windows.Forms.ContextMenuStrip
$miOpenFolder = $menu.Items.Add('打开所在文件夹')
$miCopyPath   = $menu.Items.Add('复制完整路径')
$null = $menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
$miRemoveSel  = $menu.Items.Add('从列表移除选中项   Delete')
$miKeepSel    = $menu.Items.Add('仅保留选中项')
$null = $menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
$miPaste      = $menu.Items.Add('粘贴路径添加   Ctrl+V')
$miSelectAll  = $menu.Items.Add('全选   Ctrl+A')
$list.ContextMenuStrip = $menu

# 主操作按钮（强调）
$btnAdd = New-Object Windows.Forms.Button
$btnAdd.Text = '开始添加标签'
$btnAdd.Size = New-Object Drawing.Size(170, 40)
$btnAdd.Font = New-Object Drawing.Font('Microsoft YaHei UI', 10.5, [Drawing.FontStyle]::Bold)
$btnAdd.BackColor = [Drawing.Color]::FromArgb(0, 120, 212)
$btnAdd.ForeColor = [Drawing.Color]::White
$btnAdd.FlatStyle = 'Flat'
$btnAdd.FlatAppearance.BorderSize = 0
# 次要操作按钮（弱化）
$btnScan   = New-Object Windows.Forms.Button
$btnScan.Text = '体检扫描';   $btnScan.Size = New-Object Drawing.Size(80, 26)
$btnScan.FlatStyle = 'Flat';  $btnScan.ForeColor = [Drawing.Color]::Gray
$btnScan.FlatAppearance.BorderColor = [Drawing.Color]::LightGray
$btnRemove = New-Object Windows.Forms.Button
$btnRemove.Text = '移除标签'; $btnRemove.Size = New-Object Drawing.Size(80, 26)
$btnRemove.FlatStyle = 'Flat'; $btnRemove.ForeColor = [Drawing.Color]::Gray
$btnRemove.FlatAppearance.BorderColor = [Drawing.Color]::LightGray
$btnExport = New-Object Windows.Forms.Button
$btnExport.Text = '导出问题清单…'; $btnExport.Size = New-Object Drawing.Size(120, 26)
$btnExport.FlatStyle = 'Flat'; $btnExport.ForeColor = [Drawing.Color]::Gray
$btnExport.FlatAppearance.BorderColor = [Drawing.Color]::LightGray
$btnAdd.Location    = New-Object Drawing.Point(12, 496);  $btnAdd.Anchor = 'Bottom,Left'
$btnScan.Location   = New-Object Drawing.Point(200, 503); $btnScan.Anchor = 'Bottom,Left'
$btnRemove.Location = New-Object Drawing.Point(288, 503); $btnRemove.Anchor = 'Bottom,Left'
$btnExport.Location = New-Object Drawing.Point(752, 503); $btnExport.Anchor = 'Bottom,Right'

$bar = New-Object Windows.Forms.ProgressBar
$bar.Location = New-Object Drawing.Point(12, 540)
$bar.Size = New-Object Drawing.Size(860, 14)
$bar.Anchor = 'Bottom,Left,Right'

$lblStatus = New-Object Windows.Forms.Label
$lblStatus.Text = '就绪。请拖入文件或文件夹。'
$lblStatus.Location = New-Object Drawing.Point(12, 560)
$lblStatus.Size = New-Object Drawing.Size(860, 30)
$lblStatus.Anchor = 'Bottom,Left,Right'

$form.Controls.AddRange(@($lblHint,$btnFiles,$btnFolder,$btnClear,$btnSettings,$chkBackup,
                          $list,$btnAdd,$btnScan,$btnRemove,$btnExport,$bar,$lblStatus))

# ---------------- 列表管理 ----------------
$script:Items = @{}   # 小写全路径 -> ListViewItem
$script:Busy = $false
$script:OpDone = $false
$script:CountSummary = ''
# 共享字体对象（避免每行新建 Font 占用 GDI 资源）
$script:FontNormal = $list.Font
$script:FontStrike = New-Object Drawing.Font($list.Font, [Drawing.FontStyle]::Strikeout)

function Add-Paths([string[]]$paths) {
    if ($script:Busy) { return }
    # 上一次操作已完成 -> 再次拖入/添加文件时自动清空列表, 开始新一批
    if ($script:OpDone) {
        $list.Items.Clear()
        $script:Items = @{}
        $script:OpDone = $false
    }
    $files = New-Object Collections.Generic.List[string]
    foreach ($p in $paths) {
        if (Test-Path -LiteralPath $p -PathType Container) {
            Get-ChildItem -LiteralPath $p -Recurse -File |
                Where-Object { $EXTS -contains $_.Extension.ToLower() } |
                ForEach-Object { $files.Add($_.FullName) }
        } elseif (Test-Path -LiteralPath $p -PathType Leaf) {
            if ($EXTS -contains ([IO.Path]::GetExtension($p).ToLower())) {
                $files.Add([IO.Path]::GetFullPath($p))
            }
        }
    }
    $added = 0
    $newFiles = New-Object Collections.Generic.List[string]
    $list.BeginUpdate()
    foreach ($f in $files) {
        $key = $f.ToLower()
        if (-not $script:Items.ContainsKey($key)) {
            $ext = [IO.Path]::GetExtension($f).ToLower()
            $type = if ($VIDEO_EXTS -contains $ext) { '视频' } else { '图片' }
            $it = New-Object Windows.Forms.ListViewItem([IO.Path]::GetFileName($f))
            $null = $it.SubItems.Add($type)
            $null = $it.SubItems.Add($STATUS_TEXT.pending)
            $null = $it.SubItems.Add([IO.Path]::GetDirectoryName($f))
            $it.Tag = $f
            $it.ToolTipText = $f
            $null = $list.Items.Add($it)
            $script:Items[$key] = $it
            $newFiles.Add($f)
            $added++
        }
    }
    $list.EndUpdate()
    $lblStatus.Text = "已加入 $added 个文件，共 $($list.Items.Count) 个。正在检查标签状态…"
    Update-Counts
    [Windows.Forms.Application]::DoEvents()
    # 加入后立即回读一次, 让用户马上看到哪些已有标签(划删除线)
    if ($newFiles.Count -gt 0) { Update-TagStatus $newFiles }
}

function Update-TagStatus([string[]]$files) {
    # 只读不改: 标出 已打标签 / 未打标签 / 重复 / 读取失败
    if ($script:Busy -or $files.Count -eq 0) { return }
    $script:Busy = $true; Set-Buttons $false
    try {
        $subjMap = Get-Subjects $files
        $list.BeginUpdate()
        foreach ($f in $files) {
            $subj = $null
            if ($subjMap.ContainsKey($f.ToLower())) { $subj = $subjMap[$f.ToLower()] }
            Set-ItemStatus $f (Get-FileState $subj)
        }
        $list.EndUpdate()
    } catch {
        Write-AppLog -Level ERROR -Message 'Tag status check failed' -Data $_
        $lblStatus.Text = "标签状态检查失败: $($_.Exception.Message)"
        return
    } finally {
        $script:Busy = $false; Set-Buttons $true
    }
    Update-Counts
    $lblStatus.Text = "$script:CountSummary（划删除线 = 已有标签，无需处理）"
}

function Set-ItemStatus([string]$file, [string]$state) {
    $it = $script:Items[$file.ToLower()]
    if (-not $it) { return }
    $it.SubItems[2].Text = $STATUS_TEXT[$state]
    $reason = $script:LastFileErrors[$file.ToLowerInvariant()]
    if (-not $reason) { $reason=$script:LastFileWarnings[$file.ToLowerInvariant()] }
    $it.ToolTipText = $file + $(if ($reason) { "`n" + $reason } else { '' })
    # 已有标签的文件: 划删除线 + 灰色, 一眼看出本次无需处理
    $done = @('tagged','added','fixed_duplicate','skipped')
    if ($state -in $done) { $it.Font = $script:FontStrike } else { $it.Font = $script:FontNormal }
    if ($PROBLEM -contains $state -and $state -ne 'untagged') {
        $it.ForeColor = [Drawing.Color]::Firebrick
    } elseif ($state -eq 'untagged') {
        $it.ForeColor = [Drawing.Color]::FromArgb(0, 90, 158)   # 待处理: 蓝色, 是本次要动的
    } elseif ($state -in @('added','fixed_duplicate','removed')) {
        $it.ForeColor = [Drawing.Color]::ForestGreen
    } else {
        $it.ForeColor = [Drawing.Color]::Gray                    # 已打标签/跳过: 灰
    }
}

function Get-ItemState($it) {
    $txt = $it.SubItems[2].Text
    foreach ($k in $STATUS_TEXT.Keys) { if ($STATUS_TEXT[$k] -eq $txt) { return $k } }
    return 'pending'
}

function Update-Counts {
    # 主按钮上实时显示"本次真正会被写入的数量"
    $total = $list.Items.Count
    $todo = 0; $tagged = 0; $bad = 0
    foreach ($it in $list.Items) {
        switch (Get-ItemState $it) {
            'untagged'  { $todo++ }
            'duplicate' { $todo++ }
            'pending'   { $todo++ }
            'tagged'    { $tagged++ }
            'added'     { $tagged++ }
            'fixed_duplicate' { $tagged++ }
            'skipped'   { $tagged++ }
            'removed'   { $todo++ }
            'unreadable' { $bad++ }
            'failed'    { $bad++ }
            'warning'   { $bad++ }
        }
    }
    $btnAdd.Text = if ($todo -gt 0) { "开始添加标签 ($todo)" } else { '开始添加标签' }
    $btnAdd.Enabled = ($todo -gt 0) -and (-not $script:Busy)
    $script:CountSummary = "共 $total 个 — 待打标签 $todo，已有标签 $tagged" + $(if ($bad) { "，异常 $bad" } else { '' })
}

function Add-FromClipboard {
    # 支持两种粘贴: 1) 在资源管理器里 Ctrl+C 复制的文件/文件夹  2) 纯文本路径(可多行)
    if ($script:Busy) { return }
    $paths = @()
    try {
        if ([Windows.Forms.Clipboard]::ContainsFileDropList()) {
            $paths = @([Windows.Forms.Clipboard]::GetFileDropList())
        } elseif ([Windows.Forms.Clipboard]::ContainsText()) {
            $paths = @([Windows.Forms.Clipboard]::GetText() -split "`r?`n" |
                       ForEach-Object { $_.Trim().Trim('"') } |
                       Where-Object { $_ -and (Test-Path -LiteralPath $_) })
        }
    } catch { }
    if ($paths.Count -gt 0) { Add-Paths $paths }
    else { $lblStatus.Text = '剪贴板里没有可用的文件或文件夹路径。' }
}

function Remove-Selected {
    if ($script:Busy -or $list.SelectedItems.Count -eq 0) { return }
    $n = $list.SelectedItems.Count
    $list.BeginUpdate()
    foreach ($it in @($list.SelectedItems)) {
        $script:Items.Remove(([string]$it.Tag).ToLower())
        $list.Items.Remove($it)
    }
    $list.EndUpdate()
    Update-Counts
    $lblStatus.Text = "已从列表移除 $n 个（文件本身未改动）。$script:CountSummary"
}

# ---------------- 拖拽 ----------------
$dragEnter = { param($s,$e) if ($e.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) { $e.Effect = 'Copy' } }
$dragDrop  = { param($s,$e) Add-Paths ($e.Data.GetData([Windows.Forms.DataFormats]::FileDrop)) }
$form.Add_DragEnter($dragEnter); $form.Add_DragDrop($dragDrop)
$list.Add_DragEnter($dragEnter); $list.Add_DragDrop($dragDrop)

# ---------------- 键盘快捷键 ----------------
$list.Add_KeyDown({
    param($s,$e)
    if ($e.KeyCode -eq 'Delete' -or $e.KeyCode -eq 'Back') {
        Remove-Selected
        $e.Handled = $true; $e.SuppressKeyPress = $true    # 屏蔽退格键的系统提示音
    } elseif ($e.Control -and $e.KeyCode -eq 'A') {
        foreach ($it in $list.Items) { $it.Selected = $true }
        $e.Handled = $true; $e.SuppressKeyPress = $true
    } elseif ($e.Control -and $e.KeyCode -eq 'V') {
        Add-FromClipboard
        $e.Handled = $true; $e.SuppressKeyPress = $true
    } elseif ($e.KeyCode -eq 'F5') {
        Update-TagStatus (Get-AllFiles)
        $e.Handled = $true; $e.SuppressKeyPress = $true
    }
})

# 双击打开所在文件夹并选中该文件
function Open-InExplorer($it) {
    if ($it) { Start-Process explorer.exe -ArgumentList "/select,`"$($it.Tag)`"" }
}
$list.Add_DoubleClick({ Open-InExplorer $list.FocusedItem })

# ---------------- 右键菜单 ----------------
$miOpenFolder.Add_Click({ Open-InExplorer $list.FocusedItem })
$miCopyPath.Add_Click({
    if ($list.SelectedItems.Count -gt 0) {
        $txt = (@($list.SelectedItems | ForEach-Object { $_.Tag }) -join "`r`n")
        [Windows.Forms.Clipboard]::SetText($txt)
        $lblStatus.Text = "已复制 $($list.SelectedItems.Count) 个路径到剪贴板。"
    }
})
$miRemoveSel.Add_Click({ Remove-Selected })
$miKeepSel.Add_Click({
    if ($script:Busy -or $list.SelectedItems.Count -eq 0) { return }
    $keep = @{}
    foreach ($it in $list.SelectedItems) { $keep[([string]$it.Tag).ToLower()] = $true }
    $list.BeginUpdate()
    foreach ($it in @($list.Items)) {
        if (-not $keep.ContainsKey(([string]$it.Tag).ToLower())) {
            $script:Items.Remove(([string]$it.Tag).ToLower())
            $list.Items.Remove($it)
        }
    }
    $list.EndUpdate()
    Update-Counts
    $lblStatus.Text = "已保留选中的 $($list.Items.Count) 个。$script:CountSummary"
})
$miPaste.Add_Click({ Add-FromClipboard })
$miSelectAll.Add_Click({ foreach ($it in $list.Items) { $it.Selected = $true } })
$menu.Add_Opening({
    $has = $list.SelectedItems.Count -gt 0
    $miOpenFolder.Enabled = $has; $miCopyPath.Enabled = $has
    $miRemoveSel.Enabled = $has -and (-not $script:Busy)
    $miKeepSel.Enabled = $has -and (-not $script:Busy)
})

# ---------------- 点列头排序 ----------------
$script:SortCol = -1
$script:SortAsc = $true
$list.Add_ColumnClick({
    param($s,$e)
    if ($script:SortCol -eq $e.Column) { $script:SortAsc = -not $script:SortAsc }
    else { $script:SortCol = $e.Column; $script:SortAsc = $true }
    $col = $e.Column; $asc = $script:SortAsc
    $rows = @($list.Items) | Sort-Object -Property @{Expression={ $_.SubItems[$col].Text }} -Descending:(-not $asc)
    $list.BeginUpdate()
    $list.Items.Clear()
    foreach ($r in $rows) { $null = $list.Items.Add($r) }
    $list.EndUpdate()
})

# ---------------- 按钮：加文件 ----------------
$btnFiles.Add_Click({
    $dlg = New-Object Windows.Forms.OpenFileDialog
    $dlg.Multiselect = $true
    $pat = ($EXTS | ForEach-Object { "*$_" }) -join ';'
    $dlg.Filter = "图片/视频 ($pat)|$pat|所有文件 (*.*)|*.*"
    if ($dlg.ShowDialog() -eq 'OK') { Add-Paths $dlg.FileNames }
})
$btnFolder.Add_Click({
    # 用现代版「打开」对话框选文件夹: 带地址栏、可直接输入/粘贴完整路径
    # (WinForms 自带的 FolderBrowserDialog 是老式树形控件, 不能输入路径)
    $dlg = New-Object Windows.Forms.OpenFileDialog
    $dlg.Title = '进入目标文件夹后点「打开」即可（可在地址栏或文件名框直接粘贴路径）'
    $dlg.ValidateNames = $false
    $dlg.CheckFileExists = $false
    $dlg.CheckPathExists = $true
    $dlg.FileName = '选择此文件夹'
    $dlg.Filter = '文件夹|*.__folder__'
    if ($dlg.ShowDialog() -eq 'OK') {
        $p = $dlg.FileName
        # 若用户直接选中/输入的就是一个已存在的文件夹, 用它; 否则取所在目录
        if (Test-Path -LiteralPath $p -PathType Container) { Add-Paths @($p) }
        else {
            $dir = [IO.Path]::GetDirectoryName($p)
            if ($dir -and (Test-Path -LiteralPath $dir -PathType Container)) { Add-Paths @($dir) }
        }
    }
})
$btnClear.Add_Click({
    if (-not $script:Busy) {
        $list.Items.Clear(); $script:Items = @{}
        Update-Counts
        $lblStatus.Text = '列表已清空。'
    }
})

# ---------------- 核心操作 ----------------
function Set-Buttons([bool]$enabled) {
    foreach ($b in @($btnAdd,$btnScan,$btnRemove,$btnFiles,$btnFolder,$btnClear,$btnSettings,$btnExport,$chkBackup)) { $b.Enabled = $enabled }
}

function Get-AllFiles { @($list.Items | ForEach-Object { $_.Tag }) }

function Invoke-Chunked([string[]]$files, [string]$mode, [string]$successState, [ref]$counts) {
    foreach ($f in $files) {
        $lblStatus.Text = '正在处理：' + [IO.Path]::GetFileName($f)
        [Windows.Forms.Application]::DoEvents()
        $result = Set-SafeFileTag -File $f -Mode $mode -KeepBackup $chkBackup.Checked
        $state = if ($result.Success) { $successState } else { 'failed' }
        if ($result.Success -and $result.Warning) {
            $state = 'warning'
            $script:LastFileErrors[$f.ToLowerInvariant()] = $result.Warning
        }
        $counts.Value[$state] = 1 + $(if ($counts.Value.ContainsKey($state)) { $counts.Value[$state] } else { 0 })
        Set-ItemStatus $f $state
        $bar.Value = [Math]::Min($bar.Value+1,$bar.Maximum)
    }
}

function Run-Action([string]$action) {
    if ($script:Busy) { return }
    $files = Get-AllFiles
    if ($files.Count -eq 0) {
        [Windows.Forms.MessageBox]::Show('请先拖入或添加文件/文件夹。','提示','OK','Information') | Out-Null
        return
    }
    if ($action -eq 'add') {
        # 列表里已标出状态: 只对真正需要处理的文件弹确认, 全部已打标签则直接提示不打扰
        $pending = @($list.Items | Where-Object { (Get-ItemState $_) -notin @('tagged','added','fixed_duplicate','skipped') })
        if ($pending.Count -eq 0) {
            [Windows.Forms.MessageBox]::Show(
                "列表中的文件都已含标签，无需重复写入。",'无需处理','OK','Information') | Out-Null
            return
        }
        $r = [Windows.Forms.MessageBox]::Show(
            "将为 $($pending.Count) 个文件写入标签：`n$TAG`n`n已含标签的文件会自动跳过。是否继续？",
            '确认','OKCancel','Question')
        if ($r -ne 'OK') { return }
    }
    if ($action -eq 'remove') {
        $r = [Windows.Forms.MessageBox]::Show(
            "将从 $($files.Count) 个文件移除标签 $TAG。是否继续？",'确认','OKCancel','Question')
        if ($r -ne 'OK') { return }
    }

    Write-AppLog -Level INFO -Message 'Batch started' -Data @{ action=$action; count=$files.Count; backup=$chkBackup.Checked }
    $script:Busy = $true; Set-Buttons $false
    $bar.Value = 0; $bar.Maximum = [Math]::Max($files.Count, 1)
    $lblStatus.Text = '处理中，请稍候…'
    [Windows.Forms.Application]::DoEvents()

    try {
        # 第一步：整体读取现状（体检）
        $subjMap = Get-Subjects $files
        $states = @{}
        foreach ($f in $files) {
            $subj = $null
            if ($subjMap.ContainsKey($f.ToLower())) { $subj = $subjMap[$f.ToLower()] }
            $states[$f] = Get-FileState $subj
        }

        if ($action -eq 'scan') {
            $c = @{ tagged=0; untagged=0; duplicate=0; unreadable=0 }
            foreach ($f in $files) { $c[$states[$f]]++; Set-ItemStatus $f $states[$f] }
            $bar.Value = $bar.Maximum
            $lblStatus.Text = "体检完成 — 已打标签 $($c.tagged)，未打标签 $($c.untagged)，重复 $($c.duplicate)，读取失败 $($c.unreadable)。可点「开始添加标签」补齐/去重，或导出问题清单。"
        }
        elseif ($action -eq 'add') {
            $counts = @{}
            $skipped = @($files | Where-Object { $states[$_] -eq 'tagged' })
            foreach ($f in $skipped) { Set-ItemStatus $f 'skipped'; $bar.Value++ }
            $counts['skipped'] = $skipped.Count
            $bad = @($files | Where-Object { $states[$_] -eq 'unreadable' })
            foreach ($f in $bad) { Set-ItemStatus $f 'failed'; $bar.Value++ }
            $counts['failed'] = $bad.Count

            $todo = @($files | Where-Object { $states[$_] -eq 'untagged' })
            $dups = @($files | Where-Object { $states[$_] -eq 'duplicate' })
            $refC = [ref]$counts
            if ($todo.Count) {
                Invoke-Chunked $todo 'add' 'added' $refC
            }
            if ($dups.Count) {
                Invoke-Chunked $dups 'normalize' 'fixed_duplicate' $refC
            }
            $bar.Value = $bar.Maximum
            $nAdd  = $(if ($counts.ContainsKey('added')) { $counts['added'] } else { 0 })
            $nFix  = $(if ($counts.ContainsKey('fixed_duplicate')) { $counts['fixed_duplicate'] } else { 0 })
            $nSkip = $counts['skipped']; $nFail = $(if ($counts.ContainsKey('failed')) { $counts['failed'] } else { 0 })
            $lblStatus.Text = "添加完成 — 新写入 $nAdd，去重修复 $nFix，已有跳过 $nSkip，失败 $nFail。（已校验媒体内容及写回文件）"
        }
        elseif ($action -eq 'remove') {
            $counts = @{}
            $skipped = @($files | Where-Object { $states[$_] -eq 'untagged' })
            foreach ($f in $skipped) { Set-ItemStatus $f 'untagged'; $bar.Value++ }
            $counts['skipped'] = $skipped.Count
            $bad = @($files | Where-Object { $states[$_] -eq 'unreadable' })
            foreach ($f in $bad) { Set-ItemStatus $f 'failed'; $bar.Value++ }
            $counts['failed'] = $bad.Count

            $todo = @($files | Where-Object { $states[$_] -in @('tagged','duplicate') })
            $refC = [ref]$counts
            if ($todo.Count) {
                Invoke-Chunked $todo 'remove' 'removed' $refC
            }
            $bar.Value = $bar.Maximum
            $nRem  = $(if ($counts.ContainsKey('removed')) { $counts['removed'] } else { 0 })
            $nFail = $(if ($counts.ContainsKey('failed')) { $counts['failed'] } else { 0 })
            $lblStatus.Text = "移除完成 — 已移除 $nRem，本无标签 $($counts['skipped'])，失败 $nFail。"
        }
    } catch {
        $errDetail = "处理出错(行 $($_.InvocationInfo.ScriptLineNumber)): $($_.Exception.Message)"
        Write-AppLog -Level ERROR -Message 'Batch exception' -Data $_
        foreach ($f in $files) { if ((Get-ItemState $script:Items[$f.ToLowerInvariant()]) -in @('pending','untagged','duplicate','tagged')) { $script:LastFileErrors[$f.ToLowerInvariant()]=$errDetail; Set-ItemStatus $f 'failed' } }
        [Windows.Forms.MessageBox]::Show($errDetail,'出错','OK','Error') | Out-Null
        $lblStatus.Text = $errDetail
    } finally {
        $warnings = @($list.Items | Where-Object { (Get-ItemState $_) -eq 'warning' }).Count
        $failures = @($list.Items | Where-Object { (Get-ItemState $_) -in @('failed','unreadable') }).Count
        if ($warnings) { $lblStatus.Text += " 警告 $warnings。" }
        Write-AppLog -Level $(if ($failures) { 'ERROR' } elseif ($warnings) { 'WARNING' } else { 'INFO' }) -Message 'Batch finished' -Data @{ action=$action; summary=$lblStatus.Text; failures=$failures; warnings=$warnings }
        $script:Busy = $false; Set-Buttons $true
        Update-Counts
        if ($failures -or $warnings) {
            [Windows.Forms.MessageBox]::Show("失败/读取异常 $failures 个，警告 $warnings 个。`n将鼠标停在异常行查看原因；可导出问题清单，或在设置中打包诊断日志。`n如提示恢复副本，请保留该目录。",'处理存在异常','OK','Warning') | Out-Null
        }
        if (-not $script:RuntimeLogHealthy) { $lblStatus.Text += ' 日志无法写入，请查看设置。' }
        $script:OpDone = $true   # 下次添加文件时自动清空列表
    }
}

$btnAdd.Add_Click({ Run-Action 'add' })
$btnScan.Add_Click({ Run-Action 'scan' })
$btnRemove.Add_Click({ Run-Action 'remove' })

# ---------------- 导出问题清单 ----------------
$btnExport.Add_Click({
    $problemTexts = $PROBLEM | ForEach-Object { $STATUS_TEXT[$_] }
    $rows = @($list.Items | Where-Object { $problemTexts -contains $_.SubItems[2].Text })
    if ($rows.Count -eq 0) {
        [Windows.Forms.MessageBox]::Show('当前没有未打标签/重复/失败的文件。','提示','OK','Information') | Out-Null
        return
    }
    $dlg = New-Object Windows.Forms.SaveFileDialog
    $dlg.FileName = '问题文件清单.csv'
    $dlg.Filter = 'CSV 文件 (*.csv)|*.csv'
    if ($dlg.ShowDialog() -eq 'OK') {
        try {
            $records = @($rows | ForEach-Object { [pscustomobject]@{ '文件路径'=[string]$_.Tag; '状态'=$_.SubItems[2].Text; '原因'=$script:LastFileErrors[([string]$_.Tag).ToLowerInvariant()] } })
            $records | Export-Csv -LiteralPath $dlg.FileName -NoTypeInformation -Encoding UTF8
            Write-AppLog -Level INFO -Message 'Problem list exported' -Data @{ count=$rows.Count }
        } catch {
            Write-AppLog -Level ERROR -Message 'Problem list export failed' -Data $_
            [Windows.Forms.MessageBox]::Show($_.Exception.Message,'导出失败','OK','Error') | Out-Null
            return
        }
        $lblStatus.Text = "已导出 $($rows.Count) 条到 $($dlg.FileName)"
    }
})

# ---------------- 设置与诊断 ----------------
function New-SettingsDialog {
    $settings = New-Object Windows.Forms.Form
    $settings.Text = "SynthTag 设置 · v$AppVersion"
    $settings.Size = New-Object Drawing.Size(620,350)
    $settings.StartPosition = 'CenterParent'
    $settings.Font = $form.Font
    $settings.FormBorderStyle = 'FixedDialog'
    $settings.MaximizeBox = $false; $settings.MinimizeBox = $false
    $info = New-Object Windows.Forms.Label
    $info.Location = New-Object Drawing.Point(18,18); $info.Size = New-Object Drawing.Size(570,170)
    $health = if ($script:RuntimeLogHealthy) { '正常' } else { '异常：'+$script:LastLogError }
    $info.Text = "SynthTag（打AI标签） v$AppVersion`nExifTool：$script:RuntimeExifToolVersion`n日志级别：INFO / WARNING / ERROR，保留近30天`n日志目录：$script:LogDirectory`n日志状态：$health`n`n诊断包包括版本、系统/存储环境、日志和问题清单。`n不包含图片或恢复副本；日志可能含文件名和共享路径，请确认后再分享。"
    $openLogs = New-Object Windows.Forms.Button
    $openLogs.Text = '打开日志目录'; $openLogs.Location = New-Object Drawing.Point(18,205); $openLogs.Size = New-Object Drawing.Size(130,32)
    $openLogs.Add_Click({
        try { $null=[IO.Directory]::CreateDirectory($script:LogDirectory); Start-Process explorer.exe -ArgumentList ('"'+$script:LogDirectory+'"') }
        catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'无法打开','OK','Error') | Out-Null }
    })
    $export = New-Object Windows.Forms.Button
    $export.Text = '打包诊断压缩包…'; $export.Location = New-Object Drawing.Point(160,205); $export.Size = New-Object Drawing.Size(160,32)
    $export.Add_Click({
        $dialog = New-Object Windows.Forms.SaveFileDialog
        $dialog.Filter = 'ZIP 诊断压缩包 (*.zip)|*.zip'
        $dialog.FileName = 'SynthTag-diagnostics-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.zip'
        if ($dialog.ShowDialog() -ne 'OK') { return }
        try {
            $issues = @($list.Items | Where-Object { (Get-ItemState $_) -in $PROBLEM } | ForEach-Object { @{ file=[string]$_.Tag; state=$_.SubItems[2].Text; reason=$script:LastFileErrors[([string]$_.Tag).ToLowerInvariant()] } })
            $bundle = Export-DiagnosticBundle -Destination $dialog.FileName -Context @{ fileCount=$list.Items.Count; summary=$lblStatus.Text; issues=$issues; keepBackup=$chkBackup.Checked }
            [Windows.Forms.MessageBox]::Show("已保存诊断包：`n$bundle",'导出完成','OK','Information') | Out-Null
        } catch {
            Write-AppLog -Level ERROR -Message 'Diagnostic export UI failure' -Data $_
            [Windows.Forms.MessageBox]::Show($_.Exception.Message,'诊断包导出失败','OK','Error') | Out-Null
        } finally { $dialog.Dispose() }
    })
    $settings.Controls.AddRange(@($info,$openLogs,$export))
    return $settings
}

function Show-Settings {
    $settings = New-SettingsDialog
    try { $null=$settings.ShowDialog($form) } finally { $settings.Dispose() }
}
$btnSettings.Add_Click({ Show-Settings })
$form.Add_FormClosing({
    param($sender,$eventArgs)
    if ($script:Busy) { $eventArgs.Cancel=$true; $lblStatus.Text='正在处理文件，请等待本次处理完成后再关闭。'; return }
    Write-AppLog -Level INFO -Message 'Application closed'
})
$form.Add_Shown({
    if (-not $script:RuntimeLogHealthy) { $lblStatus.Text='日志无法写入，请在设置中查看原因。' }
    $workRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'SynthTag\Work'
    if ([IO.Directory]::Exists($workRoot)) {
        $journals = @(Get-ChildItem -LiteralPath $workRoot -Filter recovery.json -Recurse -File -ErrorAction SilentlyContinue)
        if ($journals.Count) {
            Write-AppLog -Level WARNING -Message 'Unresolved file recovery journals found' -Data @{ count=$journals.Count; directory=$workRoot }
            [Windows.Forms.MessageBox]::Show("发现 $($journals.Count) 个上次写入留下的恢复记录，请保留并核对：`n$workRoot`n诊断包不包含恢复图片。",'存在待核对的恢复副本','OK','Warning') | Out-Null
        }
    }
})
if (-not $NoUI) { $null = $form.ShowDialog() }
