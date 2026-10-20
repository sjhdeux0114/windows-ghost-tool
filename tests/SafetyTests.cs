using System;
using System.Collections.Generic;
class SafetyTests {
    static int passed;
    static DiskInfo Disk(uint n) { return new DiskInfo { Index=n,Model="Test",Serial="S"+n,UniqueId="U"+n,PnpId="P"+n,Size=100000000000 }; }
    static void Block(Action action,string name) { try { action(); } catch { passed++; return; } throw new Exception("Unsafe case accepted: "+name); }
    static void Main() {
        var host=Disk(0); host.Protected=true; var target=Disk(1); var data=Disk(2);
        var disks=new List<DiskInfo> {host,target,data};
        if(RestorePolicy.Validate(disks,target,data,host)!=target) throw new Exception("Valid target rejected"); passed++;
        Block(delegate { RestorePolicy.Validate(disks,host,data,data); },"system disk");
        Block(delegate { RestorePolicy.Validate(disks,target,target,host); },"GHO source disk");
        Block(delegate { RestorePolicy.Validate(disks,target,data,target); },"application disk");
        var replaced=Disk(1); replaced.Serial="other";
        Block(delegate { RestorePolicy.Validate(disks,replaced,data,host); },"hotplug replacement");
        target.ReadOnly=true; Block(delegate { RestorePolicy.Validate(disks,target,data,host); },"read-only disk"); target.ReadOnly=false;
        Block(delegate { RestorePolicy.Validate(new List<DiskInfo>{host,data},target,data,host); },"missing target");
        Block(delegate { RestorePolicy.Validate(new List<DiskInfo>{target,data},target,data,host); },"noncontiguous enumeration");
        Block(delegate { RestorePolicy.Validate(disks,target,null,host); },"unknown source device");
        Console.WriteLine("PASS: "+passed+" restore policy cases. No real disks accessed.");
    }
}
