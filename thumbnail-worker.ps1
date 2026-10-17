param([switch]$Worker, [string]$TempDirectory)
# Isolated, read-only preview worker. Windows PowerShell 5.1, .NET and Windows Shell.
# Protocol: one UTF8-path Base64 per stdin line; OK|PNG-Base64 / ERROR|UTF8-Base64.
$ErrorActionPreference='Stop'
function Write-ThumbnailFailure([string]$Message) {
    $text=($Message -replace '[\r\n]+',' ').Trim()
    if (-not $text) { $text='Thumbnail unavailable.' }
    if ($text.Length -gt 240) { $text=$text.Substring(0,240) }
    [Console]::WriteLine('ERROR|'+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text)))
    [Console]::Out.Flush()
}
if (-not $Worker) { return }
try {
    $resolved=[IO.Path]::GetFullPath($TempDirectory).TrimEnd('\','/')
    $leaf=[IO.Path]::GetFileName($resolved)
    $parent=[IO.Path]::GetDirectoryName($resolved)
    $grandparent=[IO.Path]::GetDirectoryName($parent)
    $guid=[guid]::Empty
    if (-not [guid]::TryParse($leaf,[ref]$guid) -or [IO.Path]::GetFileName($parent) -ne 'ThumbnailWork' -or [IO.Path]::GetFileName($grandparent) -ne 'SynthTag') {
        throw 'Unsafe thumbnail temporary directory. Expected SynthTag\ThumbnailWork\<GUID>.'
    }
    if (-not [IO.Directory]::Exists($resolved)) { throw 'Parent-created thumbnail directory does not exist.' }
    foreach ($directory in @($resolved,$parent,$grandparent)) {
        if (([IO.File]::GetAttributes($directory) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Thumbnail temporary directories cannot be reparse points.' }
    }
    Add-Type -AssemblyName System.Drawing
    Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.IO;
using System.Drawing;
using System.Drawing.Imaging;
using System.Drawing.Drawing2D;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace SynthTag {
    public static class ThumbnailWorker {
        const long MaxBytes=64L*1024*1024;
        const long MaxPixels=60000000L;
        static readonly HashSet<string> OwnedSnapshots=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        sealed class UnsafeImageException : Exception { public UnsafeImageException(string text):base(text){} }
        [StructLayout(LayoutKind.Sequential)] struct Size { public int cx,cy; public Size(int x,int y){cx=x;cy=y;} }
        [ComImport,Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IShellItemImageFactory {
            [PreserveSig] int GetImage(Size size,int flags,out IntPtr bitmap);
        }
        [DllImport("shell32.dll",CharSet=CharSet.Unicode,PreserveSig=true)]
        static extern int SHCreateItemFromParsingName(string path,IntPtr bindContext,ref Guid iid,[MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory item);
        [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr handle);

        static MemoryStream Snapshot(string source) {
            var memory=new MemoryStream();
            try {
                // The original handle is always closed before any decoder or COM call.
                using(var input=new FileStream(source,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete)) {
                    if(input.Length>MaxBytes) throw new UnsafeImageException("Image exceeds the 64 MB preview limit.");
                    var buffer=new byte[65536]; int count; long total=0;
                    while((count=input.Read(buffer,0,buffer.Length))>0) {
                        total+=count;
                        if(total>MaxBytes) throw new UnsafeImageException("Image exceeds the 64 MB preview limit.");
                        memory.Write(buffer,0,count);
                    }
                }
                if(memory.Length==0) throw new UnsafeImageException("Image is empty.");
                memory.Position=0; return memory;
            } catch { memory.Dispose(); throw; }
        }
        static void Orient(Image image) {
            if(Array.IndexOf(image.PropertyIdList,0x0112)<0) return;
            var value=image.GetPropertyItem(0x0112).Value;
            if(value==null||value.Length<2) return;
            int orientation=value[0]|(value[1]<<8);
            if(orientation>8 && value[0]==0) orientation=value[1];
            RotateFlipType rotate;
            switch(orientation) {
                case 2: rotate=RotateFlipType.RotateNoneFlipX; break;
                case 3: rotate=RotateFlipType.Rotate180FlipNone; break;
                case 4: rotate=RotateFlipType.Rotate180FlipX; break;
                case 5: rotate=RotateFlipType.Rotate90FlipX; break;
                case 6: rotate=RotateFlipType.Rotate90FlipNone; break;
                case 7: rotate=RotateFlipType.Rotate270FlipX; break;
                case 8: rotate=RotateFlipType.Rotate270FlipNone; break;
                default: return;
            }
            image.RotateFlip(rotate);
        }
        static byte[] Render(Image image) {
            if(image.Width<1||image.Height<1||(long)image.Width*image.Height>MaxPixels) throw new UnsafeImageException("Image exceeds the 60 megapixel preview limit.");
            double ratio=Math.Min(40.0/image.Width,40.0/image.Height);
            int width=Math.Max(1,(int)Math.Round(image.Width*ratio)),height=Math.Max(1,(int)Math.Round(image.Height*ratio));
            using(var result=new Bitmap(40,40,PixelFormat.Format32bppArgb))
            using(var graphics=Graphics.FromImage(result))
            using(var attributes=new ImageAttributes())
            using(var output=new MemoryStream()) {
                graphics.Clear(Color.Transparent);
                graphics.CompositingMode=CompositingMode.SourceCopy;
                graphics.InterpolationMode=InterpolationMode.HighQualityBicubic;
                graphics.PixelOffsetMode=PixelOffsetMode.HighQuality;
                attributes.SetWrapMode(WrapMode.TileFlipXY);
                graphics.DrawImage(image,new Rectangle((40-width)/2,(40-height)/2,width,height),0,0,image.Width,image.Height,GraphicsUnit.Pixel,attributes);
                result.Save(output,ImageFormat.Png); return output.ToArray();
            }
        }
        static byte[] FromShell(MemoryStream memory,string extension,string tempDirectory) {
            // Shell receives only a private local snapshot, never the source path.
            string snapshot=Path.Combine(tempDirectory,"snapshot-"+Guid.NewGuid().ToString("N")+extension);
            IShellItemImageFactory factory=null; IntPtr bitmap=IntPtr.Zero;
            try {
                using(var file=new FileStream(snapshot,FileMode.CreateNew,FileAccess.Write,FileShare.Read)) {
                    OwnedSnapshots.Add(snapshot); memory.Position=0; memory.CopyTo(file);
                }
                var iid=typeof(IShellItemImageFactory).GUID;
                int hr=SHCreateItemFromParsingName(snapshot,IntPtr.Zero,ref iid,out factory);
                if(hr<0) Marshal.ThrowExceptionForHR(hr);
                // THUMBNAILONLY: a generic file icon must never masquerade as a preview.
                hr=factory.GetImage(new Size(40,40),8,out bitmap);
                if(hr<0) throw new InvalidDataException("Windows Shell thumbnail is unavailable (0x"+hr.ToString("X8")+").");
                if(bitmap==IntPtr.Zero) throw new InvalidDataException("Windows Shell returned no thumbnail.");
                using(var image=Image.FromHbitmap(bitmap)) { return Render(image); }
            } finally {
                if(bitmap!=IntPtr.Zero) DeleteObject(bitmap);
                if(factory!=null) { try { Marshal.FinalReleaseComObject(factory); } catch {} }
                try { if(File.Exists(snapshot)) File.Delete(snapshot); OwnedSnapshots.Remove(snapshot); } catch {}
            }
        }
        public static byte[] Create(string source,string tempDirectory) {
            using(var memory=Snapshot(source)) {
                try {
                    using(var image=Image.FromStream(memory,false,false)) {
                        if((long)image.Width*image.Height>MaxPixels) throw new UnsafeImageException("Image exceeds the 60 megapixel preview limit.");
                        Orient(image); return Render(image);
                    }
                } catch(UnsafeImageException) { throw; }
                catch(ArgumentException) {}
                catch(ExternalException) {}
                // GDI does not decode every Windows-installed format (e.g. WebP).
                string extension=Path.GetExtension(source);
                if(extension.Length<2||extension.Length>10) throw new InvalidDataException("Unsupported thumbnail format.");
                foreach(char c in extension.Substring(1)) if(!char.IsLetterOrDigit(c)) throw new InvalidDataException("Unsupported thumbnail extension.");
                return FromShell(memory,extension,tempDirectory);
            }
        }
        public static void Cleanup() {
            foreach(string snapshot in new List<string>(OwnedSnapshots)) {
                try { if(File.Exists(snapshot)) File.Delete(snapshot); OwnedSnapshots.Remove(snapshot); } catch {}
            }
        }
    }
}
'@
} catch {
    Write-ThumbnailFailure $_.Exception.GetBaseException().Message
    exit 1
}
try {
    while ($null -ne ($line=[Console]::ReadLine())) {
        try {
            if ($line.Length -gt 262144) { throw 'Thumbnail request is too long.' }
            $path=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($line))
            if (-not [IO.Path]::IsPathRooted($path)) { throw 'Thumbnail source must be an absolute file path.' }
            $bytes=[SynthTag.ThumbnailWorker]::Create($path,$resolved)
            [Console]::WriteLine('OK|'+[Convert]::ToBase64String($bytes))
            [Console]::Out.Flush()
        } catch { Write-ThumbnailFailure $_.Exception.GetBaseException().Message }
    }
} finally { [SynthTag.ThumbnailWorker]::Cleanup() }
