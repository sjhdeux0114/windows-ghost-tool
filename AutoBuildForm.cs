using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Management;
using System.ComponentModel;
using System.Text;
using System.Windows.Forms;

class AutoBuildForm : Form {
    readonly string basePath=AppDomain.CurrentDomain.BaseDirectory;
    string jobPath, isoPath, selectedOutput, familyOverride="Auto"; Process worker; Timer poll=new Timer();
    TextBox output=new TextBox(); Label status=new Label(); Button open=new Button();
    bool finished=false; long lastLength=-1;
    bool stopping=false; Button stop=new Button();
    int memoryGB=8, processorCount=4;
    readonly object launcherLock=new object(); string launcherLog;
    public AutoBuildForm() {
        Text="ISO → GHO 파일 만들기";
        ClientSize=new Size(900,600); MinimumSize=new Size(800,500);
        Font=new Font("Malgun Gothic",10); StartPosition=FormStartPosition.CenterParent;
        status.Text="자동 빌드를 준비합니다..."; status.SetBounds(20,15,860,60); status.Anchor=AnchorStyles.Left|AnchorStyles.Right|AnchorStyles.Top; Controls.Add(status);
        output.Multiline=true; output.ReadOnly=true; output.ScrollBars=ScrollBars.Both; output.WordWrap=false;
        output.SetBounds(20,90,860,425); output.Anchor=AnchorStyles.Left|AnchorStyles.Right|AnchorStyles.Top|AnchorStyles.Bottom; Controls.Add(output);
        open.Text="결과 / 로그 폴더 열기"; open.SetBounds(20,540,230,38); open.Anchor=AnchorStyles.Left|AnchorStyles.Bottom; open.Enabled=false; Controls.Add(open);
        open.Click+=delegate { if(Directory.Exists(jobPath)) Process.Start(new ProcessStartInfo(jobPath){UseShellExecute=true}); };
        stop.Text="강제 중단"; stop.SetBounds(270,540,150,38); stop.Anchor=AnchorStyles.Left|AnchorStyles.Bottom; stop.Enabled=false; stop.Click+=delegate { StopBuild(); }; Controls.Add(stop);
        Button close=new Button { Text="닫기" }; close.SetBounds(760,540,120,38); close.Anchor=AnchorStyles.Right|AnchorStyles.Bottom; Controls.Add(close); close.Click+=delegate { Close(); };
        poll.Interval=1000; poll.Tick+=delegate { PollWorker(); };
        Shown+=delegate { BeginBuild(); };
        FormClosing+=delegate(object sender,FormClosingEventArgs e) {
            if(worker!=null&&!finished) { e.Cancel=true; MessageBox.Show(this,"자동 작업이 진행 중입니다. 이 창을 닫아 강제 종료하지 않습니다. 완료 또는 오류가 표시될 때까지 기다려 주세요.","자동 빌드 진행 중"); }
        };
        FormClosed+=delegate { poll.Dispose(); if(worker!=null) worker.Dispose(); };
    }
    void BeginBuild() {
        try {
            string script=Path.Combine(basePath,"AutoBuild.ps1");
            if(!File.Exists(script)) throw new Exception("AutoBuild.ps1이 없습니다. 앱과 같은 폴더에 두세요.");
            using(OpenFileDialog d=new OpenFileDialog { Filter="Windows 설치 ISO|*.iso",Title="Windows 7 / 10 / 11 ISO 선택",InitialDirectory=basePath,FileName="Windows_10.iso" }) {
                if(d.ShowDialog(this)!=DialogResult.OK) { finished=true; status.Text="ISO 선택을 취소했습니다."; return; }
                isoPath=d.FileName;
            }
            using(SaveFileDialog d=new SaveFileDialog { Filter="Ghost 이미지|*.gho",Title="GHO 저장 위치 선택",FileName="Windows-"+DateTime.Now.ToString("yyyyMMdd-HHmmss")+".gho",InitialDirectory=basePath }) {
                if(d.ShowDialog(this)!=DialogResult.OK) { finished=true; status.Text="저장 위치 선택을 취소했습니다."; return; }
                selectedOutput=d.FileName;
            }
            if(!ChooseResources()) { finished=true; status.Text="VM 설정을 취소했습니다."; return; }
            StartWorker(script);
        } catch(Exception ex) { finished=true; status.Text="자동 빌드를 시작하지 못했습니다."; output.Text=ex.Message; }
    }
    void StartWorker(string script) {
            jobPath=Path.Combine(Path.GetDirectoryName(selectedOutput),"AutoBuilds",DateTime.Now.ToString("yyyyMMdd-HHmmss")+"-"+Guid.NewGuid().ToString("N").Substring(0,6));
            Directory.CreateDirectory(Path.GetDirectoryName(jobPath));
            File.AppendAllText(Path.Combine(basePath,"vm-history-roots.txt"),Path.GetDirectoryName(jobPath)+Environment.NewLine);
            launcherLog=jobPath+".launcher.log";
            string args="-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \""+script+"\" -IsoPath \""+isoPath+"\" -JobDirectory \""+jobPath+"\" -OutputPath \""+selectedOutput+"\" -WindowsFamily "+familyOverride;
            args+=" -MemoryGB "+memoryGB+" -ProcessorCount "+processorCount;
            string ps=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),@"WindowsPowerShell\v1.0\powershell.exe");
            worker=new Process { StartInfo=new ProcessStartInfo(ps,args){UseShellExecute=false,CreateNoWindow=true,RedirectStandardError=true,RedirectStandardOutput=true} };
            worker.OutputDataReceived+=delegate(object sender,DataReceivedEventArgs e) { RecordLauncher(e.Data); };
            worker.ErrorDataReceived+=delegate(object sender,DataReceivedEventArgs e) { RecordLauncher(e.Data); };
            worker.Start(); worker.BeginOutputReadLine(); worker.BeginErrorReadLine();
            finished=false; lastLength=-1; output.Clear();
            stop.Enabled=true;
            status.Text="ISO의 Windows 버전 자동 판별 → Windows 설치 → Sysprep → GHO 생성\nWindows 7: BIOS / Windows 10·11 x64: UEFI · 새 VM만 사용합니다.";
            poll.Start();
    }
    void PollWorker() {
        if(stopping) return;
        try {
            string log=Path.Combine(jobPath,"build.log");
            if(File.Exists(log)) {
                using(FileStream f=new FileStream(log,FileMode.Open,FileAccess.Read,FileShare.ReadWrite)) {
                    if(f.Length!=lastLength) { lastLength=f.Length; using(StreamReader r=new StreamReader(f)) { output.Text=r.ReadToEnd(); } output.SelectionStart=output.TextLength; output.ScrollToCaret(); }
                }
                open.Enabled=true;
            }
            if(worker==null||!worker.HasExited) return;
            worker.WaitForExit();
            poll.Stop(); finished=true; stop.Enabled=false;
            if(worker.ExitCode==20) {
                string family=ChooseFamily();
                if(family!=null) { familyOverride=family; worker.Dispose(); worker=null; StartWorker(Path.Combine(basePath,"AutoBuild.ps1")); return; }
            }
            bool success=worker.ExitCode==0 && File.Exists(Path.Combine(jobPath,"result.json"));
            status.Text=success ? "GHO 생성 및 Ghost 무결성 검사 통과\n"+selectedOutput :
                worker.ExitCode==3010 ? "Hyper-V 설치 완료. PC를 재부팅하고 ISO → GHO 파일 만들기를 다시 누르세요." : "자동 빌드 중단. 아래 로그의 원인을 확인하세요. 완료된 이미지로 취급하지 마세요.";
            if(!File.Exists(log)) output.Text="작업 로그가 생성되지 않았습니다. 종료 코드: "+worker.ExitCode+"\r\n"+(File.Exists(launcherLog)?File.ReadAllText(launcherLog):"PowerShell 실행 상태와 폴더 권한을 확인하세요.");
        } catch(IOException) { } catch(Exception ex) { output.AppendText(Environment.NewLine+ex.Message); }
    }
    void RecordLauncher(string line) {
        if(line==null) return;
        try { lock(launcherLock) { File.AppendAllText(launcherLog,DateTime.Now.ToString("o")+" "+line+Environment.NewLine); } } catch(IOException) { }
    }
    void StopBuild() {
        if(stopping||finished||worker==null)return;
        if(MessageBox.Show(this,"현재 빌드와 해당 가상 Windows를 강제로 중단할까요?\n미완성 VM·이미지는 사용할 수 없으며 작업 파일은 보존됩니다.","강제 중단",MessageBoxButtons.YesNo,MessageBoxIcon.Warning,MessageBoxDefaultButton.Button2)!=DialogResult.Yes)return;
        stopping=true; stop.Enabled=false; status.Text="작업과 VM을 강제 중단하고 있습니다...";
        int workerId=worker.Id;
        var background=new BackgroundWorker();
        background.DoWork+=delegate(object sender,DoWorkEventArgs e){
            string script=Path.Combine(basePath,"StopBuild.ps1");
            string ps=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),@"WindowsPowerShell\v1.0\powershell.exe");
            using(var p=new Process {StartInfo=new ProcessStartInfo(ps,"-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \""+script+"\" -JobDirectory \""+jobPath+"\" -WorkerId "+workerId){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true}}){
                var errors=new StringBuilder();p.ErrorDataReceived+=delegate(object s,DataReceivedEventArgs ev){if(ev.Data!=null)errors.AppendLine(ev.Data);};
                p.Start();p.BeginErrorReadLine();p.StandardOutput.ReadToEnd();p.WaitForExit();if(p.ExitCode!=0)throw new Exception(errors.ToString());
            }
        };
        background.RunWorkerCompleted+=delegate(object sender,RunWorkerCompletedEventArgs e){
            background.Dispose();stopping=false;
            if(e.Error!=null){stop.Enabled=true;status.Text="강제 중단에 실패했습니다.";MessageBox.Show(this,e.Error.Message);return;}
            poll.Stop();finished=true;status.Text="사용자 요청으로 강제 중단했습니다. 미완성 결과는 사용하지 마세요.";output.AppendText(Environment.NewLine+status.Text);
        };
        background.RunWorkerAsync();
    }
    bool ChooseResources() {
        int totalGB=0, availableGB=0, cpus=Environment.ProcessorCount;
        using(ManagementObjectSearcher search=new ManagementObjectSearcher("SELECT TotalVisibleMemorySize,FreePhysicalMemory FROM Win32_OperatingSystem"))
        using(ManagementObjectCollection rows=search.Get()) foreach(ManagementObject row in rows) {
            totalGB=(int)(Convert.ToUInt64(row["TotalVisibleMemorySize"])/1048576);
            availableGB=(int)(Convert.ToUInt64(row["FreePhysicalMemory"])/1048576);
        }
        if(totalGB<2) throw new Exception("VM에 할당할 메모리가 부족합니다.");
        using(Form f=new Form { Text="가상 Windows 사양 선택",ClientSize=new Size(520,260),StartPosition=FormStartPosition.CenterParent,Font=Font,FormBorderStyle=FormBorderStyle.FixedDialog,MaximizeBox=false,MinimizeBox=false }) {
            f.Controls.Add(new Label { Text="이 PC: RAM "+totalGB+"GB / 현재 사용 가능 약 "+availableGB+"GB / 논리 CPU "+cpus+"개\n호스트에서 사용할 자원을 남겨 주세요. 값은 직접 높일 수 있습니다.",Left=20,Top=20,Width=480,Height=65 });
            f.Controls.Add(new Label { Text="VM RAM (GB)",Left=20,Top=100,Width=160 });
            NumericUpDown ram=new NumericUpDown { Left=200,Top=95,Width=140,Minimum=2,Maximum=totalGB,Value=Math.Max(2,Math.Min(8,Math.Min(totalGB/2,availableGB-2))) }; f.Controls.Add(ram);
            f.Controls.Add(new Label { Text="VM CPU 개수",Left=20,Top=145,Width=160 });
            NumericUpDown cpu=new NumericUpDown { Left=200,Top=140,Width=140,Minimum=1,Maximum=cpus,Value=Math.Max(1,Math.Min(4,cpus/2)) }; f.Controls.Add(cpu);
            Button ok=new Button { Text="시작",Left=300,Top=205,Width=90,DialogResult=DialogResult.OK }; f.Controls.Add(ok); f.AcceptButton=ok;
            Button cancel=new Button { Text="취소",Left=400,Top=205,Width=90,DialogResult=DialogResult.Cancel }; f.Controls.Add(cancel); f.CancelButton=cancel;
            if(f.ShowDialog(this)!=DialogResult.OK) return false;
            memoryGB=(int)ram.Value; processorCount=(int)cpu.Value; return true;
        }
    }
    string ChooseFamily() {
        using(Form f=new Form { Text="Windows 버전 선택",ClientSize=new Size(440,180),StartPosition=FormStartPosition.CenterParent,Font=Font,FormBorderStyle=FormBorderStyle.FixedDialog,MaximizeBox=false,MinimizeBox=false }) {
            f.Controls.Add(new Label { Text="ISO 정보를 자동 판별하지 못했습니다.\n설치 미디어의 Windows 버전을 선택하세요.",Left=20,Top=15,Width=400,Height=55 });
            ComboBox c=new ComboBox { Left=20,Top=80,Width=390,DropDownStyle=ComboBoxStyle.DropDownList }; c.Items.AddRange(new object[]{"Windows 7","Windows 10","Windows 11"}); c.SelectedIndex=1; f.Controls.Add(c);
            Button ok=new Button { Text="계속",Left=220,Top=130,Width=90,DialogResult=DialogResult.OK }; f.Controls.Add(ok); f.AcceptButton=ok;
            Button cancel=new Button { Text="취소",Left=320,Top=130,Width=90,DialogResult=DialogResult.Cancel }; f.Controls.Add(cancel); f.CancelButton=cancel;
            return f.ShowDialog(this)==DialogResult.OK ? new string[]{"7","10","11"}[c.SelectedIndex] : null;
        }
    }
}
