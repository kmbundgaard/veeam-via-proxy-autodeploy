# Start here — Veeam 13.1 proxy mass deployment

This toolkit deploys Veeam Infrastructure Appliance (VIA) 13.1 backup proxies on VMware vSphere
from a CSV and registers them to their Veeam Backup & Replication (VBR) server. Everything it
does uses Veeam's documented mechanisms: the unattended appliance ISO with an answer file,
PowerCLI for vSphere, and the VBR REST API for registration. It runs fully offline.
The same run also deploys the Veeam Software Appliance itself, as a Backup & Replication server or
an Enterprise Manager (CSV role `vbr` / `em`).

One appliance (proxy VM) belongs to exactly one VBR; that is a Veeam property of the appliance,
not of this toolkit. One deployment server and one fleet CSV serve all your VBRs: the `vbr`
column says which VBR owns each row, you keep one settings file per VBR, and each run works
against one VBR (its rows, its credentials, its settings file). Run the VBRs one after the other
from the same server.

## What you need

| Item | Official source | Notes |
|------|-----------------|-------|
| `VeeamInfrastructureAppliance_13.1.x.iso` | [veeam.com/downloads](https://www.veeam.com/downloads.html), signed in with your Veeam account | Verify the SHA-256 against [KB4738](https://www.veeam.com/kb4738) before use. |
| Rocky Linux 9 minimal ISO (Option A only) | [rockylinux.org/download](https://rockylinux.org/download) or [dl.rockylinux.org](https://dl.rockylinux.org/pub/rocky/9/isos/x86_64/) | Verify against the CHECKSUM file in the same folder. |
| PowerShell 7 | [github.com/PowerShell/PowerShell/releases](https://github.com/PowerShell/PowerShell/releases): `powershell-7.x-1.rh.x86_64.rpm` for Option A, or the [install guide](https://learn.microsoft.com/powershell/scripting/install/install-rhel) for an existing host | Windows PowerShell 5.1 is not supported. |
| xorriso, libisoburn, libisofs, libburn (Option A) | Rocky 9 AppStream: [Packages/x](https://dl.rockylinux.org/pub/rocky/9/AppStream/x86_64/os/Packages/x/) and [Packages/l](https://dl.rockylinux.org/pub/rocky/9/AppStream/x86_64/os/Packages/l/) | On an existing host: `dnf install xorriso`. |
| libicu (Option A) | Rocky 9 BaseOS: [Packages/l](https://dl.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/Packages/l/) | Needed by PowerShell. |
| rsync (Option A) | Rocky 9 BaseOS: [Packages/r](https://dl.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/Packages/r/) | Resumable copies of large ISOs to the server (`rsync --partial`). Take the build for the **same Rocky minor as the ISO** (9.8: `rsync-3.2.5-7.el9_8.2`); `3.2.7` needs a newer libacl than the 9.8 ISO installs. |
| `VeeamSoftwareAppliance_13.1.x.iso` (optional) | [veeam.com/downloads](https://www.veeam.com/downloads.html) | Only to deploy backup servers or Enterprise Manager (CSV role `vbr` / `em`). 15 GB: copy it to the server with `rsync --partial` rather than baking it into the server ISO over a slow link. |
| PowerCLI | [PowerShell Gallery, VCF.PowerCLI](https://www.powershellgallery.com/packages/VCF.PowerCLI): `Save-Module VCF.PowerCLI -Path ./PowerCLI` on a connected machine | Product page: [developer.broadcom.com/powercli](https://developer.broadcom.com/powercli). Includes the distributed-switch module. |
| vCenter account | Your vCenter | Create VMs, upload ISOs, edit VM settings. |
| VBR account | Your VBR | Add managed servers and proxies via REST; an MFA seed can be supplied. |

**One download for a site without internet.** On any machine with internet, `Get-DeployServerMedia.ps1`
downloads the Rocky 9.8 minimal ISO, the seven RPMs, PowerCLI and the PowerShell 7 MSI, verifies each against
its publisher's checksum, and lays them out in one folder to carry to the site (`NEXT-STEPS.txt` inside has the
build commands). Only the Veeam ISOs still come from veeam.com. Works in Windows PowerShell 5.1:

```powershell
powershell -ExecutionPolicy Bypass -File .\Get-DeployServerMedia.ps1 -Destination D:\autodeploy-media
```

Install the server from the Rocky ISO in that folder: the RPMs match its minor version only.

**Downloads and licensing.** The links point to the vendors' official pages; nothing is mirrored
in this toolkit. Rocky Linux, PowerShell, xorriso and its libraries are open source and may sit
inside the server ISO. PowerCLI is Broadcom software and the appliance ISO is Veeam software:
download both under your own account and entitlement and pass them to the ISO build
(`-PowerCliModulesDir`, `-IncludeIso`). If your Veeam contact builds the server ISO for you, hand
them your downloads of these two so the image contains your own copies.

## Option A: build the deployment server (recommended)

`Build-DeployServerIso.ps1` turns the official Rocky Linux 9 minimal ISO into a self-installing
image that carries this toolkit, PowerShell, xorriso, PowerCLI and your appliance ISO. The build
machine needs PowerShell 7, PowerCLI (for the VM step) and xorriso: on Linux or macOS install
xorriso natively; on Windows it runs inside WSL (`wsl --install -d Ubuntu`, then
`sudo apt install xorriso` in the distro, pass `-WslDistro Ubuntu` if it is not your default). If you
may not install xorriso or turn on WSL, see "Build machine without xorriso or WSL" below. All
seven RPMs from the table go into one folder, given as `-RpmDir`.
`New-DeployServerVm.ps1` creates the VM, lets it install, detaches the ISO and boots it. Put the
seven RPMs from the table (PowerShell, xorriso, libisoburn, libisofs, libburn, libicu, rsync) in one folder
and pass it as `-RpmDir`; the server installs them offline.

```bash
pwsh -File ./Build-DeployServerIso.ps1 -RockyIso Rocky-9-minimal.iso -OutIso deploy-server.iso \
     -Hostname deploy01.corp.local -Ip 10.10.1.20 -Gateway 10.10.1.1 -Dns 10.10.1.5 \
     -SshPublicKeyFile "~/.ssh/id_ed25519.pub,./keys/anna.pub" -RpmDir ./rpms -IncludeIso ./VeeamInfrastructureAppliance_13.1.1.18_20260825.iso
pwsh -File ./New-DeployServerVm.ps1 -vCenterServer vc01.corp.local -vCenterUser svc-deploy@vsphere.local \
     -Name deploy01 -Cluster CL-Mgmt -Datastore DS-Mgmt -Portgroup 'VM Network' -IsoPath ./deploy-server.iso -Ip 10.10.1.20
```

The `\` at the line ends is the Linux/macOS shell continuation. **In PowerShell on Windows the
continuation character is the backtick `` ` ``**; a `\` there ends the command, the next lines are
lost and the script asks for `-Ip` and the other values. Same build in PowerShell:

```powershell
pwsh -File .\Build-DeployServerIso.ps1 -RockyIso .\iso\Rocky-9-minimal.iso -OutIso .\deploy-server.iso `
     -Hostname deploy01.corp.local -Ip 10.10.1.20 -Gateway 10.10.1.1 -Dns 10.10.1.5 `
     -SshPublicKeyFile "$HOME\.ssh\id_ed25519.pub,.\keys\anna.pub" -RpmDir .\rpms `
     -IncludeIso .\iso\VeeamInfrastructureAppliance_13.1.1.18_20260825.iso -WslDistro Ubuntu
```

Nothing may follow the backtick on its line, not even a space. Or put the whole command on one line.

Give `-SshPublicKeyFile` every public key that should be allowed to log in, as one quoted value
with commas and no spaces: each becomes an authorized key of the `deploy` account, and nothing has
to be added by hand later. The toolkit does not create these keys; each admin makes their own and
hands over only the public half:

```powershell
# on each admin's own machine (Windows PowerShell, Linux or macOS - OpenSSH is built in)
ssh-keygen -t ed25519 -C "firstname@company"     # creates ~/.ssh/id_ed25519 and id_ed25519.pub
```

The admin sends you `id_ed25519.pub` (one line starting `ssh-ed25519 AAAA...`); the private file
`id_ed25519` never leaves their machine. Collect the `.pub` files in a folder next to the build,
for example `./keys/anna.pub` and `./keys/bo.pub`, and list them in `-SshPublicKeyFile`. With
PuTTYgen, choose EdDSA (Ed25519) and save the text from the box "Public key for pasting into OpenSSH
authorized_keys file"; the "Save public key" button writes a format the build rejects.
A rebuilt server has a new SSH host key, so remove the old entry on your workstation first
(`ssh-keygen -R <server-ip>`).

About twelve minutes later the server is up. Reach the web page through an SSH tunnel; the page
is bound to the server's localhost on purpose and has no login of its own:

```bash
ssh -L 8080:127.0.0.1:8080 deploy@10.10.1.20        # then open http://127.0.0.1:8080
```

**Optional: open the page over the LAN with HTTPS and a client certificate.** If your admins should open the
page from their workstations without an SSH tunnel, put nginx in front of it. It's a script in the toolkit:
`deploy-server/enable-https-client-cert.sh`.
- The page is then served at `https://<server-fqdn>/` on port 443 of the server's LAN address.
- Only a browser that presents a **client certificate issued by your CA** gets through. Without one, the
  server answers HTTP 400.
- The page itself still listens only on the server's localhost. The tunnel keeps working.

What you need:
- **A CA.** A small private one is enough; you'll find the commands in the README.
- **A server certificate for the server's FQDN.** The server creates its own private key, and the key never
  leaves it.
- **One client certificate (`.p12`) per admin.** Import the CA certificate and the `.p12` into each admin's
  browser.

Always open the page by its FQDN (the name in the certificate), not by its IP address. The full steps are in
`Deploy-VeeamProxies.README.md`, section 1c, "HTTPS on the LAN with client certificates".
- **Don't make port 443 reachable from the internet.** The page can create and delete VMs.
- **A server rebuilt from the ISO doesn't keep this setup.** Run the script again with the same certificates.

### Build machine on Windows: installing xorriso

xorriso is a Linux tool. On Windows the toolkit runs it inside WSL (Windows Subsystem for Linux)
and translates the paths itself. In an elevated PowerShell:

```powershell
wsl --status                              # is WSL present
wsl --set-default-version 1               # recommended on a VM, see the note below
wsl --install -d Ubuntu                   # reboot if asked, then create the Linux user it prompts for
wsl -d Ubuntu -- sudo apt update
wsl -d Ubuntu -- sudo apt install -y xorriso
wsl -d Ubuntu -- xorriso -version         # must print "GNU xorriso 1.5.x"
```

Then add `-WslDistro Ubuntu` to `Build-DeployServerIso.ps1` (and to `Deploy-VeeamProxies.ps1` when
you run deployments from Windows).

- **Windows running as a VM:** WSL 2 needs nested virtualisation exposed to the VM and otherwise
  fails with `HCS_E_HYPERV_NOT_INSTALLED`. WSL 1 has no such requirement and is fully sufficient,
  because xorriso only reads and writes files. That is why the commands above set version 1 first.
- **No internet on the build machine:** import a distro with `wsl --import`, and install xorriso
  from the `.deb` packages `xorriso`, `libisoburn1`, `libisofs6` and `libburn4`, fetched on a
  connected machine with `apt download`. Alternatively build the ISO on any Linux host with
  xorriso; the ISO is portable.
- **WSL not allowed:** use `-NoXorriso` (next section), which needs nothing beyond Windows itself. A
  native Windows xorriso (Cygwin or MSYS2 package) also works through
  `-XorrisoCommand C:\path\to\xorriso.exe`; it is a third-party build and the least tested route.
- **PowerCLI** is the other half of the build machine: `New-DeployServerVm.ps1` needs it.
  `Install-Module VCF.PowerCLI -Scope CurrentUser` once, or copy the `Save-Module` folder into
  `Documents\PowerShell\Modules` on a dark site.

### Build machine without xorriso or WSL

With `-NoXorriso` the Rocky ISO is not modified at all. The build writes a second, small ISO with
the volume label `OEMDRV` that holds only the kickstart and the payload. The Rocky installer finds a
`ks.cfg` on a volume with that label by itself. Windows writes this ISO with IMAPI2, which is part of
Windows, so nothing has to be installed and WSL stays off. macOS uses `hdiutil`. Linux uses
`genisoimage`, `mkisofs` or `xorriso`, whichever is present.

```powershell
pwsh -File .\Build-DeployServerIso.ps1 -NoXorriso -OutIso .\deploy-server-seed.iso `
     -Hostname deploy01.corp.local -Ip 10.10.1.20 -Gateway 10.10.1.1 -Dns 10.10.1.5 `
     -SshPublicKeyFile "$HOME\.ssh\id_ed25519.pub,.\keys\anna.pub" -RpmDir .\rpms `
     -IncludeIso .\iso\VeeamInfrastructureAppliance_13.1.1.18_20260825.iso
pwsh -File .\New-DeployServerVm.ps1 -vCenterServer vc01.corp.local -vCenterUser svc-deploy@vsphere.local `
     -Name deploy01 -Cluster CL-Mgmt -Datastore DS-Mgmt -Portgroup 'VM Network' `
     -IsoPath .\iso\Rocky-9-minimal.iso -SeedIsoPath .\deploy-server-seed.iso -Ip 10.10.1.20
```

- `New-DeployServerVm.ps1 -SeedIsoPath` uploads both ISOs and puts the seed ISO in a second CD drive.
  After the install it detaches both, removes the second drive and deletes both ISOs from the
  datastore (keep them with `-KeepIso`).
- The Rocky boot menu is untouched, so the VM waits 60 seconds on it and then runs the media check
  before the install starts. That adds a few minutes to the build.
- Files of 2 GB or more, such as the appliance ISOs, are split into 1 GB parts on the seed ISO,
  because the Windows ISO writer can't hold larger files. The server joins the parts again during the install.
- No PowerCLI on the build machine either? Create the VM by hand in the vSphere Client: Rocky 9
  guest, EFI with Secure Boot, the Rocky ISO in the first CD drive and the seed ISO in a second one.
  When the VM powers off at the end of the install, disconnect both ISOs and power it on again.
  `Build-DeployServerIso.ps1 -NoXorriso` still needs PowerCLI installed, or a `Save-Module` folder
  given as `-PowerCliModulesDir`, because the modules go into the payload.

## Option B: run on an existing host

Copy this folder to a Linux host (or a Windows host with WSL for xorriso) that has PowerShell 7,
PowerCLI and xorriso. Use `Fleet-Planner.html` as a plain file to build the CSV and the command
lines, then run `Deploy-VeeamProxies.ps1`. Section 1 of the usage guide lists the details.

## The seven steps

1. **Settings file.** Copy `appliance-secrets.example.conf`, replace every example value: the
   `veeamadmin` password, the TOTP seed (`Protect-DeploymentSecrets.ps1 -NewTotpSeed`) and your
   NTP servers. If you turn the Security Officer on (`VEEAMSO_ENABLED = true`), it also needs its own
   password, its own seed (`-NewTotpSeed` again) and a recovery token
   (`Protect-DeploymentSecrets.ps1 -NewRecoveryToken`, which prints a GUID). Keep the token in your
   password vault: it is the Security Officer's break-glass token. The toolkit refuses the example values because they make the appliance's first boot
   fail. Upload it through the web page (stored encrypted) or encrypt it with
   `Protect-DeploymentSecrets.ps1 -Encrypt` for command-line runs. One file per VBR.
2. **Plan the fleet** in `Fleet-Planner.html`: your own host name pattern (`{namespace}-{nn}` by
   default), IP ranges, cluster, datastore, folder, port group, task slots. With the server, "Load
   vSphere inventory" fills the placement fields from vCenter. Export the CSV.
   When the VM name in vCenter follows a different standard than the host name, set a **VM name
   pattern** as well, e.g. `{datacenter}_km_{hostname}` next to the hostname pattern
   `{location}-{cluster}{nn}` gives VM `ros_km_vpr-nodspa0101` with host name `vpr-nodspa0101`.
   A **search domain** keeps the host name short and makes the VBR register `hostname.domain`. The
   optional **VM/Host group** (e.g. `vmgr-{cluster}`) puts the VMs into an existing DRS VM group, and
   the **vSphere tags** under Run commands (`Category = Tag` per line) go on every VM of the run.
3. **DNS.** Create the A and PTR records with `New-ProxyDnsRecords.ps1` (Microsoft AD DNS), or set
   the `vbrname` column to each proxy's IP so VBR adds it by address.
4. **Test connections** in the web page, or run the script with `-ValidateOnly -BaseIso` from the
   command line. Nothing is created yet.
5. **Deploy one node first.** A full run takes about 25 minutes per node: unattended install, first
   boot with the answer file applied, registration by certificate trust, proxy role assigned.
6. **Deploy the rest**, one VBR at a time. The run report CSV records deploy, register and validate
   results per row; reruns skip what already exists.
7. **Check in VBR** that the proxies show as Available with the expected transport mode and task
   count.

## Good to know

- **Many appliances at once.** A run deploys its rows one after the other by default. Set
  *Appliances at a time* under Run commands (or pass `-Parallel 4`) to deploy several at the same time:
  each row runs as its own worker, starts are 45 s apart, and you get one merged report. Not for Replace
  runs or `gatewayrepo` rows. See section 4f of `Deploy-VeeamProxies.README.md`.
- **Backup servers and Enterprise Manager too.** A CSV row with `role` = `vbr` or `em` deploys a Veeam
  Software Appliance (Backup & Replication server or Enterprise Manager) from the
  `VeeamSoftwareAppliance_13.1.x.iso`: same settings file, same Stage A, two 240 GB disks, no
  registration step. Keep those rows under their own `vbr` key. See section 4e of
  `Deploy-VeeamProxies.README.md`.

- No clear-text secrets stay on the deploy host. Settings and passwords are stored encrypted with
  a separate key; per-run copies are deleted when the run ends. The answer file exists in
  clear text only inside each node's ISO, which is deleted after the deploy.
- **Replacing a proxy** instead of troubleshooting it: tick "Replace existing proxies" (or pass
  `-Replace`) and run the same CSV row again. The toolkit records which jobs pin that proxy,
  removes it from VBR, shuts down the old VM (found by its IP, so also when it had another name) and
  renames it `<name>_ToBeDeleted`, deploys and registers a fresh appliance on the same address, and
  pins it back into the same jobs. Jobs that were pinned only
  to that proxy run on automatic proxy selection during the 25 minutes, or are disabled if you choose
  that option. Repository proxy affinity is the one setting you re-check by hand afterwards.
- **Gateway servers** for Dell Data Domain or HPE StoreOnce: set the row's role to `gateway` (or
  `viproxy+gateway` for both on one appliance) and, optionally, `gatewayrepo` to the repository names.
  The appliance is then added to those repositories' gateway lists. ExaGrid, Quantum DXi, ETERNUS CS800
  and InfiniGuard need no gateway. Details: section 2a of `Deploy-VeeamProxies.README.md`.
- **No vCenter access?** Build the ISO only (`-IsoOnly`, or "No vCenter access" under Run commands in
  the planner) and hand it with the generated VM build sheet to the vSphere team. With `-SingleIso`
  one ISO serves every node: the boot menu lists each node by name and IP and waits until the right
  one is picked. With `-PromptIso` the ISO holds no node data at all: the console asks for
  hostname and the network of both NICs at install time. Register afterwards with `-SkipDeploy`. Details: section 4c of `Deploy-VeeamProxies.README.md`.
- **Extra data disk:** `-MultiDisk -VmDataDiskGB <GB>` (planner: "Extra data disk GB") adds a second
  thin disk and uses Veeam's multi-disk install.
- **Second network adapter:** CSV columns `ip2`, `netmask2`, `portgroup2` (planner: "Second network
  adapter"). Static address, no gateway, no default route; NIC 1 stays the management NIC. The
  installer matches the adapters by PCI order, so adapter 1 of the VM is always NIC 1.
- **Logs on disk 2:** `-LogsOnDataDisk` (planner: "Logs on disk 2") sets the appliance's *Logs
  location* - the Host Management Console setting - to the data volume on the extra disk
  (`/var/lib/veeam/VeeamBackupLogFolder`) before first boot, so the Veeam logs never land on disk 1.
  The disk layout stays Veeam's standard two-disk layout. **Note:** VBR's *Export logs* does not collect
  logs from there (13.1.1.18); use the support bundle in the appliance web UI for support cases.
  Details: section 4d of `Deploy-VeeamProxies.README.md`.
- **No vCenter access?** Also from the deployment server page: Mode "ISO only" builds the ISO(s) and the
  VM build sheet on the server.
- The appliance is hardened by Veeam. Do not add packages or change the OS; registration and
  updates go through VBR.
- If a node times out at first boot, the toolkit saves a screenshot of its console next to the
  staging area. A console showing the Initial Configuration Wizard means the settings file was not
  usable on that node.
- Full parameter reference, recipes and the troubleshooting table: `Deploy-VeeamProxies.README.md`.

## Security posture of the deployment server

For your security team. This is what a server built from the ISO enforces; the same settings are
in `deploy-server/ks.cfg.template` for review.

| Area | Setting |
|------|---------|
| Network | Two listeners only: SSH on the network, the web API on 127.0.0.1:8080. Firewall allows SSH alone. With the optional HTTPS front end there's a third: nginx on 443, client certificate required, and the firewall also allows `https`. |
| SSH | Key-only for the `deploy` account. Password and keyboard-interactive authentication off, root login off, X11 forwarding off, `AllowUsers deploy`. A user-name-and-password attempt is refused before any prompt. |
| Accounts | Root locked. `deploy` has no password unless one is set at build time; with a password, sudo asks for it. Without one, sudo is passwordless, so the SSH private key is a root credential. |
| OS | Rocky Linux 9 minimal, SELinux enforcing, no extra packages beyond PowerShell, xorriso and their libraries. |
| Service | Runs as `deploy` under systemd sandboxing: read-only system (`ProtectSystem=strict`), `NoNewPrivileges`, private `/tmp`. |
| Web page | No login of its own; by default reachable only through the SSH tunnel. For several users on a LAN, use the optional HTTPS front end (`deploy-server/enable-https-client-cert.sh`). nginx with TLS 1.2/1.3 lets in only browsers presenting a client certificate from your CA, logs each client's certificate name, and the page itself stays on localhost. Never bind the page's listener to a LAN address directly. |
| Secrets | Settings files are encrypted at rest (AES-256-CBC + HMAC-SHA256) with a key readable only by `deploy`. Passwords typed for a run are stored encrypted for that run and deleted when it ends. Nothing secret is written to logs. |
| Not covered | Disk encryption: the encryption key sits on the same disk as the encrypted files, so use vSphere VM encryption if the datastore is a concern. Automatic OS patching: the server works offline; patch it from your own repository on your own schedule. |
