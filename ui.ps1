# Shared WinForms presentation. Windows PowerShell 5.1; no extra runtime.
if (-not ('SynthTag.ModernButton' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
namespace SynthTag {
    // All source I/O belongs to a killable child process; UI painting only reads small memory bitmaps.
    public sealed class ThumbnailCache : IDisposable {
        sealed class Entry { public Bitmap Image; public string State; public LinkedListNode<string> Node; }
        readonly object gate=new object(), processGate=new object();
        readonly Dictionary<string,Entry> cache=new Dictionary<string,Entry>(StringComparer.OrdinalIgnoreCase);
        readonly Dictionary<string,int> pending=new Dictionary<string,int>(StringComparer.OrdinalIgnoreCase);
        readonly LinkedList<string> order=new LinkedList<string>(), jobs=new LinkedList<string>();
        readonly Queue<string[]> warnings=new Queue<string[]>();
        readonly AutoResetEvent wake=new AutoResetEvent(false);
        readonly Control owner; readonly Thread thread;
        Process process; string tempDirectory; bool paused,disposed; int generation;
        public string WorkerScript { get; set; }
        public ThumbnailCache(Control control) { owner=control; thread=new Thread(Work); thread.IsBackground=true; thread.Name="SynthTag thumbnails"; thread.Start(); }
        public int Count { get { lock(gate) return cache.Count; } }
        public string State(string path) { lock(gate) { Entry e; if(cache.TryGetValue(path,out e)) return e.State; return pending.ContainsKey(path)?"pending":"missing"; } }
        public Bitmap Copy(string path) { lock(gate) { Entry e; return cache.TryGetValue(path,out e)&&e.Image!=null?(Bitmap)e.Image.Clone():null; } }
        public string[][] DrainWarnings() { lock(gate) { var result=warnings.ToArray(); warnings.Clear(); return result; } }
        void Put(string path,Bitmap image,string state) {
            Entry old; if(cache.TryGetValue(path,out old)) { order.Remove(old.Node); if(old.Image!=null) old.Image.Dispose(); }
            cache[path]=new Entry { Image=image, State=state, Node=order.AddLast(path) };
            while(cache.Count>256) { string first=order.First.Value; Entry e=cache[first]; order.RemoveFirst(); cache.Remove(first); if(e.Image!=null)e.Image.Dispose(); }
        }
        public void Draw(Graphics graphics,string path,Rectangle bounds,bool unreadable) {
            string state="missing";
            lock(gate) {
                if(disposed) return;
                Entry e;
                if(cache.TryGetValue(path,out e)) {
                    order.Remove(e.Node); e.Node=order.AddLast(path); state=e.State;
                    if(e.Image!=null && !unreadable) { graphics.DrawImageUnscaled(e.Image,bounds.Location); return; }
                } else if(!pending.ContainsKey(path) && !paused) {
                    string ext=Path.GetExtension(path).ToLowerInvariant();
                    if(ext!=".png"&&ext!=".jpg"&&ext!=".jpeg"&&ext!=".tif"&&ext!=".tiff"&&ext!=".webp"&&ext!=".bmp"&&ext!=".gif") { Put(path,null,"unsupported"); state="unsupported"; }
                    else if(unreadable) { Put(path,null,"failed"); state="failed"; }
                    else if(pending.Count<32) { pending[path]=generation; jobs.AddLast(path); wake.Set(); }
                }
            }
            graphics.SmoothingMode=SmoothingMode.AntiAlias;
            using(var shape=UiDrawing.Rounded(bounds,6)) using(var b=new SolidBrush(Color.FromArgb(239,243,248))) graphics.FillPath(b,shape);
            TextRenderer.DrawText(graphics,(unreadable||state=="failed")?"!":(state=="unsupported"?"—":"图"),owner.Font,bounds,Color.FromArgb(148,163,184),TextFormatFlags.HorizontalCenter|TextFormatFlags.VerticalCenter);
        }
        void Refresh() { try { if(owner.IsHandleCreated&&!owner.IsDisposed) owner.BeginInvoke(new Action(delegate { if(!owner.IsDisposed) owner.Invalidate(); })); } catch(InvalidOperationException) {} }
        Process GetProcess(int token) {
            lock(processGate) {
                lock(gate) { if(paused||disposed||token!=generation) return null; }
                if(process!=null&&!process.HasExited) return process;
                StopProcess();
                string root=Environment.GetEnvironmentVariable("LOCALAPPDATA");
                if(String.IsNullOrEmpty(root)) root=Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                tempDirectory=Path.Combine(root,"SynthTag","ThumbnailWork",Guid.NewGuid().ToString("N")); Directory.CreateDirectory(tempDirectory);
                var info=new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),@"WindowsPowerShell\v1.0\powershell.exe"));
                info.Arguments="-NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -File \""+WorkerScript+"\" -Worker -TempDirectory \""+tempDirectory+"\"";
                info.UseShellExecute=false; info.CreateNoWindow=true; info.RedirectStandardInput=true; info.RedirectStandardOutput=true; info.RedirectStandardError=true;
                process=new Process(); process.StartInfo=info; process.Start(); process.ErrorDataReceived+=delegate {}; process.BeginErrorReadLine(); return process;
            }
        }
        bool StopProcess() {
            // Caller holds processGate; never wait while holding the bitmap/cache lock.
            if(process!=null) {
                try { if(!process.HasExited) { process.Kill(); if(!process.WaitForExit(2000)) return false; } } catch(InvalidOperationException) {} catch { return false; }
                process.Dispose(); process=null;
            }
            if(tempDirectory!=null) {
                try {
                    if(Directory.Exists(tempDirectory) && (File.GetAttributes(tempDirectory)&FileAttributes.ReparsePoint)==0) {
                        foreach(string file in Directory.GetFiles(tempDirectory)) if((File.GetAttributes(file)&FileAttributes.ReparsePoint)==0) File.Delete(file);
                        Directory.Delete(tempDirectory,false);
                    }
                } catch(IOException) {} catch(UnauthorizedAccessException) {}
                tempDirectory=null;
            }
            return true;
        }
        void Work() {
            while(true) {
                string path=null; int token=0;
                lock(gate) { if(disposed) return; if(!paused&&jobs.Count>0) { path=jobs.Last.Value; jobs.RemoveLast(); token=pending[path]; } }
                if(path==null) { wake.WaitOne(); continue; }
                Bitmap result=null; string state="failed",error="缩略图不可用。";
                try {
                    Process child=GetProcess(token);
                    if(child!=null) {
                        child.StandardInput.WriteLine(Convert.ToBase64String(Encoding.UTF8.GetBytes(path))); child.StandardInput.Flush();
                        var response=child.StandardOutput.ReadLineAsync();
                        if(!response.Wait(8000)) { error="缩略图读取超时（8 秒）。"; lock(processGate) StopProcess(); }
                        else {
                            string line=response.Result;
                            if(line!=null&&line.StartsWith("ERROR|")&&line.Length<65536) error=Encoding.UTF8.GetString(Convert.FromBase64String(line.Substring(6)));
                            if(line!=null&&line.StartsWith("OK|")&&line.Length<65536) {
                                using(var stream=new MemoryStream(Convert.FromBase64String(line.Substring(3))))
                                using(var image=Image.FromStream(stream)) {
                                    if(image.Width>40||image.Height>40) throw new InvalidDataException("Oversized preview.");
                                    result=new Bitmap(image); state="ready";
                                }
                            }
                        }
                    }
                } catch(Exception ex) { error=ex.GetBaseException().Message; lock(processGate) StopProcess(); }
                lock(gate) {
                    int existing;
                    if(!disposed && token==generation && pending.TryGetValue(path,out existing)&&existing==token) {
                        pending.Remove(path); Put(path,result,state); result=null;
                        if(state=="failed") { if(warnings.Count==64)warnings.Dequeue(); warnings.Enqueue(new[]{path,error}); }
                    }
                }
                if(result!=null)result.Dispose(); Refresh();
            }
        }
        public bool Pause() {
            lock(processGate) {
                lock(gate) { paused=true; generation++; pending.Clear(); jobs.Clear(); }
                return StopProcess();
            }
        }
        public void Resume() { lock(gate) { if(disposed)return; paused=false; wake.Set(); } Refresh(); }
        public void Clear() {
            bool wasPaused; lock(gate) wasPaused=paused;
            Pause();
            lock(gate) { foreach(var e in cache.Values) if(e.Image!=null)e.Image.Dispose(); cache.Clear(); order.Clear(); warnings.Clear(); }
            if(!wasPaused)Resume();
        }
        public void Dispose() {
            lock(gate) { if(disposed)return; disposed=true; }
            Pause(); lock(gate) { foreach(var e in cache.Values)if(e.Image!=null)e.Image.Dispose(); cache.Clear(); order.Clear(); wake.Set(); }
        }
    }
    public static class UiDrawing {
        public static GraphicsPath Rounded(Rectangle r, int radius) {
            var p=new GraphicsPath(); int d=Math.Min(radius*2,Math.Min(r.Width,r.Height));
            if(d<2) { p.AddRectangle(r); return p; }
            p.AddArc(r.Left,r.Top,d,d,180,90); p.AddArc(r.Right-d,r.Top,d,d,270,90);
            p.AddArc(r.Right-d,r.Bottom-d,d,d,0,90); p.AddArc(r.Left,r.Bottom-d,d,d,90,90); p.CloseFigure(); return p;
        }
    }
    public class ModernButton : Button {
        bool hover, down;
        public bool Primary { get; set; }
        public ModernButton() {
            SetStyle(ControlStyles.UserPaint|ControlStyles.AllPaintingInWmPaint|ControlStyles.OptimizedDoubleBuffer|ControlStyles.ResizeRedraw,true);
            FlatStyle=FlatStyle.Flat; FlatAppearance.BorderSize=0; Cursor=Cursors.Hand; Height=36;
        }
        protected override void OnMouseEnter(EventArgs e) { hover=true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover=false; down=false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { down=true; Invalidate(); base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { down=false; Invalidate(); base.OnMouseUp(e); }
        protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
        protected override void OnPaint(PaintEventArgs e) {
            e.Graphics.Clear(Parent==null?Color.White:Parent.BackColor); e.Graphics.SmoothingMode=SmoothingMode.AntiAlias;
            Color bg=Primary?Color.FromArgb(37,99,235):Color.White;
            Color fg=Primary?Color.White:ForeColor;
            if(!Enabled) { bg=Color.FromArgb(238,241,245); fg=Color.FromArgb(148,157,173); }
            else if(down) bg=Primary?Color.FromArgb(29,78,216):Color.FromArgb(226,232,240);
            else if(hover) bg=Primary?Color.FromArgb(29,78,216):Color.FromArgb(246,248,251);
            using(var p=UiDrawing.Rounded(new Rectangle(1,1,Width-3,Height-3),8)) {
                using(var b=new SolidBrush(bg)) e.Graphics.FillPath(b,p);
                using(var pen=new Pen(Focused?Color.FromArgb(37,99,235):(Primary?bg:Color.FromArgb(217,224,234)),Focused?2:1)) e.Graphics.DrawPath(pen,p);
            }
            TextRenderer.DrawText(e.Graphics,Text,Font,ClientRectangle,fg,TextFormatFlags.HorizontalCenter|TextFormatFlags.VerticalCenter|TextFormatFlags.EndEllipsis);
        }
    }
    public class ModernCard : Panel {
        public ModernCard() { DoubleBuffered=true; BackColor=Color.White; Padding=new Padding(1); }
        protected override void OnPaint(PaintEventArgs e) {
            base.OnPaint(e); e.Graphics.SmoothingMode=SmoothingMode.AntiAlias;
            using(var p=UiDrawing.Rounded(new Rectangle(0,0,Width-1,Height-1),10))
            using(var pen=new Pen(Color.FromArgb(224,230,238))) e.Graphics.DrawPath(pen,p);
        }
    }
    public class ModernProgress : Control {
        int maximum=1, value;
        public event EventHandler ValueChanged;
        public int Maximum { get { return maximum; } set { maximum=Math.Max(1,value); this.value=Math.Min(this.value,maximum); Invalidate(); if(ValueChanged!=null) ValueChanged(this,EventArgs.Empty); } }
        public int Value { get { return value; } set { this.value=Math.Max(0,Math.Min(maximum,value)); Invalidate(); if(ValueChanged!=null) ValueChanged(this,EventArgs.Empty); } }
        public ModernProgress() { DoubleBuffered=true; Height=4; AccessibleRole=AccessibleRole.ProgressBar; }
        protected override void OnPaint(PaintEventArgs e) {
            e.Graphics.Clear(Color.FromArgb(226,232,240));
            using(var b=new SolidBrush(Color.FromArgb(37,99,235))) e.Graphics.FillRectangle(b,0,0,(int)(Width*(double)value/maximum),Height);
        }
    }
    public class ModernList : ListView {
        readonly ThumbnailCache thumbnails;
        public string ThumbnailWorkerScript { get { return thumbnails.WorkerScript; } set { thumbnails.WorkerScript=value; } }
        public int CachedThumbnailCount { get { return thumbnails.Count; } }
        public string GetThumbnailState(string path) { return thumbnails.State(path); }
        public Bitmap GetThumbnailCopy(string path) { return thumbnails.Copy(path); }
        public string[][] DrainThumbnailWarnings() { return thumbnails.DrainWarnings(); }
        public bool PauseThumbnailLoading() { return thumbnails.Pause(); }
        public void ResumeThumbnailLoading() { thumbnails.Resume(); }
        public void ClearThumbnails() { thumbnails.Clear(); }
        protected override void Dispose(bool disposing) { if(disposing)thumbnails.Dispose(); base.Dispose(disposing); }
        public int SortColumn { get; set; }
        public bool SortAscending { get; set; }
        public ModernList() {
            thumbnails=new ThumbnailCache(this);
            DoubleBuffered=true; OwnerDraw=true; View=View.Details; FullRowSelect=true;
            HideSelection=false; BorderStyle=BorderStyle.None; BackColor=Color.White;
            ShowItemToolTips=true; SortColumn=-1;
        }
        protected override void OnDrawColumnHeader(DrawListViewColumnHeaderEventArgs e) {
            e.Graphics.FillRectangle(Brushes.White,e.Bounds);
            if(e.Bounds.Width<28 || e.Bounds.Height<1) return;
            using(var p=new Pen(Color.FromArgb(226,232,240))) e.Graphics.DrawLine(p,e.Bounds.Left,e.Bounds.Bottom-1,e.Bounds.Right,e.Bounds.Bottom-1);
            var r=e.Bounds; r.X+=12; r.Width-=26;
            TextRenderer.DrawText(e.Graphics,e.Header.Text,Font,r,Color.FromArgb(100,116,139),TextFormatFlags.Left|TextFormatFlags.VerticalCenter|TextFormatFlags.EndEllipsis);
            if(e.ColumnIndex==SortColumn) {
                int x=e.Bounds.Right-15,y=e.Bounds.Top+e.Bounds.Height/2;
                Point[] points=SortAscending?new[]{new Point(x-3,y+2),new Point(x+3,y+2),new Point(x,y-2)}:new[]{new Point(x-3,y-2),new Point(x+3,y-2),new Point(x,y+2)};
                using(var b=new SolidBrush(Color.FromArgb(100,116,139))) e.Graphics.FillPolygon(b,points);
            }
        }
        protected override void OnDrawItem(DrawListViewItemEventArgs e) { }
        protected override void OnDrawSubItem(DrawListViewSubItemEventArgs e) {
            Color bg=e.Item.Selected?Color.FromArgb(235,242,255):(e.ItemIndex%2==0?Color.White:Color.FromArgb(250,251,253));
            using(var b=new SolidBrush(bg)) e.Graphics.FillRectangle(b,e.Bounds);
            if(e.Bounds.Width<24 || e.Bounds.Height<1) return;
            if(e.ColumnIndex==2) {
                string state=e.SubItem.Tag as string; Color fg=Color.FromArgb(71,85,105), tint=Color.FromArgb(241,245,249);
                if(state=="pending"||state=="untagged") { fg=Color.FromArgb(29,78,216); tint=Color.FromArgb(239,246,255); }
                if(state=="added"||state=="fixed_duplicate") { fg=Color.FromArgb(4,120,87); tint=Color.FromArgb(236,253,245); }
                if(state=="duplicate"||state=="warning") { fg=Color.FromArgb(161,98,7); tint=Color.FromArgb(255,251,235); }
                if(state=="failed"||state=="unreadable") { fg=Color.FromArgb(185,28,28); tint=Color.FromArgb(254,242,242); }
                int width=Math.Min(e.Bounds.Width-14,TextRenderer.MeasureText(e.SubItem.Text,Font).Width+15);
                var r=new Rectangle(e.Bounds.Left+8,e.Bounds.Top+(e.Bounds.Height-24)/2,width,24);
                e.Graphics.SmoothingMode=SmoothingMode.AntiAlias;
                using(var p=UiDrawing.Rounded(r,5)) using(var b=new SolidBrush(tint)) e.Graphics.FillPath(b,p);
                TextRenderer.DrawText(e.Graphics,e.SubItem.Text,Font,r,fg,TextFormatFlags.HorizontalCenter|TextFormatFlags.VerticalCenter|TextFormatFlags.EndEllipsis);
            } else {
                var r=e.Bounds; r.X+=12; r.Width-=20;
                if(e.ColumnIndex==0) {
                    string path=e.Item.Tag as string;
                    if(!String.IsNullOrEmpty(path)) thumbnails.Draw(e.Graphics,path,new Rectangle(e.Bounds.Left+10,e.Bounds.Top+(e.Bounds.Height-40)/2,40,40),e.Item.SubItems[2].Tag as string=="unreadable");
                    r.X+=52; r.Width=Math.Max(0,r.Width-52);
                }
                Color fg=e.ColumnIndex==0?Color.FromArgb(30,41,59):Color.FromArgb(100,116,139);
                TextRenderer.DrawText(e.Graphics,e.SubItem.Text,Font,r,fg,TextFormatFlags.Left|TextFormatFlags.VerticalCenter|TextFormatFlags.EndEllipsis|TextFormatFlags.NoPrefix);
            }
        }
    }
}
'@
}

function New-UiButton([string]$Text,[int]$Width=100,[bool]$Primary=$false) {
    $button=New-Object SynthTag.ModernButton
    $button.Text=$Text; $button.Width=$Width; $button.Height=36; $button.Primary=$Primary
    $button.ForeColor=[Drawing.Color]::FromArgb(51,65,85)
    $button.Margin=New-Object Windows.Forms.Padding(0,0,8,0)
    return $button
}

function New-UiLabel([string]$Text,[single]$Size=9.5,[bool]$Bold=$false) {
    $label=New-Object Windows.Forms.Label
    $label.Text=$Text; $label.AutoSize=$false
    $style=if ($Bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }
    $label.Font=New-Object Drawing.Font('Microsoft YaHei UI',$Size,$style)
    $label.ForeColor=[Drawing.Color]::FromArgb(100,116,139)
    return $label
}

function New-SynthTagWindow([string]$Version) {
    $form=New-Object Windows.Forms.Form
    $form.Text="SynthTag（打AI标签） v$Version"
    $form.ClientSize=New-Object Drawing.Size(1040,690)
    $form.MinimumSize=New-Object Drawing.Size(850,610)
    $form.StartPosition='CenterScreen'; $form.AllowDrop=$true
    $form.BackColor=[Drawing.Color]::FromArgb(246,248,251)
    $form.Font=New-Object Drawing.Font('Microsoft YaHei UI',9.5)
    $root=New-Object Windows.Forms.TableLayoutPanel
    $root.Dock='Fill'; $root.Padding=New-Object Windows.Forms.Padding(22,14,22,16)
    $root.ColumnCount=1; $root.RowCount=7
    foreach ($height in @(64,46,38,-1,78,56,34)) {
        $row=New-Object Windows.Forms.RowStyle
        if ($height -eq -1) { $row.SizeType='Percent'; $row.Height=100 } else { $row.SizeType='Absolute'; $row.Height=$height }
        $null=$root.RowStyles.Add($row)
    }
    $form.Controls.Add($root)
    $header=New-Object Windows.Forms.Panel; $header.Size=New-Object Drawing.Size(996,64); $header.Dock='Fill'; $header.Margin=New-Object Windows.Forms.Padding(0)
    $brand=New-UiLabel 'SynthTag' 22 $true; $brand.ForeColor=[Drawing.Color]::FromArgb(15,23,42); $brand.SetBounds(0,0,156,38)
    $brand.Font=New-Object Drawing.Font('Segoe UI',22,[Drawing.FontStyle]::Bold)
    $versionLabel=New-UiLabel "v$Version" 9; $versionLabel.SetBounds(158,14,92,23)
    $description=New-UiLabel '打 AI 标签，让图片与视频批量处理更轻松' 9; $description.SetBounds(2,40,600,21)
    $settings=New-UiButton '设置与诊断' 108; $settings.Anchor='Top,Right'; $settings.Location=New-Object Drawing.Point(876,6)
    $header.Controls.AddRange(@($brand,$versionLabel,$description,$settings)); $root.Controls.Add($header,0,0)
    $tools=New-Object Windows.Forms.Panel; $tools.Size=New-Object Drawing.Size(996,46); $tools.Dock='Fill'; $tools.Margin=New-Object Windows.Forms.Padding(0)
    $files=New-UiButton '+  添加文件' 118; $files.Location=New-Object Drawing.Point(0,4)
    $folder=New-UiButton '添加文件夹' 114; $folder.Location=New-Object Drawing.Point(128,4)
    $paste=New-UiButton '粘贴路径' 102; $paste.Location=New-Object Drawing.Point(252,4)
    $clear=New-UiButton '清空列表' 100; $clear.Anchor='Top,Right'; $clear.Location=New-Object Drawing.Point(884,4)
    $tools.Controls.AddRange(@($files,$folder,$paste,$clear)); $root.Controls.Add($tools,0,1)
    $summary=New-Object Windows.Forms.FlowLayoutPanel; $summary.Dock='Fill'; $summary.Margin=New-Object Windows.Forms.Padding(0); $summary.Padding=New-Object Windows.Forms.Padding(0,8,0,0)
    $counts=@{}
    foreach ($entry in @(@('TotalCount','全部  0',124),@('PendingCount','待添加  0',144),@('TaggedCount','已有标签  0',164),@('IssueCount','需关注  0',144))) {
        $label=New-UiLabel $entry[1] 9
        $label.Size=New-Object Drawing.Size($entry[2],25); $label.Margin=New-Object Windows.Forms.Padding(0)
        $summary.Controls.Add($label); $counts[$entry[0]]=$label
    }
    $counts.PendingCount.ForeColor=[Drawing.Color]::FromArgb(37,99,235)
    $counts.IssueCount.ForeColor=[Drawing.Color]::FromArgb(180,83,9)
    $root.Controls.Add($summary,0,2)
    $card=New-Object SynthTag.ModernCard; $card.Dock='Fill'; $card.Margin=New-Object Windows.Forms.Padding(0,0,0,10); $card.Padding=New-Object Windows.Forms.Padding(1)
    $list=New-Object SynthTag.ModernList; $list.Dock='Fill'; $list.AllowDrop=$true
    $null=$list.Columns.Add('文件名',300); $null=$list.Columns.Add('类型',68); $null=$list.Columns.Add('标签状态',156); $null=$list.Columns.Add('所在文件夹',460)
    $list.ThumbnailWorkerScript=Join-Path $PSScriptRoot 'thumbnail-worker.ps1'
    $rowImages=New-Object Windows.Forms.ImageList; $rowImages.ImageSize=New-Object Drawing.Size(1,56); $list.SmallImageList=$rowImages
    $list.Add_Disposed({ if ($this.SmallImageList) { $this.SmallImageList.Dispose() } })
    $list.Add_ClientSizeChanged({
        param($sender,$eventArgs)
        if ($sender.Columns.Count -eq 4) {
            $available=[Math]::Max(560,$sender.ClientSize.Width-4)
            $sender.Columns[0].Width=[Math]::Max(210,[int]($available*0.31))
            $sender.Columns[1].Width=64; $sender.Columns[2].Width=156
            $sender.Columns[3].Width=[Math]::Max(160,$available-$sender.Columns[0].Width-220)
        }
    })
    $empty=New-Object Windows.Forms.Panel; $empty.Dock='Fill'; $empty.BackColor=[Drawing.Color]::White; $empty.AllowDrop=$true
    $emptyText=New-UiLabel "将图片或文件夹拖到这里`n`n也可点击上方按钮，或按 Ctrl+V 粘贴路径`n支持 JPG、PNG、TIFF、WebP 及常用视频格式" 11
    $emptyText.Dock='Fill'; $emptyText.TextAlign='MiddleCenter'; $emptyText.ForeColor=[Drawing.Color]::FromArgb(100,116,139)
    $emptyText.AllowDrop=$true; $empty.Controls.Add($emptyText)
    $card.Controls.Add($list); $card.Controls.Add($empty); $empty.BringToFront(); $root.Controls.Add($card,0,3)
    $detail=New-Object Windows.Forms.TableLayoutPanel; $detail.Dock='Fill'; $detail.Margin=New-Object Windows.Forms.Padding(0,0,0,8)
    $detail.ColumnCount=2; $detail.RowCount=2
    $null=$detail.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100)))
    $null=$detail.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute,110)))
    $null=$detail.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,22)))
    $null=$detail.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100)))
    $detailTitle=New-UiLabel '文件详情' 9 $true; $detailTitle.Dock='Fill'; $detailTitle.Margin=New-Object Windows.Forms.Padding(0)
    $detailBody=New-Object Windows.Forms.TextBox; $detailBody.Dock='Fill'; $detailBody.BorderStyle='None'; $detailBody.Multiline=$true; $detailBody.ReadOnly=$true; $detailBody.ScrollBars='Vertical'
    $detailBody.BackColor=$form.BackColor; $detailBody.ForeColor=[Drawing.Color]::FromArgb(100,116,139); $detailBody.Font=New-Object Drawing.Font('Microsoft YaHei UI',9)
    $detailBody.Text='添加文件后，选中一行查看完整路径和处理结果。'; $detailBody.Margin=New-Object Windows.Forms.Padding(0,2,12,0)
    $copyDetails=New-UiButton '复制详情' 100; $copyDetails.Enabled=$false; $copyDetails.Anchor='Top,Right'; $copyDetails.Margin=New-Object Windows.Forms.Padding(0,10,0,0)
    $detail.Controls.Add($detailTitle,0,0); $detail.Controls.Add($detailBody,0,1); $detail.Controls.Add($copyDetails,1,0); $detail.SetRowSpan($copyDetails,2)
    $root.Controls.Add($detail,0,4)
    $actions=New-Object Windows.Forms.Panel; $actions.Size=New-Object Drawing.Size(996,56); $actions.Dock='Fill'; $actions.Margin=New-Object Windows.Forms.Padding(0)
    $backup=New-Object Windows.Forms.CheckBox; $backup.Text='保留原始文件备份'; $backup.AutoSize=$true; $backup.SetBounds(0,18,180,25); $backup.ForeColor=[Drawing.Color]::FromArgb(71,85,105)
    $scan=New-UiButton '检查标签' 96; $scan.Location=New-Object Drawing.Point(206,8)
    $remove=New-UiButton '移除标签…' 108; $remove.Location=New-Object Drawing.Point(312,8)
    $export=New-UiButton '导出问题清单' 126; $export.Anchor='Top,Right'; $export.Location=New-Object Drawing.Point(654,8)
    $add=New-UiButton '开始添加标签' 190 $true; $add.Height=42; $add.Anchor='Top,Right'; $add.Location=New-Object Drawing.Point(794,5)
    $actions.Controls.AddRange(@($backup,$scan,$remove,$export,$add)); $root.Controls.Add($actions,0,5)
    $footer=New-Object Windows.Forms.TableLayoutPanel; $footer.Dock='Fill'; $footer.Margin=New-Object Windows.Forms.Padding(0); $footer.ColumnCount=2; $footer.RowCount=2
    $null=$footer.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100)))
    $null=$footer.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute,80)))
    $null=$footer.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,5)))
    $null=$footer.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100)))
    $bar=New-Object SynthTag.ModernProgress; $bar.Dock='Fill'; $bar.Margin=New-Object Windows.Forms.Padding(0); $bar.Visible=$false
    $status=New-UiLabel '添加文件，然后开始打标签。' 9; $status.Dock='Fill'; $status.TextAlign='MiddleLeft'; $status.Margin=New-Object Windows.Forms.Padding(0)
    $status.AutoEllipsis=$true
    $progressText=New-UiLabel '' 9; $progressText.Dock='Fill'; $progressText.TextAlign='MiddleRight'; $progressText.Margin=New-Object Windows.Forms.Padding(0)
    $footer.Controls.Add($bar,0,0); $footer.SetColumnSpan($bar,2); $footer.Controls.Add($status,0,1); $footer.Controls.Add($progressText,1,1); $root.Controls.Add($footer,0,6)
    $menu=New-Object Windows.Forms.ContextMenuStrip
    $open=$menu.Items.Add('打开所在文件夹'); $copy=$menu.Items.Add('复制完整路径'); $null=$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    $removeSel=$menu.Items.Add('从列表移出选中项    Delete'); $keep=$menu.Items.Add('仅保留选中项'); $null=$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    $pasteMenu=$menu.Items.Add('粘贴文件或路径    Ctrl+V'); $selectAll=$menu.Items.Add('全选    Ctrl+A'); $list.ContextMenuStrip=$menu
    $tips=New-Object Windows.Forms.ToolTip
    $tips.SetToolTip($clear,'仅清空当前列表，不删除任何文件。')
    $tips.SetToolTip($backup,'写入前保留一个带 _original 后缀的原始文件备份。')
    $tips.SetToolTip($scan,'重新检查标签和文件状态，不修改文件。')
    $tips.SetToolTip($counts.IssueCount,'包含重复、读取失败、处理失败或已完成但有警告的文件；可能与其他计数重叠。')
    $form.Tag=@{ ToolTip=$tips }
    $form.Add_Disposed({ if ($this.Tag.ToolTip) { $this.Tag.ToolTip.Dispose() } })
    return [pscustomobject]@{
        Form=$form; List=$list; Files=$files; Folder=$folder; Paste=$paste; Clear=$clear; Settings=$settings; Add=$add; Scan=$scan; Remove=$remove; Export=$export; Backup=$backup; Bar=$bar; Status=$status
        DetailTitle=$detailTitle; DetailBody=$detailBody; CopyDetails=$copyDetails; EmptyPanel=$empty; EmptyText=$emptyText; TotalCount=$counts.TotalCount; PendingCount=$counts.PendingCount; TaggedCount=$counts.TaggedCount; IssueCount=$counts.IssueCount; ProgressText=$progressText
        Menu=$menu; OpenFolder=$open; CopyPath=$copy; RemoveSelected=$removeSel; KeepSelected=$keep; PasteMenu=$pasteMenu; SelectAll=$selectAll
    }
}

function New-SynthTagSettingsWindow([string]$Version,[string]$EngineVersion,[string]$LogDirectory,[bool]$Healthy,[string]$LogError) {
    $window=New-Object Windows.Forms.Form
    $window.Text="设置与诊断 · SynthTag v$Version"
    $window.ClientSize=New-Object Drawing.Size(600,494)
    $window.StartPosition='CenterParent'; $window.FormBorderStyle='FixedDialog'
    $window.MaximizeBox=$false; $window.MinimizeBox=$false
    $window.Font=New-Object Drawing.Font('Microsoft YaHei UI',9.5)
    $window.BackColor=[Drawing.Color]::FromArgb(246,248,251)
    $root=New-Object Windows.Forms.TableLayoutPanel
    $root.Dock='Fill'; $root.Padding=New-Object Windows.Forms.Padding(24,18,24,18)
    $root.ColumnCount=1; $root.RowCount=5
    foreach ($height in @(56,54,156,138,54)) { $null=$root.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,$height))) }
    $title=New-UiLabel '设置与诊断' 18 $true; $title.Dock='Fill'; $title.ForeColor=[Drawing.Color]::FromArgb(15,23,42); $title.Margin=New-Object Windows.Forms.Padding(0)
    $root.Controls.Add($title,0,0)
    $about=New-UiLabel "SynthTag  v$Version     ·     ExifTool $EngineVersion" 10
    $about.Dock='Fill'; $about.Margin=New-Object Windows.Forms.Padding(0); $root.Controls.Add($about,0,1)
    $logs=New-Object SynthTag.ModernCard; $logs.Dock='Fill'; $logs.Margin=New-Object Windows.Forms.Padding(0,0,0,12)
    $logTitle=New-UiLabel '本地日志' 10 $true; $logTitle.SetBounds(16,12,220,25); $logTitle.ForeColor=[Drawing.Color]::FromArgb(30,41,59)
    $logState=New-UiLabel $(if ($Healthy) { '● 记录正常' } else { '● 日志写入异常' }) 9
    $logState.SetBounds(390,14,140,22); $logState.TextAlign='MiddleRight'
    $logState.ForeColor=if ($Healthy) { [Drawing.Color]::FromArgb(4,120,87) } else { [Drawing.Color]::FromArgb(185,28,28) }
    $retention=New-UiLabel '保留近 30 天   ·   INFO / WARNING / ERROR' 9; $retention.SetBounds(16,42,500,24)
    $location=New-Object Windows.Forms.TextBox; $location.SetBounds(16,72,510,26); $location.ReadOnly=$true; $location.TabStop=$false; $location.BorderStyle='None'; $location.BackColor=[Drawing.Color]::White; $location.ForeColor=[Drawing.Color]::FromArgb(100,116,139); $location.Text=$LogDirectory
    $open=New-UiButton '打开日志文件夹' 140; $open.SetBounds(14,101,140,32)
    $logs.Controls.AddRange(@($logTitle,$logState,$retention,$location,$open))
    if (-not $Healthy) { $location.Text=$LogError+'  ·  '+$LogDirectory }
    $root.Controls.Add($logs,0,2)
    $diagnostics=New-Object SynthTag.ModernCard; $diagnostics.Dock='Fill'; $diagnostics.Margin=New-Object Windows.Forms.Padding(0,0,0,12)
    $diagTitle=New-UiLabel '问题排查' 10 $true; $diagTitle.SetBounds(16,12,300,25); $diagTitle.ForeColor=[Drawing.Color]::FromArgb(30,41,59)
    $privacy=New-UiLabel "诊断包包含环境、软件版本、日志和问题清单。`n不包含图片或恢复副本；分享前请检查文件名与共享路径。" 9
    $privacy.SetBounds(16,43,510,58)
    $diagnostics.Controls.AddRange(@($diagTitle,$privacy)); $root.Controls.Add($diagnostics,0,3)
    $footer=New-Object Windows.Forms.FlowLayoutPanel; $footer.Dock='Fill'; $footer.FlowDirection='RightToLeft'; $footer.Margin=New-Object Windows.Forms.Padding(0); $footer.Padding=New-Object Windows.Forms.Padding(0,5,0,0)
    $export=New-UiButton '导出诊断压缩包' 172 $true; $export.Margin=New-Object Windows.Forms.Padding(0)
    $close=New-UiButton '完成' 90; $close.Margin=New-Object Windows.Forms.Padding(0,0,10,0)
    $footer.Controls.Add($export); $footer.Controls.Add($close); $root.Controls.Add($footer,0,4)
    $window.Controls.Add($root)
    $window.CancelButton=$close
    $close.Add_Click({ param($sender,$eventArgs) $sender.FindForm().Close() })
    return [pscustomobject]@{ Form=$window; OpenLogs=$open; Export=$export }
}
