#Requires -Version 7.0
<#
.SYNOPSIS
    Create the deployment-server VM in vCenter from the ISO built by Build-DeployServerIso.ps1,
    let the unattended Rocky install run (it ends with power-off), detach the ISO, power on and
    wait for SSH.

.EXAMPLE
    pwsh -File ./New-DeployServerVm.ps1 -vCenterServer vc01.lab.example -vCenterUser administrator@vsphere.local `
        -Name deploy01 -Cluster Prod-Cluster -Datastore SSD-2 -Portgroup 'VM Network' -Folder LAB2.0 `
        -IsoPath ~/iso/deploy-server.iso -Ip 10.10.1.20
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)][string]$vCenterServer,
    [pscredential]$vCenterCredential,
    [string]$vCenterUser,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Cluster,
    [Parameter(Mandatory)][string]$Datastore,
    [Parameter(Mandatory)][string]$Portgroup,
    [string]$Folder,
    [Parameter(Mandatory)][ValidateScript({ Test-Path $_ -PathType Leaf })][string]$IsoPath,
    [Parameter(Mandatory)][string]$Ip,          # the static IP baked into the ISO's kickstart (used to wait for SSH)
    [int]$Cpu = 4, [int]$MemoryGB = 8, [int]$DiskGB = 100,
    [int]$InstallTimeoutSec = 2400,
    # The ISO is already in [<datastore>] iso/<file name> (copied there another way, e.g. a rate-limited
    # upload over a weak VPN): skip the upload. Its size must match -IsoPath, so a stale copy is refused.
    [switch]$UseUploadedIso,
    [switch]$KeepIso
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Log { param([string]$m, [string]$l = 'INFO') $c = switch ($l) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Gray' } }; Write-Host ("[{0}] [{1,-5}] {2}" -f (Get-Date).ToString('HH:mm:ss'), $l, $m) -ForegroundColor $c }
function Test-Tcp { param([string]$TargetHost, [int]$Port) $c = [System.Net.Sockets.TcpClient]::new(); try { $iar = $c.BeginConnect($TargetHost, $Port, $null, $null); if (-not $iar.AsyncWaitHandle.WaitOne(3000)) { return $false }; $c.EndConnect($iar); return $true } catch { return $false } finally { $c.Close() } }

$core = Get-Module -ListAvailable VMware.VimAutomation.Core | Sort-Object Version -Descending | Select-Object -First 1
if (-not $core) { throw 'PowerCLI (VMware.VimAutomation.Core) is not installed.' }
if (-not (Get-Command Connect-VIServer -ErrorAction SilentlyContinue)) { Import-Module $core | Out-Null }
Set-PowerCLIConfiguration -Scope User -InvalidCertificateAction Ignore -ParticipateInCeip $false -Confirm:$false | Out-Null
if (-not $vCenterCredential) { $vCenterCredential = if ($vCenterUser) { Get-Credential -UserName $vCenterUser -Message "vCenter $vCenterServer" } else { Get-Credential -Message "vCenter $vCenterServer" } }
$vi = Connect-VIServer -Server $vCenterServer -Credential $vCenterCredential
Log "Connected to $vCenterServer" 'OK'
try {
    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { throw "A VM named '$Name' already exists." }
    $cl = Get-Cluster -Name $Cluster; $vmhost = $cl | Get-VMHost | Where-Object ConnectionState -eq 'Connected' | Sort-Object MemoryUsageGB | Select-Object -First 1
    $ds = Get-Datastore -Name $Datastore -ErrorAction SilentlyContinue; if (-not $ds) { $ds = Get-DatastoreCluster -Name $Datastore -ErrorAction Stop }
    $loc = if ($Folder) { Get-Folder -Name $Folder -Type VM -ErrorAction Stop | Select-Object -First 1 } else { $null }
    $pg = Get-VirtualPortGroup -Name $Portgroup -ErrorAction SilentlyContinue | Select-Object -First 1; if (-not $pg) { $pg = Get-VDPortgroup -Name $Portgroup -ErrorAction Stop }

    # upload ISO
    $isoDs = if ($ds -is [VMware.VimAutomation.ViCore.Types.V1.DatastoreManagement.DatastoreCluster]) { Get-Datastore -RelatedObject $ds | Sort-Object FreeSpaceGB -Descending | Select-Object -First 1 } else { $ds }
    $leaf = Split-Path $IsoPath -Leaf
    if ($UseUploadedIso) {
        $drv = "dsiso_$([guid]::NewGuid().ToString('N').Substring(0,6))"
        New-PSDrive -Name $drv -PSProvider VimDatastore -Root '\' -Datastore $isoDs | Out-Null
        try { $have = Get-Item "${drv}:\iso\$leaf" -ErrorAction SilentlyContinue } finally { Remove-PSDrive $drv -ErrorAction SilentlyContinue }
        $want = (Get-Item -LiteralPath $IsoPath).Length
        if (-not $have) { throw "-UseUploadedIso: [$($isoDs.Name)] iso/$leaf does not exist." }
        if ($have.Length -ne $want) { throw "-UseUploadedIso: [$($isoDs.Name)] iso/$leaf is $($have.Length) bytes, the local ISO $want - upload incomplete or a different build." }
        Log "Using the ISO already on [$($isoDs.Name)] iso/$leaf ($([math]::Round($want / 1MB)) MB, size matches)." 'OK'
    }
    elseif ($PSCmdlet.ShouldProcess($isoDs.Name, "Upload $leaf")) {
        $drv = "dsiso_$([guid]::NewGuid().ToString('N').Substring(0,6))"
        New-PSDrive -Name $drv -PSProvider VimDatastore -Root '\' -Datastore $isoDs | Out-Null
        try { if (-not (Test-Path "${drv}:\iso")) { New-Item -ItemType Directory -Path "${drv}:\iso" | Out-Null }; for ($t = 1; ; $t++) { try { Copy-DatastoreItem -Item $IsoPath -Destination "${drv}:\iso\$leaf" -Force; break } catch { if ($t -ge 3) { throw }; Log "Upload failed (attempt $t/3): $($_.Exception.Message) - retrying in 30s." 'WARN'; Start-Sleep -Seconds 30 } } } finally { Remove-PSDrive $drv -ErrorAction SilentlyContinue }
        Log "Uploaded ISO to [$($isoDs.Name)] iso/$leaf" 'OK'
    }
    $isoDsPath = "[{0}] iso/{1}" -f $isoDs.Name, $leaf

    if ($PSCmdlet.ShouldProcess($Name, "New-VM $Cpu vCPU / $MemoryGB GB / $DiskGB GB, UEFI + Secure Boot, boot the installer")) {
        $p = @{ Name = $Name; VMHost = $vmhost; Datastore = $ds; NumCpu = $Cpu; MemoryGB = $MemoryGB; DiskGB = $DiskGB; DiskStorageFormat = 'Thin'; GuestId = 'rhel9_64Guest'; Portgroup = $pg; CD = $true }
        if ($loc) { $p.Location = $loc }
        $vm = New-VM @p
        $spec = New-Object VMware.Vim.VirtualMachineConfigSpec
        $spec.Firmware = [VMware.Vim.GuestOsDescriptorFirmwareType]::efi
        $spec.BootOptions = New-Object VMware.Vim.VirtualMachineBootOptions; $spec.BootOptions.EfiSecureBootEnabled = $true
        $vm.ExtensionData.ReconfigVM($spec)
        Get-CDDrive -VM $vm | Set-CDDrive -IsoPath $isoDsPath -StartConnected:$true -Confirm:$false | Out-Null
        Start-VM -VM $vm -Confirm:$false | Out-Null
        Log "VM '$Name' created on $($vmhost.Name) and powered on - unattended Rocky install running (ends with power-off)." 'OK'

        # 1) wait for the kickstart's power-off
        $deadline = (Get-Date).AddSeconds($InstallTimeoutSec)
        do { Start-Sleep 20; $vm = Get-VM -Name $Name } while ($vm.PowerState -eq 'PoweredOn' -and (Get-Date) -lt $deadline)
        if ($vm.PowerState -eq 'PoweredOn') { throw "Installer did not finish within ${InstallTimeoutSec}s - check the VM console." }
        Log "Install finished (VM powered off). Detaching ISO and booting from disk." 'OK'
        Get-CDDrive -VM $vm | Set-CDDrive -NoMedia -Confirm:$false | Out-Null
        if (-not $KeepIso) { $drv = "dsiso_$([guid]::NewGuid().ToString('N').Substring(0,6))"; New-PSDrive -Name $drv -PSProvider VimDatastore -Root '\' -Datastore $isoDs | Out-Null; try { Remove-Item "${drv}:\iso\$leaf" -Force -ErrorAction SilentlyContinue } finally { Remove-PSDrive $drv -ErrorAction SilentlyContinue } }
        Start-VM -VM $vm -Confirm:$false | Out-Null

        # 2) wait for SSH on the kickstart IP
        $deadline = (Get-Date).AddSeconds(900); $up = $false
        while ((Get-Date) -lt $deadline) { if (Test-Tcp -TargetHost $Ip -Port 22) { $up = $true; break }; Start-Sleep 10 }
        if (-not $up) { throw "SSH on $Ip did not come up within 15 min - check the VM console." }
        Log "Deployment server is up. Connect:  ssh -L 8080:127.0.0.1:8080 deploy@$Ip   then open http://127.0.0.1:8080" 'OK'
        Log "On the server: sudo systemctl status deployment-server ; ISOs go to /opt/autodeploy/server-data/iso" 'INFO'
    }
}
finally { Disconnect-VIServer -Server $vi -Confirm:$false -ErrorAction SilentlyContinue }
