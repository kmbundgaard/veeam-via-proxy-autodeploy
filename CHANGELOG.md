# Changelog

## 1.3.1 - 2026-10-15

Fixes for the lab incident of 2026-10-14. A sequential Full run and a `-Parallel 4` Full run of the same
four proxies were started 8 minutes apart on the deployment server. Each run hit "A VM named ... already
exists" for the other run's VMs, and `-RollbackOnFailure` then deleted, by name, that other run's VMs (three
of them healthy, finished installs), their VBR managed servers and the datastore ISO a running install was
booting from. Three rows had also waited 20 minutes to install, only to fail at Stage B on stale
`Unavailable` VBR objects.

- **`-RollbackOnFailure` removes only what this run created.** Each row records the VM it created (by VM id,
  not name), the datastore ISO it uploaded, the staged ISO and whether it sent the VBR add (the name was
  confirmed free just before). A row that fails before creating anything removes nothing and its report
  says `(nothing created, nothing removed)`. `-Rollback` (explicit teardown) still works by name.
  A `-SkipDeploy` rerun whose registration fails no longer deletes the existing VM.
- **Pre-check of taken names, before any ISO is built:** for a deploying run without `-Replace`, every row is
  checked for an existing VM in vCenter and an existing VBR managed server (any status). Those rows are skipped
  and nothing is created or removed for them; the other rows carry on. Runs under `-WhatIf` too.
- **`-ValidateOnly` runs the same check, read-only,** when `-vCenterCredentialFile` and/or `-VBRCredentialFile`
  are given (never prompts; skipped for `-SkipDeploy`, where existing appliances are expected). Rows with a taken
  name are reported as failed (exit 2). The deployment server's Validate passes the vCenter / VBR credentials
  when the form has them filled in.
- **Deployment server: one run per appliance.** A Full / DeployOnly / RegisterOnly / Rollback run is refused
  while another such run that shares a host name or IP is still running (`Run <id> ... is still running and
  handles ...`). Validate, WhatIf and the ISO builds are never blocked.
- Lab (2026-10-15): the first clean `-Parallel 4` Full run (prx-01..04 on vbr02) deployed, registered and
  assigned the proxy role on all four in 40 minutes. One console kept showing the Initial Configuration Wizard
  although the appliance was configured and paired (README troubleshooting). 1.3.1 itself: 21 mock tests
  of the rollback / pre-check / server-lock logic, and a live read-only `-ValidateOnly` against the lab vCenter
  and VBR that flagged the four existing proxies. **A failing deploy with 1.3.1 has not yet been run live.**

## 1.3.0 - 2026-10-14

- **Veeam Software Appliance (VSA) deployment:** CSV `role` `vbr` (Veeam Backup & Replication server) or
  `em` (Veeam Backup Enterprise Manager), built from `VeeamSoftwareAppliance_13.1.x.iso`. Per row, the build
  takes `/vbr-ks.cfg` or `/vbem-ks.cfg` and the product's fresh-install boot entry (the ISO's own default
  is *Reinstall*). It writes no `applianceRole.*` keys, uses label `VeeamSA`, and always creates two disks
  (240 GB minimum each). Per-product sizing is 8 vCPU / 16 GB for the backup server and 4 vCPU / 16 GB for
  EM; `-Vm*` overrides it. There is no Stage B: the run waits for HMC `:10443`, then for the product on `:443`.
  The run warns when veeamadmin MFA is off. VSA and VIA rows cannot share a run. Fleet-Planner, the
  deployment server and the VM build sheet know the new roles.
  Kickstart names and menu titles were read from `VeeamSoftwareAppliance_13.1.1.18_20260825.iso`.
  Lab (2026-10-14): `-ValidateOnly` with the real ISO and xorriso, and `-WhatIf` against vCenter, both
  passed. **A full install of a `vbr` / `em` appliance is not yet confirmed.**
- `Build-DeployServerIso.ps1`: relative paths resolve against the PowerShell location. Before, they used
  the process directory, which is `C:\Windows\system32` in an elevated shell, so `./iso/x.iso` failed
  with "Cannot acquire drive".
- `Build-DeployServerIso.ps1 -IncludeIso` takes one comma-separated value (`'via.iso,vsa.iso'`), like
  `-SshPublicKeyFile`; under `pwsh -File` the list arrived as one string. The ISOs are checked before the
  slow payload copy.
- Datastore uploads retry (3 attempts, 30 s apart) in `Deploy-VeeamProxies.ps1` and `New-DeployServerVm.ps1`.
  Lab: an L2TP VPN dropped every large upload. `/var/log/ppp.log` showed `No buffer space available`, then the
  UDM ending the session, so saturating uploads starve the VPN keepalives.
- `New-DeployServerVm.ps1 -UseUploadedIso`: use an ISO already in `[datastore] iso/` (copied another way,
  e.g. a rate-limited upload) instead of uploading. Refused when the size differs from `-IsoPath`.
- Deployment server: `rsync` is a payload RPM (resumable `rsync --partial` copies of large ISOs to the
  server). The kickstart installs it in its own step, so a build for a newer Rocky minor (`3.2.7` needs a
  newer libacl than the 9.8 ISO) cannot block PowerShell and xorriso. Lab: `rsync-3.2.5-7.el9_8.2` installs
  offline on Rocky 9.8.

- `Protect-DeploymentSecrets.ps1 -NewRecoveryToken` prints a Security Officer recovery token (GUID) for
  `VEEAMSO_RECOVERY_TOKEN`. START-HERE, the README and the example settings file now explain when it is
  needed (`VEEAMSO_ENABLED = true`) and that it belongs in a vault.
- Deployment server, settings upload: refuses a file with the Security Officer on and no valid recovery
  token (before: only the run's full check caught it), splits `NTP_SERVERS` on `,` as well as `;`, and the
  page shows `recovery token set / missing` next to "Security Officer on".
- **Parallel deployment, `-Parallel N` (1–16)** ("Appliances at a time" in Fleet-Planner and on the
  deployment server). The run becomes an orchestrator with one worker process per row (one-row CSV, own staging
  folder, sessions and report), at most N at once, starts `-ParallelStaggerSec` apart (45 s). Credentials are
  asked once and handed over as encrypted files. Workers take unique TOTP time steps (shared lock file). Log
  lines are prefixed with the host; one merged report. Checks the free staging space for N ISO builds. Refuses
  `-Replace` and `gatewayrepo` rows (shared job / gateway lists would be overwritten). Validate / Rollback /
  ISO-only stay sequential. Lab: `-WhatIf` with 2 VSA rows and with 2 proxy rows (VBR REST login per worker)
  passed.
- Under `-WhatIf`, PowerCLI's module start-up no longer prints a page of `Set Alias` / `TabExpansion2` lines.
- Software Appliance rows wait up to 2 hours for readiness (proxies: 30 minutes). Lab: the first full `vbr`
  install was healthy but at package 692 of 771 after 30 minutes; the proxy-sized timeout plus *Rollback on
  failure* deleted it. The unattended boot, Secure Boot and kickstart were confirmed by that console screenshot.
- Deployment server: a run's per-run credential files and staged ISOs are removed when the run ends, even
  with nobody watching the page (before: only when the page next asked for that run; lab: `vcenter.cred` left
  behind). The server sweeps finished runs between requests (30 s), and at start it scrubs runs a restart
  interrupted.
- Wrong base ISO for the rows (lab: `vbr` rows run with the Infrastructure Appliance ISO): the script now
  says which ISO the role needs instead of a bare `xorriso failed (exit 5)`. The page preselects the
  matching ISO for the chosen VBR key and refuses a mismatched pick before the run starts.

- DNS search domain is back: the `-PromptIso` console asks for it (default = the hostname's domain, `-` =
  none) and CSV modes take an optional column `dnssearch` (`,`-separated). Both become anaconda
  `--ipv4-dns-search` on NIC 1. Fleet-Planner shows, checks and exports the column. Confirmed in the lab
  on 2026-10-01 with the `prompt-search` ISO.

## 1.2.0 - 2026-09-30

- `-PromptIso` (with `-IsoOnly`): one generic ISO; at install the console asks for hostname, NIC 1 (IP,
  netmask, gateway, DNS) and NIC 2, checks every value and installs only after `y`.
- `-IsoOnly`: build the ISO(s) plus a VM build sheet (`*-VM-SPEC.txt` / `.csv`) without vCenter or VBR
  access, for teams that create the VMs themselves. Register afterwards with `-SkipDeploy`.
- `-SingleIso` (with `-IsoOnly`): one ISO for all rows. The boot menu gets one entry per node (name + IP),
  each with its own kickstart, and waits until one is picked, so nothing installs under the wrong identity
  by itself.
- `-IsoOnly` pings every CSV address first and warns about the ones that answer; CSV load now refuses
  duplicate IP addresses.
- Fleet-Planner: "No vCenter access" command set (Validate, build ISO, register), "Extra data disk GB"
  (`-MultiDisk -VmDataDiskGB`), and non-default vCPU / RAM / disk sizing now reaches the commands.
- Second network adapter per node: optional CSV columns `ip2` / `netmask2` / `portgroup2`. Stage A adds
  adapter 2; the kickstart configures it statically with no default route and names both adapters by PCI
  order at install time (no ens192/ens224 guessing). Boot-menu entries show both addresses.
- `-LogsOnDataDisk` (with `-MultiDisk`): the appliance's Logs location (Host Management Console setting,
  `rootLogDirPath`) is set to the data volume on disk 2, `/var/lib/veeam/VeeamBackupLogFolder`, at install
  time; the folder and the Veeam rsyslog / logrotate rules follow. Disk layout unchanged. Planner: "Logs on disk 2".
- Deployment server: ISO-only run modes (per node, single ISO, prompt ISO), the planner's sizing and disk
  options on every run, download of the VM build sheet, an scp command for the ISOs, and deleting the ISO
  output on the server.
- Windows build host: `wsl.exe --exec` for path translation and xorriso (was broken for every path since 1.0.0).
- Lab-verified 2026-09-30 (VIA 13.1.1.18): single ISO, prompt ISO, two NICs, two disks, logs on disk 2,
  registration. Known: VBR *Export logs* skips a logs location on disk 2 - use the web UI support bundle.

## 1.1.0 - 2026-09-30

- New CSV roles `gateway` and `viproxy+gateway`: the appliance becomes a gateway server for Dell Data
  Domain / HPE StoreOnce repositories. Optional column `gatewayrepo` (`;`-separated repository names)
  adds it to each repository's gateway server list over REST; without it the appliance is only added
  as a managed server. ExaGrid / Quantum DXi / ETERNUS CS800 / InfiniGuard are refused (no gateway).
- `-Replace` and `-Rollback` also release the appliance from repository gateway lists; Replace
  re-pins the new appliance there.
- CSV load refuses unknown roles and `gatewayrepo` on a row without the gateway role; `tasks` may be
  empty on gateway-only rows.
- Fleet-Planner: role choice, optional `gatewayrepo` column and matching checks.
- Repository field names are from the `1.3-rev2` spec; confirm on a real Data Domain / StoreOnce first.

## 1.0.0 - 2026-09-29

First release.

- CSV-driven deployment of Veeam Infrastructure Appliance 13.1 backup proxies on vSphere: per-node
  unattended ISO (xorriso), UEFI + Secure Boot VM (PowerCLI), certificate-trust registration and
  VMware proxy role over the VBR REST API (`1.3-rev2`).
- Replace mode (`-Replace`): redeploy a broken or running proxy under the same name and IP and
  restore its place in backup and replication jobs.
- DNS safeguards: preflight resolution, certificate cross-check by name and by IP, IP fallback.
- `Fleet-Planner.html` offline planner; optional deployment server (Rocky Linux 9, built
  unattended from the vendor ISO) with a web page and Run button, reached through an SSH tunnel.
- Secrets encrypted at rest (`Protect-DeploymentSecrets.ps1`); example values refused.
- Microsoft AD DNS records from the same CSV (`New-ProxyDnsRecords.ps1`).
- Builds on Linux, macOS and Windows (xorriso in WSL).
