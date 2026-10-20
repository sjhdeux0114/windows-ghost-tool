using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Forms;

class VmHistoryEntry {
    public string Name { get; set; }
    public string Created { get; set; }
    public string Status { get; set; }
    public string Path { get; set; }
}
class VmHistoryForm : Form {
    readonly DataGridView grid=new DataGridView();
    readonly Button refresh=new Button(),delete=new Button();
    readonly Button openVm=new Button(),openDisk=new Button(),detach=new Button();
    readonly Label status=new Label();
    bool busy;
    readonly string root=AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
    public VmHistoryForm() {
        Text="가상 윈도우 내역"; ClientSize=new Size(1050,520); MinimumSize=new Size(850,450);
        Font=new Font("Malgun Gothic",10); StartPosition=FormStartPosition.CenterParent;
        Controls.Add(new Label {Text="생성했던 가상 Windows 목록입니다. 삭제하면 VM 등록, 가상 디스크와 해당 작업 폴더의 내역이 삭제됩니다.\n완성된 GHO 파일은 보존됩니다. 실행 중이거나 디스크가 연결된 VM은 먼저 정상 종료·연결 해제하세요.",Left=20,Top=15,Width=1010,Height=60,Anchor=AnchorStyles.Top|AnchorStyles.Left|AnchorStyles.Right});
        grid.SetBounds(20,85,1010,340); grid.Anchor=AnchorStyles.Top|AnchorStyles.Bottom|AnchorStyles.Left|AnchorStyles.Right;
        grid.ReadOnly=true; grid.AllowUserToAddRows=false; grid.AllowUserToDeleteRows=false; grid.MultiSelect=false; grid.SelectionMode=DataGridViewSelectionMode.FullRowSelect; grid.AutoGenerateColumns=false; grid.RowHeadersVisible=false;
        AddColumn("이름","Name",220); AddColumn("생성 시각","Created",170); AddColumn("상태","Status",200);
        grid.Columns.Add(new DataGridViewTextBoxColumn {HeaderText="작업 폴더",DataPropertyName="Path",AutoSizeMode=DataGridViewAutoSizeColumnMode.Fill,MinimumWidth=230});
        Controls.Add(grid);
        status.SetBounds(20,427,1010,23); status.Anchor=AnchorStyles.Bottom|AnchorStyles.Left|AnchorStyles.Right; Controls.Add(status);
        openVm.Text="VM 화면 열기"; openVm.SetBounds(20,450,150,40); openVm.Anchor=AnchorStyles.Bottom|AnchorStyles.Left; openVm.Click+=delegate { EntryAction("OpenVm"); }; Controls.Add(openVm);
        openDisk.Text="디스크 위치 열기"; openDisk.SetBounds(180,450,160,40); openDisk.Anchor=AnchorStyles.Bottom|AnchorStyles.Left; openDisk.Click+=delegate { OpenDiskFolder(); }; Controls.Add(openDisk);
        detach.Text="디스크 연결 해제"; detach.SetBounds(350,450,170,40); detach.Anchor=AnchorStyles.Bottom|AnchorStyles.Left; detach.Click+=delegate { EntryAction("Detach"); }; Controls.Add(detach);
        refresh.Text="새로 고침"; refresh.SetBounds(750,450,130,40); refresh.Anchor=AnchorStyles.Bottom|AnchorStyles.Right; refresh.Click+=delegate { LoadEntries(); }; Controls.Add(refresh);
        delete.Text="삭제하기"; delete.SetBounds(895,450,135,40); delete.Anchor=AnchorStyles.Bottom|AnchorStyles.Right; delete.Click+=delegate { DeleteEntry(); }; Controls.Add(delete);
        Shown+=delegate { LoadEntries(); };
        FormClosing+=delegate(object sender,FormClosingEventArgs e){if(busy)e.Cancel=true;};
    }
    void AddColumn(string title,string property,int width) { grid.Columns.Add(new DataGridViewTextBoxColumn {HeaderText=title,DataPropertyName=property,Width=width}); }
    void RunAction(string action,string path,Action<string> completed) {
        if(busy)return;
        busy=true; refresh.Enabled=delete.Enabled=grid.Enabled=openVm.Enabled=openDisk.Enabled=detach.Enabled=false; UseWaitCursor=true;
        status.Text=action=="List"?"생성 내역을 확인하고 있습니다...":action=="OpenVm"?"VM 화면을 열고 있습니다...":action=="Detach"?"가상 디스크 연결을 해제하고 있습니다...":"VM과 디스크 파일, 내역을 삭제하고 있습니다...";
        var worker=new BackgroundWorker();
        worker.DoWork+=delegate(object sender,DoWorkEventArgs e){
            string script=System.IO.Path.Combine(root,"VmHistory.ps1");
            if(!File.Exists(script))throw new Exception("VmHistory.ps1 파일이 없습니다.");
            string args="-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \""+script+"\" -Action "+action+" -Root \""+root+"\"";
            if(path!=null)args+=" -EntryBase64 "+Convert.ToBase64String(Encoding.UTF8.GetBytes(path));
            string ps=System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),@"WindowsPowerShell\v1.0\powershell.exe");
            using(var process=new Process {StartInfo=new ProcessStartInfo(ps,args){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true,StandardOutputEncoding=Encoding.UTF8,StandardErrorEncoding=Encoding.UTF8}}) {
                var errors=new StringBuilder();
                process.ErrorDataReceived+=delegate(object s,DataReceivedEventArgs ev){if(ev.Data!=null)errors.AppendLine(ev.Data);};
                process.Start(); process.BeginErrorReadLine(); string output=process.StandardOutput.ReadToEnd(); process.WaitForExit();
                if(process.ExitCode!=0)throw new Exception(errors.Length>0?errors.ToString():"내역 작업에 실패했습니다.");
                e.Result=output;
            }
        };
        worker.RunWorkerCompleted+=delegate(object sender,RunWorkerCompletedEventArgs e){
            busy=false; refresh.Enabled=delete.Enabled=grid.Enabled=openVm.Enabled=openDisk.Enabled=detach.Enabled=true; UseWaitCursor=false; worker.Dispose();
            if(e.Error!=null){status.Text="작업을 완료하지 못했습니다."; MessageBox.Show(this,e.Error.Message,"가상 윈도우 내역",MessageBoxButtons.OK,MessageBoxIcon.Warning);return;}
            try{completed((string)e.Result);}catch(Exception ex){status.Text="내역 표시 오류";MessageBox.Show(this,ex.Message);}
        };
        worker.RunWorkerAsync();
    }
    void LoadEntries() {
        RunAction("List",null,delegate(string output){
            var rows=new JavaScriptSerializer().Deserialize<VmHistoryEntry[]>(output.Trim());
            grid.DataSource=rows; status.Text="생성 내역 "+rows.Length+"개";
        });
    }
    void DeleteEntry() {
        if(busy||grid.CurrentRow==null)return;
        var entry=grid.CurrentRow.DataBoundItem as VmHistoryEntry; if(entry==null)return;
        if(MessageBox.Show(this,"가상 Windows를 삭제할까요?\n\n이름: "+entry.Name+"\n폴더: "+entry.Path+"\n\nVM 등록과 이 폴더 안의 가상 디스크·내역을 모두 삭제합니다. 되돌릴 수 없습니다.\n완성된 GHO 파일은 보존됩니다.","가상 Windows 삭제",MessageBoxButtons.YesNo,MessageBoxIcon.Warning,MessageBoxDefaultButton.Button2)!=DialogResult.Yes)return;
        RunAction("Delete",entry.Path,delegate(string output){MessageBox.Show(this,output.Trim(),"삭제 완료");LoadEntries();});
    }
    VmHistoryEntry SelectedEntry() { return busy||grid.CurrentRow==null?null:grid.CurrentRow.DataBoundItem as VmHistoryEntry; }
    void OpenDiskFolder() {
        var entry=SelectedEntry(); if(entry==null)return;
        try {
            string disk=System.IO.Path.Combine(entry.Path,"Windows.vhdx");
            if(File.Exists(disk))Process.Start(new ProcessStartInfo("explorer.exe","/select,\""+disk+"\""){UseShellExecute=true});
            else Process.Start(new ProcessStartInfo(entry.Path){UseShellExecute=true});
        }catch(Exception ex){MessageBox.Show(this,ex.Message);}
    }
    void EntryAction(string action) {
        var entry=SelectedEntry(); if(entry==null)return;
        if(action=="Detach"&&MessageBox.Show(this,"선택한 VM의 디스크를 호스트에서 연결 해제할까요?\nVM이 종료되어 있고 이 앱의 작업 디스크인지 확인한 뒤 해제합니다.\n파일과 내역은 삭제하지 않습니다.","디스크 연결 해제",MessageBoxButtons.YesNo,MessageBoxIcon.Question,MessageBoxDefaultButton.Button2)!=DialogResult.Yes)return;
        RunAction(action,entry.Path,delegate(string output){status.Text=output.Trim();if(action=="Detach")MessageBox.Show(this,output.Trim(),"연결 해제");});
    }
}
