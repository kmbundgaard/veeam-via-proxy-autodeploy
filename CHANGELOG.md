# Changelog

## 1.3.2 - unreleased

- **DNS search domain on 13.0.x appliances.** The 13.0.x VIA installs from Rocky 9.2, whose installer does not
  know `--ipv4-dns-search` and stopped with "unrecognized arguments: --ipv4-dns-search=..." before touching the
  disks. For a 13.0.x base ISO the search domain (CSV `dnssearch`) now goes into the installed NIC 1 profile from
  the %post block (NetworkManager keyfile or ifcfg, matched by the row's IP); 13.1 keeps the kickstart option.
  The generic prompt ISO on 13.0.x sets no search domain (warned). Customer, 2026-11-06.
- **VM hardware version no longer taken from the cluster default.** New-VM used the cluster's default VM
  compatibility; at ESXi 6.0 (vmx-11) vCenter refuses the `rhel9_64Guest` guest OS ("not supported on the host at
  hardware version"). Without `-HardwareVersion`, the deploy (and `New-DeployServerVm.ps1`) now takes the newest
  hardware version the target host can create that knows the guest OS (ESXi 8.0 U2+ = vmx-21). The planner has a
  "VM hardware" choice (Auto / vmx-21 / vmx-20 / vmx-19). Customer, 2026-11-06.
- **`-Replace` safe to rerun after a half-done release.** If a job update failed part-way through releasing the old
  proxy, the rerun captured only the jobs still pinned to it and lost those already unpinned, so the new proxy
  was never pinned back there. The rerun now keeps the earlier manifest's job lists (minus the old proxy id) and
  adds what it finds. With `-ReplaceJobPolicy Disable`, each disabled job is written to the manifest at once,
  so a failure later no longer leaves a job disabled that the restore does not know about.
- **Job update refused by the VBR: "'Credentials Per Machine' must not be empty".** The VBR returns a job whose
  guest-processing credentials carry an empty per-machine list and then refuses that same model on PUT, so
  re-pinning a job's proxy list (`-Replace`) failed. When every such list in the job is empty, the update is
  retried once without the list and once with it as `[]`; a list with entries is never touched. If the VBR still
  refuses, the run names the job and what to check in the console. Customer, 2026-11-06.
- **Planner page no longer widens on Run.** A long line in the run log stretched the panel and the whole page
  (grid items default to `min-width: auto`); the log now scrolls inside its box.
- **vSphere inventory with distributed switches fixed.** "Load inventory" failed with "The property 'VlanId'
  cannot be found on this object" as soon as the vCenter had a distributed switch: only a single-VLAN port group
  has `VlanId`; a trunk (every VDS's uplink port group), a private VLAN and VLAN type None do not, and the server
  runs under StrictMode. The VLAN is now read for every type (`120`, `trunk 0-4094`, `pvlan 201`, empty) and
  uplink port groups are no longer listed. Found at a customer, 2026-11-06.
- **`Get-DeployServerMedia.ps1`: one download for a dark site.** On any machine with internet (Windows
  PowerShell 5.1 or pwsh 7) it fetches the Rocky minimal ISO, the seven RPMs, PowerCLI and the PowerShell 7 MSI
  for the build host into one folder (`iso\`, `rpms\`, `PowerCLI\`, `tools\`, empty `veeam-iso\` and `keys\`),
  with `SHA256SUMS.txt` and a `NEXT-STEPS.txt` holding the build commands. ISO and RPMs always come from the
  same Rocky minor (default 9.8, the tested set, pinned by file name); every file is checked against Rocky's
  CHECKSUM file, the repository metadata or GitHub's release digest. Background: a server installed from one
  Rocky minor with RPMs of another ends with no pwsh, and the service fails with `203/EXEC`.
- **Base ISO upload from the planner.** The deployment server panel takes a new base ISO (`PUT /api/iso/<name>`,
  streamed to disk, SHA-256 and volume label recorded and shown for the KB4738 check). Refuses non-ISO files,
  existing names and a too-full disk; an interrupted upload leaves nothing behind. `enable-https-client-cert.sh`
  lifts nginx's 16 MB body limit for that path only. Lab 2026-11-02: 2.7 GB in 33 s over SSH, 1.7 GB in 13 s
  over HTTPS with client certificate.
- **13.0.x Infrastructure Appliance ISOs recognised.** A base ISO with `/vmware-proxy-ks.cfg` (13.0.x layout)
  gets the kickstart and boot entry of its role (`vmware-proxy-ks.cfg` for the iSCSI role, `proxy-ks.cfg` for
  the plain one) and an answer file without `applianceRole.*` keys; `-KickstartName` / `-GrubDefaultEntry`
  still override. 13.0.x has no single-disk layout (its installer stops with "At least 2 disks are required"),
  so such a run always gets the second disk (`-VmDataDiskGB`, default 120 GB). Without an explicit
  `-ApiVersion`, a VBR that refuses `1.3-rev2` (13.0.x) is retried once with `1.3-rev1`; the deployment server
  no longer pins the API version unless started with `-ApiVersion`. On `1.3-rev1`, `/connectionCertificate`
  demands SSH credentials (which the appliance does not accept), so the fingerprint is read from the
  appliance's TLS certificate on :443 - the hash the VBR itself pins. Lab 2026-11-02, end to end: VBR 13.0.3.63
  (Software Appliance, built by the tool) + VIA 13.0.3.63 proxy: install, first-boot answer file, add as managed
  server and VMware proxy role.
- **Unlicensed VBR named as such.** A VBR without a licence (a fresh Software Appliance) answers every REST call
  with "License restrictions apply"; the run now stops with "install a licence on the VBR first" instead of the
  bare HTTP 400 of whichever lookup came first.
- **Hardened repository ISOs: CSV role `hardenedrepo`.** ISO build only (`-IsoOnly`, `-ValidateOnly`), with the
  same per-node network, accounts, MFA and NTP as the proxies. 13.1: answer-file role `veeam-lhr` (read from
  `veeamhostmanager` 13.1.1.9) and the multi-disk boot entry; 13.0.x: `/hardened-repo-ks.cfg`. Refused unless
  veeamadmin MFA or the Security Officer is on (Veeam's own rule for the role), when mixed with other rows in one
  run, and in deploy / register modes. Planner: role option, own command block, run panel guard.

- **VM name separate from the host name.** New optional CSV column `vmname` for the name in vCenter, for
  naming standards such as `ros_km_vpr-nodspa0101` (VM) with `vpr-nodspa0101` (host name). Underscores are
  kept; empty = `hostname`, so existing CSVs behave as before. Every lookup by name (pre-check, `-Rollback`,
  the `-IsoOnly` build sheet) uses it.
- **Fleet planner naming.** The generator has free-text **Datacenter** and **Location** fields (tokens
  `{datacenter}`, `{location}`), a **VM name pattern** (fills `vmname`; `{hostname}` = the generated host
  name, literal text such as `km` kept as typed, underscores kept), a **Search domain** (the host name stays
  short; fills `dnssearch` and `vbrname` = `hostname.domain`; the DNS command gets `-ZoneName`) and a
  **VM/Host group** field (fills `vmgroup`; `{cluster}` = the cluster name, suggestions `vmgr-{cluster}` and
  `vmgu-{cluster}`). A `_` in the namespace is no longer turned into `-` in the VM name (only in the host
  name, where DNS needs it). The naming fields and the tag list are remembered in the browser.
- **vSphere tags: `-Tag` and `-CreateMissingTags`.** `'Category=Tag'` pairs for every VM of the run, entered
  in the planner as `Category = Tag` per line (also sent by the deployment server's web form). Checked right
  after the vCenter connect, before anything is built: a missing category, a category that does not take
  VMs, two tags in a single-cardinality category, or a missing tag stops the run. `-CreateMissingTags`
  creates a missing tag inside its existing category; categories are never created. Tags are assigned right
  after the VM is created.
- **DRS VM groups: CSV column `vmgroup`.** The VM is added to the existing VM group of its cluster right after
  it is created. The placement pre-check stops the run when the group does not exist.
- **`-Replace` finds the old VM by IP.** The VM that VMware Tools report with the row's `ip` / `ip2`, or the VM
  with the row's VM name, is the one replaced, so a proxy that gets a new name under a new naming standard is
  still found. It is looked up before anything is released in the VBR; several matching VMs, or an address
  that answers a ping while no VM reports it, stop the row with nothing changed. The old VM is shut down from
  the guest (hard power-off after `-ReplaceShutdownTimeoutSec`, default 300 s) and renamed
  `<old name>_ToBeDeleted` (was `<host>-old-<stamp>`), with the date appended when that name is taken. In the
  VBR the old proxy is also found by the old VM's guest host name or VM name.
- **Fix: CSV `dnssearch` on a single-adapter row stopped the appliance install.** anaconda refuses
  `--ipv4-dns-search` without `--device` ("Option --ipv4-dns-search requires --device to be specified", the
  installer terminates). The network line now gets `--device=link` (the first adapter with a link) when a
  search domain is set; rows with a second adapter and the prompt ISO already named the device. Found in the
  lab on 2026-10-28, the first run that filled `dnssearch`.
- Parallel runs hand `-Tag` to the workers as one `;`-separated value (the first array parameter of the
  script; a plain `[string]` conversion would have joined the pairs with spaces).

- **Deployment server without xorriso or WSL: `Build-DeployServerIso.ps1 -NoXorriso`.** For build machines
  where xorriso can't be installed and WSL can't be turned on. The Rocky ISO stays untouched. `-OutIso` is a
  small second ISO labelled `OEMDRV` with only `ks.cfg` and the payload; the Rocky installer loads a kickstart
  from such a volume by itself.
  - Windows writes the seed ISO with the built-in IMAPI2, macOS with `hdiutil`, Linux with `genisoimage`,
    `mkisofs` or `xorriso`.
  - `New-DeployServerVm.ps1 -SeedIsoPath` uploads both ISOs, attaches the seed ISO in a second CD drive and
    removes that drive after the install. `-RockyIso` is optional with `-NoXorriso`.
  - Files of 2 GiB or more (the appliance ISOs) are split into 1 GiB parts on the seed ISO and joined again in
    the kickstart's `%post`. IMAPI2 refuses larger files on ISO 9660 / Joliet ("Data file is too large").
  - The kickstart mounts the `OEMDRV` volume when the payload isn't on the install ISO, and makes the copied
    files writable (an IMAPI2 ISO has no Rock Ridge permissions). The existing build is unchanged.
  - IMAPI2 keeps the source files open until its COM objects are released. The build releases them, so the
    work folder in `%TEMP%` (19 GB with the appliance ISOs) is deleted afterwards. If a work folder can't be
    deleted, the build now prints a warning instead of failing silently.
  - Lab (2026-10-27): seed ISO built on Windows Server 2022 (vone) with IMAPI2 only, 18 GB with the VIA and VSA
    ISOs, in 4 minutes. The VM installed from the untouched Rocky 9.8 ISO plus the seed ISO in 27 minutes. Both
    joined appliance ISOs match the source SHA-256, the service answers on 8080 and the hardening is as before.

- **Optional HTTPS on the LAN with client-certificate authentication** for the deployment server:
  `deploy-server/enable-https-client-cert.sh`. nginx terminates TLS on 443 and only lets through a browser that
  presents a client certificate from your CA. The server itself stays on `127.0.0.1:8080`, and the firewall
  opens `https` only.
  - `--make-csr` creates the server's private key on the server itself; the key never leaves it.
  - The script sets the SELinux boolean `httpd_can_network_connect` and logs the client's certificate DN for
    every request.
  - The README (section 1c) has the private-CA, server-certificate and client-certificate (`.p12`) steps.
  - The script is part of the hand-out list.
  - nginx comes from Rocky AppStream. The server ISO doesn't include it yet: on a dark site, install it from
    your own repository.
  - A rebuild from the ISO doesn't keep this setup. Run the steps again after a rebuild.
  - Lab (2026-10-16): without a client certificate the answer is HTTP 400; with one, the page and the API work.

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
