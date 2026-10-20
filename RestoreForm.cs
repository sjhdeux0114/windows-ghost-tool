using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Windows.Forms;

class RestoreForm : Form {
    ComboBox disks=new ComboBox(); TextBox image=new TextBox(),log=new TextBox();
    Button refresh,browse,install; Timer poll=new Timer(); Process ghostProcess;
    DiskInfo selected; string source,workDir; int phase=0; List<DiskInfo> lastDisks;
    readonly string appPath=AppDomain.CurrentDomain.BaseDirectory;
    FileStream sourceLock;
    public RestoreForm() {
        Text="GHO → HDD에 설치하기"; ClientSize=new Size(940,570); MinimumSize=new Size(956,609); Font=new Font("Malgun Gothic",10); StartPosition=FormStartPosition.CenterParent;
        LabelAt("GHO의 Windows와 파티션을 대상 HDD 전체에 복원합니다.",20,15,900,35).Font=new Font(Font.FontFamily,15,FontStyle.Bold);
        LabelAt("대상 HDD의 기존 파티션과 데이터가 삭제됩니다. 시스템·부팅·페이지 파일·앱 디스크는 보호됩니다.",20,60,900,45);
        LabelAt("1. 설치할 물리 HDD 선택",20,120,800,25);
        disks.DropDownStyle=ComboBoxStyle.DropDownList; disks.SetBounds(20,150,770,32); Controls.Add(disks);
        refresh=ButtonAt("새로 고침",800,148,120,36); refresh.Click+=delegate { LoadDisks(); };
        LabelAt("2. 복원할 GHO 파일 선택",20,210,800,25);
        image.SetBounds(20,243,770,32); image.ReadOnly=true; Controls.Add(image);
        browse=ButtonAt("GHO 선택",800,241,120,36); browse.Click+=delegate { using(var d=new OpenFileDialog { Filter="Ghost 이미지|*.gho",InitialDirectory=appPath }) { if(d.ShowDialog(this)==DialogResult.OK) image.Text=d.FileName; } };
        install=ButtonAt("선택한 HDD에 Windows 설치",580,303,340,45); install.Click+=delegate { BeginRestore(); };
        LabelAt("UEFI/GPT 이미지와 BIOS/MBR 이미지에 맞춰 대상 PC의 부팅 모드를 설정하세요.",20,365,900,32);
        log.Multiline=true; log.ReadOnly=true; log.ScrollBars=ScrollBars.Vertical; log.SetBounds(20,410,900,135); log.Anchor=AnchorStyles.Left|AnchorStyles.Right|AnchorStyles.Top|AnchorStyles.Bottom; Controls.Add(log);
        poll.Interval=750; poll.Tick+=delegate { Poll(); }; Shown+=delegate { LoadDisks(); };
        FormClosing+=delegate(object sender,FormClosingEventArgs e) { if(ghostProcess!=null) { e.Cancel=true; Warn("Ghost 검증/복원이 진행 중입니다. 완료될 때까지 기다리세요."); } };
        FormClosed+=delegate { poll.Dispose(); if(sourceLock!=null) sourceLock.Dispose(); };
        try { workDir=Path.Combine(appPath,"RestoreLogs",DateTime.Now.ToString("yyyyMMdd-HHmmss")+"-"+Guid.NewGuid().ToString("N").Substring(0,6)); Directory.CreateDirectory(workDir); Write("복원 창 시작. 아직 디스크에 쓰지 않습니다."); }
        catch(Exception ex) { install.Enabled=false; log.Text="로그 폴더 생성 실패: "+ex.Message; }
    }
    Label LabelAt(string s,int x,int y,int w,int h) { var l=new Label { Text=s }; l.SetBounds(x,y,w,h); Controls.Add(l); return l; }
    Button ButtonAt(string s,int x,int y,int w,int h) { var b=new Button { Text=s }; b.SetBounds(x,y,w,h); Controls.Add(b); return b; }
    void Warn(string s) { MessageBox.Show(this,s,"복원 확인",MessageBoxButtons.OK,MessageBoxIcon.Warning); }
    void Write(string s) { string line=DateTime.Now.ToString("o")+"  "+s+Environment.NewLine; log.AppendText(line); if(workDir!=null&&Directory.Exists(workDir)) File.AppendAllText(Path.Combine(workDir,"restore.log"),line); }
    void Busy(bool busy) { install.Enabled=browse.Enabled=refresh.Enabled=disks.Enabled=!busy; if(!busy) install.Text="선택한 HDD에 Windows 설치"; }
    void LoadDisks() {
        try {
            disks.Items.Clear(); lastDisks=DiskCatalog.Read(); DiskInfo appDisk=DiskCatalog.ForPath(lastDisks,Application.ExecutablePath);
            foreach(var d in lastDisks) { if(!d.Protected&&!d.ReadOnly&&d.Index!=appDisk.Index) disks.Items.Add(d); }
            Write("설치 가능한 디스크 "+disks.Items.Count+"개. 대상이 보이지 않으면 관리자 권한과 연결 상태를 확인하세요.");
        } catch(Exception ex) { disks.Items.Clear(); Write(ex.ToString()); Warn("디스크 조회 실패: "+ex.Message); }
    }
    DiskInfo ValidateTarget() {
        var fresh=DiskCatalog.Read();
        // Ghost's native physical disks are one-based (Broadcom KB 263551).
        // Gaps or excessive counts could indicate special enumeration: fail closed.
        return RestorePolicy.Validate(fresh,selected,DiskCatalog.ForPath(fresh,source),DiskCatalog.ForPath(fresh,Application.ExecutablePath));
    }
    void BeginRestore() {
        if(ghostProcess!=null||phase!=0) return;
        try {
            selected=disks.SelectedItem as DiskInfo; if(selected==null) throw new Exception("설치할 HDD를 선택하세요.");
            source=Path.GetFullPath(image.Text);
            if(!File.Exists(source)||!string.Equals(Path.GetExtension(source),".gho",StringComparison.OrdinalIgnoreCase)) throw new Exception("유효한 GHO 파일을 선택하세요.");
            if(source.IndexOfAny(new char[]{',','"','\r','\n'})>=0) throw new Exception("GHO 경로에서 쉼표와 따옴표를 제거하세요.");
            if(!File.Exists(Path.Combine(appPath,"Ghost64.exe"))) throw new Exception("Ghost64.exe가 없습니다.");
            if(Process.GetProcessesByName("Ghost64").Length!=0) throw new Exception("이미 실행 중인 Ghost를 먼저 종료하세요.");
            DiskInfo current=ValidateTarget();
            string text="이 HDD의 모든 파티션과 데이터가 삭제됩니다.\n\n대상: "+current+"\n고유 ID: "+current.UniqueId+"\n원본: "+source+"\n\n진행 순서: 이미지 무결성 검사 → HDD 복원 1회.\n검사 화면에서는 HDD에 쓰지 않습니다. 계속할까요?";
            if(MessageBox.Show(this,text,"HDD 전체 덮어쓰기 확인",MessageBoxButtons.YesNo,MessageBoxIcon.Warning,MessageBoxDefaultButton.Button2)!=DialogResult.Yes) { Write("사용자가 복원을 취소했습니다. Ghost를 실행하지 않았습니다."); return; }
            ValidateTarget();
            if(workDir==null||!Directory.Exists(workDir)) throw new Exception("복원 로그 폴더가 없습니다.");
            File.WriteAllText(Path.Combine(workDir,"request.txt"),"Image: "+source+Environment.NewLine+"Target: "+selected+Environment.NewLine+"UniqueId: "+selected.UniqueId);
            foreach(var disk in DiskCatalog.Read()) File.AppendAllText(Path.Combine(workDir,"disk-snapshot.txt"),disk+" | UniqueId="+disk.UniqueId+" | PnpId="+disk.PnpId+Environment.NewLine);
            sourceLock=new FileStream(source,FileMode.Open,FileAccess.Read,FileShare.Read);
            Busy(true); phase=1;
            install.Text="1/2 이미지 검사 중 (HDD 쓰기 없음)";
            Write("GHO 무결성 검사 중. 아직 대상 HDD에 쓰지 않습니다.");
            StartGhost("\"-chkimg,"+source+"\" -batch -fx");
        } catch(Exception ex) { if(sourceLock!=null) { sourceLock.Dispose(); sourceLock=null; } phase=0; Busy(false); Write(ex.ToString()); Warn(ex.Message); }
    }
    void StartGhost(string args) {
        args+=" \"-afile="+Path.Combine(workDir,"ghost-error-phase"+phase+".txt")+"\"";
        Write("실행: Ghost64.exe "+args);
        File.AppendAllText(Path.Combine(workDir,"request.txt"),Environment.NewLine+"Ghost64.exe "+args);
        ghostProcess=Process.Start(new ProcessStartInfo(Path.Combine(appPath,"Ghost64.exe"),args){UseShellExecute=true,WorkingDirectory=workDir}); poll.Start();
    }
    void Poll() {
        try {
            if(ghostProcess==null||!ghostProcess.HasExited) return;
            int code=ghostProcess.ExitCode; ghostProcess.Dispose(); ghostProcess=null; poll.Stop();
            Write("Ghost 단계 "+phase+" 종료 코드: "+code);
            if(code!=0) throw new Exception("Ghost 작업 실패: 종료 코드 "+code+". 로그 폴더: "+workDir);
            if(phase==1) {
                DiskInfo current=ValidateTarget();
                phase=2;
                install.Text="2/2 HDD 복원 중";
                // Keep Ghost's own final destination confirmation. No -sure / -batch on restore.
                Write("Ghost 복원 창에서 대상 모델과 용량을 최종 확인하세요. 예상 Ghost 디스크: "+(current.Index+1));
                StartGhost("\"-clone,mode=restore,src="+source+",dst="+(current.Index+1)+"\" -fx");
            } else {
                if(sourceLock!=null) { sourceLock.Dispose(); sourceLock=null; }
                phase=0; Busy(false); Write("Ghost 종료 코드 0. Ghost의 완료 표시를 확인하세요. 취소했다면 설치 완료가 아닙니다. 실제 대상 PC의 부팅 검증이 필요합니다.");
            }
        } catch(Exception ex) { poll.Stop(); if(ghostProcess==null) { if(sourceLock!=null) { sourceLock.Dispose(); sourceLock=null; } phase=0; Busy(false); } Warn(ex.Message); Write(ex.ToString()); }
    }
}
