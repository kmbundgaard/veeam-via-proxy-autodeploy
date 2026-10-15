# Copilot instructions — Veeam v13.1 proxy mass-deployment

This repository deploys **Veeam Infrastructure Appliance (VIA) 13.1** backup proxies at scale on
VMware vSphere and registers them to Veeam Backup & Replication (VBR). One CSV drives everything;
one VBR at a time (a VIA binds to exactly one VBR). Read `START-HERE.md` and `Deploy-VeeamProxies.README.md` for the architecture; record behaviour
changes in `CHANGELOG.md`.

## What is in the repo

| Path | Role |
|------|------|
| `Deploy-VeeamProxies.ps1` | The deliverable. PowerShell 7 script. Stage A builds a per-node unattended ISO and creates the VM (PowerCLI + xorriso). Stage B registers the appliance to VBR (REST by default, Veeam cmdlets optional). Modes: default, `-SkipDeploy`, `-SkipRegister`, `-ValidateOnly`, `-Rollback`, `-RollbackOnFailure`, `-WhatIf`. |
| `templates/` | `vbr_init.cfg.template` (answer file), `network-line.template` (kickstart network line), `veeam-init.sh.template`, `veeam-init.service`. Rendered with `{{TOKEN}}` placeholders by `ConvertTo-RenderedTemplate`; the renderer fails on any `{{WORD}}` it cannot resolve, so never write literal double-brace text in template comments. |
| `Fleet-Planner.html` | Offline single-file web UI that builds, validates and exports the CSV and generates the per-VBR command lines. No CDN, no network calls: it must keep working from `file://` on an air-gapped host. |
| `appliance-secrets.example.conf` | Format of the settings file passed via `-ApplianceSecretsFile` (passwords, TOTP seeds, NTP). Example values only. |
| `Start-DeploymentServer.ps1`, `deployment-server.service.example` | Optional web front end: PowerShell `HttpListener` serving the planner plus a JSON run API; runs are child `pwsh` processes under `server-data/runs/<id>/`. Localhost-only by default; never add LAN exposure without TLS + auth in front. Keep `New-Run`'s argument builder in step with the deploy script's parameters. |
| `Build-DeployServerIso.ps1`, `deploy-server/ks.cfg.template`, `New-DeployServerVm.ps1` | Build the Rocky 9 deployment server unattended: repack the official minimal ISO with a kickstart + `/payload` (project, RPMs, PowerCLI modules), then create the VM, wait for the kickstart power-off, detach the ISO, boot, wait for SSH. Keep the kickstart's `%post` in step with `deployment-server.service.example`. |
| `New-ProxyDnsRecords.ps1` | Creates or removes A + PTR records for the CSV rows on Microsoft AD DNS (`DnsServer` module, Windows only). Idempotent; `-WhatIf`; report CSV. Zone derived from FQDN hostnames or `-ZoneName`. |
| `Protect-DeploymentSecrets.ps1` | Encrypts secret files at rest (settings, credential files, TOTP seed) with a separate key file: AES-256-CBC + HMAC-SHA256, `VEEAMENC1` marker. The deploy script's `Read-ProtectedText` decrypts them in memory when `-SecretsKeyFile` is given. Keep the two implementations byte-compatible. |
| `proxies-template.csv`, `proxies-vbr01.sample.csv` | CSV schema and a filled sample. |
| `START-HERE.md` | Customer-facing quick start (what to supply, two ways to run, seven steps). Written for the customer's admins, not for us; keep lab details out of it. |
| `New-HandoverPackage.ps1` | Builds the customer hand-out zip from a fixed whitelist (+ `.sha256`). `-ListOnly` prints the list; `Build-DeployServerIso.ps1` uses it for the server payload. When you add a shipping file, add it to the list here, or neither the zip nor the server gets it. |
| `Deploy-VeeamProxies.README.md`, `templates/README.md` | Operator docs. Update them with any parameter or behaviour change. |

## Hard constraints — do not violate

- **Supported paths only.** PowerCLI, the Veeam REST API, Veeam PowerShell cmdlets and xorriso. No
  Docker, no community tooling as a dependency, no modifications to the appliance beyond the
  documented answer file (extra packages or OS tweaks void Veeam support).
- **Dark-site safe.** The script makes no internet calls at run time. Prerequisites (PowerCLI,
  xorriso, the base ISO) are pre-staged. Do not add runtime downloads.
- **Secrets never reach logs, the CSV, or the repo.** Passwords and TOTP seeds live only in the
  protected settings file. `Write-Log` output must never include them. Do not commit real
  settings files, CSVs with customer data, run reports or staged ISOs.
- **PowerShell 7.x only** (`#Requires -Version 7.0`). Windows PowerShell 5.1 is not supported.
- **Line endings.** Everything written into the ISO (kickstart, grub, answer file, shell script,
  systemd unit) must be UTF-8 without BOM and LF only. Use `Write-TextFileLF`.
- **Idempotency.** Stage B does find-before-add for both the managed server and the proxy. Keep it
  that way so reruns never create duplicates.
- **`-WhatIf` must stay honest.** Every state-changing action goes through `ShouldProcess`.
- **Automatic cleanup removes only what this run created.** `-RollbackOnFailure` acts on the row's
  `$script:Owned` record (`New-RowOwnership`: VM id, datastore ISO, staged ISO, VBR add sent); never
  look resources up by name in that path. Any new resource a run creates gets recorded there right
  where it is created. Only the explicit `-Rollback` tears down by name. (2026-10-14: a by-name rollback
  deleted a concurrent run's healthy appliances.) Taken names are caught by `Get-ExistingTargetConflicts`
  before anything is built, and the deployment server refuses overlapping state-changing runs
  (`Assert-NoConflictingRun`). Keep both.

## Facts verified against real systems (2026-09-24) — do not "correct" these from memory

- 13.1 VIA ISO layout: one unified kickstart `/proxy-ks.cfg`, grub at `/EFI/BOOT/grub.cfg`, volume
  label `VeeamJeOS`. Boot submenus `Single-Disk Deployment` and `Standard (Multi-Disk) Deployment`;
  fresh-install entries `Install - fresh install, wipes everything on all devices` and
  `Install - fresh install, wipes everything (including local backups)`.
- The kickstart contains `log "Veeam post install commands"` inside the chroot `%post` (the
  documented anchor for the Initial-Configuration block) and generates the network line in `%pre`
  as `network --bootproto=dhcp --nodns --hostname=...` inside a heredoc. 13.0.x ISOs need two disks
  and per-role kickstarts (`-KickstartName`, `-GrubDefaultEntry`, `-ApplianceRole None`, `-MultiDisk`).
- VBR 13.1 REST: `x-api-version: 1.3-rev2`. The live OpenAPI spec is at
  `https://<vbr>:9419/swagger/v1.3-rev2/swagger.json` — use it, not memory, for field names.
- `POST /api/v1/connectionCertificate` takes only `serverName` + `type`. The value for
  `LinuxHostSpec.sshFingerprint` is the **SHA-256 of the appliance TLS certificate** (uppercase hex,
  no separators), computed from `certificateUpload.certificate`. The SHA-1 `certificate.thumbprint`
  is rejected with 400 "Invalid TLS key certificate fingerprint".
- `ViProxySpec`: `hostId`, `maxTaskCount`, `transportMode` (`Auto|DirectAccess|VirtualAppliance|Network`),
  `failoverToNetwork`, `hostToProxyEncryption`, `connectedDatastores` all sit **inside `server`**.
- Replace mode (`-Replace`): the VBR keeps the old appliance identity under a name, so redeploying a
  proxy is remove + add, and removing a proxy drops it from every job that pins it. Order is fixed:
  capture (`<host>.replace.json` in staging) → unpin/disable → DELETE proxy + managed server → move
  the old VM aside → deploy → register → re-pin → delete manifest. Job proxy lists live in
  `storage.backupProxies` (VSphereBackup) and `dataTransfer.sourceProxies|targetProxies`
  (VSphereReplica), edited by GET + PUT of the whole `JobModel` (JSON depth 20). Repository proxy
  affinity is not in the REST API. Never remove a proxy from VBR without the capture step.
- Gateway role (CSV `role` = `gateway` | `viproxy+gateway`, 2026-09-30): the VIA Infrastructure Server
  install may be a Gateway Server; only Dell Data Domain and HPE StoreOnce use one. No REST gateway
  object: the managed-server id goes into `<dellDataDomain|hpeStoreOnce>.gatewayServer.gatewayServerIds`
  (+ `autoSelection`) of the repository, GET + PUT of the whole model. Optional CSV `gatewayrepo`
  (`;`-separated names). Replace/Rollback release those lists before deleting the managed server.
  Field names are from the 1.3-rev2 spec, not yet lab-confirmed.
- Stage B fetches the appliance certificate both by the registration name and by the row's IP and
  refuses a mismatch (`DNS mismatch:`, stale A record from a replaced proxy); when the VBR reports
  "Failed to get certificate from" for a name it falls back to the IP with a warning. Keep both checks.
- First-time pairing uses handshake code `000000`; a pairing code is needed only when re-homing an
  appliance to a different VBR. Adding an appliance whose build is older than the VBR triggers an
  in-add OS upgrade that can take 15 to 30 minutes (`-RegisterTimeoutSec`).
- Appliance answer-file rules enforced by `Test-ApplianceSecrets`: passwords 15+ chars, all four
  classes, max 4 same-class chars in a row, veeamadmin ≠ veeamso; 16-char Base32 TOTP seeds;
  hex-GUID recovery token when the Security Officer is enabled.
- An unmodified `appliance-secrets.example.conf` passes those rules but breaks the appliance: with
  `ntp.runSync=true` an unresolvable NTP name (`ntp01.example.local`) fails the whole first-boot
  Initial Configuration and the console shows the interactive wizard (seen 2026-09-25). Both
  `Test-ApplianceSecrets` and the server's `POST /api/settings` refuse the example password, seed and
  `example.*` NTP hosts; keep those checks. On a readiness timeout Stage A saves a console PNG.
- Deployment-server invariants (`deploy-server/ks.cfg.template`): SSH is key-only for `deploy` alone,
  whatever the console-password option does (`PasswordAuthentication no`, `PermitRootLogin no`,
  `AllowUsers deploy`, `X11Forwarding no` in `sshd_config.d/10-autodeploy.conf`, named 10-* so it
  beats Rocky's `50-redhat.conf`); firewall = SSH only; SELinux enforcing; the web listener stays on
  127.0.0.1. Do not loosen these for convenience.
- Rocky kickstart (`deploy-server/ks.cfg.template`): never put `net.ifnames=0` in `bootloader
  --append`. The installer boots without it and writes the static profile for `ens192`; renaming
  the NIC to `eth0` afterwards makes NetworkManager fall back to DHCP.
- `Get-VDPortgroup` (distributed port groups) lives in `VMware.VimAutomation.Vds`, which is not part
  of the Core dependency closure. Always test `Get-Command Get-VDPortgroup` before calling it; a missing
  cmdlet is a command-not-found error that `-ErrorAction SilentlyContinue` cannot swallow. Resolve
  port groups through `Get-PortGroupByName` (standard on the chosen host first, then distributed).
- Never guard a PowerCLI import with `Get-Command Connect-VIServer`: PowerShell auto-loads the
  module for that lookup, so any code inside the guard (such as `Set-PowerCLIConfiguration
  -InvalidCertificateAction Ignore`) silently never runs on a fresh host. Guard on `Get-Module` and
  apply the configuration unconditionally, `-Scope User` (Session scope is unreliable on PowerCLI Core).
- Everything rendered into staging (`vbr_init.cfg`, `veeam-init.*`, `_build_*`, `_validate_*`,
  per-node ISOs) embeds secrets. The deploy script's outer `finally` and the server's `Complete-Run`
  remove them; keep every new artifact inside that cleanup.

## Project decisions in force

- Single-disk 120 GB thin VM, 6 vCPU, 12 GB RAM, UEFI + Secure Boot, `disk.EnableUUID=TRUE`.
- veeamadmin TOTP **on** with one shared seed per settings file; Security Officer **disabled**
  (placeholders auto-filled). One settings file per VBR.
- Role `InfrastructureServerIscsi` by default (`applianceRole.role=vbproxy` + `applianceRole.iSCSI=true`).
- Registration by REST; cmdlet path only from a Windows host with the VBR console installed.
- Proxy host names are the customer's own standard: planner default `{namespace}-{nn}` with a free-text
  Namespace field (`{cluster}` and `{vbr}` stay optional tokens; warn above 15 characters before the
  first dot). The CSV `vbr` column only selects which rows a run processes.

## How to test changes

1. Parse: `pwsh -c '[System.Management.Automation.Language.Parser]::ParseFile(...)'` must be clean.
2. Offline: `-ValidateOnly` with a settings file validates secrets and renders templates. With
   `-BaseIso` it extracts and patches the real kickstart and grub into `<staging>/_validate_<host>/`
   without repacking or touching vSphere. A mock xorriso (a shell script that copies from
   `<iso>.tree/`) plus a synthetic kickstart/grub is enough for regression tests of the patching.
3. Live: one row, `-SkipRegister -KeepIso` first, then `-SkipDeploy`, then a full run. Watch the
   VM console through vCenter screenshots; the appliance has no SSH.
4. If you touch the anchors, grub titles or REST bodies, say so in `CHANGELOG.md` and
   re-verify against a real ISO or the live swagger before merging.

## Style

- Functions are `Verb-Noun`, comments explain *why* and cite the Veeam doc or the live observation.
- Formatted messages: for `Write-Log` the `-f` must sit INSIDE the outer parentheses,
  `Write-Log (("..." + "...") -f $a, $b) 'WARN'`; written as `Write-Log ("...") -f $a 'WARN'` the operator
  becomes a command argument and the log shows literal `{0}` (happened 2026-09-28). `throw` is an
  expression context and formats either way; the project uses `throw (("..." + "...") -f $a, $b)` for
  uniformity. When reading a PowerShell 7 error, the line after `Line |` is the echoed SOURCE line with
  its literal `{0}`; the formatted message follows below it. Do not mistake the echo for the message.
- Fail early with actionable messages that name the file or endpoint and what was found.
- Keep the README parameter table, the CSV column table and the troubleshooting table in sync with
  the `param()` block.
