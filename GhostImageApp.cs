using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Management;
using System.Windows.Forms;

class DiskInfo {
    public uint Index; public string Model,Serial,UniqueId,PnpId; public ulong Size;
    public bool Protected,ReadOnly; public List<string> Letters=new List<string>();
    public bool Same(DiskInfo d) { return d!=null && Index==d.Index && Size==d.Size && Model==d.Model && Serial==d.Serial && UniqueId==d.UniqueId && PnpId==d.PnpId; }
    public override string ToString() { return string.Format("디스크 {0} | {1} | {2:N1} GB | {3} | S/N {4}{5}",Index,Model,Size/1000000000.0,string.Join(" ",Letters.ToArray()),Serial,Protected?" [보호됨]":ReadOnly?" [읽기 전용]":""); }
}
static class DiskCatalog {
    public static List<DiskInfo> Read() {
        var list=new List<DiskInfo>(); var protectedDisks=new Dictionary<uint,bool>(); var readOnly=new Dictionary<uint,bool>(); var ids=new Dictionary<uint,string>();
        using(var q=new ManagementObjectSearcher(@"root\Microsoft\Windows\Storage","SELECT Number,IsBoot,IsSystem,IsReadOnly,UniqueId,BusType FROM MSFT_Disk"))
        foreach(ManagementObject m in q.Get()) { using(m) {
            uint n=Convert.ToUInt32(m["Number"]); uint bus=Convert.ToUInt32(m["BusType"]);
            protectedDisks[n]=Convert.ToBoolean(m["IsBoot"])||Convert.ToBoolean(m["IsSystem"])||bus==14||bus==15||bus==16;
            readOnly[n]=Convert.ToBoolean(m["IsReadOnly"]); ids[n]=Convert.ToString(m["UniqueId"]);
        } }
        var pageLetters=new List<string>();
        using(var q=new ManagementObjectSearcher("SELECT Name FROM Win32_PageFileUsage"))
        foreach(ManagementObject p in q.Get()) { using(p) { string s=Convert.ToString(p["Name"]); if(s.Length>=2) pageLetters.Add(s.Substring(0,2)); } }
        using(var q=new ManagementObjectSearcher("SELECT * FROM Win32_DiskDrive"))
        foreach(ManagementObject m in q.Get()) { using(m) {
            var d=new DiskInfo { Index=Convert.ToUInt32(m["Index"]),Model=Convert.ToString(m["Model"]),Serial=Convert.ToString(m["SerialNumber"]).Trim(),PnpId=Convert.ToString(m["PNPDeviceID"]),Size=Convert.ToUInt64(m["Size"]) };
            d.Protected=!protectedDisks.ContainsKey(d.Index)||protectedDisks[d.Index];
            d.ReadOnly=!readOnly.ContainsKey(d.Index)||readOnly[d.Index]; d.UniqueId=ids.ContainsKey(d.Index)?ids[d.Index]:"";
            foreach(ManagementObject part in m.GetRelated("Win32_DiskPartition")) { using(part) {
                foreach(ManagementObject volume in part.GetRelated("Win32_LogicalDisk")) { using(volume) {
                    string letter=Convert.ToString(volume["DeviceID"]); d.Letters.Add(letter);
                    if(string.Equals(letter,Environment.GetEnvironmentVariable("SystemDrive"),StringComparison.OrdinalIgnoreCase)||pageLetters.Exists(delegate(string s){return string.Equals(s,letter,StringComparison.OrdinalIgnoreCase);})) d.Protected=true;
                } }
            } }
            list.Add(d);
        } }
        list.Sort(delegate(DiskInfo a,DiskInfo b){return a.Index.CompareTo(b.Index);}); return list;
    }
    public static DiskInfo ForPath(List<DiskInfo> disks,string path) {
        path=Path.GetFullPath(path);
        if(path.StartsWith(@"\\")) throw new Exception("네트워크 경로는 복원 원본으로 사용할 수 없습니다.");
        // Reject directory junctions / volume mount points rather than guessing their physical disk.
        string p=File.Exists(path)?Path.GetDirectoryName(path):path;
        while(!string.IsNullOrEmpty(p)) {
            if(Directory.Exists(p)&&(File.GetAttributes(p)&FileAttributes.ReparsePoint)!=0) throw new Exception("연결 폴더/볼륨 탑재 경로는 지원하지 않습니다. 일반 드라이브 문자의 경로를 사용하세요.");
            p=Path.GetDirectoryName(p.TrimEnd(Path.DirectorySeparatorChar));
        }
        if(File.Exists(path)&&(File.GetAttributes(path)&FileAttributes.ReparsePoint)!=0) throw new Exception("연결 파일은 원본으로 사용할 수 없습니다.");
        string letter=Path.GetPathRoot(path).TrimEnd('\\');
        var matches=disks.FindAll(delegate(DiskInfo d){return d.Letters.Exists(delegate(string s){return string.Equals(s,letter,StringComparison.OrdinalIgnoreCase);});});
        if(matches.Count!=1) throw new Exception("파일이 저장된 물리 디스크를 확인할 수 없습니다.");
        return matches[0];
    }
}
static class RestorePolicy {
    public static DiskInfo Validate(List<DiskInfo> disks,DiskInfo selected,DiskInfo sourceDisk,DiskInfo appDisk) {
        if(selected==null) throw new Exception("대상을 선택하세요.");
        DiskInfo current=disks.Find(delegate(DiskInfo d){return d.Index==selected.Index;});
        if(!selected.Same(current)||current.Protected||current.ReadOnly||current.Size==0) throw new Exception("대상 디스크가 변경되었거나 보호된 디스크입니다. 다시 선택하세요.");
        if(sourceDisk==null||appDisk==null) throw new Exception("원본 또는 앱의 물리 디스크를 식별할 수 없습니다.");
        if(sourceDisk.Index==current.Index) throw new Exception("GHO가 저장된 HDD에는 복원할 수 없습니다. GHO를 다른 디스크에 두세요.");
        if(appDisk.Index==current.Index) throw new Exception("앱이 실행되는 디스크에는 복원할 수 없습니다.");
        if(disks.Count>=50) throw new Exception("디스크가 너무 많아 Ghost 번호를 안전하게 연결할 수 없습니다.");
        for(int i=0;i<disks.Count;i++) if(disks[i].Index!=(uint)i) throw new Exception("디스크 번호가 연속적이지 않습니다. 디스크 구성을 정리한 뒤 앱을 다시 실행하세요.");
        return current;
    }
}
class MainForm : Form {
    public MainForm() {
        Text="Windows Ghost 설치 도구"; ClientSize=new Size(660,375); FormBorderStyle=FormBorderStyle.FixedSingle; MaximizeBox=false;
        Font=new Font("Malgun Gothic",11); StartPosition=FormStartPosition.CenterScreen;
        Controls.Add(new Label { Text="Windows 이미지 만들기 / HDD에 설치하기",Left=25,Top=25,Width=610,Height=40,Font=new Font(Font.FontFamily,18,FontStyle.Bold) });
        Button iso=new Button { Text="ISO → GHO 파일 만들기",Left=25,Top=95,Width=610,Height=65 };
        Button restore=new Button { Text="GHO → HDD에 설치하기",Left=25,Top=180,Width=610,Height=65 };
        Button history=new Button { Text="가상 윈도우 내역",Left=25,Top=265,Width=610,Height=65 };
        iso.Click+=delegate { using(var f=new AutoBuildForm()) f.ShowDialog(this); };
        restore.Click+=delegate { using(var f=new RestoreForm()) f.ShowDialog(this); };
        history.Click+=delegate { using(var f=new VmHistoryForm()) f.ShowDialog(this); };
        Controls.Add(iso); Controls.Add(restore); Controls.Add(history);
    }
    [STAThread] static void Main() {
        Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
        using(var mutex=new System.Threading.Mutex(false,@"Local\GhostImageAppMain")) {
            bool acquired=false;
            try { acquired=mutex.WaitOne(0); if(!acquired) { MessageBox.Show("앱이 이미 실행 중입니다."); return; } Application.Run(new MainForm()); }
            finally { if(acquired) mutex.ReleaseMutex(); }
        }
    }
}
