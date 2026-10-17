# Windows PowerShell 5.1. ExifTool writes only to a local working copy.
$script:LastFileErrors = @{}
$script:LastFileWarnings = @{}

function ConvertFrom-ExifRecord($Record) {
    $properties=@{}; $warnings=@(); $errors=@()
    foreach ($property in $Record.PSObject.Properties) {
        $name=$property.Name -replace '^.*:', ''
        if ($name -eq 'Warning') { $warnings+=@($property.Value) }
        elseif ($name -eq 'Error') { $errors+=@($property.Value) }
        else { $properties[$name]=$property.Value }
    }
    $properties.Warnings=@($warnings)
    $properties.Warning=$warnings -join '; '
    $properties.Error=$errors -join '; '
    return [pscustomobject]$properties
}

function Test-BlockingMediaWarnings([string[]]$Warnings) {
    # Some Photoshop/legacy exports have incomplete EXIF directories even though
    # their encoded pixels are intact. Only these specific metadata warnings are
    # tolerated; unknown, truncated or corrupt-media warnings still block writes.
    $allowed=@(
        '^(?:\[minor\] )?Missing required JPEG (?:ExifIFD|IFD0|InteropIFD) tag 0x[0-9a-fA-F]+ (?:ExifVersion|ComponentsConfiguration|YCbCrPositioning|FlashpixVersion|ColorSpace|ExifImageWidth|ExifImageHeight|ResolutionUnit|XResolution|YResolution)$',
        '^\[minor\] Odd offset for (?:IFD\d+|ExifIFD|GPS|InteropIFD) tag 0x[0-9a-fA-F]+ \S+$',
        '^\[minor\] IFD0 tag 0x[0-9a-fA-F]+ (?:ImageWidth|ImageHeight|BitsPerSample|PhotometricInterpretation|SamplesPerPixel) is not allowed in JPEG$',
        '^Multiple IPTC CodedCharacterSet tags$'
    )
    foreach ($warning in $Warnings) {
        if (-not $warning) { continue }
        $known=$false
        foreach ($pattern in $allowed) { if ($warning -match $pattern) { $known=$true; break } }
        if (-not $known) { return $true }
    }
    return $false
}

function Invoke-ExifTool([string[]]$ExifArgs, [string[]]$Files) {
    $tmp = [IO.Path]::GetTempFileName()
    $p = $null
    try {
        $all = @('-charset','filename=utf8','-charset','utf8') + $ExifArgs + $Files
        [IO.File]::WriteAllLines($tmp, $all, (New-Object Text.UTF8Encoding($false)))
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $ExifTool
        $psi.Arguments = '-@ "' + $tmp + '"'
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
        # Windows Perl cannot use the C.UTF-8 locale inherited from some shells.
        foreach ($name in @('LANG','LC_ALL','LC_CTYPE')) { $psi.EnvironmentVariables[$name] = 'C' }
        $p = [Diagnostics.Process]::Start($psi)
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while (-not $p.WaitForExit(100) -and $timer.ElapsedMilliseconds -lt 120000) {
            if ('System.Windows.Forms.Application' -as [type]) { [Windows.Forms.Application]::DoEvents() }
        }
        if (-not $p.HasExited) {
            $p.Kill(); $p.WaitForExit()
            throw 'ExifTool 超过120秒未完成，已停止。原文件未由ExifTool直接写入。'
        }
        $result = [pscustomobject]@{ StdOut=$outTask.Result; StdErr=$errTask.Result; ExitCode=$p.ExitCode }
        if ($result.ExitCode -ne 0 -or $result.StdErr) {
            $level = if ($result.ExitCode -ne 0) { 'ERROR' } else { 'WARNING' }
            Write-AppLog -Level $level -Message 'ExifTool process result' -Data @{ files=$Files; args=$ExifArgs; exitCode=$result.ExitCode; stderr=$result.StdErr }
        }
        return $result
    } finally {
        if ($p) { $p.Dispose() }
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Get-Subjects([string[]]$Files) {
    $map = @{}
    for ($i=0; $i -lt $Files.Count; $i+=100) {
        $slice = @($Files[$i..([Math]::Min($i+100,$Files.Count)-1)])
        foreach ($file in $slice) { $script:LastFileErrors.Remove($file.ToLowerInvariant()) }
        try {
            $result = Invoke-ExifTool @('-j','-G4','-a','-validate','-FileType','-Error','-Warning','-XMP-dc:Subject','-api','largefilesupport=1') $slice
            if (-not $result.StdOut.Trim()) { throw ('ExifTool 未返回文件信息。' + $result.StdErr) }
            $items = ConvertFrom-Json -InputObject $result.StdOut -ErrorAction Stop
            foreach ($raw in @($items)) {
                $it = ConvertFrom-ExifRecord $raw
                if (-not $it.SourceFile) { continue }
                $key = [IO.Path]::GetFullPath($it.SourceFile).ToLowerInvariant()
                if ($it.FileType -eq 'PNG' -and -not $it.Error) {
                    try { Assert-PngIntegrity $it.SourceFile }
                    catch {
                        $script:LastFileErrors[$key]=$_.Exception.Message
                        Write-AppLog -Level ERROR -Message 'PNG integrity check failed' -Data @{ file=$it.SourceFile; error=$_ }
                        continue
                    }
                }
                if ($it.Error -or -not $it.FileType -or (Test-BlockingMediaWarnings $it.Warnings) -or ($it.Validate -match 'Error')) {
                    $script:LastFileErrors[$key] = if ($it.Error) { [string]$it.Error } elseif ($it.Warning) { [string]$it.Warning } else { '无法识别或验证图片/视频格式。' }
                    Write-AppLog -Level ERROR -Message 'File metadata unreadable' -Data @{ file=$it.SourceFile; error=$script:LastFileErrors[$key] }
                    continue
                }
                $map[$key] = @()
                if ($null -ne $it.Subject) { $map[$key] = @($it.Subject | ForEach-Object { [string]$_ }) }
                if ($it.Warning) {
                    $script:LastFileWarnings[$key]=$it.Warning
                    Write-AppLog -Level WARNING -Message 'File metadata warning' -Data @{ file=$it.SourceFile; warning=$it.Warning }
                } else { $script:LastFileWarnings.Remove($key) }
            }
            foreach ($file in $slice) {
                $key = $file.ToLowerInvariant()
                if (-not $map.ContainsKey($key) -and -not $script:LastFileErrors.ContainsKey($key)) {
                    $script:LastFileErrors[$key] = 'ExifTool 未返回该文件的有效信息。' + $result.StdErr
                }
            }
        } catch {
            foreach ($file in $slice) { $script:LastFileErrors[$file.ToLowerInvariant()] = $_.Exception.Message }
            Write-AppLog -Level ERROR -Message 'Metadata read failed' -Data @{ files=$slice; error=$_ }
        }
    }
    return $map
}

function Get-FileState([string[]]$subjects) {
    if ($null -eq $subjects) { return 'unreadable' }
    $n = @($subjects | Where-Object { $_ -eq $TAG }).Count
    if ($n -eq 0) { return 'untagged' }
    if ($n -eq 1) { return 'tagged' }
    return 'duplicate'
}

function Get-StreamHash([IO.Stream]$Stream) {
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $Stream.Position=0; return ([BitConverter]::ToString($hash.ComputeHash($Stream))).Replace('-','') }
    finally { $hash.Dispose() }
}

function Get-SafeFileHash([string]$Path) {
    $stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try { return Get-StreamHash $stream } finally { $stream.Dispose() }
}

function Assert-PngIntegrity([string]$File) {
    # ExifTool does not validate the zero-length IEND CRC. Check every chunk,
    # including large IDAT chunks, without loading the complete image into RAM.
    if (-not ('SynthTag.PngIntegrity' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
namespace SynthTag {
    public static class PngIntegrity {
        static readonly uint[] Table = MakeTable();
        static uint[] MakeTable() {
            var t = new uint[256];
            for (uint i=0;i<256;i++) {
                uint c=i;
                for (int n=0;n<8;n++) c=(c&1)!=0 ? 0xedb88320U^(c>>1) : c>>1;
                t[i]=c;
            }
            return t;
        }
        static uint Update(uint c, byte[] b, int n) {
            for (int i=0;i<n;i++) c=Table[(c^b[i])&255]^(c>>8);
            return c;
        }
        static void Read(Stream f, byte[] b, int n) {
            int p=0;
            while(p<n) { int got=f.Read(b,p,n-p); if(got==0) throw new InvalidDataException("Truncated PNG"); p+=got; }
        }
        static uint U32(byte[] b) { return ((uint)b[0]<<24)|((uint)b[1]<<16)|((uint)b[2]<<8)|b[3]; }
        public static void Validate(string path) {
            using(var f=File.Open(path,FileMode.Open,FileAccess.Read,FileShare.Read)) {
                byte[] h=new byte[8], type=new byte[4], size=new byte[4], buf=new byte[65536];
                Read(f,h,8);
                byte[] sig={137,80,78,71,13,10,26,10};
                for(int i=0;i<8;i++) if(h[i]!=sig[i]) throw new InvalidDataException("Invalid PNG signature");
                bool first=true, data=false;
                while(true) {
                    Read(f,size,4); uint len=U32(size); Read(f,type,4);
                    string name=System.Text.Encoding.ASCII.GetString(type);
                    if(first && (name!="IHDR" || len!=13)) throw new InvalidDataException("Missing PNG IHDR");
                    first=false;
                    if(len>0x7fffffff || len+4L>f.Length-f.Position) throw new InvalidDataException("Truncated PNG chunk: "+name);
                    uint crc=Update(0xffffffffU,type,4), left=len;
                    while(left>0) { int n=(int)Math.Min((uint)buf.Length,left); Read(f,buf,n); crc=Update(crc,buf,n); left-=(uint)n; }
                    Read(f,size,4);
                    if((crc^0xffffffffU)!=U32(size)) throw new InvalidDataException("Bad PNG CRC: "+name);
                    if(name=="IDAT") data=true;
                    if(name=="IEND") {
                        if(len!=0 || !data || f.Position!=f.Length) throw new InvalidDataException("Invalid PNG ending");
                        return;
                    }
                }
            }
        }
    }
}
'@
    }
    [SynthTag.PngIntegrity]::Validate($File)
}

function Get-MediaIntegrity([string]$File) {
    $result = Invoke-ExifTool @('-j','-G4','-a','-validate','-warning','-error','-FileType','-FileTypeExtension','-ImageDataHash','-api','ImageHashType=SHA256','-api','largefilesupport=1','-XMP-dc:Subject') @($File)
    if ($result.ExitCode -ne 0) { throw ('媒体校验失败：' + $result.StdErr) }
    $items = ConvertFrom-Json -InputObject $result.StdOut -ErrorAction Stop
    $items = @($items)
    if ($items.Count -ne 1) { throw 'ExifTool 未返回唯一媒体记录。' }
    $item = ConvertFrom-ExifRecord $items[0]
    if ($item.Error -or -not $item.FileType) { throw ('无法读取有效媒体：' + $item.Error) }
    if ($item.FileType -eq 'PNG') { Assert-PngIntegrity $File }
    if ((Test-BlockingMediaWarnings $item.Warnings) -or ($item.Validate -match 'Error')) { throw ('媒体结构校验有异常，已停止写入：' + $item.Warning + ' ' + $item.Validate) }
    if (-not $item.ImageDataHash) { throw '无法取得图像/视频内容摘要，已停止写入以保护原文件。' }
    return $item
}

function Get-TargetStorageInfo([string]$File) {
    $root = [IO.Path]::GetPathRoot($File)
    $info = @{ root=$root; kind='unknown'; fileSystem='unknown' }
    if ($root.StartsWith('\\')) { $info.kind='UNC/SMB' }
    else { $info.kind='drive-letter (local, mapped or virtual)'; $info.note='Filesystem and Dokan evidence available in diagnostic environment; no synchronous volume probe here.' }
    return $info
}

function Invoke-NativeFileReplace([string]$StagedPath,[string]$Destination,[string]$BackupPath) {
    [IO.File]::Replace($StagedPath,$Destination,$BackupPath,$false)
}

function Invoke-NativeMoveReplacement([string]$StagedPath,[string]$Destination) {
    if (-not ('SynthTag.FileOperations' -as [type])) {
        Add-Type -Namespace SynthTag -Name FileOperations -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode, SetLastError=true)]
[return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
public static extern bool MoveFileEx(string existingName, string newName, int flags);
'@
    }
    if (-not [SynthTag.FileOperations]::MoveFileEx($StagedPath,$Destination,9)) {
        $nativeCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw (New-Object ComponentModel.Win32Exception($nativeCode))
    }
}

function Complete-SafeReplacement([string]$StagedPath,[string]$Destination,[string]$BackupPath,[string]$OriginalHash,[IO.Stream]$OriginalGuard) {
    try { Invoke-NativeFileReplace $StagedPath $Destination $BackupPath; return }
    catch {
        $baseError = $_.Exception.GetBaseException()
        $code = if ($baseError -is [ComponentModel.Win32Exception]) { $baseError.NativeErrorCode } else { $baseError.HResult -band 0xffff }
        # Dokan / virtual drives may implement rename-with-replacement but not ReplaceFile.
        # Fall back only for explicit unsupported-operation errors, while original is intact.
        if ($code -notin @(1,50,120)) { throw }
        if (-not [IO.File]::Exists($Destination) -or -not [IO.File]::Exists($StagedPath) -or [IO.File]::Exists($BackupPath)) { throw }
        Write-AppLog -Level WARNING -Message 'File.Replace unsupported; using backed-up rename' -Data @{ file=$Destination; nativeCode=$code }
        if ($OriginalHash -and (Get-SafeFileHash $Destination) -ne $OriginalHash) { throw '兼容写入前发现原图已被修改，已停止。' }
        [IO.File]::Copy($Destination,$BackupPath,$false)
        if ((Get-SafeFileHash $Destination) -ne (Get-SafeFileHash $BackupPath)) { throw '兼容写入前的备份校验失败。' }
        # MoveFileEx on Windows/Dokan needs the old read handle released. The
        # native ReplaceFile branch keeps it open to exclude in-place writers.
        if ($OriginalGuard) { $OriginalGuard.Dispose() }
        # REPLACE_EXISTING | WRITE_THROUGH; never truncate the original in place.
        Invoke-NativeMoveReplacement $StagedPath $Destination
    }
}

function Set-SafeFileTag {
    param([string]$File,[ValidateSet('add','remove','normalize')][string]$Mode,[bool]$KeepBackup=$false)
    $work = $null; $upload=$null; $guard=$null; $commitAttempted=$false; $succeeded=$false
    $phase='inspect'; $operationTimer=[Diagnostics.Stopwatch]::StartNew()
    $result = [pscustomobject]@{ Success=$false; Warning=''; Error=''; RecoveryPath='' }
    try {
        $File = [IO.Path]::GetFullPath($File)
        $key = $File.ToLowerInvariant()
        Write-AppLog -Level INFO -Message 'File operation started' -Data @{ file=$File; mode=$Mode; backup=$KeepBackup; storage=(Get-TargetStorageInfo $File) }
        foreach ($suffix in @('_original','_exiftool_tmp')) {
            if ([IO.File]::Exists($File+$suffix)) { throw "发现既有 $suffix 文件，请先确认历史备份/异常文件；本次未改动原图。" }
        }
        $attributes = [IO.File]::GetAttributes($File)
        if ($attributes -band [IO.FileAttributes]::ReadOnly) { throw '文件为只读，请检查本地、共享目录或网盘的编辑权限。' }
        $appRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'SynthTag'
        if ($script:RuntimeRoot) { $appRoot = $script:RuntimeRoot }
        $work = Join-Path (Join-Path $appRoot 'Work') ([guid]::NewGuid().ToString('N'))
        $null = [IO.Directory]::CreateDirectory($work)
        $original = Join-Path $work ('original'+[IO.Path]::GetExtension($File))
        $staged = Join-Path $work ('staged'+[IO.Path]::GetExtension($File))
        $phase='local-snapshot'
        $guard = [IO.File]::Open($File,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try {
            $output = [IO.File]::Open($original,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try { $guard.CopyTo($output); $output.Flush($true) } finally { $output.Dispose() }
            $originalHash = Get-StreamHash $guard
        } finally { $guard.Dispose(); $guard=$null }
        if ((Get-SafeFileHash $original) -ne $originalHash) { throw '本地原始副本校验失败。' }
        [IO.File]::Copy($original,$staged,$false)
        $phase='local-media-validation'
        $before = Get-MediaIntegrity $original
        $args = @('-overwrite_original','-api','largefilesupport=1',"-XMP-dc:Subject-=$TAG")
        if ($Mode -ne 'remove') { $args += "-XMP-dc:Subject+=$TAG" }
        $write = Invoke-ExifTool $args @($staged)
        if ($write.ExitCode -ne 0) { throw ('ExifTool 写入失败：' + $write.StdErr) }
        if ($write.StdErr) { $result.Warning=$write.StdErr }
        $after = Get-MediaIntegrity $staged
        if ($before.Warning -or $after.Warning) {
            $metadataWarnings=@(@($before.Warnings)+@($after.Warnings) | Select-Object -Unique)
            $result.Warning += '原文件存在EXIF元数据规范警告（图像内容另行校验）：' + ($metadataWarnings -join '; ')
        }
        if ($before.FileTypeExtension -ne $after.FileTypeExtension -or $before.ImageDataHash -ne $after.ImageDataHash) { throw '写入前后图像/视频内容摘要不同，已停止写回。' }
        $subjects = @($after.Subject)
        $tagCount = @($subjects | Where-Object { $_ -eq $TAG }).Count
        if (($Mode -eq 'remove' -and $tagCount -ne 0) -or ($Mode -ne 'remove' -and $tagCount -ne 1)) { throw '标签回读验证失败，已停止写回。' }
        $expectedHash = Get-SafeFileHash $staged
        $phase='upload-staged-file'
        $id = [guid]::NewGuid().ToString('N')
        $upload = Join-Path ([IO.Path]::GetDirectoryName($File)) ('.synthtag-'+$id+'.tmp')
        $backup = if ($KeepBackup) { $File+'_original' } else { Join-Path ([IO.Path]::GetDirectoryName($File)) ('.synthtag-'+$id+'.bak') }
        $input = [IO.File]::OpenRead($staged)
        try {
            $output = New-Object IO.FileStream($upload,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,1048576,[IO.FileOptions]::WriteThrough)
            try { $input.CopyTo($output); $output.Flush($true) } finally { $output.Dispose() }
        } finally { $input.Dispose() }
        if ((Get-SafeFileHash $upload) -ne $expectedHash) { throw '目标目录临时文件校验失败（可能网络中断或网盘未完成写入），原图未替换。' }
        $guard = [IO.File]::Open($File,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::Read -bor [IO.FileShare]::Delete))
        if ((Get-StreamHash $guard) -ne $originalHash) { throw '处理期间文件被其他程序修改，已停止替换，请重新加载文件。' }
        if ([IO.File]::Exists($backup)) { throw '目标备份文件已存在，已停止替换。' }
        # A persistent journal keeps the untouched local original even if the process crashes.
        [IO.File]::WriteAllText((Join-Path $work 'recovery.json'),(@{ file=$File; original=$original; originalHash=$originalHash; expectedHash=$expectedHash; staged=$staged; upload=$upload; backup=$backup; started=[DateTimeOffset]::Now.ToString('o') } | ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
        $commitAttempted=$true
        $phase='target-replacement'
        Write-AppLog -Level INFO -Message 'Target replacement started' -Data @{ file=$File; backup=$backup }
        Complete-SafeReplacement -StagedPath $upload -Destination $File -BackupPath $backup -OriginalHash $originalHash -OriginalGuard $guard
        # The old handle now refers to the backup, not the new destination.
        # Release before verification/cleanup: Dokan may otherwise wait a minute
        # and reject deletion even though the handle allowed FILE_SHARE_DELETE.
        if ($guard) { $guard.Dispose(); $guard=$null }
        Write-AppLog -Level INFO -Message 'Target replacement returned' -Data @{ file=$File }
        $phase='target-readback-validation'
        if ((Get-SafeFileHash $backup) -ne $originalHash) { throw '替换时原图已被其他程序修改，已保留目标备份和本地副本，请人工核对。' }
        if ((Get-SafeFileHash $File) -ne $expectedHash) { throw '写回后完整文件校验失败；恢复副本已保留，请勿继续处理该文件。' }
        $final = Get-MediaIntegrity $File
        if ($final.ImageDataHash -ne $before.ImageDataHash) { throw '目标文件媒体回读校验失败。' }
        if (-not $KeepBackup) {
            try { [IO.File]::Delete($backup) }
            catch { $result.Warning += ' 标签已写入，但本次临时备份未能删除：'+$backup+'；'+$_.Exception.Message }
        }
        $succeeded=$true; $result.Success=$true
        $script:LastFileErrors.Remove($key)
        $level = if ($result.Warning) { 'WARNING' } else { 'INFO' }
        Write-AppLog -Level $level -Message 'File operation verified' -Data @{ file=$File; mode=$Mode; mediaHash=$final.ImageDataHash; warning=$result.Warning; elapsedMilliseconds=$operationTimer.ElapsedMilliseconds }
    } catch {
        $result.Error=$_.Exception.Message
        if ($commitAttempted -and $work) { $result.RecoveryPath=$work; $result.Error += "`n恢复副本（请勿删除）：$work" }
        if ($File) { $script:LastFileErrors[$File.ToLowerInvariant()]=$result.Error }
        $baseError=$_.Exception.GetBaseException()
        $nativeCode=$null
        if ($baseError -is [ComponentModel.Win32Exception]) { $nativeCode=$baseError.NativeErrorCode }
        elseif ($baseError -is [IO.IOException] -or $baseError -is [UnauthorizedAccessException]) { $nativeCode=$baseError.HResult -band 0xffff }
        Write-AppLog -Level ERROR -Message 'File operation failed' -Data @{ file=$File; mode=$Mode; error=$_; phase=$phase; hresult=$baseError.HResult; nativeErrorCode=$nativeCode; recovery=$result.RecoveryPath; commitAttempted=$commitAttempted; elapsedMilliseconds=$operationTimer.ElapsedMilliseconds }
    } finally {
        if ($guard) { $guard.Dispose() }
        if ($upload -and [IO.File]::Exists($upload) -and (-not $commitAttempted -or $succeeded)) {
            try { [IO.File]::Delete($upload) } catch { Write-AppLog -Level WARNING -Message 'Upload temporary cleanup failed' -Data @{ file=$upload; error=$_ } }
        }
        if ($work -and (-not $commitAttempted -or $succeeded)) {
            try { [IO.Directory]::Delete($work,$true) } catch { Write-AppLog -Level WARNING -Message 'Local work cleanup failed' -Data @{ directory=$work; error=$_ } }
        }
    }
    return $result
}
