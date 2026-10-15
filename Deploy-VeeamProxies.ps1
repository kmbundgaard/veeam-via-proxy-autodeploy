#Requires -Version 7.0
<#
.SYNOPSIS
    Mass-deploy and register Veeam v13.1 Infrastructure Appliance (VIA) backup proxies
    on VMware vSphere, one VBR at a time, from a CSV.

.DESCRIPTION
    Two-stage, CSV-driven deployment (target: VIA 13.1 - VeeamInfrastructureAppliance_13.1.x ISO):

      Stage A (PowerCLI) - build a per-node UNATTENDED ISO from the base 13.1 VIA ISO: extract the
                           unified /proxy-ks.cfg kickstart + /EFI/BOOT/grub.cfg, swap in the per-node
                           static network line, inject the documented "Automating Installation with
                           Initial Configuration" block (answer file /etc/veeam/vbr_init.cfg with the
                           veeamadmin/veeamso accounts, optional MFA, NTP and the appliance ROLE, plus
                           the one-shot veeam-init.service that applies it on first boot), patch grub
                           for unattended single-disk install, repack with xorriso. Then create a UEFI
                           + Secure Boot VM on the row's cluster/datastore (datastore may be an SDRS
                           cluster), attach the ISO, power on, wait for the Host Management Console,
                           detach the ISO.

      Stage B (REST/PS)  - register the proxy to its OWNING VBR non-interactively using the VIA's
                           certificate-based trust (no username/password). A first-time pairing uses
                           the fixed handshake code 000000 (Veeam Add-VBRLinux reference); a pairing
                           code is only needed when re-pairing an appliance to a DIFFERENT VBR. Then,
                           per the CSV 'role': assign the VMware Linux proxy role, transport mode and
                           task slots (viproxy), and/or make the appliance a gateway server of Dell
                           Data Domain / HPE StoreOnce repositories (gateway, optional 'gatewayrepo').

    A VIA binds to exactly ONE VBR, so run one VBR at a time. Point -Vbr at the owning VBR and
    the script processes only rows whose 'vbr' column matches (or pass -Vbr *  to process the
    whole CSV against a single connected VBR - not recommended for a multi-VBR CSV).

    Veeam Software Appliance (VSA): CSV rows with role 'vbr' (Backup & Replication server) or 'em'
    (Backup Enterprise Manager) run Stage A only, from the VeeamSoftwareAppliance_13.1.x ISO: per row
    /vbr-ks.cfg or /vbem-ks.cfg + that product's fresh-install boot entry, two disks of 240 GB+, wait
    for the Host Management Console and the product on :443. No Stage B (nothing to register).

    Dark-site friendly: no internet is used at runtime. PowerCLI, xorriso and the base ISO must be
    pre-staged (the PowerCLI auto-install only works on a connected host).

.PARAMETER CsvPath
    Path to the deployment CSV. Schema:
    vbr,hostname,ip,netmask,gateway,dns,cluster,datastore,folder,portgroup,role,tasks
    ('gateway' is the network default gateway.) 'role' is one of:
      viproxy          VMware Linux backup proxy with 'tasks' task slots.
      gateway          Gateway server for deduplicating storage (Dell Data Domain, HPE StoreOnce). The
                       appliance is added as a managed server; with the optional column 'gatewayrepo'
                       (existing repository names, ';'-separated) it is also put into each repository's
                       gateway server list (automatic selection off). REST path only for 'gatewayrepo'.
                       ExaGrid, Quantum DXi, ETERNUS CS800 and InfiniGuard use no gateway.
      viproxy+gateway  Both on the same appliance ('tasks' applies to the proxy).
      vbr              Veeam Software Appliance - Veeam Backup & Replication server (Stage A only).
      em               Veeam Software Appliance - Veeam Backup Enterprise Manager (Stage A only).
                       vbr / em need -BaseIso = the Software Appliance ISO, cannot be combined with another
                       role and cannot share a run with proxy / gateway rows.
    Optional columns: vbrname, handshakecode, gatewayrepo, dnssearch (DNS search domains, ','-separated),
    and ip2 + netmask2 + portgroup2 (a second network adapter: static address, no gateway, no default
    route; all three together).

.PARAMETER Vbr
    The owning VBR key to process (matches the CSV 'vbr' column). Use '*' to process every row.

.PARAMETER VBRServer
    FQDN/IP of the Veeam Backup & Replication server to register proxies against (Stage B).

.PARAMETER VBRCredential
    Credential for the VBR server. If omitted you'll be prompted (unless -SkipRegister).

.PARAMETER vCenterServer
    FQDN/IP of the vCenter for the Stage A deploy.

.PARAMETER vCenterCredential
    Credential for vCenter. If omitted you'll be prompted (unless -SkipDeploy).

.PARAMETER BaseIso
    Path to the pristine, UNMODIFIED 13.1 Veeam INFRASTRUCTURE Appliance ISO (used by Stage A), or the
    Veeam SOFTWARE Appliance ISO for CSV rows with role vbr / em. Per-node ISOs are repacked from it;
    the base is never edited in place.

.PARAMETER ApplianceSecretsFile
    Protected key=value file with the SHARED appliance-account settings (veeamadmin/veeamso
    passwords, optional MFA seeds, SO recovery token, NTP) rendered into every node's answer file.
    NEVER in the CSV/repo. See appliance-secrets.example.conf. Distinct from -VBRMfaSecret* (Stage B).
    Values are validated against the documented appliance password/MFA/token rules before any
    ISO is built (a bad value would otherwise fail silently inside the appliance).

.PARAMETER SecretsKeyFile
    Key file from Protect-DeploymentSecrets.ps1 -NewKey. With it, -ApplianceSecretsFile,
    -vCenterCredentialFile, -VBRCredentialFile and -VBRMfaSecretFile may be encrypted at rest
    (VEEAMENC1 marker; AES-256-CBC + HMAC-SHA256) and are decrypted in memory only. Plaintext
    files still work but are flagged with a warning. Keep the key apart from the files.

.PARAMETER vCenterCredentialFile
    Two-line file (user, password), plaintext or encrypted, used when -vCenterCredential is not
    given. Avoids interactive Get-Credential prompts and clear-text passwords on disk.

.PARAMETER VBRCredentialFile
    Same as -vCenterCredentialFile, for the VBR REST / console account.

.PARAMETER vCenterUser
    Interactive alternative: the vCenter user name. The run then prompts for that account's
    password only, and nothing is stored on disk. Without it (and without a credential object or
    file) Get-Credential asks for user name and password.

.PARAMETER VBRUser
    Same as -vCenterUser, for the VBR account.

.PARAMETER ApplianceRole
    Appliance role written to the answer file (13.1 unified VIA ISO; the role is no longer chosen
    from the boot menu). InfrastructureServerIscsi (default) = "Infrastructure Server with
    iSCSI/FC/NVMe-oF" (keeps Direct SAN / backup from storage snapshots open);
    InfrastructureServer = plain proxy.

.PARAMETER Parallel
    Deploy up to N rows at the same time (1-16, default 1 = one after the other). The run becomes an
    orchestrator: one worker process per row (this script with a one-row CSV, its own staging folder,
    vCenter/VBR sessions and report), at most N at once, starts -ParallelStaggerSec apart (default 45 s).
    Credentials are asked once and handed to the workers encrypted. Refused with -Replace and with
    'gatewayrepo' rows (shared job / gateway lists). -ValidateOnly, -Rollback and -IsoOnly stay sequential.
    The staging folder needs about N x the base ISO size free (checked before the start).

.PARAMETER MultiDisk
    Use the "Standard (Multi-Disk) Deployment" boot entry and give the VM a second data disk of
    -VmDataDiskGB. Default is the 13.1 "Single-Disk Deployment" entry (one 120 GB disk), which is
    what a backup proxy needs.

.PARAMETER TemplateDir
    Dir with the answer-file template, network-line template and first-boot artifacts. Defaults
    to <script dir>\templates.

.PARAMETER IsoStagingDir
    Working dir for per-node <hostname>.iso. Defaults to <CSV dir>\iso-staging.

.PARAMETER HandshakeCode
    Pairing / handshake code used when the VBR adds the appliance. Per the Veeam Add-VBRLinux
    reference, the FIRST pairing of a fresh appliance uses 000000 (default). Only an appliance
    previously paired to a different VBR needs a code generated in its Host Management Console;
    put that in an optional CSV column 'handshakecode' to override per row.

.PARAMETER TransportMode
    Proxy transport mode: Auto (default), HotAdd (virtual appliance), Nbd (network) or
    DirectStorageAccess. Failover to network is on unless -NoFailoverToNbd is given.

.PARAMETER SkipDeploy
    Skip Stage A (assume VMs already exist); only register + validate.

.PARAMETER SkipRegister
    Skip Stage B (only deploy to vSphere); no VBR connection is made.

.PARAMETER ValidateOnly
    Do neither stage; just validate the CSV/environment and report what WOULD happen.

.PARAMETER IsoOnly
    Build the ISO(s) and stop: no vCenter login, no VM, no VBR. For when someone else creates and
    boots the VMs. Writes the ISO(s) plus a VM build sheet (<name>-VM-SPEC.txt / .csv: hardware,
    placement, which ISO or boot entry belongs to which VM) to -IsoOutDir, and warns when a CSV
    address already answers a ping. The ISOs are kept (they are the output) and hold the appliance
    passwords in clear text. Register afterwards with -SkipDeploy (VBR access only). With -MultiDisk
    the ISO uses the multi-disk install entry and the build sheet asks for the second disk.

.PARAMETER SingleIso
    With -IsoOnly: ONE ISO for every row instead of one per row. The boot menu gets an 'AutoDeploy'
    submenu with one entry per row (name + IP) and WAITS: the person at the VM console picks the
    entry for that VM. Nothing installs unattended, so a VM cannot take another node's IP by itself.

.PARAMETER PromptIso
    With -IsoOnly: ONE generic ISO with no node data in it. At install time the appliance stops on
    a console screen and asks for the hostname and the settings of NIC 1 (IP, netmask, gateway, DNS,
    DNS search domain) and, when the VM has a second adapter, NIC 2 (IP, netmask; empty =
    unconfigured). Every answer is checked, a summary is shown and the install only starts after
    "y". The appliance settings
    file (passwords, MFA, NTP, role), -MultiDisk and -LogsOnDataDisk are built in as usual.
    -CsvPath is optional here: when given, its first row supplies the default netmask, gateway,
    DNS, dnssearch and netmask2 shown in the questions (the search domain defaults to the domain
    part of the typed hostname; '-' = none). Register afterwards with a CSV of what was typed and
    -SkipDeploy.

.PARAMETER IsoOutDir
    Output folder for -IsoOnly. Default <CSV dir>/iso-out. Must differ from -IsoStagingDir (the
    run clears ISOs from the staging dir at the end).

.PARAMETER LogsOnDataDisk
    With -MultiDisk: set the appliance's "Logs location" (the Host Management Console setting, key
    rootLogDirPath in /etc/veeam/veeam_global.conf) to /var/lib/veeam/VeeamBackupLogFolder - the data
    volume on disk 2, the other location the console offers - instead of /var/log/VeeamBackup on
    disk 1, before first boot. The kickstart creates the folder with the owner and mode the packages
    give /var/log/VeeamBackup (root:veeam-grp-log, 02770) and points the Veeam rsyslog / logrotate /
    retention rules at it; the host manager reads the key when it first starts. Components VBR
    deploys later (transport) are expected to follow that root. The disk layout is Veeam's standard
    two-disk layout, unchanged. Lab check: after the first job the console shows the data volume as
    the logs location and the transport logs sit under that folder (lab-verified 2026-09-30). Known
    limitation (13.1.1.18): VBR's "Export logs" does not collect that folder; the support bundle in the
    appliance web UI does.

.PARAMETER Rollback
    Teardown mode: power off and delete the VMs named in the CSV (and remove them from VBR if
    connected). Destructive - always dry-run with -WhatIf first.

.PARAMETER RollbackOnFailure
    Auto-clean a row (delete its VM / remove from VBR) if that row fails mid-deploy.

.PARAMETER Replace
    Redeploy over a proxy that already exists in VBR (same name/IP) WITHOUT losing its place in the
    backup and replication jobs, or in the gateway server lists of Data Domain / StoreOnce repositories. The VBR keeps the old appliance identity under that name, so a fresh
    appliance can only be added after the old object is removed - and removing a proxy drops it from
    every job that pins it. Per row: capture the proxy's settings and every job list that pins it
    (manifest '<host>.replace.json' in the staging dir), unpin, remove proxy + managed server, power
    off and rename the old VM ('<host>-old-<stamp>'), deploy + register the new appliance, re-pin the
    jobs with the new proxy id, re-enable what was disabled, delete the manifest. If the run is
    interrupted after the release step, rerun with -Replace (-SkipDeploy) and the manifest on disk is
    restored. REST path only. With -RegisterVia Cmdlet or -SkipRegister the script refuses.

.PARAMETER ReplaceJobPolicy
    What pinned jobs do while their proxy is being rebuilt (about 25 minutes): 'Auto' (default) switches
    a list that would become empty to automatic proxy selection so the job keeps running on other
    proxies; 'Disable' disables the job and re-enables it after the new proxy is pinned. Jobs that keep
    other pinned proxies stay pinned to those either way.

.PARAMETER PurgeOldVm
    With -Replace: delete the old VM immediately instead of powering it off and renaming it.

.PARAMETER ReportPath
    Path for the run-report CSV. Defaults to .\DeployReport_<vbr>_<timestamp>.csv

.EXAMPLE
    pwsh -File ./Deploy-VeeamProxies.ps1 -CsvPath ./proxies-vbr01.csv -Vbr vbr01 `
        -vCenterServer vc01.lab.local -VBRServer vbr01.lab.local `
        -BaseIso ./VeeamInfrastructureAppliance_13.1.1.18_20260825.iso `
        -ApplianceSecretsFile ./appliance-secrets.conf `
        -VBRMfaSecretFile ./vbr-svc-totp.txt -SkipTlsVerify -WhatIf

.EXAMPLE
    # Offline smoke test: validates CSV + secrets, renders the artifacts and - when -BaseIso is
    # given and xorriso is present - extracts and patches the real kickstart/grub into
    # <staging>/_validate/ for inspection, without repacking or touching any infrastructure.
    pwsh -File ./Deploy-VeeamProxies.ps1 -CsvPath ./proxies-vbr01.csv -Vbr vbr01 `
        -ApplianceSecretsFile ./appliance-secrets.conf `
        -BaseIso ./VeeamInfrastructureAppliance_13.1.1.18_20260825.iso -ValidateOnly

.EXAMPLE
    # No vCenter access: build ONE ISO with a boot entry per row + the VM build sheet, hand both to
    # the vSphere team, then register once the appliances are up.
    pwsh -File ./Deploy-VeeamProxies.ps1 -CsvPath ./proxies-vbr01.csv -Vbr vbr01 -IsoOnly -SingleIso `
        -BaseIso ./VeeamInfrastructureAppliance_13.1.1.18_20260825.iso -ApplianceSecretsFile ./appliance-secrets.conf
    pwsh -File ./Deploy-VeeamProxies.ps1 -CsvPath ./proxies-vbr01.csv -Vbr vbr01 -VBRServer vbr01.lab.local -SkipDeploy

.NOTES
    Supported paths only - PowerCLI + Veeam REST/PowerShell + xorriso.
    Built for VIA 13.1 (verified against 13.1.1.18). Confirm in the lab, on the
    REAL 13.1 ISO, before a fleet run:
      - /proxy-ks.cfg contains the anchor 'log "Veeam post install commands"' (else the fallbacks
        fire - the build log says which one); grub submenu/entry titles match (the build asserts).
      - The repacked ISO boots with UEFI Secure Boot ON (Veeam requires Secure Boot for the VIA).
      - REST: LinuxHost body fields (sshFingerprint / handshakeCode) on api 1.3-rev2.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
# PSScriptAnalyzer: these parameters are PATHS to (encrypted) files or a credentials record id, not
# secrets; Test-AppliancePassword's $Password is the value under validation and must be a string.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'vCenterCredentialFile', Justification = 'path to an encrypted credential file')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'VBRCredentialFile', Justification = 'path to an encrypted credential file')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'internal helpers take a credentials id (GUID) or validate a password value')]
param(
    # Required for every mode except -IsoOnly -PromptIso (checked at the start of the run).
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$CsvPath,

    [string]$Vbr = '*',

    [string]$VBRServer,
    [System.Management.Automation.PSCredential]$VBRCredential,

    [string]$vCenterServer,
    [System.Management.Automation.PSCredential]$vCenterCredential,

    # --- ISO unattended deploy (Stage A) ---------------------------------------
    # Pristine, UNMODIFIED 13.1 Veeam Infrastructure Appliance ISO. Per-node ISOs are repacked
    # from it; the base is never edited in place.
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$BaseIso,

    # Kickstart file inside the ISO. 13.1 ships ONE unified '/proxy-ks.cfg' for all VIA roles
    # (the role moved into the answer file). 13.0.x ISOs had per-role files
    # ('/vmware-proxy-ks.cfg' etc.) - pass that name only if you really must build from 13.0.x.
    [string]$KickstartName = 'proxy-ks.cfg',

    # ISO volume label referenced by the grub kernel lines (LABEL=<label>:/<kickstart>).
    [string]$IsoLabel = 'VeeamJeOS',

    # Override the grub default entry ("<submenu title>><entry title>") for an ISO whose menu
    # differs from 13.1 - e.g. 13.0.2: 'Veeam Infrastructure Appliance (with iSCSI & NVMe/TCP)>Install
    # - fresh install, wipes everything (including local backups)'. Still asserted against the
    # titles found in the extracted grub.cfg.
    [string]$GrubDefaultEntry,

    # Dir with the answer-file template, network-line template and first-boot artifacts.
    [string]$TemplateDir = (Join-Path $PSScriptRoot 'templates'),

    # SHARED appliance-account settings (veeamadmin/veeamso passwords, optional MFA seeds, SO
    # recovery token, NTP). NEVER in the CSV/repo. Distinct from -VBRMfaSecret* (Stage B).
    # May be PLAINTEXT or a file encrypted with Protect-DeploymentSecrets.ps1 (needs -SecretsKeyFile).
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ApplianceSecretsFile,

    # --- Secrets at rest --------------------------------------------------------
    # Key file created by Protect-DeploymentSecrets.ps1 -NewKey. When given, every secret file
    # (-ApplianceSecretsFile, -vCenterCredentialFile, -VBRCredentialFile, -VBRMfaSecretFile) that
    # starts with the VEEAMENC1 marker is decrypted in memory. Keep the key apart from the files.
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$SecretsKeyFile,
    # Credential files: two lines (user, password), plaintext or encrypted. Used when the matching
    # -vCenterCredential / -VBRCredential object is not supplied; otherwise Get-Credential prompts.
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$vCenterCredentialFile,
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$VBRCredentialFile,
    # Interactive alternative to credential files: give the user names and the run prompts for the
    # PASSWORDS only (nothing stored on disk). Ignored when a credential object or file is supplied.
    [string]$vCenterUser,
    [string]$VBRUser,

    # Appliance role written to the answer file (13.1: role is chosen by the init wizard / answer
    # file, not the boot menu). Iscsi variant = "Infrastructure Server with iSCSI/FC/NVMe-oF".
    # 'None' omits the applianceRole.* lines (13.0.x ISOs pick the role by kickstart file instead).
    [ValidateSet('InfrastructureServer', 'InfrastructureServerIscsi', 'None')]
    [string]$ApplianceRole = 'InfrastructureServerIscsi',

    # Working dir for per-node <hostname>.iso. Prefer a WSL-reachable path.
    [string]$IsoStagingDir,

    # Datastore to upload per-node ISOs to (New-CDDrive needs a datastore path).
    # Default: the row's own 'datastore' (a member is chosen if that is an SDRS cluster).
    [string]$IsoDatastore,

    # --- Appliance VM hardware -------------------------------------------------
    # Default = 13.1 "Single-Disk Deployment" (one 120 GB disk - right for a proxy). -MultiDisk
    # selects the "Standard (Multi-Disk) Deployment" entry and adds a -VmDataDiskGB data disk
    # (the VIA requirements page lists Disk 1 = 120 GB system, Disk 2 = 120 GB+ data).
    [int]$VmCpu = 6,
    [int]$VmMemoryGB = 12,
    [int]$VmDiskGB = 120,
    [switch]$MultiDisk,
    [int]$VmDataDiskGB = 120,
    # Veeam logs on disk 2: set the appliance's "Logs location" (Host Management Console setting, key
    # rootLogDirPath in /etc/veeam/veeam_global.conf) to /var/lib/veeam/VeeamBackupLogFolder - the data
    # volume the multi-disk layout puts on disk 2, the other location the console offers - instead of
    # /var/log/VeeamBackup on disk 1, before first boot. Needs -MultiDisk. Disk layout unchanged.
    [switch]$LogsOnDataDisk,
    [string]$GuestId = 'rhel9_64Guest',
    [string]$HardwareVersion,
    # Veeam requires UEFI Secure Boot ENABLED for the VIA. The repacked ISO only changes text
    # config (grub.cfg / kickstart), not signed binaries, so it boots with Secure Boot on. Use
    # -NoSecureBoot only for troubleshooting.
    [switch]$NoSecureBoot,
    [int]$GrubTimeout = 5,

    # --- Appliance readiness gate (Host Management Console HTTPS) --------------
    [int]$HmcPort = 10443,
    [int]$IsoReadyTimeoutSec = 1800,
    [int]$IsoReadyPollSec = 20,
    # After the HMC port answers, give veeam-init.service time to apply the answer file before
    # Stage B connects (the console can be up a little before the initial configuration lands).
    [int]$PostReadySettleSec = 90,

    [switch]$KeepIso,           # keep staged + datastore ISOs after a successful deploy
    [string]$WslDistro,         # wsl.exe -d <distro> used to run xorriso on a Windows host
    [string]$XorrisoCommand,    # native xorriso command (when running under pwsh on Linux/macOS)

    # --- Registration method ---------------------------------------------------
    # 'Rest'   : register over the Veeam REST API (:9419) - version-independent, non-interactive
    #            by design (cert fingerprint via /connectionCertificate). RECOMMENDED.
    # 'Cmdlet' : register with Veeam.Backup.PowerShell cmdlets (needs the console installed).
    [ValidateSet('Rest', 'Cmdlet')]
    [string]$RegisterVia = 'Rest',

    [int]$VBRRestPort = 9419,
    # x-api-version header. VBR 13.1 = '1.3-rev2' (current Help Center REST reference). A v13.0
    # GA server only accepts up to '1.3-rev1' (verified 2026-07-06 on the lab VBR) - pass that
    # explicitly when registering against a 13.0 VBR. HTTP 400 "does not support the API version"
    # means the header is above the server's ceiling.
    [string]$ApiVersion = '1.3-rev2',
    [switch]$SkipTlsVerify,             # skip TLS validation on the VBR REST endpoint (lab/self-signed)

    # --- Appliance pairing + proxy settings (Stage B) --------------------------
    # First-time pairing of a fresh VIA uses 000000 (Veeam Add-VBRLinux reference). A CSV column
    # 'handshakecode' overrides per row (needed only when re-pairing to a different VBR).
    [string]$HandshakeCode = '000000',
    [ValidateSet('Auto', 'HotAdd', 'Nbd', 'DirectStorageAccess')]
    [string]$TransportMode = 'Auto',
    [switch]$NoFailoverToNbd,
    # Max wait for the VBR's async "add managed server" session. Seen live: when the appliance build
    # is older than the VBR, the add includes "Appliance OS upgrade is required" + mandatory updates
    # and runs far longer than a plain add. Use a matching ISO build to keep adds short.
    [int]$RegisterTimeoutSec = 3600,

    # --- MFA (REST) ------------------------------------------------------------
    # When the VBR account is MFA-enforced (v13 appliance default), the OAuth2 password grant
    # returns an mfa_token instead of an access_token; the script computes the current TOTP code
    # from this Base32 shared secret and completes the second-leg exchange (grant_type=Mfa).
    # Provide the secret directly or via a protected file (first non-empty, non-# line is used).
    # Leave both empty for non-MFA accounts (plain password grant).
    [string]$VBRMfaSecret,
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$VBRMfaSecretFile,

    [switch]$SkipDeploy,
    [switch]$SkipRegister,
    [switch]$ValidateOnly,

    # --- ISO only: build the ISO(s) for someone else to boot; no vCenter, no VBR ---
    [switch]$IsoOnly,
    [switch]$SingleIso,         # with -IsoOnly: ONE ISO, one boot-menu entry per CSV row
    [string]$IsoOutDir,         # where -IsoOnly writes the ISO(s) + VM build sheet (default <CSV dir>/iso-out)
    [switch]$PromptIso,         # with -IsoOnly: ONE generic ISO that asks for hostname + NIC 1/NIC 2 settings at install time
    [switch]$Rollback,
    [switch]$RollbackOnFailure,

    # --- Replace mode: redeploy over a proxy that already exists in VBR and keep its job assignments ---
    [switch]$Replace,
    [ValidateSet('Auto', 'Disable')][string]$ReplaceJobPolicy = 'Auto',
    [switch]$PurgeOldVm,

    [string]$ReportPath,

    # --- Parallel deployment ---------------------------------------------------
    # Deploy up to N rows at the same time. The run becomes an orchestrator: one worker process per row
    # (this same script, a one-row CSV, its own staging folder, vCenter/VBR session and report), at most N at
    # once, starts staggered by -ParallelStaggerSec. Log lines carry the row's host name; one merged report.
    # Applies to deploy / register runs; -ValidateOnly, -Rollback and -IsoOnly stay sequential.
    [ValidateRange(1, 16)][int]$Parallel = 1,
    [ValidateRange(0, 600)][int]$ParallelStaggerSec = 45,
    # Internal (set by the orchestrator for its workers): lock file that keeps TOTP codes unique across workers.
    [Parameter(DontShow)][string]$TotpLockFile,
    # Internal: set by the orchestrator on its workers (no further dispatch; the report is always written for it).
    [Parameter(DontShow)][switch]$ParallelWorker
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Parameters the operator actually passed: VSA rows use their product's sizing for the -Vm* values
# that were NOT given (Get-RowVmSize).
$script:BoundParams = @{} + $PSBoundParameters
$script:ParallelTmp = $null

# Host OS (StrictMode-safe: $IsWindows is undefined on Windows PowerShell 5.1).
$script:IsWindowsHost = if ($PSVersionTable.PSVersion.Major -lt 6) { $true } else { $IsWindows }

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'STEP')][string]$Level = 'INFO'
    )
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture)
    $color = switch ($Level) {
        'ERROR' { 'Red' }; 'WARN' { 'Yellow' }; 'OK' { 'Green' }; 'STEP' { 'Cyan' }; default { 'Gray' }
    }
    Write-Host ("[{0}] [{1,-5}] {2}" -f $ts, $Level, $Message) -ForegroundColor $color
}

# ---------------------------------------------------------------------------
# Dependency bootstrap
# ---------------------------------------------------------------------------
function Install-ModuleIfMissing {
    <#
        Ensures a module is available for the current user. Idempotent: does nothing if a
        matching version is already present. Sets up TLS 1.2, the NuGet provider and trusts
        PSGallery only if an install is actually required.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$Name,
        [version]$MinimumVersion
    )

    $found = Get-Module -ListAvailable -Name $Name |
        Where-Object { -not $MinimumVersion -or $_.Version -ge $MinimumVersion } |
        Sort-Object Version -Descending | Select-Object -First 1

    if ($found) {
        Write-Log "$Name already present (v$($found.Version))." 'OK'
        return
    }

    Write-Log "$Name not found - installing for CurrentUser..." 'STEP'

    if ($PSCmdlet.ShouldProcess($Name, 'Install-Module')) {
        # Modern TLS for PSGallery
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

        if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
            Write-Log "Installing NuGet package provider..." 'INFO'
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
        }

        $repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
        if ($repo -and $repo.InstallationPolicy -ne 'Trusted') {
            Write-Log "Temporarily trusting PSGallery for this install..." 'INFO'
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        }

        $installParams = @{
            Name               = $Name
            Scope              = 'CurrentUser'
            Force              = $true
            AllowClobber       = $true
            SkipPublisherCheck = $true
        }
        if ($MinimumVersion) { $installParams.MinimumVersion = $MinimumVersion }

        Install-Module @installParams
        Write-Log "$Name installed." 'OK'

        # Restore PSGallery policy if we changed it
        if ($repo -and $repo.InstallationPolicy -ne 'Trusted') {
            Set-PSRepository -Name PSGallery -InstallationPolicy $repo.InstallationPolicy
        }
    }

    Import-Module $Name -ErrorAction Stop
}

function Initialize-PowerCLI {
    # PowerCLI 13.4+ (Broadcom) renamed the umbrella meta-module VMware.PowerCLI -> VCF.PowerCLI.
    # We deliberately do NOT import the umbrella under either name: importing it loads EVERY
    # VMware.VimAutomation.* assembly (incl. .Ceip) and, when the umbrella and the core module
    # are both imported - or more than one PowerCLI build is staged - produces
    #   "Could not load file or assembly 'VMware.VimAutomation.Ceip ...'; Assembly with same
    #    name is already loaded".
    # Instead we import ONLY the core command module, whose name (VMware.VimAutomation.Core) is
    # identical under both the old VMware.PowerCLI and the new VCF.PowerCLI packages.
    # Module load is not an infrastructure change: under -WhatIf, PowerCLI's own start-up (Set-Alias, Set-Item
    # function:TabExpansion2 ...) would otherwise print each step, a page of noise per run / parallel worker.
    # A module runs in its own scope tree under the GLOBAL scope, so the global preference matters too.
    $outerWhatIf = $WhatIfPreference; $outerGlobalWhatIf = $global:WhatIfPreference
    $WhatIfPreference = $false; $global:WhatIfPreference = $false
    if (-not (Get-Command -Name Connect-VIServer -ErrorAction SilentlyContinue)) {

        # Ensure PowerCLI is installed. On a dark site it is pre-staged, so this no-ops; only a
        # connected host would reach PSGallery. Accept either packaging name.
        if (-not (Get-Module -ListAvailable -Name 'VMware.VimAutomation.Core')) {
            $pkg = if (Get-Module -ListAvailable -Name 'VCF.PowerCLI') { 'VCF.PowerCLI' } else { 'VMware.PowerCLI' }
            Install-ModuleIfMissing -Name $pkg
        }

        # Import exactly ONE version of the core module (the install step above may already have
        # loaded it via the umbrella - re-check before importing to avoid the assembly clash).
        if (-not (Get-Command -Name Connect-VIServer -ErrorAction SilentlyContinue)) {
            $core = Get-Module -ListAvailable -Name 'VMware.VimAutomation.Core' |
                Sort-Object Version -Descending | Select-Object -First 1
            if (-not $core) {
                throw "PowerCLI core module 'VMware.VimAutomation.Core' not found. Install/stage " +
                      "VCF.PowerCLI (or the legacy VMware.PowerCLI), or run with -SkipDeploy."
            }
            Import-Module $core -ErrorAction Stop
            Write-Log "PowerCLI loaded (VMware.VimAutomation.Core v$($core.Version))." 'OK'
        }
    }
    else {
        Write-Log "PowerCLI already loaded in this session." 'OK'
    }

    # Non-interactive, no CEIP prompt, tolerate self-signed vCenter certs (adjust for prod).
    # NOTE: -Scope User, not -Scope Session. On PowerCLI Core (Linux) the *Session* scope does
    # NOT reliably apply InvalidCertificateAction, so a self-signed vCenter cert (e.g. the VMCA
    # default) still fails Connect-VIServer with "The SSL connection could not be established".
    # -Scope User persists the setting to the PowerCLI config file and applies it on every
    # connect (this deploy host is dedicated to the run, so a persisted setting is acceptable).
    $WhatIfPreference = $outerWhatIf; $global:WhatIfPreference = $outerGlobalWhatIf
    Set-PowerCLIConfiguration -Scope User -InvalidCertificateAction Ignore `
        -ParticipateInCeip $false -Confirm:$false | Out-Null
    Write-Log "PowerCLI ready." 'OK'
}

function Initialize-VeeamModule {
    # v13 ships the Veeam.Backup.PowerShell module with the console. It is NOT on PSGallery,
    # so we can only import it - if it is missing, the Veeam console/PowerShell must be
    # installed on this machine first.
    $mod = Get-Module -ListAvailable -Name 'Veeam.Backup.PowerShell' | Select-Object -First 1
    if (-not $mod) {
        throw "Veeam.Backup.PowerShell module not found. Install the Veeam Backup & Replication " +
              "console/PowerShell on this host (it is not available from the PowerShell Gallery), " +
              "or run with -SkipRegister to do the vSphere deploy only."
    }
    Import-Module Veeam.Backup.PowerShell -ErrorAction Stop
    Write-Log "Veeam PowerShell module ready (v$($mod.Version))." 'OK'
}

# ---------------------------------------------------------------------------
# Veeam REST API client (Stage B, -RegisterVia Rest)
#
# Harvested from BaptisteTellier/autodeploy-web (internal/veeam) - the exact,
# version-independent VBR REST sequence for registering a Linux VMware proxy:
#   OAuth2 token -> connectionCertificate (fingerprint) -> managedServers -> proxies
# All infrastructure ops are async and return a session id to poll. The
# x-api-version header is required on every call. Uses only Invoke-RestMethod
# (built-in) - a first-class Veeam-supported interface, no extra modules.
# ---------------------------------------------------------------------------
$script:Rest = $null

function Get-UniqueTotpCode {
    # Parallel workers log in to the same VBR account, also on every token renewal (~15 min). Two workers in
    # the same 30-second window would send the SAME code, which an MFA server may refuse as a replay. With
    # -TotpLockFile (set by the orchestrator) each worker takes the next unused time step: a worker whose step
    # is already taken waits for the next one (at most 30 s). Without it: plain Get-TotpCode.
    param([Parameter(Mandatory)][string]$Base32Secret)
    if (-not $TotpLockFile) { return Get-TotpCode -Base32Secret $Base32Secret }
    $deadline = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $deadline) {
        $fs = $null
        try { $fs = [System.IO.File]::Open($TotpLockFile, 'OpenOrCreate', 'ReadWrite', 'None') }
        catch [System.IO.IOException] { Start-Sleep -Milliseconds (200 + (Get-Random -Maximum 300)); continue }
        try {
            $buf = [byte[]]::new(64); $n = $fs.Read($buf, 0, 64)
            $last = 0L; [void][long]::TryParse([Text.Encoding]::ASCII.GetString($buf, 0, $n).Trim(), [ref]$last)
            $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); $step = [long][math]::Floor($now / 30)
            if ($step -le $last) { $wait = 30 - ($now % 30) + 1 }
            else {
                $fs.SetLength(0); $b = [Text.Encoding]::ASCII.GetBytes("$step"); $fs.Write($b, 0, $b.Length); $fs.Flush()
                return Get-TotpCode -Base32Secret $Base32Secret
            }
        }
        finally { $fs.Dispose() }
        Write-Log "TOTP: this 30-second code was just used by another worker - waiting ${wait}s for the next one." 'INFO'
        Start-Sleep -Seconds $wait
    }
    throw "TOTP: could not get a unique code within 5 minutes (lock file $TotpLockFile)."
}

function Get-TotpCode {
    # RFC 6238 TOTP (the scheme Veeam appliance MFA uses): HMAC-SHA1 over an 8-byte big-endian
    # counter = floor(unixtime / period), dynamic truncation, mod 10^digits. Pure .NET, no modules.
    param(
        [Parameter(Mandatory)][string]$Base32Secret,
        [int]$Digits = 6,
        [int]$Period = 30,
        [datetime]$UtcNow = [datetime]::UtcNow
    )

    # Base32 decode (RFC 4648, no padding, case-insensitive).
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
    $clean = ($Base32Secret -replace '[^A-Za-z2-7]', '').ToUpperInvariant()
    if (-not $clean) { throw "Get-TotpCode: empty/invalid Base32 secret." }
    $bits = ''
    foreach ($ch in $clean.ToCharArray()) {
        $idx = $alphabet.IndexOf($ch)
        if ($idx -lt 0) { throw "Get-TotpCode: invalid Base32 char '$ch'." }
        $bits += [Convert]::ToString($idx, 2).PadLeft(5, '0')
    }
    $bytes = [System.Collections.Generic.List[byte]]::new()
    for ($i = 0; ($i + 8) -le $bits.Length; $i += 8) {
        $bytes.Add([Convert]::ToByte($bits.Substring($i, 8), 2))
    }
    $key = $bytes.ToArray()
    if ($key.Length -eq 0) { throw "Get-TotpCode: secret decoded to zero bytes." }

    # 8-byte big-endian counter.
    $epoch = [datetime]::new(1970, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
    $counter = [long][math]::Floor(($UtcNow - $epoch).TotalSeconds / $Period)
    $counterBytes = [System.BitConverter]::GetBytes($counter)
    if ([System.BitConverter]::IsLittleEndian) { [array]::Reverse($counterBytes) }

    $hmac = [System.Security.Cryptography.HMACSHA1]::new($key)
    try { $hash = $hmac.ComputeHash($counterBytes) } finally { $hmac.Dispose() }

    # Dynamic truncation (RFC 4226 §5.3).
    $offset = $hash[$hash.Length - 1] -band 0x0f
    $binCode = (($hash[$offset] -band 0x7f) -shl 24) -bor
               (($hash[$offset + 1] -band 0xff) -shl 16) -bor
               (($hash[$offset + 2] -band 0xff) -shl 8) -bor
                ($hash[$offset + 3] -band 0xff)
    $otp = $binCode % [int][math]::Pow(10, $Digits)
    return $otp.ToString().PadLeft($Digits, '0')
}

function Connect-VbrRest {
    [CmdletBinding()]
    param([switch]$Reauth)

    if (-not $Reauth) {
        $extra = @{}
        if ($SkipTlsVerify) {
            if ($PSVersionTable.PSVersion.Major -ge 6) {
                $extra.SkipCertificateCheck = $true   # PS 7+
            }
            else {
                # Windows PowerShell 5.1 - trust all certs for this session
                if (-not ('TrustAllCertsPolicy' -as [type])) {
                    Add-Type -TypeDefinition @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy {
    public static bool Validate(object s, X509Certificate c, X509Chain ch, System.Net.Security.SslPolicyErrors e) { return true; }
}
"@
                }
                [System.Net.ServicePointManager]::ServerCertificateValidationCallback = [TrustAllCertsPolicy]::Validate
                [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
            }
        }
        # Resolve the MFA TOTP secret (direct value wins; else first real line of the file).
        $mfaSecret = $VBRMfaSecret
        if (-not $mfaSecret -and $VBRMfaSecretFile) {
            $mfaSecret = ((Read-ProtectedText -Path $VBRMfaSecretFile -Purpose 'VBR TOTP seed file') -split "`r?`n" |
                Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') } |
                Select-Object -First 1)
            if ($mfaSecret) { $mfaSecret = $mfaSecret.Trim() }
        }
        $script:Rest = @{
            BaseUrl    = "https://{0}:{1}" -f $VBRServer, $VBRRestPort
            ApiVersion = $ApiVersion
            Username   = $VBRCredential.UserName
            Password   = $VBRCredential.GetNetworkCredential().Password
            MfaSecret  = $mfaSecret
            IrmExtra   = $extra
            Token      = $null
        }
    }

    $tokenUri = $script:Rest.BaseUrl.TrimEnd('/') + '/api/oauth2/token'
    $headers  = @{ 'x-api-version' = $script:Rest.ApiVersion; 'Accept' = 'application/json' }
    $extra    = $script:Rest.IrmExtra   # splat requires a plain variable, not a property expr

    # Leg 1 - password grant. On an MFA-enforced account this returns an mfa_token, not a token.
    try {
        $resp = Invoke-RestMethod -Method POST -Uri $tokenUri -Headers $headers `
            -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop @extra `
            -Body @{ grant_type = 'Password'; username = $script:Rest.Username; password = $script:Rest.Password }
    }
    catch {
        $status = $null; try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        if ($status -eq 401) { throw "VBR REST at $($script:Rest.BaseUrl): user name or password rejected (HTTP 401). Check the VBR account (and whether it is MFA-enforced: then supply -VBRMfaSecret*)." }
        if ($status -eq 400) { throw "VBR REST at $($script:Rest.BaseUrl): HTTP 400 - usually the x-api-version '$($script:Rest.ApiVersion)' is above what this VBR supports (13.1 = 1.3-rev2, 13.0 = 1.3-rev1)." }
        throw ("Cannot reach the VBR REST API at $tokenUri : $($_.Exception.Message). " +
               "Check that -VBRServer is the Backup & Replication server itself (not Veeam ONE, Enterprise Manager or vCenter), " +
               "that its REST API service is running on port $VBRRestPort, and that the port is open from this host.")
    }

    if (-not $resp.access_token -and $resp.mfa_token) {
        # Leg 2 - compute the current TOTP and exchange the mfa_token for an access_token.
        if (-not $script:Rest.MfaSecret) {
            throw "VBR REST: account is MFA-enforced (received mfa_token) but no -VBRMfaSecret/-VBRMfaSecretFile was supplied."
        }
        $code = Get-UniqueTotpCode -Base32Secret $script:Rest.MfaSecret
        $resp = Invoke-RestMethod -Method POST -Uri $tokenUri -Headers $headers `
            -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop @extra `
            -Body @{ grant_type = 'Mfa'; mfa_token = $resp.mfa_token; code = $code }
        if (-not $Reauth) { Write-Log "Completed MFA (TOTP) token exchange." 'OK' }
    }

    if (-not $resp.access_token) { throw "VBR REST: no access_token from $($script:Rest.BaseUrl) (MFA secret wrong or account not permitted?)." }
    $script:Rest.Token = $resp.access_token
    if (-not $Reauth) { Write-Log "Authenticated to VBR REST $($script:Rest.BaseUrl) (api $($script:Rest.ApiVersion))." 'OK' }
}

function Invoke-VbrRest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        $Body,
        [switch]$NoReauth
    )
    if (-not $script:Rest -or -not $script:Rest.Token) { throw "VBR REST not connected - call Connect-VbrRest first." }

    $params = @{
        Method      = $Method
        Uri         = $script:Rest.BaseUrl.TrimEnd('/') + $Path
        Headers     = @{
            'Authorization' = "Bearer $($script:Rest.Token)"
            'x-api-version' = $script:Rest.ApiVersion
            'Accept'        = 'application/json'
        }
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $params.Body        = ($Body | ConvertTo-Json -Depth 20 -Compress)   # job models (PUT /jobs/{id}) nest deeper than 10
        $params.ContentType = 'application/json'
    }

    try {
        $extra = $script:Rest.IrmExtra
        return Invoke-RestMethod @params @extra
    }
    catch {
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch {}
        if ($status -eq 401 -and -not $NoReauth) {
            # Token lives ~15 min; a long fleet run re-auths at each 401 boundary.
            Write-Log "REST token expired - re-authenticating..." 'INFO'
            Connect-VbrRest -Reauth
            return Invoke-VbrRest -Method $Method -Path $Path -Body $Body -NoReauth
        }
        # Surface the VBR's own error message (e.g. "Invalid TLS key certificate fingerprint ...")
        # instead of the bare HTTP status - it is what you need to fix a rejected request.
        $detail = $null
        try { if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail = ($_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction Stop).message } } catch { $detail = $_.ErrorDetails.Message }
        if ($detail) { throw "$Method $Path -> HTTP $status : $detail" }
        throw
    }
}

function Wait-VbrRestSession {
    param([string]$SessionId, [int]$TimeoutSec = 900, [int]$PollSec = 10)
    if (-not $SessionId) { return }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        $s = Invoke-VbrRest -Method GET -Path ("/api/v1/sessions/{0}" -f [uri]::EscapeDataString($SessionId))
        $result = if ($s.PSObject.Properties.Name -contains 'result' -and $s.result) { $s.result.result } else { $null }
        $state  = $s.state
        if ($result -eq 'Failed') { throw "VBR REST session $SessionId failed." }
        if ($result -in @('Success', 'Warning')) { return }
        if ($state -eq 'Stopped') { return }
        if ((Get-Date) -gt $deadline) { throw "VBR REST session $SessionId did not finish within ${TimeoutSec}s (state=$state)." }
        Start-Sleep -Seconds $PollSec
    }
}

function Get-VbrRestFingerprint {
    # POST /api/v1/connectionCertificate -> the identity the VBR will pin for this host. The
    # 1.3-rev2 model (live swagger, 2026-09-24) returns 'fingerprint' (SSH hosts) and/or
    # 'certificate' (CertificateModel with 'thumbprint') + 'certificateUpload' (TLS hosts such
    # as the VIA). This value goes into LinuxHostSpec.sshFingerprint - the non-interactive
    # equivalent of accepting the trust dialog. Prefer what the server itself reports.
    param([string]$ServerName, [string]$CredsId)
    # HostConnectionSpec: send ONLY serverName + type. Adding credentialsStorageType=Certificate makes
    # the 13.1.1.18 VBR answer 400 "SingleUseCredentials property must be set" (lab, 2026-09-24);
    # the plain request returns the appliance TLS certificate (verified against vhr01).
    $body = @{ serverName = $ServerName; type = 'LinuxHost' }
    if ($CredsId) { $body.credentialsId = $CredsId }
    $out = Invoke-VbrRest -Method POST -Path '/api/v1/connectionCertificate' -Body $body

    $has = { param($o, $n) ($null -ne $o) -and ($o.PSObject.Properties.Name -contains $n) -and $o.$n }
    # LinuxHostSpec.sshFingerprint for a TLS-trusted appliance must be the SHA-256 hash of the
    # certificate (uppercase hex, no separators). Confirmed live 2026-09-24: the SHA-1
    # 'certificate.thumbprint' is rejected with 400 "Invalid TLS key certificate fingerprint ...
    # <SHA-256>", and that SHA-256 equals the hash of the certificate in 'certificateUpload'.
    if ((& $has $out 'certificateUpload') -and (& $has $out.certificateUpload 'certificate')) {
        $raw = [Convert]::FromBase64String($out.certificateUpload.certificate)
        try { $x = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($raw); $raw = $x.RawData } catch { }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return (([BitConverter]::ToString($sha.ComputeHash($raw))) -replace '-', '') } finally { $sha.Dispose() }
    }
    if (& $has $out 'fingerprint') { return ([string]$out.fingerprint).Trim() }          # SSH hosts
    if ((& $has $out 'certificate') -and (& $has $out.certificate 'thumbprint')) { return ([string]$out.certificate.thumbprint).Trim() }   # last resort (SHA-1)
    throw "VBR REST: no certificate / fingerprint returned for $ServerName."
}

function Find-VbrRestManagedServer {
    param([string]$Name)
    $out = Invoke-VbrRest -Method GET -Path ("/api/v1/backupInfrastructure/managedServers?nameFilter={0}&limit=10" -f [uri]::EscapeDataString($Name))
    foreach ($s in $out.data) { if ($s.name -eq $Name) { return $s.id } }
    return $null
}

function Find-VbrRestProxyByHost {
    param([string]$HostId)
    $out = Invoke-VbrRest -Method GET -Path '/api/v1/backupInfrastructure/proxies?limit=200'
    foreach ($p in $out.data) { if ($p.server -and $p.server.hostId -eq $HostId) { return $p.id } }
    return $null
}

function Add-VbrRestLinuxHost {
    # POST managedServers (async -> session id). Certificate-based trust, non-interactive.
    param([string]$Name, [string]$Fingerprint, [string]$HandshakeCode, [string]$Description)
    $body = @{
        type                   = 'LinuxHost'
        name                   = $Name
        description            = $Description
        credentialsStorageType = 'Certificate'
        sshFingerprint         = $Fingerprint
    }
    if ($HandshakeCode) { $body.handshakeCode = $HandshakeCode }
    return Invoke-VbrRest -Method POST -Path '/api/v1/backupInfrastructure/managedServers' -Body $body
}

function Get-RegistrationName {
    # Name or address the VBR uses to add (and later find/remove) the appliance. Optional CSV column
    # 'vbrname' (an FQDN the VBR can resolve, or the IP) wins; otherwise the kickstart hostname.
    param($Row)
    if (($Row.PSObject.Properties.Name -contains 'vbrname') -and -not [string]::IsNullOrWhiteSpace($Row.vbrname)) {
        return ([string]$Row.vbrname).Trim()
    }
    return $Row.hostname
}

function Resolve-HandshakeCode {
    # Per-row 'handshakecode' CSV column wins; else the script default (000000 = first pairing of a
    # fresh appliance, per the Veeam Add-VBRLinux reference).
    param($Row)
    if (($Row.PSObject.Properties.Name -contains 'handshakecode') -and -not [string]::IsNullOrWhiteSpace($Row.handshakecode)) {
        return ([string]$Row.handshakecode).Trim()
    }
    return $HandshakeCode
}

function ConvertTo-RestTransportMode {
    # Script/cmdlet names -> REST enum EBackupProxyTransportMode. Values confirmed in the live
    # 1.3-rev2 OpenAPI spec (2026-09-24): Auto | DirectAccess | VirtualAppliance | Network.
    param([string]$Mode)
    switch ($Mode) {
        'HotAdd'              { return 'VirtualAppliance' }
        'Nbd'                 { return 'Network' }
        'DirectStorageAccess' { return 'DirectAccess' }
        default               { return 'Auto' }
    }
}

function Add-VbrRestVmwareProxy {
    # POST proxies (async -> session id). Field layout confirmed 2026-09-24 against a live
    # 13.1.1.18 VBR (GET /backupInfrastructure/proxies): maxTaskCount, transportMode,
    # failoverToNetwork, hostToProxyEncryption and connectedDatastores ALL live inside 'server'.
    param([string]$HostId, [int]$MaxTasks)
    if ($MaxTasks -le 0) { $MaxTasks = 4 }
    $body = @{
        type        = 'ViProxy'
        description = 'VIA proxy (autodeploy)'
        server      = @{
            hostId                = $HostId
            maxTaskCount          = $MaxTasks
            transportMode         = (ConvertTo-RestTransportMode -Mode $TransportMode)
            failoverToNetwork     = (-not $NoFailoverToNbd)
            hostToProxyEncryption = $false
            connectedDatastores   = @{ autoSelectEnabled = $true }
        }
    }
    return Invoke-VbrRest -Method POST -Path '/api/v1/backupInfrastructure/proxies' -Body $body
}

function Test-RegistrationNames {
    # The VBR adds the appliance under its registration name (CSV 'vbrname', else 'hostname'). A name
    # without a DNS record fails only after the 25-minute deploy ("Failed to get certificate from:
    # https://<name>:443/"), so resolve the names here first - this host's DNS is usually the VBR's too.
    # Warning only: registration falls back to the IP when the VBR cannot resolve the name.
    param([Parameter(Mandatory)]$Rows)
    $bad = [System.Collections.Generic.List[string]]::new(); $mismatch = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $Rows) {
        $n = Get-RegistrationName -Row $r
        if ($n -match '^\d{1,3}(\.\d{1,3}){3}$') { continue }
        try {
            $addrs = @([System.Net.Dns]::GetHostAddresses($n) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.IPAddressToString })
            # A record that points elsewhere = the VBR would talk to another machine (a stale record from
            # the proxy being replaced is the classic case - lab, 2026-09-28).
            if ($r.ip -and $addrs.Count -and ($addrs -notcontains [string]$r.ip)) { $mismatch.Add("$n -> $($addrs -join ',') but CSV ip is $($r.ip)") }
        }
        catch { $bad.Add($n) }
    }
    if ($mismatch.Count) {
        Write-Log (("DNS points {0} registration name(s) at a DIFFERENT address than the CSV: {1}. If the VBR sees the same, Stage B stops with a certificate mismatch " +
                    "instead of registering the wrong machine. Fix the A record (New-ProxyDnsRecords.ps1 -UpdateExisting) or set CSV 'vbrname' to the IP.") -f $mismatch.Count, (($mismatch | Select-Object -First 10) -join '; ')) 'WARN'
    }
    if ($bad.Count) {
        Write-Log (("{0} registration name(s) do not resolve from this host: {1}. If the VBR cannot resolve them either, they are registered by IP (logged as a warning). " +
                    "To register by name, create the A records first (New-ProxyDnsRecords.ps1) or set CSV 'vbrname'.") -f $bad.Count, (($bad | Select-Object -First 10) -join ', ')) 'WARN'
    }
    if (-not $bad.Count -and -not $mismatch.Count) { Write-Log "All $($Rows.Count) registration name(s) resolve from this host to the CSV addresses." 'OK' }
}

function Invoke-StageB-Register-Rest {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param($Row, [int]$AddAttempts = 3, [int]$AddRetrySec = 60)

    $regName = Get-RegistrationName -Row $Row
    $roles = Get-RowRoles -Row $Row
    Write-Log ("Stage B (REST): registering '{0}' -> managedServers{1}{2}" -f $regName, $(if ($roles.Proxy) { ' + proxy' } else { '' }), $(if ($roles.Gateway) { ' + gateway' } else { '' })) 'STEP'

    # Idempotency - skip host add if already registered. But an existing object that is NOT Available is
    # almost always the previous appliance's identity (VM rebuilt or gone): a fresh appliance can never
    # take it over, and "skipping add" would report success while the proxy stays Unavailable. Stop and
    # point at -Replace instead (the old VM may have been powered off and renamed by hand first).
    $hostId = Find-VbrRestManagedServer -Name $regName
    if ($hostId) {
        $ms = Invoke-VbrRest -Method GET -Path ("/api/v1/backupInfrastructure/managedServers/{0}" -f [uri]::EscapeDataString($hostId))
        $msStatus = if ($ms.PSObject.Properties['status']) { [string]$ms.status } else { '' }
        if ($msStatus -and $msStatus -ne 'Available' -and -not $Replace) {
            throw (("'{0}' already exists in the VBR but its status is '{1}': that object belongs to the previous appliance and a fresh one cannot " +
                    "take it over. Rerun this row with -Replace (captures the job pinning, removes the old object, re-adds and re-pins), or wait if the proxy is only briefly offline.") -f $regName, $msStatus)
        }
        Write-Log "'$regName' already a managed server (status $msStatus) - skipping add." 'WARN'
    }
    elseif ($PSCmdlet.ShouldProcess($regName, "POST managedServers (certificate trust + handshake code)")) {
        $handshake = Resolve-HandshakeCode -Row $Row
        $lastErr = $null
        # A fresh appliance can still be finishing its first-boot Initial Configuration when the
        # HMC port first answers - retry the certificate fetch + add a few times.
        for ($attempt = 1; $attempt -le $AddAttempts; $attempt++) {
            try {
                $fp = Get-VbrRestFingerprint -ServerName $regName
                Write-Log "Certificate thumbprint/fingerprint for '$regName': $fp" 'INFO'
                if ($regName -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -and $Row.ip) {
                    # Cross-check with the VBR's own view: the certificate it sees under the NAME must be the
                    # one it sees at the row's IP. If not, DNS points the name at another machine (a stale
                    # record from the proxy being replaced) and we must not register that machine.
                    $fpIp = Get-VbrRestFingerprint -ServerName ([string]$Row.ip)
                    if ($fpIp -ne $fp) {
                        throw (("DNS mismatch: from '{0}' the VBR gets certificate {1}, from {2} it gets {3}. The name points at a different machine (stale A record?). " +
                                "Fix DNS (New-ProxyDnsRecords.ps1 -UpdateExisting) or set CSV 'vbrname' to the IP. Not retried.") -f $regName, $fp, $Row.ip, $fpIp)
                    }
                }
                # The name was free a moment ago (find-before-add above), so whatever the VBR holds under it from here on is ours to roll back.
                if ($script:Owned) { $script:Owned.VbrAdded = $true }
                $res = Add-VbrRestLinuxHost -Name $regName -Fingerprint $fp -HandshakeCode $handshake -Description "$(Get-RoleLabel -Row $Row) $($Row.hostname) (autodeploy)"
                if ($res.id) {
                    Write-Log "Add accepted (session $($res.id)); waiting up to ${RegisterTimeoutSec}s for the VBR to deploy components (an appliance OS upgrade may be included)..." 'INFO'
                    Wait-VbrRestSession -SessionId $res.id -TimeoutSec $RegisterTimeoutSec
                }
                break
            }
            catch {
                # "Failed to get certificate from: https://<name>:443/" means the VBR could not resolve or
                # reach the appliance under that NAME (typically: no DNS record yet). Waiting will not fix
                # DNS, so fall back to the row's IP address at once and say so (seen in the lab: without the
                # fallback, all three attempts burned 60 s each on a name with no DNS record).
                if ($_.Exception.Message -like 'DNS mismatch:*') { throw }   # configuration problem: retrying cannot help
                # "Failed to verify the client connection token" = the appliance is already paired. Either
                # someone added it to THIS VBR meanwhile (seen in the lab: the host was added by hand in the
                # console while the run was retrying) - then the object exists now and we simply continue with the proxy
                # role - or it belongs to ANOTHER VBR, which needs that appliance's pairing code (CSV 'handshakecode').
                if ($_.Exception.Message -match 'client connection token') {
                    $hostId = Find-VbrRestManagedServer -Name $regName
                    if (-not $hostId -and $Row.ip) { $hostId = Find-VbrRestManagedServer -Name ([string]$Row.ip) }
                    if ($hostId) { Write-Log "'$regName' was added to this VBR by someone else meanwhile (id $hostId) - continuing with the proxy role." 'WARN'; break }
                    if ($attempt -ge $AddAttempts) {
                        throw (("The appliance '{0}' rejected the pairing with handshake code {1} ('client connection token'): it is already paired with a backup server " +
                                "that is not this one. Re-home it with the pairing code shown on the appliance console (CSV 'handshakecode'), or redeploy it fresh.") -f $regName, $handshake)
                    }
                }
                $isIp = $regName -match '^\d{1,3}(\.\d{1,3}){3}$'
                if (-not $isIp -and $Row.ip -and $_.Exception.Message -match 'Failed to get certificate from') {
                    Write-Log (("The VBR could not fetch the certificate from '{0}' - it cannot resolve or reach that name (no DNS record?). " +
                                "Falling back to the IP {1}: the appliance will be registered by address. Create the A/PTR record " +
                                "(New-ProxyDnsRecords.ps1) or set CSV 'vbrname' to register by name next time.") -f $regName, $Row.ip) 'WARN'
                    $regName = [string]$Row.ip
                    $hostId = Find-VbrRestManagedServer -Name $regName
                    if ($hostId) { Write-Log "'$regName' already a managed server - skipping add." 'WARN'; break }
                    $attempt--          # the switch to the IP must not consume one of the add attempts
                    continue
                }
                $lastErr = $_.Exception.Message
                if ($attempt -ge $AddAttempts) { throw }
                Write-Log "Add attempt $attempt/$AddAttempts for '$regName' failed: $($_.Exception.Message) - retrying in ${AddRetrySec}s." 'WARN'
                Start-Sleep -Seconds $AddRetrySec
            }
        }
        if (-not $hostId) { $hostId = Find-VbrRestManagedServer -Name $regName }
        if (-not $hostId) { throw ("Managed server '{0}' not found after the add attempts.{1}" -f $regName, $(if ($lastErr) { " Last error: $lastErr" } else { '' })) }
        Write-Log "Managed server '$regName' present (id $hostId)." 'OK'
    }

    if (-not $hostId) { return }   # -WhatIf path: nothing was added

    # VMware Linux proxy role + transport + task slots (REST equivalent of Add-VBRViLinuxProxy)
    if ($roles.Proxy) {
        $proxyId = Find-VbrRestProxyByHost -HostId $hostId
        if ($proxyId) {
            Write-Log "Proxy already registered on '$($Row.hostname)' - skipping." 'WARN'
        }
        elseif ($PSCmdlet.ShouldProcess($Row.hostname, "POST proxies (ViProxy, maxTaskCount=$($Row.tasks), transport=$TransportMode)")) {
            $res = Add-VbrRestVmwareProxy -HostId $hostId -MaxTasks ([int]$Row.tasks)
            if ($res.id) { Wait-VbrRestSession -SessionId $res.id -TimeoutSec 600 }
            Write-Log "Assigned VMware proxy role ($($Row.tasks) tasks, $TransportMode$(if (-not $NoFailoverToNbd) { ' + NBD failover' })) to '$($Row.hostname)'." 'OK'
        }
    }

    # Gateway server for Data Domain / StoreOnce repositories (CSV 'gatewayrepo').
    if ($roles.Gateway) { $null = Add-VbrRestGatewayToRepositories -Row $Row -HostId $hostId }
}

function Test-ProxyRegisteredRest {
    # True when the row's roles are in place: managed server, proxy (viproxy), and a gateway entry in every
    # repository named in 'gatewayrepo' (gateway).
    param($Row)
    $hostId = Find-VbrRestManagedServer -Name (Get-RegistrationName -Row $Row)
    if (-not $hostId -and $Row.ip) { $hostId = Find-VbrRestManagedServer -Name ([string]$Row.ip) }
    if (-not $hostId) { return $false }
    $roles = Get-RowRoles -Row $Row
    if ($roles.Proxy -and -not (Find-VbrRestProxyByHost -HostId $hostId)) { return $false }
    $want = @(Get-GatewayRepoNames -Row $Row)
    if ($roles.Gateway -and $want.Count) {
        $have = @(Get-VbrRestGatewayReferences -HostId $hostId | ForEach-Object { $_.repoName })
        if (@($want | Where-Object { $_ -notin $have }).Count) { return $false }
    }
    return $true
}

# ---------------------------------------------------------------------------------------------------------
# Replace mode (2026-09-28): redeploy over an existing proxy WITHOUT losing its job assignments.
# The VBR keeps the OLD appliance identity under the name, so a fresh appliance can never be re-added on
# top of it (console: "Unavailable", "Failed to update identity service configuration"). The supported
# path is remove + add, and removing the proxy silently drops it from every job that pins it. Hence:
# capture -> release -> (deploy) -> register -> restore, with a manifest on disk so an interrupted run
# can still restore. Job lists per the live 1.3-rev2 swagger: VSphereBackup -> storage.backupProxies,
# VSphereReplica -> dataTransfer.sourceProxies / targetProxies (autoSelectEnabled + proxyIds); a job is
# updated by PUT of the whole model. Repository proxy affinity is NOT in the REST API (cmdlets only).
# ---------------------------------------------------------------------------------------------------------
function Get-ObjectPath {
    param($Object, [string]$Path)
    $n = $Object
    foreach ($seg in ($Path -split '\.')) {
        if ($null -eq $n) { return $null }
        $prop = $n.PSObject.Properties[$seg]
        if (-not $prop) { return $null }
        $n = $prop.Value
    }
    return $n
}

function Get-VbrRestAllJobs {
    $all = [System.Collections.Generic.List[object]]::new(); $skip = 0; $limit = 200
    while ($true) {
        $page = Invoke-VbrRest -Method GET -Path "/api/v1/jobs?limit=$limit&skip=$skip"
        $items = @($page.data); foreach ($j in $items) { $all.Add($j) }
        if ($items.Count -lt $limit) { break }
        $skip += $limit
    }
    return $all
}

function Get-VbrRestProxyReferences {
    # Every job list that pins this proxy id.
    param([Parameter(Mandatory)][string]$ProxyId)
    $refs = [System.Collections.Generic.List[object]]::new()
    foreach ($j in (Get-VbrRestAllJobs)) {
        $paths = switch ($j.type) {
            'VSphereBackup'  { @('storage.backupProxies') }
            'VSphereReplica' { @('dataTransfer.sourceProxies', 'dataTransfer.targetProxies') }
            default          { @() }
        }
        foreach ($p in $paths) {
            $node = Get-ObjectPath -Object $j -Path $p
            if ($node -and ($node.PSObject.Properties['proxyIds']) -and (@($node.proxyIds) -contains $ProxyId)) {
                $refs.Add([pscustomobject]@{
                    jobId = $j.id; jobName = $j.name; jobType = $j.type; path = $p
                    autoSelectEnabled = [bool]$node.autoSelectEnabled; proxyIds = @($node.proxyIds); wasDisabled = [bool]$j.isDisabled
                })
            }
        }
    }
    return $refs
}

function Set-VbrRestJobProxyList {
    # GET the job, change ONE proxy list, PUT the whole model back (the API has no partial update).
    param([Parameter(Mandatory)][string]$JobId, [Parameter(Mandatory)][string]$Path, [string[]]$ProxyIds, [bool]$AutoSelect)
    $job  = Invoke-VbrRest -Method GET -Path ("/api/v1/jobs/{0}" -f [uri]::EscapeDataString($JobId))
    $node = Get-ObjectPath -Object $job -Path $Path
    if (-not $node) { throw "Job '$($job.name)': '$Path' not found in the job model." }
    $node.autoSelectEnabled = $AutoSelect
    $node.proxyIds = @($ProxyIds)
    Invoke-VbrRest -Method PUT -Path ("/api/v1/jobs/{0}" -f [uri]::EscapeDataString($JobId)) -Body $job | Out-Null
}

function Get-VbrRestProxyById { param([Parameter(Mandatory)][string]$ProxyId) Invoke-VbrRest -Method GET -Path ("/api/v1/backupInfrastructure/proxies/{0}" -f [uri]::EscapeDataString($ProxyId)) }
function Remove-VbrRestProxy  { param([Parameter(Mandatory)][string]$ProxyId) Invoke-VbrRest -Method DELETE -Path ("/api/v1/backupInfrastructure/proxies/{0}" -f [uri]::EscapeDataString($ProxyId)) | Out-Null }   # 204

# ---------------------------------------------------------------------------------------------------------
# Gateway server role (2026-09-30). The VIA "Infrastructure Server" install can hold the Gateway Server role
# (helpcenter.veeam.com/docs/vbr/userguide/linux_infrastructure_appliance_byb.html?ver=13). Of the
# deduplicating storage appliances only Dell Data Domain and HPE StoreOnce use a gateway; ExaGrid, Quantum
# DXi, ETERNUS CS800 and InfiniGuard run the Data Mover on the appliance itself (gateway_server.html?ver=13).
# The REST API has no gateway object: a gateway is a managed server whose id sits in the repository's
# '<type>.gatewayServer' = { autoSelection, gatewayServerIds } (1.3-rev2 RepositoryModel), changed by GET +
# PUT of the whole repository. Field names are from the 1.3-rev2 spec - lab-confirm on a real DD/StoreOnce.
# ---------------------------------------------------------------------------------------------------------
$script:GatewayRepoPaths = @{ DellDataDomain = 'dellDataDomain.gatewayServer'; HPEStoreOnce = 'hpeStoreOnce.gatewayServer' }

function Get-RowRoles {
    # CSV 'role': viproxy | gateway | viproxy+gateway (order, case and spaces ignored). Empty = add the
    # managed server only. vbr / em = a Veeam Software Appliance (backup server / Enterprise Manager),
    # never combined with anything. Unknown tokens are returned so the CSV load can refuse them.
    param($Row)
    $parts = @(([string]$Row.role).ToLowerInvariant() -split '[+;, ]+' | Where-Object { $_ })
    [pscustomobject]@{
        Proxy   = $parts -contains 'viproxy'
        Gateway = $parts -contains 'gateway'
        Vbr     = $parts -contains 'vbr'
        Em      = $parts -contains 'em'
        Count   = $parts.Count
        Unknown = @($parts | Where-Object { $_ -notin @('viproxy', 'gateway', 'vbr', 'em') })
    }
}

function Get-RoleLabel {
    param($Row)
    $p = Get-RowVsaProduct -Row $Row
    if ($p) { return $p.Label }
    $r = Get-RowRoles -Row $Row
    if ($r.Proxy -and $r.Gateway) { return 'VIA proxy+gateway' }
    if ($r.Gateway) { return 'VIA gateway' }
    return 'VIA proxy'
}

# Veeam Software Appliance (VSA) rows - CSV role 'vbr' or 'em'. Both products come from the SAME
# VeeamSoftwareAppliance_13.1.x ISO (volume label VeeamSA); unlike the 13.1 VIA, the product is picked
# by the BOOT MENU: one kickstart and one submenu per product. Kickstart names and entry titles read
# from VeeamSoftwareAppliance_13.1.1.18_20260825.iso. The stock grub default of that ISO is the VBR
# *Reinstall* entry - the build always sets the product's fresh-install entry instead.
# Both kickstarts use the same disk layout (vbr_server_disk_layout.json): disk 1 (system) AND disk 2
# (data) of at least 240 GB each - the installer stops on a smaller or missing disk.
# Sizing (Help Center, ver=13): backup server 8 vCPU / 16 GB (+500 MB per concurrent job); Enterprise
# Manager 2 vCPU / 6 GB minimum, 4 vCPU / 16 GB recommended. Readiness port: 443 for both (13.x moved
# the VBR REST API to 443 next to the web UI; 9419 is kept for Swagger / backward compatibility).
$script:VsaMinDiskGB = 240
# Install + first boot of a VSA takes far longer than a proxy: lab 2026-10-14, the unattended VBR install was
# at package 692 of 771 after 30 minutes (proxy-sized -IsoReadyTimeoutSec 1800 timed out, the run rolled the
# healthy VM back). VSA rows wait this long unless -IsoReadyTimeoutSec is given.
$script:VsaReadyTimeoutSec = 7200
$script:VsaProducts = @{
    vbr = [pscustomobject]@{
        Key = 'vbr'; Label = 'VSA Backup & Replication'; Kickstart = 'vbr-ks.cfg'
        Grub = 'Veeam Backup & Replication>Install - fresh install, wipes everything (including local backups)'
        Cpu = 8; MemoryGB = 16; DiskGB = 240; DataDiskGB = 240
        ServicePort = 443; ServiceName = 'VBR web UI / REST API'
    }
    em  = [pscustomobject]@{
        Key = 'em'; Label = 'VSA Enterprise Manager'; Kickstart = 'vbem-ks.cfg'
        Grub = 'Veeam Backup Enterprise Manager>Install - fresh install, wipes everything'
        Cpu = 4; MemoryGB = 16; DiskGB = 240; DataDiskGB = 240
        ServicePort = 443; ServiceName = 'Enterprise Manager web UI'
    }
}

function Get-RowVsaProduct {
    # The VSA product of a row ($null for a VIA row).
    param($Row)
    $r = Get-RowRoles -Row $Row
    if ($r.Vbr) { return $script:VsaProducts.vbr }
    if ($r.Em)  { return $script:VsaProducts.em }
    return $null
}

function Get-RowKickstart {
    # Kickstart inside the base ISO for this row: per product on the VSA, -KickstartName on the VIA.
    param($Row)
    $p = Get-RowVsaProduct -Row $Row
    if ($p) { return $p.Kickstart }
    return $KickstartName
}

function Get-RowVmSize {
    # VM hardware for a row. VIA rows: the -Vm* parameters as given. VSA rows: the product's sizing
    # unless the operator passed the parameter, always two disks (the VSA has no single-disk layout).
    param($Row)
    $p = Get-RowVsaProduct -Row $Row
    if (-not $p) {
        return [pscustomobject]@{ Cpu = $VmCpu; MemoryGB = $VmMemoryGB; DiskGB = $VmDiskGB; MultiDisk = [bool]$MultiDisk; DataDiskGB = $VmDataDiskGB }
    }
    $pick = { param($name, $def) if ($script:BoundParams.ContainsKey($name)) { $script:BoundParams[$name] } else { $def } }
    [pscustomobject]@{
        Cpu        = & $pick 'VmCpu' $p.Cpu
        MemoryGB   = & $pick 'VmMemoryGB' $p.MemoryGB
        DiskGB     = & $pick 'VmDiskGB' $p.DiskGB
        MultiDisk  = $true
        DataDiskGB = & $pick 'VmDataDiskGB' $p.DataDiskGB
    }
}

function Get-GatewayRepoNames {
    # Optional CSV 'gatewayrepo': existing Data Domain / StoreOnce repository names, ';'-separated.
    param($Row)
    if ($Row.PSObject.Properties.Name -notcontains 'gatewayrepo') { return @() }
    return @(([string]$Row.gatewayrepo) -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-RowNic2 {
    # Optional CSV columns ip2 / netmask2 / portgroup2 = a second network adapter (static, no
    # gateway, no default route). All three or none; returns $null when the row has no second NIC.
    param($Row)
    $names = $Row.PSObject.Properties.Name
    $v = @{}
    foreach ($c in 'ip2', 'netmask2', 'portgroup2') { $v[$c] = if ($names -contains $c) { ([string]$Row.$c).Trim() } else { '' } }
    $set = @(@('ip2', 'netmask2', 'portgroup2') | Where-Object { $v[$_] })
    if (-not $set.Count) { return $null }
    if ($set.Count -ne 3) { throw "Row '$($Row.hostname)': a second NIC needs ip2, netmask2 AND portgroup2 (given: $($set -join ', '))." }
    return [pscustomobject]@{ Ip = $v['ip2']; Netmask = $v['netmask2']; PortGroup = $v['portgroup2'] }
}

function Set-ObjectProperty {
    # StrictMode-safe set on a PSCustomObject from ConvertFrom-Json (a missing property cannot be assigned).
    param($Object, [string]$Name, $Value)
    if ($Object.PSObject.Properties[$Name]) { $Object.$Name = $Value } else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Get-ManifestList {
    # Replace manifests are an ordered dictionary (fresh capture) or a PSCustomObject (read back from disk,
    # possibly written before a key existed). Returns the list, or an empty one.
    param($Manifest, [string]$Key)
    if ($Manifest -is [System.Collections.IDictionary]) { if ($Manifest.Contains($Key)) { return @($Manifest[$Key]) } else { return @() } }
    if ($Manifest.PSObject.Properties[$Key]) { return @($Manifest.$Key) }
    return @()
}

function Get-VbrRestAllRepositories {
    $all = [System.Collections.Generic.List[object]]::new(); $skip = 0; $limit = 200
    while ($true) {
        $page = Invoke-VbrRest -Method GET -Path "/api/v1/backupInfrastructure/repositories?limit=$limit&skip=$skip"
        $items = @($page.data); foreach ($r in $items) { $all.Add($r) }
        if ($items.Count -lt $limit) { break }
        $skip += $limit
    }
    return $all
}

function Get-VbrRestRepositoryGatewayNode {
    # The repository's gateway settings node, or $null for a type without a gateway.
    param($Repository)
    $path = $script:GatewayRepoPaths[[string]$Repository.type]
    if (-not $path) { return $null }
    return Get-ObjectPath -Object $Repository -Path $path
}

function Set-VbrRestRepositoryGateways {
    # GET the repository, replace its gateway list, PUT the whole model back (no partial update).
    param([Parameter(Mandatory)][string]$RepositoryId, [string[]]$HostIds, [bool]$AutoSelect)
    $repo = Invoke-VbrRest -Method GET -Path ("/api/v1/backupInfrastructure/repositories/{0}" -f [uri]::EscapeDataString($RepositoryId))
    $node = Get-VbrRestRepositoryGatewayNode -Repository $repo
    if (-not $node) { throw "Repository '$($repo.name)' (type $($repo.type)): no gateway settings in the repository model." }
    Set-ObjectProperty -Object $node -Name 'autoSelection' -Value $AutoSelect
    Set-ObjectProperty -Object $node -Name 'gatewayServerIds' -Value @($HostIds)
    $res = Invoke-VbrRest -Method PUT -Path ("/api/v1/backupInfrastructure/repositories/{0}" -f [uri]::EscapeDataString($RepositoryId)) -Body $repo
    # Edit Repository answers with a session model; wait for it so a failure surfaces here.
    if ($res -and $res.PSObject.Properties['sessionType'] -and $res.PSObject.Properties['id']) { Wait-VbrRestSession -SessionId $res.id -TimeoutSec 600 }
}

function Get-VbrRestGatewayReferences {
    # Every Data Domain / StoreOnce repository whose explicit gateway list holds this managed server.
    param([Parameter(Mandatory)][string]$HostId)
    $refs = [System.Collections.Generic.List[object]]::new()
    foreach ($repo in (Get-VbrRestAllRepositories)) {
        $node = Get-VbrRestRepositoryGatewayNode -Repository $repo
        if ($node -and $node.PSObject.Properties['gatewayServerIds'] -and (@($node.gatewayServerIds) -contains $HostId)) {
            $refs.Add([pscustomobject]@{
                repoId = $repo.id; repoName = $repo.name; repoType = $repo.type
                autoSelection = [bool](Get-ObjectPath -Object $node -Path 'autoSelection'); gatewayServerIds = @($node.gatewayServerIds)
            })
        }
    }
    return $refs
}

function Add-VbrRestGatewayToRepositories {
    # Put the managed server into the gateway list of every repository named in CSV 'gatewayrepo'.
    # Without 'gatewayrepo' the appliance is only added as a managed server; it can then be picked as
    # gateway in the repository settings. Returns the number of repositories changed.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param($Row, [Parameter(Mandatory)][string]$HostId)
    $names = @(Get-GatewayRepoNames -Row $Row)
    if (-not $names.Count) {
        Write-Log "'$($Row.hostname)' is a managed server and can be selected as gateway server for a Data Domain / StoreOnce repository (no CSV 'gatewayrepo' given, no repository changed)." 'INFO'
        return 0
    }
    $repos = @(Get-VbrRestAllRepositories)
    $n = 0
    foreach ($name in $names) {
        $hit = @($repos | Where-Object { $_.name -eq $name })
        if (-not $hit.Count) { throw "Gateway: repository '$name' (CSV 'gatewayrepo') does not exist in this VBR. Create the Data Domain / StoreOnce repository first, or fix the name." }
        $repo = $hit[0]
        if (-not $script:GatewayRepoPaths.ContainsKey([string]$repo.type)) {
            throw ("Gateway: repository '{0}' is type '{1}', which has no gateway server. Only Dell Data Domain and HPE StoreOnce use one; ExaGrid, Quantum DXi, " +
                   "ETERNUS CS800 and InfiniGuard run the Data Mover on the appliance itself.") -f $name, $repo.type
        }
        $full = Invoke-VbrRest -Method GET -Path ("/api/v1/backupInfrastructure/repositories/{0}" -f [uri]::EscapeDataString($repo.id))
        $node = Get-VbrRestRepositoryGatewayNode -Repository $full
        $ids  = @(if ($node -and $node.PSObject.Properties['gatewayServerIds']) { $node.gatewayServerIds | Where-Object { $_ } })
        $auto = [bool](Get-ObjectPath -Object $node -Path 'autoSelection')
        if (($ids -contains $HostId) -and -not $auto) { Write-Log "Gateway: '$($Row.hostname)' is already a gateway server of '$name' - skipping." 'WARN'; continue }
        $section = ($script:GatewayRepoPaths[[string]$repo.type] -split '\.')[0]
        if (Get-ObjectPath -Object $full -Path "$section.useFCConnectivity") {
            Write-Log ("Gateway: '{0}' connects over Fibre Channel. The gateway must see the appliance over FC (VIA role 'Infrastructure Server with iSCSI/FC/NVMe-oF', " +
                       "-ApplianceRole InfrastructureServerIscsi, plus an FC path into the VM). Check before the first job.") -f $name 'WARN'
        }
        if ($auto) { Write-Log "Gateway: '$name' used automatic gateway selection. It now uses the explicit list ($(($ids.Count + 1)) server(s)); add further gateways the same way." 'WARN' }
        if ($PSCmdlet.ShouldProcess($name, "PUT repository: add '$($Row.hostname)' to the gateway servers (automatic selection off)")) {
            Set-VbrRestRepositoryGateways -RepositoryId $repo.id -HostIds @(@($ids + $HostId) | Select-Object -Unique) -AutoSelect $false
            Write-Log "Gateway: '$($Row.hostname)' added as gateway server of '$name' ($($repo.type))." 'OK'
            $n++
        }
    }
    return $n
}

function Remove-VbrRestGatewayReferences {
    # Take the managed server out of every repository gateway list (an empty list falls back to automatic
    # selection). Needed before the managed server can be removed. Returns the references it released.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][string]$HostId, [object[]]$References)
    if ($null -eq $References) { $References = @(Get-VbrRestGatewayReferences -HostId $HostId) }
    foreach ($g in @($References)) {
        if (-not $PSCmdlet.ShouldProcess($g.repoName, 'remove the old appliance from the repository gateway servers')) { continue }
        $remaining = @($g.gatewayServerIds | Where-Object { $_ -ne $HostId })
        $auto = if ($remaining.Count) { [bool]$g.autoSelection } else { $true }
        Set-VbrRestRepositoryGateways -RepositoryId $g.repoId -HostIds $remaining -AutoSelect $auto
        Write-Log ("Gateway: '{0}' -> {1}" -f $g.repoName, $(if ($remaining.Count) { "still uses $($remaining.Count) other gateway server(s)" } else { 'automatic gateway selection until the appliance is back' })) 'INFO'
    }
    return @($References)
}

function Get-ReplaceManifestPath { param($Row) Join-Path $IsoStagingDir ("{0}.replace.json" -f $Row.hostname) }

function Save-ReplaceManifest {
    param($Manifest)
    if ($WhatIfPreference) { return }
    Write-TextFileLF -Path (Join-Path $IsoStagingDir ("{0}.replace.json" -f $Manifest.hostname)) -Text ($Manifest | ConvertTo-Json -Depth 6)
}

function Get-ReplaceManifest {
    # Capture everything needed to put the new proxy back where the old one was. Written to disk BEFORE
    # anything is removed. Returns $null when the row is not registered in this VBR.
    param($Row)
    $regName = Get-RegistrationName -Row $Row
    $hostId = Find-VbrRestManagedServer -Name $regName
    if (-not $hostId -and $Row.ip) { $hostId = Find-VbrRestManagedServer -Name ([string]$Row.ip) }
    if (-not $hostId) { return $null }
    $proxyId = Find-VbrRestProxyByHost -HostId $hostId
    $settings = $null; $refs = @()
    if ($proxyId) {
        $px = Get-VbrRestProxyById -ProxyId $proxyId
        $settings = [ordered]@{ maxTaskCount = $px.server.maxTaskCount; transportMode = $px.server.transportMode; failoverToNetwork = $px.server.failoverToNetwork; hostToProxyEncryption = $px.server.hostToProxyEncryption }
        $refs = @(Get-VbrRestProxyReferences -ProxyId $proxyId)
    }
    # Gateway pins are captured whatever the CSV role says: a proxy may also have been picked as a gateway by hand.
    $gws = @(Get-VbrRestGatewayReferences -HostId $hostId)
    $m = [ordered]@{
        hostname = $Row.hostname; registrationName = $regName; capturedAt = (Get-Date).ToString('o')
        oldHostId = $hostId; oldProxyId = $proxyId; proxySettings = $settings; policy = $ReplaceJobPolicy
        jobs = $refs; gateways = $gws; disabledByUs = @()
    }
    Save-ReplaceManifest -Manifest $m
    Write-Log ("Replace: captured '{0}' - managed server {1}, proxy {2}, pinned in {3} job list(s){4}" -f $regName, $hostId, $(if ($proxyId) { $proxyId } else { 'none' }), $refs.Count,
               $(if ($refs.Count) { ': ' + (($refs | ForEach-Object { "$($_.jobName) [$($_.path)]" }) -join ', ') } else { '' })) 'INFO'
    if ($gws.Count) { Write-Log ("Replace: '{0}' is gateway server of {1} repository(ies): {2}" -f $regName, $gws.Count, (($gws | ForEach-Object { $_.repoName }) -join ', ')) 'INFO' }
    if ($settings -and $Row.tasks -and ([int]$Row.tasks -ne [int]$settings.maxTaskCount)) {
        Write-Log "Replace: CSV tasks=$($Row.tasks) but the existing proxy has maxTaskCount=$($settings.maxTaskCount). The CSV value is applied; set the CSV to $($settings.maxTaskCount) if the old value was intended." 'WARN'
    }
    if ($settings -and $settings.transportMode -and ((ConvertTo-RestTransportMode -Mode $TransportMode) -ne $settings.transportMode)) {
        Write-Log "Replace: -TransportMode $TransportMode differs from the existing proxy's '$($settings.transportMode)'. The parameter value is applied." 'WARN'
    }
    return $m
}

function Invoke-ReplaceRelease {
    # Unpin (and optionally disable) the jobs, then remove proxy role + managed server from the VBR.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param($Manifest)
    $disabled = [System.Collections.Generic.List[string]]::new()
    foreach ($ref in @($Manifest.jobs)) {
        if (-not $PSCmdlet.ShouldProcess($ref.jobName, "unpin the old proxy from the job ($($ref.path))")) { continue }
        if ($Manifest.policy -eq 'Disable' -and -not $ref.wasDisabled -and ($disabled -notcontains $ref.jobId)) {
            try {
                Invoke-VbrRest -Method POST -Path ("/api/v1/jobs/{0}/disable" -f [uri]::EscapeDataString($ref.jobId)) | Out-Null
                $disabled.Add([string]$ref.jobId)
                Write-Log "Replace: job '$($ref.jobName)' disabled while its proxy is rebuilt." 'WARN'
            }
            catch {
                # The VBR refuses to disable a job that has no schedule ("RunAutomatically: [False]", lab
                # 2026-09-28). Such a job never starts by itself, so unpinning is enough - carry on.
                Write-Log "Replace: job '$($ref.jobName)' could not be disabled ($($_.Exception.Message)) - it has no schedule, so it will not start on its own; continuing." 'WARN'
            }
        }
        $remaining = @($ref.proxyIds | Where-Object { $_ -ne $Manifest.oldProxyId })
        $auto = if ($remaining.Count) { [bool]$ref.autoSelectEnabled } else { $true }
        Set-VbrRestJobProxyList -JobId $ref.jobId -Path $ref.path -ProxyIds $remaining -AutoSelect $auto
        Write-Log ("Replace: job '{0}' [{1}] -> {2}" -f $ref.jobName, $ref.path, $(if ($remaining.Count) { "still pinned to $($remaining.Count) other proxy id(s)" } else { 'automatic proxy selection until the new proxy is back' })) 'INFO'
    }
    $Manifest.disabledByUs = @($disabled)
    Save-ReplaceManifest -Manifest $Manifest
    $gws = @(Get-ManifestList -Manifest $Manifest -Key 'gateways')
    if ($gws.Count) { $null = Remove-VbrRestGatewayReferences -HostId $Manifest.oldHostId -References $gws }
    if ($Manifest.oldProxyId -and $PSCmdlet.ShouldProcess($Manifest.registrationName, 'DELETE proxy role (REST)')) {
        Remove-VbrRestProxy -ProxyId $Manifest.oldProxyId
        Write-Log "Replace: removed the proxy role of '$($Manifest.registrationName)'." 'OK'
    }
    if ($PSCmdlet.ShouldProcess($Manifest.registrationName, 'DELETE managed server (REST)')) {
        $sess = Invoke-VbrRest -Method DELETE -Path ("/api/v1/backupInfrastructure/managedServers/{0}" -f [uri]::EscapeDataString($Manifest.oldHostId))
        try { if ($sess -and $sess.PSObject.Properties['id'] -and $sess.id) { Wait-VbrRestSession -SessionId $sess.id -TimeoutSec 600 } }
        catch { Write-Log "Replace: the VBR reported a problem while removing '$($Manifest.registrationName)' ($($_.Exception.Message)) - checking whether it is gone anyway." 'WARN' }
        if (Find-VbrRestManagedServer -Name $Manifest.registrationName) { throw "Replace: managed server '$($Manifest.registrationName)' is still present after the DELETE - remove it in the console and rerun (manifest kept)." }
        Write-Log "Replace: removed managed server '$($Manifest.registrationName)' from VBR." 'OK'
    }
}

function Invoke-ReplaceRestore {
    # Re-pin every captured job list with the NEW proxy id and every repository gateway list with the NEW
    # managed-server id, re-enable what we disabled, drop the manifest. Returns the counts.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param($Manifest, [string]$NewProxyId, [string]$NewHostId)
    $n = 0; $g = 0; $failed = [System.Collections.Generic.List[string]]::new()
    foreach ($ref in @($Manifest.jobs)) {
        try {
            if (-not $PSCmdlet.ShouldProcess($ref.jobName, "pin the new proxy in the job ($($ref.path))")) { continue }
            $ids = @(@(@($ref.proxyIds | Where-Object { $_ -ne $Manifest.oldProxyId }) + $NewProxyId) | Select-Object -Unique)
            Set-VbrRestJobProxyList -JobId $ref.jobId -Path $ref.path -ProxyIds $ids -AutoSelect ([bool]$ref.autoSelectEnabled)
            $n++
            Write-Log "Replace: job '$($ref.jobName)' [$($ref.path)] pinned to the new proxy again ($($ids.Count) proxy id(s), automatic selection $(if ($ref.autoSelectEnabled) { 'on' } else { 'off' }))." 'OK'
        }
        catch { $failed.Add("$($ref.jobName) [$($ref.path)]: $($_.Exception.Message)") }
    }
    foreach ($gw in @(Get-ManifestList -Manifest $Manifest -Key 'gateways')) {
        try {
            if (-not $PSCmdlet.ShouldProcess($gw.repoName, 'add the new appliance to the repository gateway servers')) { continue }
            $ids = @(@(@($gw.gatewayServerIds | Where-Object { $_ -ne $Manifest.oldHostId }) + $NewHostId) | Select-Object -Unique)
            Set-VbrRestRepositoryGateways -RepositoryId $gw.repoId -HostIds $ids -AutoSelect ([bool]$gw.autoSelection)
            $g++
            Write-Log "Replace: repository '$($gw.repoName)' uses the new appliance as gateway server again ($($ids.Count) gateway(s))." 'OK'
        }
        catch { $failed.Add("repository $($gw.repoName): $($_.Exception.Message)") }
    }
    foreach ($jid in @($Manifest.disabledByUs)) {
        try {
            if ($PSCmdlet.ShouldProcess($jid, 're-enable the job')) {
                Invoke-VbrRest -Method POST -Path ("/api/v1/jobs/{0}/enable" -f [uri]::EscapeDataString([string]$jid)) | Out-Null
                Write-Log "Replace: job $jid re-enabled." 'OK'
            }
        }
        catch { $failed.Add("enable ${jid}: $($_.Exception.Message)") }
    }
    $mp = Join-Path $IsoStagingDir ("{0}.replace.json" -f $Manifest.hostname)
    if ($failed.Count) {
        throw ("Replace: {0} job update(s) failed - fix them by hand or rerun with -Replace -SkipDeploy (manifest kept at {1}): {2}" -f $failed.Count, $mp, ($failed -join '; '))
    }
    if (-not $WhatIfPreference -and (Test-Path -LiteralPath $mp)) { Remove-Item -LiteralPath $mp -Force -WhatIf:$false -ErrorAction SilentlyContinue }
    return [pscustomobject]@{ Jobs = $n; Gateways = $g }
}

function Move-ReplacedVmAside {
    # -Replace: the VM with this name is the proxy being replaced. Power it off and rename it (kept for a
    # rollback window) or delete it (-PurgeOldVm), so the new VM can take the name and the IP address.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param($Vm, [string]$Hostname)
    if ($PurgeOldVm) {
        if ($PSCmdlet.ShouldProcess($Hostname, 'power off + DELETE the old VM (-PurgeOldVm)')) {
            if ($Vm.PowerState -eq 'PoweredOn') { Stop-VM -VM $Vm -Confirm:$false | Out-Null }
            Remove-VM -VM $Vm -DeletePermanently -Confirm:$false
            Write-Log "Replace: old VM '$Hostname' deleted (-PurgeOldVm)." 'WARN'
        }
        return
    }
    $newName = "{0}-old-{1}" -f $Hostname, (Get-Date).ToString('yyyyMMdd-HHmm')
    if ($PSCmdlet.ShouldProcess($Hostname, "power off + rename the old VM to '$newName'")) {
        if ($Vm.PowerState -eq 'PoweredOn') { Stop-VM -VM $Vm -Confirm:$false | Out-Null }
        Set-VM -VM $Vm -Name $newName -Confirm:$false | Out-Null
        Write-Log "Replace: old VM powered off and renamed to '$newName' - delete it once the new proxy has proven itself." 'WARN'
    }
}

function Remove-VbrRestHost {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param($Row)
    $regName = Get-RegistrationName -Row $Row
    $hostId = Find-VbrRestManagedServer -Name $regName
    # A server that is still a repository gateway cannot be removed cleanly: release those lists first.
    if ($hostId) { $null = Remove-VbrRestGatewayReferences -HostId $hostId }
    if ($hostId -and $PSCmdlet.ShouldProcess($regName, "DELETE managed server (REST)")) {
        $sess = Invoke-VbrRest -Method DELETE -Path ("/api/v1/backupInfrastructure/managedServers/{0}" -f [uri]::EscapeDataString($hostId))
        if ($sess.id) { Wait-VbrRestSession -SessionId $sess.id -TimeoutSec 600 }
        Write-Log "Removed managed server '$regName' from VBR (REST)." 'OK'
    }
}

# ---------------------------------------------------------------------------
# CSV load + validation
# ---------------------------------------------------------------------------
function Import-DeploymentCsv {
    param([string]$Path, [string]$VbrFilter)

    $required = @('vbr', 'hostname', 'ip', 'netmask', 'gateway', 'dns', 'cluster',
                  'datastore', 'folder', 'portgroup', 'role', 'tasks')

    $rows = Import-Csv -Path $Path
    if (-not $rows) { throw "CSV '$Path' is empty." }

    $cols = ($rows | Select-Object -First 1).PSObject.Properties.Name
    $missing = $required | Where-Object { $_ -notin $cols }
    if ($missing) { throw "CSV is missing required column(s): $($missing -join ', ')" }

    if ($VbrFilter -ne '*') {
        $rows = $rows | Where-Object { $_.vbr -eq $VbrFilter }
        if (-not $rows) { throw "No rows in CSV match vbr = '$VbrFilter'." }
    }

    # Per-row validation
    $seen = @{}
    foreach ($r in $rows) {
        foreach ($f in @('hostname', 'ip', 'cluster', 'datastore', 'portgroup')) {
            if ([string]::IsNullOrWhiteSpace($r.$f)) {
                throw "Row '$($r.hostname)': required field '$f' is empty."
            }
        }
        [ipaddress]$null = $r.ip   # throws if not a valid IP
        $roles = Get-RowRoles -Row $r
        if ($roles.Unknown.Count) {
            throw "Row '$($r.hostname)': role '$($r.role)' is not valid. Use viproxy, gateway or viproxy+gateway (Infrastructure Appliance), or vbr / em (Software Appliance: Backup & Replication / Enterprise Manager)."
        }
        if (($roles.Vbr -or $roles.Em) -and $roles.Count -ne 1) {
            throw "Row '$($r.hostname)': role '$($r.role)' - vbr and em are whole appliances (Veeam Software Appliance) and cannot be combined with another role."
        }
        if (@(Get-GatewayRepoNames -Row $r).Count -and -not $roles.Gateway) {
            throw "Row '$($r.hostname)': 'gatewayrepo' is set but the role '$($r.role)' has no gateway. Use role gateway or viproxy+gateway."
        }
        if ($r.tasks -and -not ($r.tasks -as [int])) {
            throw "Row '$($r.hostname)': tasks '$($r.tasks)' is not an integer."
        }
        if ($seen.ContainsKey($r.hostname)) {
            throw "Duplicate hostname '$($r.hostname)' in CSV - hostnames must be unique across the network."
        }
        $seen[$r.hostname] = $true
        # Two rows with one address = an IP conflict the moment the second appliance boots.
        $ipKey = 'ip:' + $r.ip
        if ($r.ip -and $seen.ContainsKey($ipKey)) {
            throw ("Duplicate ip '{0}' in CSV (rows '{1}' and '{2}') - every appliance needs its own address." -f $r.ip, $seen[$ipKey], $r.hostname)
        }
        if ($r.ip) { $seen[$ipKey] = $r.hostname }
        if ($r.PSObject.Properties['dnssearch'] -and $r.dnssearch) {
            foreach ($d in (([string]$r.dnssearch) -split '[,; ]+' | Where-Object { $_ })) {
                if ($d -notmatch '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$') { throw "Row '$($r.hostname)': dnssearch '$d' is not a valid domain name." }
            }
        }
        # Optional second NIC (ip2 / netmask2 / portgroup2 as a set): its address must be unique as well.
        $nic2 = Get-RowNic2 -Row $r
        if ($nic2) {
            [ipaddress]$null = $nic2.Ip
            [ipaddress]$null = $nic2.Netmask
            if ($nic2.Ip -eq $r.ip) { throw "Row '$($r.hostname)': ip2 equals ip - the two adapters need different addresses." }
            $ip2Key = 'ip:' + $nic2.Ip
            if ($seen.ContainsKey($ip2Key)) {
                throw ("Duplicate address '{0}' in CSV (ip2 of '{1}' is also used by '{2}') - every adapter needs its own address." -f $nic2.Ip, $r.hostname, $seen[$ip2Key])
            }
            $seen[$ip2Key] = $r.hostname
        }
    }

    # One run = one base ISO: Infrastructure Appliance rows and Software Appliance rows need different ISOs.
    $vsaRows = @($rows | Where-Object { Get-RowVsaProduct -Row $_ })
    if ($vsaRows.Count -and $vsaRows.Count -ne @($rows).Count) {
        throw ("The selected rows mix Software Appliance roles (vbr / em: {0}) with Infrastructure Appliance roles - they are built from different ISOs. " +
               "Put them in separate CSVs or give them different 'vbr' values and run each with -Vbr.") -f (($vsaRows.hostname) -join ', ')
    }

    Write-Log "Loaded $($rows.Count) row(s) for vbr '$VbrFilter'." 'OK'
    return , @($rows)
}

# ---------------------------------------------------------------------------
# ISO unattended-deploy toolchain + artifact rendering (Stage A)
#
# The 13.1 VIA is deployed by booting a per-node ISO repacked from the pristine
# base ISO: the kickstart (/proxy-ks.cfg) gets the per-node static network line
# and the documented Initial-Configuration block (answer file /etc/veeam/vbr_init.cfg
# with accounts / optional MFA / NTP / appliance role + a one-shot veeam-init.service
# that applies it on first boot); grub gets a default entry, timeout and
# inst.assumeyes. Repack uses xorriso (native on Linux/macOS, WSL on Windows).
#   Ref: helpcenter.veeam.com/docs/vbr/userguide/deployment_linux_silent_deploy_configure.html
# See templates/README.md for the artifacts and the lab confirm-list.
# ---------------------------------------------------------------------------
# Veeam logs location on the appliance (-LogsOnDataDisk): the install-time default on disk 1 and the
# data-volume folder the Host Management Console offers as the alternative (disk 2 with -MultiDisk).
$script:VeeamLogsDefaultDir = '/var/log/VeeamBackup'
$script:VeeamLogsDataDir    = '/var/lib/veeam/VeeamBackupLogFolder'

function Write-TextFileLF {
    # Write a text file with LF line endings and UTF-8 (no BOM) - required for the Linux
    # kickstart/grub/shell/systemd artifacts (CRLF or a BOM breaks them). Ensures the parent
    # directory exists first: [IO.File]::WriteAllText does NOT create it and otherwise throws
    # "Could not find a part of the path ...".
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir) {
        if (Test-Path -LiteralPath $dir -PathType Leaf) {
            throw "Write-TextFileLF: '$dir' exists as a FILE, not a directory. Remove it (or point -IsoStagingDir elsewhere) and re-run."
        }
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false | Out-Null
        }
    }
    $lf = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    if (Test-Path -LiteralPath $Path) { (Get-Item -LiteralPath $Path).IsReadOnly = $false }   # files extracted from an ISO may be mode 444
    [System.IO.File]::WriteAllText($Path, $lf, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-WorkerSecretFile {
    # Orchestrator -> worker hand-over of a secret (credential "user`npassword", TOTP seed): written encrypted
    # with -SecretsKeyFile in the VEEAMENC1 format of Protect-DeploymentSecrets.ps1 (AES-256-CBC + HMAC-SHA256),
    # mode 600, in a private folder the orchestrator deletes at the end. Never a plaintext secret on disk.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$KeyFile)
    $raw = [Convert]::FromBase64String((Get-Content -LiteralPath $KeyFile -Raw).Trim())
    $hk = [System.Security.Cryptography.HMACSHA256]::new($raw)
    try { $encKey = $hk.ComputeHash([Text.Encoding]::UTF8.GetBytes('veeam-autodeploy-enc')); $macKey = $hk.ComputeHash([Text.Encoding]::UTF8.GetBytes('veeam-autodeploy-mac')) }
    finally { $hk.Dispose() }
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.KeySize = 256; $aes.Key = $encKey; $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'; $aes.GenerateIV()
        $plain = [Text.Encoding]::UTF8.GetBytes($Text)
        [byte[]]$ivct = $aes.IV + $aes.CreateEncryptor().TransformFinalBlock($plain, 0, $plain.Length)
    }
    finally { $aes.Dispose() }
    $hm = [System.Security.Cryptography.HMACSHA256]::new($macKey)
    try { $tag = $hm.ComputeHash($ivct) } finally { $hm.Dispose() }
    New-Item -ItemType File -Path $Path -Force -WhatIf:$false | Out-Null
    if (-not $script:IsWindowsHost) { & chmod 600 $Path }
    [System.IO.File]::WriteAllText($Path, "VEEAMENC1`n" + [Convert]::ToBase64String([byte[]]($ivct + $tag)) + "`n")
}

function Read-ProtectedText {
    # Return a secret file's text. Files starting with the VEEAMENC1 marker (written by
    # Protect-DeploymentSecrets.ps1: AES-256-CBC + HMAC-SHA256, keys derived from -SecretsKeyFile)
    # are decrypted in memory; anything else is returned as-is with a warning that it is plaintext.
    param([Parameter(Mandatory)][string]$Path, [string]$Purpose = 'secret file')
    $blob = Get-Content -LiteralPath $Path -Raw
    if ($blob -notmatch '^\s*VEEAMENC1\s*\r?\n') {
        Write-Log "$Purpose '$Path' is PLAINTEXT - encrypt it with Protect-DeploymentSecrets.ps1 and pass -SecretsKeyFile." 'WARN'
        return $blob
    }
    if (-not $SecretsKeyFile) { throw "$Purpose '$Path' is encrypted (VEEAMENC1) but -SecretsKeyFile was not given." }
    $raw = [Convert]::FromBase64String((Get-Content -LiteralPath $SecretsKeyFile -Raw).Trim())
    if ($raw.Length -lt 32) { throw "SecretsKeyFile '$SecretsKeyFile' is too short." }
    $hk = [System.Security.Cryptography.HMACSHA256]::new($raw)
    try {
        $encKey = $hk.ComputeHash([Text.Encoding]::UTF8.GetBytes('veeam-autodeploy-enc'))
        $macKey = $hk.ComputeHash([Text.Encoding]::UTF8.GetBytes('veeam-autodeploy-mac'))
    }
    finally { $hk.Dispose() }
    $lines = $blob -split "`r?`n"
    $data = [Convert]::FromBase64String((($lines[1..($lines.Count - 1)]) -join '').Trim())
    if ($data.Length -lt 64) { throw "Encrypted $Purpose '$Path' is truncated." }
    [byte[]]$ivct = $data[0..($data.Length - 33)]
    [byte[]]$tag  = $data[($data.Length - 32)..($data.Length - 1)]
    $hm = [System.Security.Cryptography.HMACSHA256]::new($macKey)
    try { $calc = $hm.ComputeHash($ivct) } finally { $hm.Dispose() }
    if (-not [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals($calc, $tag)) {
        throw "Integrity check failed for $Purpose '$Path' - wrong -SecretsKeyFile or the file was modified."
    }
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.KeySize = 256; $aes.Key = $encKey; $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'
        $aes.IV = [byte[]]$ivct[0..15]
        [byte[]]$ct = $ivct[16..($ivct.Length - 1)]
        return [Text.Encoding]::UTF8.GetString($aes.CreateDecryptor().TransformFinalBlock($ct, 0, $ct.Length))
    }
    finally { $aes.Dispose() }
}

function Read-CredentialFile {
    # Two-line credential file (user, password), plaintext or encrypted -> PSCredential.
    param([Parameter(Mandatory)][string]$Path, [string]$Purpose = 'credential file')
    $lines = (Read-ProtectedText -Path $Path -Purpose $Purpose) -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
    if ($lines.Count -lt 2) { throw "$Purpose '$Path' must hold two lines: user name, then password." }
    return [pscredential]::new($lines[0], (ConvertTo-SecureString $lines[1] -AsPlainText -Force))
}

function Get-ApplianceSecrets {
    # Parse -ApplianceSecretsFile (KEY = VALUE; '#'/blank ignored) into a hashtable, apply the
    # documented defaults, normalise booleans and VALIDATE against the appliance rules (Veeam
    # "Automating Installation with Initial Configuration", build 13.1.1.18). Never logged.
    # The file may be plaintext or VEEAMENC1-encrypted (see Read-ProtectedText).
    param([Parameter(Mandatory)][string]$Path)
    $h = @{}
    foreach ($line in ((Read-ProtectedText -Path $Path -Purpose 'appliance settings file') -split "`r?`n")) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $kv = $t -split '=', 2
        if ($kv.Count -ne 2) { continue }
        $h[$kv[0].Trim()] = $kv[1].Trim()
    }
    $defaults = @{
        VEEAMADMIN_MFA_ENABLED = 'true'    # project decision 2026-09-24: TOTP on, ONE shared seed for all proxies
        VEEAMSO_ENABLED        = 'false'   # project decision 2026-09-24: no Security Officer account on proxies
        VEEAMSO_MFA_ENABLED    = 'true'    # Security Officer MFA is always on when that account exists
        NTP_SERVERS            = 'pool.ntp.org'
        NTP_RUNSYNC            = 'true'
        VBR_RUNINITISO         = 'true'
        VBR_RUNSTART           = 'true'
        CLEANUP_ANSWER_FILE    = 'true'    # veeam-init.sh shreds /etc/veeam/vbr_init.cfg after a successful apply
    }
    foreach ($k in $defaults.Keys) { if (-not $h.ContainsKey($k) -or -not $h[$k]) { $h[$k] = $defaults[$k] } }
    foreach ($k in @('VEEAMADMIN_MFA_ENABLED', 'VEEAMSO_ENABLED', 'VEEAMSO_MFA_ENABLED', 'NTP_RUNSYNC', 'VBR_RUNINITISO', 'VBR_RUNSTART', 'CLEANUP_ANSWER_FILE')) {
        $h[$k] = if ($h[$k] -match '^(true|yes|1)$') { 'true' }
                 elseif ($h[$k] -match '^(false|no|0)$') { 'false' }
                 else { throw "ApplianceSecretsFile: '$k' must be true/false (got '$($h[$k])')." }
    }
    # NTP: accept ',' or ';' separated input; the answer file wants ';'.
    $h['NTP_SERVERS'] = (($h['NTP_SERVERS'] -split '[;,]') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ';'
    Test-ApplianceSecrets -Secrets $h -Path $Path
    return $h
}

function New-Base32Secret {
    # 16-char Base32 (RFC 4648) TOTP seed - the documented appliance MFA key format. Crypto RNG.
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
    return (-join (1..16 | ForEach-Object { $alphabet[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32(32)] }))
}

function New-AppliancePlaceholderPassword {
    # 20-char password that satisfies the appliance rules (all four classes, classes alternate so no
    # run of the same class). Used only for a DISABLED Security Officer account, whose
    # veeamso.password line must still be present and valid in the answer file.
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnpqrstuvwxyz', '23456789', '!@#%^*-_=+?')
    $sb = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt 20; $i++) {
        $s = $sets[$i % 4]
        [void]$sb.Append($s[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($s.Length)])
    }
    return $sb.ToString()
}

function Test-AppliancePassword {
    # Documented rules: >= 15 chars; >= 1 upper, lower, digit, special; no more than 4 characters
    # of the same class in a row. Returns the list of violations (empty = OK).
    param([string]$Password, [string]$Label)
    $p = [System.Collections.Generic.List[string]]::new()
    if (-not $Password)                      { $p.Add("$Label is empty"); return $p }
    if ($Password.Length -lt 15)             { $p.Add("$Label must be at least 15 characters (is $($Password.Length))") }
    if ($Password -cnotmatch '[A-Z]')        { $p.Add("$Label needs an upper-case character") }
    if ($Password -cnotmatch '[a-z]')        { $p.Add("$Label needs a lower-case character") }
    if ($Password -notmatch '[0-9]')         { $p.Add("$Label needs a digit") }
    if ($Password -notmatch '[^A-Za-z0-9]')  { $p.Add("$Label needs a special character") }
    if ($Password -cmatch '[a-z]{5}|[A-Z]{5}|[0-9]{5}|[^A-Za-z0-9]{5}') { $p.Add("$Label has more than 4 characters of the same class in a row") }
    return $p
}

function Test-ApplianceSecrets {
    # Fail early, on the deploy host, with every problem listed - a bad value would otherwise
    # only surface as a failed Initial Configuration inside the appliance.
    param([Parameter(Mandatory)][hashtable]$Secrets, [string]$Path)
    $errors = [System.Collections.Generic.List[string]]::new()
    $b32  = '^[A-Z2-7]{16}$'
    $guid = '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'

    foreach ($e in (Test-AppliancePassword -Password $Secrets['VEEAMADMIN_PASSWORD'] -Label 'VEEAMADMIN_PASSWORD')) { $errors.Add($e) }

    # Security Officer password: required + validated when the account is enabled. When it is
    # DISABLED the answer file still carries a veeamso.password line, so fill it with a random
    # rule-compliant placeholder if none was given (the account is never enabled).
    $soEnabled = ($Secrets['VEEAMSO_ENABLED'] -eq 'true')
    $soPwd = if ($Secrets.ContainsKey('VEEAMSO_PASSWORD')) { $Secrets['VEEAMSO_PASSWORD'] } else { '' }
    if (-not $soEnabled -and -not $soPwd) {
        $soPwd = New-AppliancePlaceholderPassword
        Write-Log "VEEAMSO_PASSWORD not set and the Security Officer is disabled - using a generated placeholder (unused)." 'INFO'
    }
    $Secrets['VEEAMSO_PASSWORD'] = $soPwd
    foreach ($e in (Test-AppliancePassword -Password $soPwd -Label 'VEEAMSO_PASSWORD')) { $errors.Add($e) }
    if ($Secrets['VEEAMADMIN_PASSWORD'] -and ($Secrets['VEEAMADMIN_PASSWORD'] -ceq $soPwd)) {
        $errors.Add('VEEAMADMIN_PASSWORD and VEEAMSO_PASSWORD must be different')
    }

    # MFA seeds: required + 16-char Base32 when that account's MFA is on. When MFA is off the
    # answer file still carries a key line, so generate a throw-away seed if none was given.
    foreach ($acct in @('VEEAMADMIN', 'VEEAMSO')) {
        $key = "${acct}_MFA_SECRET"
        $on  = ($Secrets["${acct}_MFA_ENABLED"] -eq 'true')
        if ($acct -eq 'VEEAMSO' -and $Secrets['VEEAMSO_ENABLED'] -ne 'true') { $on = $false }
        $val = if ($Secrets.ContainsKey($key) -and $Secrets[$key]) { ($Secrets[$key] -replace '\s', '').ToUpperInvariant() } else { '' }
        if ($on) {
            if (-not $val)               { $errors.Add("$key is required when ${acct} MFA is enabled") }
            elseif ($val -notmatch $b32) { $errors.Add("$key must be a 16-character Base32 string (A-Z, 2-7)") }
        }
        elseif (-not $val) {
            $val = New-Base32Secret
            Write-Log "$key not set and ${acct} MFA is disabled - using a generated placeholder seed (unused)." 'INFO'
        }
        $Secrets[$key] = $val
    }

    # Security Officer recovery token (break-glass): required when the SO account exists.
    $tok = if ($Secrets.ContainsKey('VEEAMSO_RECOVERY_TOKEN')) { $Secrets['VEEAMSO_RECOVERY_TOKEN'] } else { '' }
    if ($Secrets['VEEAMSO_ENABLED'] -eq 'true') {
        if (-not $tok)                { $errors.Add('VEEAMSO_RECOVERY_TOKEN is required when VEEAMSO_ENABLED=true (record it - it is the Security Officer break-glass token)') }
        elseif ($tok -notmatch $guid) { $errors.Add('VEEAMSO_RECOVERY_TOKEN must be a hex GUID like 1A2B3C4D-1A2B-1A2B-1A2B-1A2B3C4D5E6F (New-Guid)') }
    }
    elseif (-not $tok) { $tok = [guid]::NewGuid().ToString() }
    $Secrets['VEEAMSO_RECOVERY_TOKEN'] = $tok.ToUpperInvariant()

    if (-not $Secrets['NTP_SERVERS']) { $errors.Add('NTP_SERVERS must list at least one NTP server (the appliance does not accept NTS servers here)') }

    # An UNMODIFIED copy of appliance-secrets.example.conf passes every syntax rule above, but the
    # appliance cannot use it: the example NTP names never resolve, Initial Configuration fails at
    # first boot and the console drops into the interactive wizard (lab, 2026-09-25: two proxies
    # timed out at the readiness gate for exactly this reason). Refuse the known example values.
    $examplePasswords = @('Ex@mp13-Adm1n-Pa55w0rd!', 'Ex@mp13-S3cur1ty-0ff1cer!')
    if ($Secrets['VEEAMADMIN_PASSWORD'] -cin $examplePasswords) {
        $errors.Add('VEEAMADMIN_PASSWORD is the example value from appliance-secrets.example.conf - set your real veeamadmin password')
    }
    if ($soEnabled -and ($soPwd -cin $examplePasswords)) {
        $errors.Add('VEEAMSO_PASSWORD is the example value from appliance-secrets.example.conf - set your real Security Officer password')
    }
    if ($Secrets['VEEAMADMIN_MFA_ENABLED'] -eq 'true' -and $Secrets['VEEAMADMIN_MFA_SECRET'] -eq 'JBSWY3DPEHPK3PXP') {
        $errors.Add('VEEAMADMIN_MFA_SECRET is the example seed from appliance-secrets.example.conf - generate a fresh 16-character Base32 seed (Protect-DeploymentSecrets.ps1 -NewTotpSeed, or any authenticator tool)')
    }
    if ($Secrets['NTP_SERVERS']) {
        foreach ($n in @($Secrets['NTP_SERVERS'] -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            if ($n -match '(^|\.)example\.(local|com|net|org)$') {
                $errors.Add("NTP_SERVERS contains the example host '$n' - list your real NTP servers (the appliance cannot resolve it, so Initial Configuration fails and the console shows the interactive wizard)")
                continue
            }
            # Names are resolved by the APPLIANCE (CSV 'dns'), not by this host, so a miss here is a warning.
            if ($n -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
                try { [void][System.Net.Dns]::GetHostAddresses($n) }
                catch { Write-Log "NTP server '$n' does not resolve from this host. OK if the appliance's DNS resolves it; otherwise first-boot Initial Configuration fails (console shows the wizard, HMC never opens)." 'WARN' }
            }
        }
    }

    if ($errors.Count) {
        throw ("ApplianceSecretsFile '{0}' failed validation ({1} problem(s)):`n  - {2}" -f $Path, $errors.Count, ($errors -join "`n  - "))
    }
    Write-Log "Appliance secrets validated (passwords, MFA seeds, recovery token, NTP)." 'OK'
}

function ConvertTo-RenderedTemplate {
    # Replace {{TOKEN}} placeholders in a template. Fail-closed: throws if the template needs
    # a token that was not supplied (no half-rendered configs).
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][hashtable]$Tokens,
        [string]$OutPath
    )
    if (-not (Test-Path $TemplatePath)) { throw "Template not found: $TemplatePath" }
    $text = Get-Content -Path $TemplatePath -Raw
    $needed = [regex]::Matches($text, '\{\{(\w+)\}\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    $missing = $needed | Where-Object { -not $Tokens.ContainsKey($_) }
    if ($missing) { throw "Template '$TemplatePath' needs token(s) not supplied: $($missing -join ', ')" }
    foreach ($k in $needed) { $text = $text.Replace(('{{' + $k + '}}'), [string]$Tokens[$k]) }
    if ($OutPath) { Write-TextFileLF -Path $OutPath -Text $text; return $OutPath }
    return $text
}

function Resolve-WslPath {
    # Translate a Windows path to a /mnt/... WSL path (works for not-yet-existing paths).
    param([Parameter(Mandatory)][string]$WindowsPath, [string]$Distro)
    $p = $WindowsPath
    if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path (Get-Location).Path $p }
    # --exec: no Linux shell in between. 'wsl.exe wslpath C:\x' goes through the default shell, which
    # eats the backslashes (seen on vone, 2026-09-30: "wslpath failed" for every Windows path).
    $wslArgs = @()
    if ($Distro) { $wslArgs += @('-d', $Distro) }
    $wslArgs += @('--exec', 'wslpath', '-a', $p)
    $out = & wsl.exe @wslArgs 2>$null
    if ($LASTEXITCODE -eq 0 -and $out) { return ($out | Select-Object -First 1).Trim() }
    # Fallback for a drive path: WSL's default automount (C:\a\b -> /mnt/c/a/b).
    if ($p -match '^([A-Za-z]):[\\/](.*)$') { return ('/mnt/{0}/{1}' -f $matches[1].ToLowerInvariant(), ($matches[2] -replace '\\', '/')) }
    throw "Resolve-WslPath: cannot translate '$p' to a WSL path (wslpath failed and it is not a drive path)." 
}

function Convert-ToolPath {
    # Path as the xorriso runner sees it: a WSL path on a Windows host, else the absolute native path.
    param([Parameter(Mandatory)][string]$Path)
    $abs = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path (Get-Location).Path $Path }
    if ($script:IsWindowsHost -and -not $XorrisoCommand) { return (Resolve-WslPath -WindowsPath $abs -Distro $WslDistro) }
    return $abs
}

function Invoke-Xorriso {
    # Run xorriso: native when -XorrisoCommand set or on Linux/macOS, else via wsl.exe (argv form,
    # so paths with spaces survive). Throws on non-zero exit.
    param([Parameter(Mandatory)][string[]]$Arguments)
    if ($XorrisoCommand)              { & $XorrisoCommand @Arguments }
    elseif (-not $script:IsWindowsHost) { & xorriso @Arguments }
    else {
        $wslArgs = @()
        if ($WslDistro) { $wslArgs += @('-d', $WslDistro) }
        $wslArgs += @('--exec', 'xorriso') + $Arguments     # --exec: arguments reach xorriso verbatim (no shell: spaces, $, \ survive)
        & wsl.exe @wslArgs
    }
    if ($LASTEXITCODE -ne 0) { throw "xorriso failed (exit $LASTEXITCODE)." }
}

function Initialize-IsoToolchain {
    # Verify xorriso is runnable. Unlike PowerCLI it cannot be auto-installed - fail with guidance.
    if ($XorrisoCommand) {
        if (-not (Get-Command $XorrisoCommand -ErrorAction SilentlyContinue)) {
            throw "Initialize-IsoToolchain: -XorrisoCommand '$XorrisoCommand' not found."
        }
        Write-Log "ISO toolchain: native xorriso '$XorrisoCommand'." 'OK'; return
    }
    if (-not $script:IsWindowsHost) {
        if (-not (Get-Command xorriso -ErrorAction SilentlyContinue)) {
            throw "Initialize-IsoToolchain: 'xorriso' not on PATH. Install it (e.g. 'brew install xorriso' / 'apt install xorriso')."
        }
        Write-Log "ISO toolchain: native xorriso found." 'OK'; return
    }
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw "Initialize-IsoToolchain: wsl.exe not found. Install WSL2 + a distro with xorriso, or pass -XorrisoCommand."
    }
    $probe = @()
    if ($WslDistro) { $probe += @('-d', $WslDistro) }
    $probe += @('--', 'bash', '-lc', 'command -v xorriso')
    $found = & wsl.exe @probe 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $found) {
        throw "Initialize-IsoToolchain: xorriso not found in WSL$(if($WslDistro){" distro '$WslDistro'"}). Install it (e.g. 'sudo apt install xorriso')."
    }
    Write-Log "ISO toolchain: xorriso in WSL ($(($found | Select-Object -First 1).Trim()))." 'OK'
}

function Initialize-IsoWorkspace {
    # Render the SHARED answer file (once per run) and the first-boot artifacts. Returns paths.
    # The rendered answer file holds plaintext passwords: protect the staging dir; the deploy
    # removes each node's ISO after use unless -KeepIso.
    param(
        [Parameter(Mandatory)][string]$TemplateDir,
        [Parameter(Mandatory)][hashtable]$Secrets,
        [Parameter(Mandatory)][string]$OutDir,
        [Parameter(Mandatory)][string]$Role
    )
    if (-not (Test-Path $TemplateDir -PathType Container)) { throw "TemplateDir not found: $TemplateDir" }
    foreach ($f in @('vbr_init.cfg.template', 'network-line.template', 'network-line-nic2.template', 'prompt-network.sh.template', 'veeam-init.sh.template', 'veeam-init.service')) {
        if (-not (Test-Path (Join-Path $TemplateDir $f))) { throw "Missing template artifact '$f' in $TemplateDir" }
    }
    if (Test-Path -LiteralPath $OutDir -PathType Leaf) {
        throw "OutDir '$OutDir' exists as a FILE, not a directory. Remove it (or set a different -IsoStagingDir) and re-run."
    }
    if (-not (Test-Path -LiteralPath $OutDir -PathType Container)) { New-Item -ItemType Directory -Path $OutDir -Force -WhatIf:$false | Out-Null }

    # 13.1: the VIA role is declared in the answer file (unified ISO, unified boot menu).
    $roleLines = switch ($Role) {
        'InfrastructureServerIscsi' { "applianceRole.role=vbproxy`napplianceRole.iSCSI=true" }
        'None'                      { '' }   # 13.0.x: role comes from the kickstart file, no keys emitted
        default                     { 'applianceRole.role=vbproxy' }
    }
    $tok = @{
        VEEAMADMIN_PASSWORD    = $Secrets['VEEAMADMIN_PASSWORD']
        VEEAMADMIN_MFA_ENABLED = $Secrets['VEEAMADMIN_MFA_ENABLED']
        VEEAMADMIN_MFA_SECRET  = $Secrets['VEEAMADMIN_MFA_SECRET']
        VEEAMSO_ENABLED        = $Secrets['VEEAMSO_ENABLED']
        VEEAMSO_PASSWORD       = $Secrets['VEEAMSO_PASSWORD']
        VEEAMSO_MFA_ENABLED    = $Secrets['VEEAMSO_MFA_ENABLED']
        VEEAMSO_MFA_SECRET     = $Secrets['VEEAMSO_MFA_SECRET']
        VEEAMSO_RECOVERY_TOKEN = $Secrets['VEEAMSO_RECOVERY_TOKEN']
        NTP_SERVERS            = $Secrets['NTP_SERVERS']
        NTP_RUNSYNC            = $Secrets['NTP_RUNSYNC']
        APPLIANCE_ROLE_LINES   = $roleLines
        VBR_RUNINITISO         = $Secrets['VBR_RUNINITISO']
        VBR_RUNSTART           = $Secrets['VBR_RUNSTART']
    }
    $initOut = Join-Path $OutDir 'vbr_init.cfg'
    ConvertTo-RenderedTemplate -TemplatePath (Join-Path $TemplateDir 'vbr_init.cfg.template') -Tokens $tok -OutPath $initOut | Out-Null

    $initSh = Join-Path $OutDir 'veeam-init.sh'
    ConvertTo-RenderedTemplate -TemplatePath (Join-Path $TemplateDir 'veeam-init.sh.template') `
        -Tokens @{ CLEANUP_ANSWER_FILE = $Secrets['CLEANUP_ANSWER_FILE'] } -OutPath $initSh | Out-Null
    $initSvc = Join-Path $OutDir 'veeam-init.service'
    Write-TextFileLF -Path $initSvc -Text (Get-Content -Raw (Join-Path $TemplateDir 'veeam-init.service'))

    Write-Log "ISO workspace prepared at $OutDir (answer file [role=$Role] + veeam-init.sh/.service)." 'OK'
    return [pscustomobject]@{
        Dir         = $OutDir
        TemplateDir = $TemplateDir
        VbrInit     = $initOut
        InitScript  = $initSh
        InitService = $initSvc
        Role        = $Role
    }
}

function Build-KickstartPost {
    # The documented "Automating Installation with Initial Configuration" block, inserted INSIDE
    # the appliance's own %post (between %post and '# post end'): disable the interactive init
    # wizard, write /etc/veeam/vbr_init.cfg, write /etc/veeam/veeam-init.sh + veeam-init.service
    # and enable the one-shot unit. Heredocs use a QUOTED sentinel so '$' inside passwords is
    # never expanded by the appliance shell. No 'set -e' here - that would change the behaviour
    # of the rest of Veeam's %post script.
    param([Parameter(Mandatory)]$SharedArtifacts, [string]$LogsDir)
    $answer = (Get-Content -Raw $SharedArtifacts.VbrInit)     -replace "`r`n", "`n" -replace "`r", "`n"
    $script = (Get-Content -Raw $SharedArtifacts.InitScript)  -replace "`r`n", "`n" -replace "`r", "`n"
    $unit   = (Get-Content -Raw $SharedArtifacts.InitService) -replace "`r`n", "`n" -replace "`r", "`n"
    # Embed a clean key=value payload (strip the template's comment/blank lines).
    $answer = (($answer -split "`n") | Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') }) -join "`n"
    $eof = 'VEEAM_AUTODEPLOY_EOF'
    foreach ($c in @($answer, $script, $unit)) {
        if ($c -match "(?m)^$eof`$") { throw "Build-KickstartPost: an artifact contains the heredoc sentinel $eof." }
    }
    $nl = "`n"
    $b  = [System.Text.StringBuilder]::new()
    [void]$b.Append('# >>> veeam-autodeploy (generated): unattended Initial Configuration >>>' + $nl)
    [void]$b.Append('_vad_log() { if command -v log >/dev/null 2>&1; then log "$@"; else echo "$@"; fi; }' + $nl)
    [void]$b.Append('_vad_log "veeam-autodeploy: staging unattended Initial Configuration"' + $nl)
    [void]$b.Append('mkdir -p /etc/veeam' + $nl)
    # Disable the interactive wizard. Current docs name the flag host_management_disable_init; the
    # 13.0.x tooling used cockpit_auto_test_disable_init - touching both is harmless.
    [void]$b.Append('touch /etc/veeam/host_management_disable_init' + $nl)
    [void]$b.Append('touch /etc/veeam/cockpit_auto_test_disable_init' + $nl)
    [void]$b.Append("cat << '$eof' >> /etc/veeam/vbr_init.cfg" + $nl + $answer.TrimEnd("`n") + $nl + $eof + $nl)
    [void]$b.Append('chmod 600 /etc/veeam/vbr_init.cfg' + $nl)
    [void]$b.Append("cat << '$eof' > /etc/veeam/veeam-init.sh" + $nl + $script.TrimEnd("`n") + $nl + $eof + $nl)
    [void]$b.Append('chmod +x /etc/veeam/veeam-init.sh' + $nl)
    [void]$b.Append("cat << '$eof' > /etc/systemd/system/veeam-init.service" + $nl + $unit.TrimEnd("`n") + $nl + $eof + $nl)
    [void]$b.Append('systemctl enable veeam-init.service' + $nl)
    [void]$b.Append('_vad_log "veeam-autodeploy: veeam-init.service enabled (runs once at first boot)"' + $nl)
    if ($LogsDir) {
        # Veeam logs on the data volume (disk 2): what the console's "Logs location" does, applied before
        # first boot. rootLogDirPath is the key the host manager and the Veeam deployment service read;
        # the folder gets the owner/mode the packages give /var/log/VeeamBackup. The kickstart's own
        # rsyslog / logrotate / retention paths are patched in the kickstart text (Get-PatchedApplianceConfigs).
        [void]$b.Append('_vad_log "veeam-autodeploy: Veeam logs location -> ' + $LogsDir + '"' + $nl)
        [void]$b.Append('install -m 02770 -o root -g veeam-grp-log -d ' + $LogsDir + $nl)
        [void]$b.Append('if [ -f /etc/veeam/veeam_global.conf ] && grep -q "^[[:space:]]*rootLogDirPath[[:space:]]*=" /etc/veeam/veeam_global.conf; then' + $nl)
        [void]$b.Append('    sed -i "s#^[[:space:]]*rootLogDirPath[[:space:]]*=.*#rootLogDirPath = ' + $LogsDir + '#" /etc/veeam/veeam_global.conf' + $nl)
        [void]$b.Append('else' + $nl)
        [void]$b.Append('    echo "rootLogDirPath = ' + $LogsDir + '" >> /etc/veeam/veeam_global.conf' + $nl)
        [void]$b.Append('fi' + $nl)
    }
    [void]$b.Append('# <<< veeam-autodeploy <<<' + $nl)
    return ($b.ToString() -replace "`r`n", "`n")
}

function Get-GrubInstallEntry {
    # The stock "fresh install" entry for the chosen disk layout (-MultiDisk / -GrubDefaultEntry),
    # asserted against the titles in grub.cfg so a renamed menu fails the build instead of dropping
    # the VM into an interactive installer. Returns the titles and the entry's kernel + initrd lines.
    param([Parameter(Mandatory)][string]$GrubText, $Row)
    $vsa = if ($Row) { Get-RowVsaProduct -Row $Row } else { $null }
    if ($GrubDefaultEntry -or $vsa) {
        # Explicit override (e.g. a 13.0.x ISO) or the VSA product's fresh-install entry.
        if (-not $GrubDefaultEntry) { $GrubDefaultEntry = $vsa.Grub }
        $parts   = $GrubDefaultEntry -split '>'
        $submenu = $parts[0].Trim(); $leaf = $parts[-1].Trim()
        $default = $GrubDefaultEntry
    }
    else {
        $submenu = if ($MultiDisk) { 'Standard (Multi-Disk) Deployment' } else { 'Single-Disk Deployment' }
        $leaf    = if ($MultiDisk) { 'Install - fresh install, wipes everything (including local backups)' } else { 'Install - fresh install, wipes everything on all devices' }
        $default = "$submenu>$leaf"
    }
    $titles = @([regex]::Matches($GrubText, "(?m)^[ \t]*(?:menuentry|submenu)[ \t]+(['`"])(.+?)\1") | ForEach-Object { $_.Groups[2].Value })
    foreach ($needed in @($submenu, $leaf)) {
        if ($titles -notcontains $needed) {
            $hint = if ($vsa) { "Is -BaseIso the Veeam SOFTWARE Appliance ISO (VeeamSoftwareAppliance_13.1.x)?" } else { 'Toggle -MultiDisk or update the expected titles for this ISO build.' }
            throw "grub.cfg has no menu title '$needed'. Titles found: $(($titles | Sort-Object -Unique) -join ' | '). $hint"
        }
    }
    $body = [regex]::Match($GrubText, "(?ms)^[ \t]*menuentry[ \t]+(['`"])" + [regex]::Escape($leaf) + "\1[^\n{]*\{\n(.*?)^[ \t]*\}")
    $linux  = if ($body.Success) { [regex]::Match($body.Groups[2].Value, '(?m)^[ \t]*linux(efi)?[ \t].*$').Value.Trim() } else { '' }
    $initrd = if ($body.Success) { [regex]::Match($body.Groups[2].Value, '(?m)^[ \t]*initrd(efi)?[ \t].*$').Value.Trim() } else { '' }
    return [pscustomobject]@{ Submenu = $submenu; Leaf = $leaf; Default = $default; Linux = $linux; Initrd = $initrd }
}

function Get-PatchedApplianceConfigs {
    # Extract the REAL kickstart + grub from the base ISO and apply the per-node edits. Returns
    # the patched file paths plus what was matched, so -ValidateOnly can show the operator exactly
    # what a build changes. No repack here.
    #
    # 13.1 VIA ISO layout (VeeamInfrastructureAppliance_13.1.x): ONE unified kickstart
    # /proxy-ks.cfg for all roles (role moves into the answer file), grub at /EFI/BOOT/grub.cfg,
    # volume label VeeamJeOS, boot submenus "Single-Disk Deployment" and "Standard (Multi-Disk)
    # Deployment". The kernel lines reference LABEL=VeeamJeOS:/proxy-ks.cfg.
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][string]$BaseIso,
        [Parameter(Mandatory)][string]$Scratch,
        [Parameter(Mandatory)]$SharedArtifacts
    )
    if (-not (Test-Path -LiteralPath $Scratch -PathType Container)) { New-Item -ItemType Directory -Path $Scratch -Force -WhatIf:$false | Out-Null }
    # VSA rows: /vbr-ks.cfg or /vbem-ks.cfg from the Software Appliance ISO; VIA rows: -KickstartName.
    $KickstartName = Get-RowKickstart -Row $Row
    $exKs   = Join-Path $Scratch $KickstartName
    $exGrub = Join-Path $Scratch 'grub.cfg'

    # 1. Extract (read-only: -indev, never -dev, so the base ISO is never modified).
    # A missing file makes xorriso abort (exit 5) before anything is written: catch that and explain it
    # (lab 2026-10-14: vbr / em rows run against the Infrastructure Appliance ISO gave a bare "xorriso failed").
    $xErr = $null
    try {
        Invoke-Xorriso -Arguments @('-indev', (Convert-ToolPath $BaseIso), '-osirrox', 'on',
            '-extract', "/$KickstartName", (Convert-ToolPath $exKs),
            '-extract', '/EFI/BOOT/grub.cfg', (Convert-ToolPath $exGrub))
    }
    catch { $xErr = $_ }
    if ($xErr -or -not (Test-Path $exKs) -or -not (Test-Path $exGrub)) {
        if (Get-RowVsaProduct -Row $Row) { throw "Could not extract /$KickstartName and /EFI/BOOT/grub.cfg from '$BaseIso'. CSV role '$($Row.role)' needs the Veeam SOFTWARE Appliance ISO (VeeamSoftwareAppliance_13.1.x: /vbr-ks.cfg + /vbem-ks.cfg), not the Infrastructure Appliance ISO." }
        if ($KickstartName -eq 'proxy-ks.cfg' -and (Split-Path $BaseIso -Leaf) -match 'SoftwareAppliance') { throw "Could not extract /$KickstartName from '$BaseIso'. CSV role '$($Row.role)' is an Infrastructure Appliance role (proxy / gateway) and needs the Veeam INFRASTRUCTURE Appliance ISO (VeeamInfrastructureAppliance_13.1.x), not the Software Appliance ISO." }
        throw "Could not extract /$KickstartName and /EFI/BOOT/grub.cfg from '$BaseIso'. List the ISO root with 'xorriso -indev <iso> -find / -maxdepth 1': 13.1 ships /proxy-ks.cfg, 13.0.x shipped /vmware-proxy-ks.cfg (pass -KickstartName)."
    }

    # 2. Kickstart: swap the network line (the VIA renders it in %pre as DHCP with a hashed
    #    hostname) for the per-node STATIC line.
    # -PromptIso: the values are shell variables set by the prompt block in %pre (see below).
    $prompt = [bool]($Row.PSObject.Properties['_prompt'] -and $Row._prompt)
    $netTok = if ($prompt) { @{ HOSTNAME = '${VAD_HOST}'; IP = '${VAD_IP}'; NETMASK = '${VAD_MASK}'; GATEWAY = '${VAD_GW}'; DNS = '${VAD_DNS}' } }
              else { @{ HOSTNAME = $Row.hostname; IP = $Row.ip; NETMASK = $Row.netmask; GATEWAY = $Row.gateway; DNS = $Row.dns } }
    $netLine = ConvertTo-RenderedTemplate -TemplatePath (Join-Path $SharedArtifacts.TemplateDir 'network-line.template') -Tokens $netTok
    $netLine = ($netLine -split "`n" | Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') } | Select-Object -First 1)
    if (-not $netLine) { throw "network-line.template produced no active network line." }
    $netLine = $netLine.Trim()
    # Optional CSV column dnssearch (search domains, ',' or ';'-separated) -> anaconda --ipv4-dns-search.
    $srch = if (-not $prompt -and $Row.PSObject.Properties['dnssearch']) { (([string]$Row.dnssearch) -split '[,; ]+' | Where-Object { $_ }) -join ',' } else { '' }
    if ($srch) { $netLine += " --ipv4-dns-search=$srch" }

    $ksText = (Get-Content -Raw $exKs) -replace "`r`n", "`n"
    $rxNet = [regex]'(?m)^[ \t]*network[ \t]+--bootproto=\S+.*$'
    if (-not $rxNet.IsMatch($ksText)) { throw "No 'network --bootproto=...' line found in /$KickstartName - the VIA kickstart layout changed; inspect $exKs." }
    $nic2 = if ($prompt) { $null } else { Get-RowNic2 -Row $Row }
    if ($prompt) {
        # Generic ISO: ask for name + network on the console before the VIA writes its network file.
        $rxCat = [regex]'(?m)^[ \t]*cat[ \t]*<<[ \t]*EOF[ \t]*>[ \t]*/tmp/pre-network\.cfg[ \t]*$'
        $nCat = $rxCat.Matches($ksText).Count
        if ($nCat -ne 1) { throw "Expected exactly one 'cat <<EOF > /tmp/pre-network.cfg' in /$KickstartName (found $nCat) - the VIA kickstart layout changed; inspect $exKs." }
        $d = $Row._defaults
        $ask = ConvertTo-RenderedTemplate -TemplatePath (Join-Path $SharedArtifacts.TemplateDir 'prompt-network.sh.template') -Tokens @{
            DEF_MASK = $d.netmask; DEF_GW = $d.gateway; DEF_DNS = $d.dns; DEF_SEARCH = $d.dnssearch; DEF_MASK2 = $d.netmask2 }
        $ask = ($ask -replace "`r`n", "`n").TrimEnd("`n") + "`n"
        $netLine = $netLine.Replace('--bootproto=static', '--bootproto=static --device=${VAD_NIC1}') + ' ${VAD_SRCH_OPT}' + "`n" + '${VAD_NET2}'
        $ksText = $rxCat.Replace($ksText, { param($m) $ask + $m.Value }, 1)
    }
    elseif ($nic2) {
        # Two adapters. %pre names them by PCI order at install time (adapter 1 of the VM = first device
        # = NIC 1), so the kickstart never guesses ens192/ens224-style names; the --device values are
        # shell variables expanded inside the VIA's own unquoted heredoc, like its ${MACH_HASH}. A VM
        # that has only one adapter fails the install on purpose instead of getting half a network.
        $rxCat = [regex]'(?m)^[ \t]*cat[ \t]*<<[ \t]*EOF[ \t]*>[ \t]*/tmp/pre-network\.cfg[ \t]*$'
        $nCat = $rxCat.Matches($ksText).Count
        if ($nCat -ne 1) { throw "Expected exactly one 'cat <<EOF > /tmp/pre-network.cfg' in /$KickstartName (found $nCat) - the VIA kickstart layout changed; inspect $exKs." }
        $disc = @'
# >>> veeam-autodeploy (generated): two network adapters, matched by PCI order (adapter 1 = NIC 1) >>>
VAD_NICS=$(for n in /sys/class/net/*; do [ -e "$n/device" ] || continue; echo "$(readlink -f "$n/device") ${n##*/}"; done | sort | cut -d' ' -f2)
VAD_NIC1=$(echo "$VAD_NICS" | sed -n 1p)
VAD_NIC2=$(echo "$VAD_NICS" | sed -n 2p)
if [ -z "$VAD_NIC1" ] || [ -z "$VAD_NIC2" ]; then
    echo "veeam-autodeploy: this node is set up for 2 network adapters, the VM has: ${VAD_NICS:-none}. Add the second adapter and reinstall." >&2
    exit 1
fi
echo "veeam-autodeploy: NIC1=${VAD_NIC1} NIC2=${VAD_NIC2}"
# <<< veeam-autodeploy <<<

'@
        $disc = $disc -replace "`r`n", "`n"
        $netLine = $netLine.Replace('--bootproto=static', '--bootproto=static --device=${VAD_NIC1}')
        $line2 = ConvertTo-RenderedTemplate -TemplatePath (Join-Path $SharedArtifacts.TemplateDir 'network-line-nic2.template') -Tokens @{
            DEVICE = '${VAD_NIC2}'; IP2 = $nic2.Ip; NETMASK2 = $nic2.Netmask }
        $line2 = ($line2 -split "`n" | Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') } | Select-Object -First 1)
        if (-not $line2) { throw "network-line-nic2.template produced no active network line." }
        $netLine = $netLine + "`n" + $line2.Trim()
        $ksText = $rxCat.Replace($ksText, { param($m) $disc + $m.Value }, 1)
    }
    $ksText = $rxNet.Replace($ksText, { param($m) $netLine }, 1)

    # 2b. Veeam logs on disk 2 (-LogsOnDataDisk): the kickstart's own rsyslog / logrotate / retention
    #     setup uses VEEAM_LOG_DIR and VEEAM_LEGACY_LOG_DIR = /var/log/VeeamBackup. Point both at the
    #     data-volume folder; the generated %post block (Build-KickstartPost -LogsDir) creates that folder
    #     and writes rootLogDirPath, which is what the console's "Logs location" does.
    if ($LogsOnDataDisk) {
        foreach ($var in 'VEEAM_LOG_DIR', 'VEEAM_LEGACY_LOG_DIR') {
            $rxVar = [regex]('(?m)^([ \t]*' + $var + '=")' + [regex]::Escape($script:VeeamLogsDefaultDir) + '(")[ \t]*$')
            $nVar = $rxVar.Matches($ksText).Count
            if ($nVar -ne 1) { throw "Expected exactly one '$var=`"$script:VeeamLogsDefaultDir`"' line in /$KickstartName (found $nVar) - the VIA kickstart layout changed; inspect $exKs." }
            $ksText = $rxVar.Replace($ksText, { param($m) $m.Groups[1].Value + $script:VeeamLogsDataDir + $m.Groups[2].Value }, 1)
        }
    }

    # 3. Kickstart: insert the Initial-Configuration block INSIDE the appliance %post. Anchors in
    #    order: the line the Veeam docs name, then the anchor community tooling uses on the 13.x
    #    VIA kickstart, then the documented end-of-post marker.
    $block = Build-KickstartPost -SharedArtifacts $SharedArtifacts -LogsDir $(if ($LogsOnDataDisk) { $script:VeeamLogsDataDir } else { '' })
    $anchors = @(
        @{ Name = 'log "Veeam post install commands" (documented)'; Rx = '(?m)^[ \t]*log[ \t]+"Veeam post install commands"[ \t]*$'; Mode = 'after' },
        @{ Name = 'mkdir -p /var/log/veeam/ (fallback)';            Rx = '(?m)^[ \t]*mkdir[ \t]+-p[ \t]+/var/log/veeam/?[ \t]*$';        Mode = 'after' },
        @{ Name = '# post end (fallback)';                          Rx = '(?m)^[ \t]*#[ \t]*post end[ \t]*$';                          Mode = 'before' }
    )
    $used = $null
    foreach ($a in $anchors) {
        $m = [regex]::Match($ksText, $a.Rx)
        if (-not $m.Success) { continue }
        # Inside a %post block? The LAST kickstart section marker before the anchor must be %post
        # (a plain %end count is fooled by the %pre ... %end block that precedes %post).
        $before  = $ksText.Substring(0, $m.Index)
        $markers = [regex]::Matches($before, '(?m)^%(pre|post|packages|addon|anaconda|onerror|traceback|end)\b')
        $inPost  = ($markers.Count -gt 0) -and ($markers[$markers.Count - 1].Groups[1].Value -eq 'post')
        if (-not $inPost) { Write-Log "Anchor '$($a.Name)' found outside a %post block - skipping it." 'WARN'; continue }
        if ($a.Mode -eq 'after') {
            $insertAt = $m.Index + $m.Length
            $ksText = $ksText.Substring(0, $insertAt) + "`n" + $block.TrimEnd("`n") + $ksText.Substring($insertAt)
        }
        else {
            $ksText = $ksText.Substring(0, $m.Index) + $block + $ksText.Substring($m.Index)
        }
        $used = $a.Name; break
    }
    if (-not $used) {
        throw "No insertion anchor found inside a %post block of /$KickstartName (looked for: $($anchors.Name -join ' | ')). The kickstart layout changed - inspect $exKs and update the anchors."
    }
    Write-TextFileLF -Path $exKs -Text $ksText

    # 4. grub: default entry + timeout + inst.assumeyes on every kernel line that boots the
    #    kickstart. Assert the expected submenu/entry titles exist so a renamed menu fails the
    #    build here instead of dropping the VM into an interactive installer.
    $grubText = (Get-Content -Raw $exGrub) -replace "`r`n", "`n"
    $ie = Get-GrubInstallEntry -GrubText $grubText -Row $Row
    $defaultEntry = $ie.Default
    if ($grubText -match '(?m)^\s*set\s+timeout=') { $grubText = [regex]::Replace($grubText, '(?m)^\s*set\s+timeout=.*$', "set timeout=$GrubTimeout") }
    else { $grubText = "set timeout=$GrubTimeout`n" + $grubText }
    if ($grubText -match '(?m)^\s*set\s+default=') { $grubText = [regex]::Replace($grubText, '(?m)^\s*set\s+default=.*$', ('set default="{0}"' -f $defaultEntry)) }
    else { $grubText = ('set default="{0}"' -f $defaultEntry) + "`n" + $grubText }
    $rxKernel = [regex]("(?m)^(.*LABEL=" + [regex]::Escape($IsoLabel) + ':/' + [regex]::Escape($KickstartName) + '\b.*)$')
    $kernelLines = $rxKernel.Matches($grubText).Count
    if ($kernelLines -eq 0) { throw "grub.cfg has no kernel line referencing LABEL=${IsoLabel}:/$KickstartName - check -IsoLabel / -KickstartName against this ISO." }
    $grubText = $rxKernel.Replace($grubText, { param($m) if ($m.Value -match 'inst\.assumeyes') { $m.Value } else { $m.Value.TrimEnd() + ' inst.assumeyes' } })
    Write-TextFileLF -Path $exGrub -Text $grubText

    return [pscustomobject]@{
        Kickstart   = $exKs
        KsName      = $KickstartName
        Grub        = $exGrub
        Anchor      = $used
        GrubDefault = $defaultEntry
        KernelLines = $kernelLines
        Nic2        = [bool]$nic2
        Prompt      = $prompt
        LogsOnDataDisk = [bool]$LogsOnDataDisk
    }
}

function New-ApplianceIso {
    # Per-node ISO: copy the pristine base, then replace the two patched files in place with
    # xorriso ('-boot_image any replay' re-applies the existing EFI/isohybrid boot setup).
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][string]$BaseIso,
        [Parameter(Mandatory)][string]$OutDir,
        [Parameter(Mandatory)]$SharedArtifacts,
        [switch]$Force
    )
    if (Test-Path -LiteralPath $OutDir -PathType Leaf) {
        throw "OutDir '$OutDir' exists as a FILE, not a directory. Remove it (or set a different -IsoStagingDir) and re-run."
    }
    if (-not (Test-Path -LiteralPath $OutDir -PathType Container)) { New-Item -ItemType Directory -Path $OutDir -Force -WhatIf:$false | Out-Null }
    $target = Join-Path $OutDir ("{0}.iso" -f $Row.hostname)

    if ((Test-Path $target) -and -not $Force) {
        if ((Get-Item $target).LastWriteTimeUtc -gt (Get-Item $BaseIso).LastWriteTimeUtc) {
            Write-Log "ISO for '$($Row.hostname)' already built and newer than base - reusing (use -Force to rebuild)." 'WARN'
            return $target
        }
    }
    if (-not $PSCmdlet.ShouldProcess($Row.hostname, "Build appliance ISO from $BaseIso")) {
        Write-Log "WHATIF: would build '$target' from '$BaseIso'." 'INFO'
        return $target
    }

    $scratch = Join-Path $OutDir ("_build_{0}" -f $Row.hostname)
    if (Test-Path $scratch) { Remove-Item $scratch -Recurse -Force }
    try {
        $cfg = Get-PatchedApplianceConfigs -Row $Row -BaseIso $BaseIso -Scratch $scratch -SharedArtifacts $SharedArtifacts
        Write-Log "Patched /$($cfg.KsName) (static network + init block after '$($cfg.Anchor)') and grub (default '$($cfg.GrubDefault)', inst.assumeyes on $($cfg.KernelLines) kernel line(s))." 'INFO'

        Copy-Item -LiteralPath $BaseIso -Destination $target -Force
        $xa = @('-dev', (Convert-ToolPath $target), '-boot_image', 'any', 'replay',
            '-rm', "/$($cfg.KsName)", '--', '-map', (Convert-ToolPath $cfg.Kickstart), "/$($cfg.KsName)",
            '-rm', '/EFI/BOOT/grub.cfg', '--', '-map', (Convert-ToolPath $cfg.Grub), '/EFI/BOOT/grub.cfg')
        Invoke-Xorriso -Arguments ($xa + '-commit')

        Write-Log ("Built appliance ISO: {0}{1}{2}" -f $target, $(if ($cfg.Nic2) { ' (2 network adapters)' }), $(if ($cfg.LogsOnDataDisk) { ' (Veeam logs on disk 2)' })) 'OK'
        return $target
    }
    finally {
        Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function New-MultiNodeApplianceIso {
    # ONE ISO for many nodes (-IsoOnly -SingleIso). Every row's patched kickstart goes into
    # /autodeploy/nNNN.cfg and a new boot submenu gets one entry per row that points at it, built
    # from the stock Install entry (same kernel flags, e.g. inst.vsingledisk). The grub timeout is
    # -1: the menu waits until the person at the VM console picks the entry for THAT VM, so an
    # unattended boot never installs a node under another node's name and IP. The stock Veeam
    # entries and /proxy-ks.cfg are left as they are.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][object[]]$Rows,
        [Parameter(Mandatory)][string]$BaseIso,
        [Parameter(Mandatory)][string]$OutDir,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$SharedArtifacts
    )
    if (-not (Test-Path -LiteralPath $OutDir -PathType Container)) { New-Item -ItemType Directory -Path $OutDir -Force -WhatIf:$false | Out-Null }
    $target  = Join-Path $OutDir $Name
    # Titles stay short: the 13.1 grub theme cuts a line at about 75 characters (seen in the lab).
    $subMenu = "AutoDeploy: $($Rows.Count) node(s), fresh install wipes all disks - pick THIS VM"
    $entries = for ($i = 0; $i -lt $Rows.Count; $i++) {
        $r = $Rows[$i]
        $n2 = Get-RowNic2 -Row $r
        $title = '{0:D2}  {1}  {2}{3}' -f ($i + 1), $r.hostname, $r.ip, $(if ($n2) { ' / ' + $n2.Ip } else { '' })
        if ($title -match "['>]") { throw "Row '$($r.hostname)': the boot menu title cannot contain a quote or '>'." }
        [pscustomobject]@{ Row = $r; Title = $title; Ks = ('autodeploy/n{0:D3}.cfg' -f ($i + 1)) }
    }
    if (-not $PSCmdlet.ShouldProcess($Name, "Build one appliance ISO with $($Rows.Count) boot entries from $BaseIso")) {
        Write-Log "WHATIF: would build '$target' with $($Rows.Count) boot entries." 'INFO'
        return [pscustomobject]@{ Path = $target; SubMenu = $subMenu; Entries = @($entries) }
    }

    $scratch = Join-Path $OutDir '_build_multi'
    if (Test-Path $scratch) { Remove-Item $scratch -Recurse -Force }
    try {
        # Per-node kickstarts: the same patch as a per-node ISO, only stored under their own name.
        $ksDir = Join-Path $scratch 'autodeploy'
        foreach ($e in $entries) {
            $cfg = Get-PatchedApplianceConfigs -Row $e.Row -BaseIso $BaseIso -Scratch (Join-Path $scratch ("_" + $e.Row.hostname)) -SharedArtifacts $SharedArtifacts
            Write-TextFileLF -Path (Join-Path $scratch $e.Ks) -Text ((Get-Content -Raw $cfg.Kickstart) -replace "`r`n", "`n")
        }

        # grub: built from the PRISTINE grub.cfg, not the per-node patched one.
        $pristine = Join-Path $scratch 'grub.pristine.cfg'
        Invoke-Xorriso -Arguments @('-indev', (Convert-ToolPath $BaseIso), '-osirrox', 'on', '-extract', '/EFI/BOOT/grub.cfg', (Convert-ToolPath $pristine))
        $grubText = (Get-Content -Raw $pristine) -replace "`r`n", "`n"
        $ie = Get-GrubInstallEntry -GrubText $grubText
        $ksRef = 'LABEL=' + $IsoLabel + ':/' + $KickstartName
        if (-not $ie.Linux.Contains($ksRef) -or -not $ie.Initrd) {
            throw "grub.cfg entry '$($ie.Leaf)' has no kernel line with $ksRef and an initrd line - check -IsoLabel / -KickstartName against this ISO."
        }
        $nl = "`n"
        $b = [System.Text.StringBuilder]::new()
        [void]$b.Append("submenu '$subMenu' {" + $nl)
        foreach ($e in $entries) {
            $linux = $ie.Linux.Replace($ksRef, 'LABEL=' + $IsoLabel + ':/' + $e.Ks)
            if ($linux -notmatch 'inst\.assumeyes') { $linux += ' inst.assumeyes' }
            [void]$b.Append("`tmenuentry '$($e.Title)' --class fedora --class gnu-linux --class gnu --class os {" + $nl)
            [void]$b.Append("`t`t$linux$nl`t`t$($ie.Initrd)$nl`t}$nl")
        }
        [void]$b.Append('}' + $nl + $nl)
        $first = [regex]::Match($grubText, '(?m)^(submenu|menuentry)[ \t]')
        if (-not $first.Success) { throw "grub.cfg has no top-level submenu/menuentry to insert the AutoDeploy menu before." }
        $grubText = $grubText.Substring(0, $first.Index) + $b.ToString() + $grubText.Substring($first.Index)
        # Wait forever, AutoDeploy submenu highlighted: Enter only opens the list of nodes.
        if ($grubText -match '(?m)^\s*set\s+timeout=') { $grubText = [regex]::Replace($grubText, '(?m)^\s*set\s+timeout=.*$', 'set timeout=-1') }
        else { $grubText = "set timeout=-1`n" + $grubText }
        if ($grubText -match '(?m)^\s*set\s+default=') { $grubText = [regex]::Replace($grubText, '(?m)^\s*set\s+default=.*$', ('set default="{0}"' -f $subMenu)) }
        else { $grubText = ('set default="{0}"' -f $subMenu) + "`n" + $grubText }
        $grubOut = Join-Path $scratch 'grub.cfg'
        Write-TextFileLF -Path $grubOut -Text $grubText

        Copy-Item -LiteralPath $BaseIso -Destination $target -Force
        Invoke-Xorriso -Arguments @('-dev', (Convert-ToolPath $target), '-boot_image', 'any', 'replay',
            '-map', (Convert-ToolPath $ksDir), '/autodeploy',
            '-rm', '/EFI/BOOT/grub.cfg', '--', '-map', (Convert-ToolPath $grubOut), '/EFI/BOOT/grub.cfg',
            '-commit')
        Write-Log "Built ONE appliance ISO for $($Rows.Count) node(s): $target (boot menu '$subMenu', waits for a pick)." 'OK'
        return [pscustomobject]@{ Path = $target; SubMenu = $subMenu; Entries = @($entries) }
    }
    catch {
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue }
        throw
    }
    finally {
        Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-CsvAddressesFree {
    # -IsoOnly: someone else creates and boots the VMs, so warn BEFORE any ISO is built when a CSV
    # address already answers - a live machine there means an IP conflict once the appliance boots.
    # One ping from THIS host: no answer does not prove the address is free (ICMP filtered, no route).
    param([Parameter(Mandatory)][object[]]$Rows)
    $busy = @(foreach ($r in $Rows) {
        $addrs = @([string]$r.ip); $n2 = Get-RowNic2 -Row $r; if ($n2) { $addrs += $n2.Ip }
        foreach ($a in $addrs) {
            $up = $false
            try { $up = [bool](Test-Connection -TargetName $a -Count 1 -TimeoutSeconds 1 -Quiet -ErrorAction Stop) } catch { $up = $false }
            if ($up) { "$($r.hostname)=$a" }
        }
    })
    if ($busy.Count) {
        Write-Log (("These CSV addresses already answer a ping: {0}. A machine there means an IP conflict when the appliance boots - " +
                    "check before handing out the ISO (expected only when rebuilding a node whose old VM is switched off before the new one boots).") -f ($busy -join ', ')) 'WARN'
    }
    else { Write-Log "No CSV address answered a ping from this host (not a guarantee: ICMP may be filtered or not routed)." 'OK' }
}

function Write-IsoVmSpec {
    # -IsoOnly: the build sheet for whoever creates the VMs in vCenter - the same hardware Stage A
    # would set, which ISO / boot entry belongs to which VM, and what to do after the install.
    # Written as <name>-VM-SPEC.txt (for people) and <name>-VM-SPEC.csv (for their own tooling).
    # Holds no secrets.
    param(
        [object[]]$Items = @(),                     # Row, Iso, Boot (may be empty for -Prompt without a CSV)
        [Parameter(Mandatory)][string]$OutDir,
        [Parameter(Mandatory)][string]$BaseName,
        [switch]$Single,
        [switch]$Prompt                             # -PromptIso: generic ISO, values typed at install time
    )
    $vsaSpec = [bool]@($Items | Where-Object { Get-RowVsaProduct -Row $_.Row }).Count
    $sizes = @($Items | ForEach-Object { Get-RowVmSize -Row $_.Row })
    $sz0   = if ($sizes.Count) { $sizes[0] } else { Get-RowVmSize -Row ([pscustomobject]@{ role = '' }) }
    $mixed = @($sizes | ForEach-Object { "$($_.Cpu)/$($_.MemoryGB)/$($_.DiskGB)/$($_.MultiDisk)/$($_.DataDiskGB)" } | Sort-Object -Unique).Count -gt 1
    $disk2 = if ($sz0.MultiDisk) { "; disk 2 = $($sz0.DataDiskGB) GB thin (data$(if ($LogsOnDataDisk) { "; Veeam logs go to $script:VeeamLogsDataDir" }))" } else { '' }
    $sb    = if ($NoSecureBoot) { 'OFF (-NoSecureBoot was given: troubleshooting only)' } else { "ON$(if (-not $vsaSpec) { ' (required by Veeam for the VIA)' })" }
    $anyNic2 = $Prompt -or [bool]@($Items | Where-Object { Get-RowNic2 -Row $_.Row }).Count
    $table = @($Items | ForEach-Object {
        $n2 = Get-RowNic2 -Row $_.Row
        $sz = Get-RowVmSize -Row $_.Row
        [pscustomobject][ordered]@{
            vm_name = $_.Row.hostname; ip = $_.Row.ip; ip2 = $(if ($n2) { $n2.Ip } else { '' }); iso = (Split-Path $_.Iso -Leaf); boot_entry = $_.Boot
            cluster = $_.Row.cluster; datastore = $_.Row.datastore; folder = $_.Row.folder; portgroup = $_.Row.portgroup; portgroup2 = $(if ($n2) { $n2.PortGroup } else { '' })
            role = $_.Row.role; vcpu = $sz.Cpu; memory_gb = $sz.MemoryGB; disk1_gb = $sz.DiskGB; disk2_gb = $(if ($sz.MultiDisk) { $sz.DataDiskGB } else { '' })
        }
    })
    $netLines = if ($anyNic2) {
        @('  Network       adapter 1 (VMXNET3) = NIC 1 on the port group in column portgroup (management, VBR traffic);',
          '                rows with ip2: adapter 2 (VMXNET3) = NIC 2 on column portgroup2 (static address, no gateway).',
          '                Adapter ORDER matters: the installer takes the first PCI device as NIC 1, the second as NIC 2.')
    } else { @('  Network       1 adapter on the port group in the table') }
    $cols = @('vm_name', 'ip') + $(if ($anyNic2) { @('ip2') } else { @() }) + @('boot_entry', 'iso', 'cluster', 'datastore', 'folder', 'portgroup') + $(if ($anyNic2) { @('portgroup2') } else { @() }) +
            $(if ($mixed) { @('role', 'vcpu', 'memory_gb', 'disk1_gb', 'disk2_gb') } else { @() })
    $csv = Join-Path $OutDir "$BaseName-VM-SPEC.csv"
    if ($table.Count) { $table | Export-Csv -Path $csv -NoTypeInformation }
    $boot = if ($Prompt) {
        @("3. Attach the ISO and power on. After about a minute the console stops on 'AutoDeploy' and asks for:",
          "   hostname (FQDN), NIC 1 IP / netmask / gateway / DNS / search domain, and - when the VM has a 2nd adapter - NIC 2 IP / netmask",
          "   (type - to leave NIC 2 unconfigured). It shows a summary; type y to install, anything else to start over.",
          "   Nothing installs until y. Every VM gets its own name and addresses: never type another VM's values.")
    }
    elseif ($Single) {
        @("3. Power on and open the VM console. The boot menu WAITS - nothing installs until an entry is picked.",
          "   Open 'AutoDeploy: ...' and pick the line with THIS VM's name (column boot_entry).",
          "   Picking another VM's line gives this VM that name and IP: an IP conflict with the real one.")
    } else {
        @("3. Attach the ISO named after the VM (column iso) and power on. It installs without a keypress.")
    }
    $txt = @(
        "AutoDeploy Proxies - VM build sheet ($((Get-Date).ToString('yyyy-MM-dd HH:mm', [cultureinfo]::InvariantCulture)))"
        ''
        'Every VM:'
        "  Guest OS      Red Hat Enterprise Linux 9 (64-bit)  [$GuestId]"
        $(if ($mixed) { '  CPU / RAM     per VM - see the columns vcpu / memory_gb in the table' } else { "  CPU / RAM     $($sz0.Cpu) vCPU / $($sz0.MemoryGB) GB" })
        $(if ($mixed) { '  Disks         per VM - see disk1_gb / disk2_gb (thin; disk 1 = system, disk 2 = data)' } else { "  Disks         disk 1 = $($sz0.DiskGB) GB thin (system)$disk2" })
        $netLines
        "  Firmware      EFI, Secure Boot $sb"
        '  Advanced      disk.EnableUUID = TRUE   (VBR matches the proxy VM to the managed server)'
        '  CD/DVD        datastore ISO file, "Connect at power on" ticked'
        ''
        'Steps:'
        '1. Upload the ISO to a datastore the hosts can read.'
        '2. Create each VM below (VM name = vm_name) on its cluster / datastore / folder / port group.'
        $boot
        '4. Install + first-boot configuration take about 25 minutes. Done when https://<ip>:10443 (Host Management Console) answers.'
        '5. Disconnect the CD drive, then delete the ISO from the datastore and from the build folder:'
        '   it contains the appliance passwords and MFA seeds in clear text.'
        $(if ($vsaSpec) {
            @('6. Software Appliance: done when https://<ip> answers too (Backup & Replication web UI / Enterprise Manager). Log in as veeamadmin.',
              '   Enterprise Manager: add the backup servers under Configuration > Backup Servers.')
        } else {
            @('6. Register to VBR (needs VBR access only, no vCenter):',
              '   Deploy-VeeamProxies.ps1 -CsvPath <same csv> -Vbr <vbr> -VBRServer <vbr fqdn> -SkipDeploy')
        })
        ''
        $(if ($table.Count) { ($table | Format-Table -Property $cols -AutoSize | Out-String -Width 400).TrimEnd() } else { '(no CSV given: take hostname and addresses from your own plan)' })
    )
    $txtPath = Join-Path $OutDir "$BaseName-VM-SPEC.txt"
    Set-Content -Path $txtPath -Value ($txt -join "`n")
    Write-Log "VM build sheet: $txtPath (+ .csv) - hand this to whoever creates the VMs." 'OK'
}

function Test-TcpPort {
    param([Parameter(Mandatory)][string]$TargetHost, [Parameter(Mandatory)][int]$Port, [int]$TimeoutMs = 3000)
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $iar = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($iar); return $true
    }
    catch { return $false }
    finally { $client.Close() }
}

function Wait-ApplianceReady {
    # Gate before Stage B: the appliance finished unattended install + first-boot config and is
    # reachable. Supported signals for a hardened, SSH-off VIA: guest-tools IP/hostname (if
    # open-vm-tools present) + Host Management Console HTTPS (TCP 10443). Require N consecutive hits.
    param(
        [Parameter(Mandatory)]$Row,
        $Vm,
        [int]$HmcPort = 10443,
        [int]$TimeoutSec = 1800,
        [int]$PollSec = 20,
        [int]$RequiredConsecutive = 3
    )
    Write-Log "Waiting for '$($Row.hostname)' (install + first-boot config; timeout ${TimeoutSec}s, gate=guest-IP + HMC:$HmcPort)..." 'STEP'
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $hits = 0
    while ((Get-Date) -lt $deadline) {
        # The HMC port is the real gate. Guest-tools data is a CONSISTENCY check only when the
        # appliance reports an address (catches a DHCP fallback or a mixed-up row); with no tools
        # or no address yet we do not block on it - the VIA may not run VMware Tools at all.
        $guestOk = $true
        if ($Vm) {
            try {
                $g = Get-VMGuest -VM $Vm -ErrorAction SilentlyContinue
                if ($g -and $g.IPAddress) {
                    $ipOk = ($g.IPAddress -contains $Row.ip)
                    $hnOk = (-not $g.HostName) -or ($g.HostName -like "$($Row.hostname)*") -or ($Row.hostname -like "$($g.HostName)*")
                    $guestOk = $ipOk -and $hnOk
                    if (-not $guestOk) { Write-Log "Guest tools report ip=$($g.IPAddress -join ',') host=$($g.HostName) - not the expected $($Row.ip)/$($Row.hostname) yet." 'WARN' }
                }
            }
            catch { }
        }
        $portOk = Test-TcpPort -TargetHost $Row.ip -Port $HmcPort -TimeoutMs 3000
        if ($guestOk -and $portOk) {
            $hits++
            if ($hits -ge $RequiredConsecutive) { Write-Log "'$($Row.hostname)' ready (guest IP + HMC:$HmcPort)." 'OK'; return $true }
        }
        else { $hits = 0 }
        Start-Sleep -Seconds $PollSec
    }
    throw (("Appliance '{0}' not ready within {1}s (guest-IP / HMC:{2} gate not met). Open the VM console: if it shows the " +
           "'Initial Configuration Wizard', the answer file was NOT applied at first boot - the settings file must carry real " +
           "NTP servers the appliance can resolve and real passwords/TOTP seed (not the example values); if it shows the " +
           "installer or a boot error, check the ISO/kickstart. See the README troubleshooting table.") -f $Row.hostname, $TimeoutSec, $HmcPort)
}

function Wait-VsaService {
    # VSA rows, after the Host Management Console answers: the product's own endpoint (TCP 443: VBR web
    # UI + REST API, or the Enterprise Manager web UI) must answer too before the row counts as deployed.
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)]$Product,
        [int]$TimeoutSec = 1800,
        [int]$PollSec = 20,
        [int]$RequiredConsecutive = 3
    )
    Write-Log "Waiting for the $($Product.ServiceName) on $($Row.ip):$($Product.ServicePort)..." 'STEP'
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $hits = 0
    while ((Get-Date) -lt $deadline) {
        if (Test-TcpPort -TargetHost $Row.ip -Port $Product.ServicePort -TimeoutMs 3000) {
            $hits++
            if ($hits -ge $RequiredConsecutive) { Write-Log "'$($Row.hostname)': $($Product.ServiceName) answers on :$($Product.ServicePort)." 'OK'; return $true }
        }
        else { $hits = 0 }
        Start-Sleep -Seconds $PollSec
    }
    throw ("'{0}': the Host Management Console is up but the {1} did not answer on :{2} within {3}s. Log in to https://{4}:10443 as veeamadmin and check the appliance status." -f
           $Row.hostname, $Product.ServiceName, $Product.ServicePort, $TimeoutSec, $Row.ip)
}

function Resolve-IsoDatastore {
    # New-CDDrive needs a concrete DATASTORE (not an SDRS cluster). Prefer -IsoDatastore; else the
    # row's datastore; if that is a datastore cluster, pick its member with the most free space.
    param($Row)
    if ($IsoDatastore) { return (Get-Datastore -Name $IsoDatastore -ErrorAction Stop) }
    $ds = Get-Datastore -Name $Row.datastore -ErrorAction SilentlyContinue
    if ($ds) { return $ds }
    $dsc = Get-DatastoreCluster -Name $Row.datastore -ErrorAction SilentlyContinue
    if ($dsc) { return (Get-Datastore -RelatedObject $dsc | Sort-Object FreeSpaceGB -Descending | Select-Object -First 1) }
    throw "Resolve-IsoDatastore: '$($Row.datastore)' is neither a datastore nor a datastore cluster."
}

$script:UploadAttempts = 3
$script:UploadRetrySec  = 30
function Copy-IsoToDatastore {
    param([Parameter(Mandatory)][string]$IsoPath, [Parameter(Mandatory)]$Datastore, [string]$FolderName = 'iso')
    $name  = Split-Path $IsoPath -Leaf
    $drive = "vdsiso_$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-PSDrive -Name $drive -PSProvider VimDatastore -Root '\' -Datastore $Datastore -ErrorAction Stop | Out-Null
    try {
        $dstDir = "${drive}:\$FolderName"
        if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir | Out-Null }
        # A datastore upload cannot resume: a dropped link (VPN, lab 2026-10-14: "Broken pipe" on a 15 GB VSA
        # ISO) restarts it from zero. Retry a few times before the row fails.
        for ($try = 1; ; $try++) {
            try { Copy-DatastoreItem -Item $IsoPath -Destination "$dstDir\$name" -Force; break }
            catch {
                if ($try -ge $script:UploadAttempts) { throw }
                Write-Log ("Upload of {0} failed (attempt {1}/{2}): {3} - retrying in {4}s." -f $name, $try, $script:UploadAttempts, $_.Exception.Message, $script:UploadRetrySec) 'WARN'
                Start-Sleep -Seconds $script:UploadRetrySec
            }
        }
    }
    finally { Remove-PSDrive -Name $drive -ErrorAction SilentlyContinue }
    return ("[{0}] {1}/{2}" -f $Datastore.Name, $FolderName, $name)
}

function Remove-IsoFromDatastore {
    param([Parameter(Mandatory)][string]$Hostname, [Parameter(Mandatory)]$Datastore, [string]$FolderName = 'iso')
    $drive = "vdsiso_$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-PSDrive -Name $drive -PSProvider VimDatastore -Root '\' -Datastore $Datastore -ErrorAction SilentlyContinue | Out-Null
    try {
        $p = "${drive}:\$FolderName\$Hostname.iso"
        if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue; Write-Log "Removed datastore ISO for '$Hostname'." 'OK' }
    }
    finally { Remove-PSDrive -Name $drive -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------
# Stage A - vSphere deploy (build ISO -> create UEFI VM -> attach -> wait -> detach)
# ---------------------------------------------------------------------------
function Get-PortGroupByName {
    # Resolve a CSV 'portgroup' value to an object New-VM accepts (VirtualPortGroupBase): a standard
    # port group - on the chosen host when one is given, since standard port groups exist per host -
    # or a distributed one. Get-VDPortgroup comes from VMware.VimAutomation.Vds; when that module is
    # not staged the cmdlet does not exist at all (a command-not-found error that -ErrorAction cannot
    # swallow), so check for it first. Returns $null when nothing matches.
    param([Parameter(Mandatory)][string]$Name, $VMHost)
    # @( ) around the whole 'if': assigning an if-expression unrolls a one-element result to a scalar,
    # and under StrictMode a scalar has no .Count (caught by the lab test, 2026-09-25).
    $std = @(if ($VMHost) { Get-VirtualPortGroup -Name $Name -VMHost $VMHost -Standard -ErrorAction SilentlyContinue }
             else         { Get-VirtualPortGroup -Name $Name -Standard -ErrorAction SilentlyContinue })
    if ($std.Count) { return $std[0] }
    if (Get-Command Get-VDPortgroup -ErrorAction SilentlyContinue) {
        $vd = @(Get-VDPortgroup -Name $Name -ErrorAction SilentlyContinue)
        if ($vd.Count) { return $vd[0] }
    }
    return $null
}

function Get-AllPortGroupNames {
    $names = @(Get-VirtualPortGroup -Standard -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    if (Get-Command Get-VDPortgroup -ErrorAction SilentlyContinue) {
        $names += @(Get-VDPortgroup -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    }
    return $names
}

function Test-VspherePlacement {
    # Preflight, right after Connect-VIServer and BEFORE any ISO is built: every distinct cluster,
    # datastore (or SDRS cluster), VM folder and port group named in the CSV must exist. A typo then
    # costs seconds, not a per-row build/upload/rollback cycle, and -WhatIf catches it too. On failure
    # the error lists what vCenter actually has.
    param([Parameter(Mandatory)]$Rows)
    $missing = [System.Collections.Generic.List[string]]::new()
    $u = { param($k) @($Rows | ForEach-Object { $_.$k } | Where-Object { $_ } | Sort-Object -Unique) }
    foreach ($c in (& $u 'cluster'))   { if (-not (Get-Cluster -Name $c -ErrorAction SilentlyContinue)) { $missing.Add("cluster '$c'") } }
    foreach ($d in (& $u 'datastore')) { if (-not (Get-Datastore -Name $d -ErrorAction SilentlyContinue) -and -not (Get-DatastoreCluster -Name $d -ErrorAction SilentlyContinue)) { $missing.Add("datastore / SDRS cluster '$d'") } }
    foreach ($f in (& $u 'folder'))    {
        $hits = @(Get-Folder -Name $f -Type VM -ErrorAction SilentlyContinue)
        if (-not $hits.Count) { $missing.Add("VM folder '$f'") }
        elseif ($hits.Count -gt 1) { Write-Log "VM folder name '$f' exists $($hits.Count) times in this vCenter - the first match is used. Rename or use a unique folder to be safe." 'WARN' }
    }
    $pgAll = @(@(& $u 'portgroup') + @($Rows | ForEach-Object { Get-RowNic2 -Row $_ } | Where-Object { $_ } | ForEach-Object { $_.PortGroup }) | Sort-Object -Unique)
    foreach ($p in $pgAll) {
        if (-not (Get-PortGroupByName -Name $p)) {
            $hint = if (Get-Command Get-VDPortgroup -ErrorAction SilentlyContinue) { '' } else { ' (standard port groups only - VMware.VimAutomation.Vds is not installed, so distributed port groups cannot be seen)' }
            $missing.Add("port group '$p'$hint")
        }
    }
    if ($missing.Count) {
        $show = { param($items) $a = @($items | Sort-Object -Unique); $s = ($a | Select-Object -First 25) -join ', '; if ($a.Count -gt 25) { $s += ", ... ($($a.Count) total)" }; $s }
        $avail = "Available - clusters: $(& $show (Get-Cluster | Select-Object -ExpandProperty Name)); " +
                 "datastores: $(& $show (Get-Datastore | Select-Object -ExpandProperty Name)); " +
                 "SDRS clusters: $(& $show (Get-DatastoreCluster -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)); " +
                 "VM folders: $(& $show (Get-Folder -Type VM | Where-Object { $_.Name -ne 'vm' } | Select-Object -ExpandProperty Name)); " +
                 "port groups: $(& $show (Get-AllPortGroupNames))"
        throw "vSphere placement check failed - not found in vCenter: $($missing -join '; '). Fix the CSV (the planner can load the inventory for you). $avail"
    }
    Write-Log "vSphere placement check passed for $($Rows.Count) row(s): clusters, datastores, folders and port groups all exist." 'OK'
}

function Save-VmConsoleScreenshot {
    # Best effort: vSphere writes the console PNG into the VM folder on its datastore; download it.
    param($Vm, [string]$OutDir, [string]$Name)
    if (-not $Vm) { return $null }
    try {
        $task = $Vm.ExtensionData.CreateScreenshot_Task()
        $t = Get-Task -Id ("Task-" + $task.Value) -ErrorAction SilentlyContinue
        if ($t) { Wait-Task -Task $t -ErrorAction SilentlyContinue | Out-Null }
        $shot = (Get-View $task).Info.Result
        if ($shot -notmatch '^\[(.+?)\] (.+)$') { return $null }
        $ds = Get-Datastore -Name $matches[1] -ErrorAction Stop
        $drive = "vshot_$([guid]::NewGuid().ToString('N').Substring(0,6))"
        New-PSDrive -Name $drive -PSProvider VimDatastore -Root '\' -Datastore $ds -ErrorAction Stop | Out-Null
        try {
            if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force -WhatIf:$false | Out-Null }
            $dest = Join-Path $OutDir ("{0}-console-{1}.png" -f $Name, (Get-Date).ToString('yyyyMMdd-HHmmss'))
            Copy-DatastoreItem -Item ("${drive}:\" + ($matches[2] -replace '/', '\')) -Destination $dest -Force
            return $dest
        }
        finally { Remove-PSDrive -Name $drive -ErrorAction SilentlyContinue }
    }
    catch { Write-Log "Could not capture the console screenshot: $($_.Exception.Message)" 'WARN'; return $null }
}

function Invoke-StageA-Deploy {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][string]$IsoPath
    )

    Write-Log "Stage A: deploying '$($Row.hostname)' -> cluster '$($Row.cluster)' / datastore '$($Row.datastore)'" 'STEP'

    $existingVm = Get-VM -Name $Row.hostname -ErrorAction SilentlyContinue
    if ($existingVm) {
        if ($Replace) { Move-ReplacedVmAside -Vm $existingVm -Hostname $Row.hostname }
        else { throw "A VM named '$($Row.hostname)' already exists in vCenter (use -Replace to redeploy over it)." }
    }

    # Least-loaded host in the cluster (simple memory balance).
    $vmhost = Get-Cluster -Name $Row.cluster | Get-VMHost |
        Where-Object { $_.ConnectionState -eq 'Connected' } |
        Sort-Object MemoryUsageGB | Select-Object -First 1
    if (-not $vmhost) { throw "No connected host found in cluster '$($Row.cluster)'." }

    # Datastore column accepts EITHER a datastore OR a datastore cluster (SDRS) - unchanged.
    $storage = Get-DatastoreCluster -Name $Row.datastore -ErrorAction SilentlyContinue
    if (-not $storage) { $storage = Get-Datastore -Name $Row.datastore -ErrorAction Stop }
    $location = if ($Row.folder) { Get-Folder -Name $Row.folder -ErrorAction Stop } else { $null }

    # Upload the per-node ISO to a datastore (New-CDDrive requires a datastore path).
    $isoDs = Resolve-IsoDatastore -Row $Row
    $isoDsPath = $null
    if ($PSCmdlet.ShouldProcess($Row.hostname, "Upload ISO to datastore [$($isoDs.Name)]")) {
        if ($script:Owned) { $script:Owned.IsoDatastore = $isoDs }   # before the copy: a half-written upload is ours too
        $isoDsPath = Copy-IsoToDatastore -IsoPath $IsoPath -Datastore $isoDs
        Write-Log "Uploaded ISO to $isoDsPath." 'OK'
    }

    $size = Get-RowVmSize -Row $Row
    $vsa  = Get-RowVsaProduct -Row $Row
    if ($PSCmdlet.ShouldProcess($Row.hostname, "New-VM (UEFI $($size.Cpu) vCPU/$($size.MemoryGB) GB/$($size.DiskGB) GB thin$(if ($size.MultiDisk) { " + $($size.DataDiskGB) GB" })) + attach ISO + power on")) {
        # Standard port groups exist per host, so resolve on the host the VM lands on (a multi-host
        # cluster otherwise hands New-VM another host's port group); distributed ones need the Vds module.
        $pg = Get-PortGroupByName -Name $Row.portgroup -VMHost $vmhost
        if (-not $pg) {
            throw ("Port group '{0}' not found on host {1} (standard) or as a distributed port group{2}." -f $Row.portgroup, $vmhost.Name,
                   $(if (Get-Command Get-VDPortgroup -ErrorAction SilentlyContinue) { '' } else { ' - VMware.VimAutomation.Vds is not installed, so distributed port groups cannot be seen' }))
        }
        # Optional second adapter (CSV portgroup2): resolved BEFORE the VM exists, so a typo costs nothing.
        $nic2 = Get-RowNic2 -Row $Row
        $pg2 = $null
        if ($nic2) {
            $pg2 = Get-PortGroupByName -Name $nic2.PortGroup -VMHost $vmhost
            if (-not $pg2) { throw "Port group '$($nic2.PortGroup)' (CSV portgroup2) not found on host $($vmhost.Name) (standard) or as a distributed port group." }
        }
        $newVmParams = @{
            Name              = $Row.hostname
            VMHost            = $vmhost
            Datastore         = $storage
            DiskGB            = $size.DiskGB
            DiskStorageFormat = 'Thin'
            MemoryGB          = $size.MemoryGB
            NumCpu            = $size.Cpu
            GuestId           = $GuestId
            Portgroup         = $pg
            CD                = $true
        }
        if ($location)        { $newVmParams.Location        = $location }
        if ($HardwareVersion) { $newVmParams.HardwareVersion = $HardwareVersion }
        $vm = New-VM @newVmParams
        if ($script:Owned) { $script:Owned.VmId = $vm.Id }

        # UEFI firmware + Secure Boot (Veeam requires Secure Boot ENABLED for the VIA). New-VM has
        # no -Firmware, so use a config spec. The repacked ISO only changes text config, so it
        # still boots with Secure Boot on.
        $spec = New-Object VMware.Vim.VirtualMachineConfigSpec
        $spec.Firmware = [VMware.Vim.GuestOsDescriptorFirmwareType]::efi
        if (-not $NoSecureBoot) {
            $spec.BootOptions = New-Object VMware.Vim.VirtualMachineBootOptions
            $spec.BootOptions.EfiSecureBootEnabled = $true
        }
        $vm.ExtensionData.ReconfigVM($spec)

        # disk.EnableUUID lets VBR match the proxy VM to the managed server (HotAdd on Linux proxies).
        New-AdvancedSetting -Entity $vm -Name 'disk.EnableUUID' -Value 'TRUE' -Confirm:$false -Force | Out-Null

        # Second adapter after the first: adapter order = PCI order = the order the kickstart names them in.
        if ($pg2) {
            New-NetworkAdapter -VM $vm -Portgroup $pg2 -Type Vmxnet3 -StartConnected -Confirm:$false | Out-Null
            Write-Log "Added network adapter 2 on '$($nic2.PortGroup)' = NIC 2 ($($nic2.Ip)/$($nic2.Netmask), no gateway)." 'INFO'
        }

        if ($size.MultiDisk) {
            New-HardDisk -VM $vm -CapacityGB $size.DataDiskGB -StorageFormat Thin -Confirm:$false | Out-Null
            Write-Log "Added $($size.DataDiskGB) GB thin data disk ($(if ($vsa) { 'VSA disk 2' } else { 'multi-disk deployment' }))." 'INFO'
        }

        # Attach the per-node ISO to the CD drive New-VM created (-CD) and boot it.
        Get-CDDrive -VM $vm | Set-CDDrive -IsoPath $isoDsPath -StartConnected:$true -Confirm:$false | Out-Null
        Start-VM -VM $vm -Confirm:$false | Out-Null
        Write-Log "Created + powered on '$($Row.hostname)' on host $($vmhost.Name) (UEFI, Secure Boot $(if ($NoSecureBoot) { 'OFF' } else { 'ON' })); booting unattended installer." 'OK'

        # Wait for unattended install + first boot (HMC answering), give veeam-init.service time to
        # apply the answer file, then detach + delete the secrets-bearing ISO. On a timeout, grab the
        # VM console as a PNG next to the staging area BEFORE any rollback removes the evidence.
        try {
            $readyTimeout = if ($vsa -and -not $script:BoundParams.ContainsKey('IsoReadyTimeoutSec')) { $script:VsaReadyTimeoutSec } else { $IsoReadyTimeoutSec }
            Wait-ApplianceReady -Row $Row -Vm $vm -HmcPort $HmcPort -TimeoutSec $readyTimeout -PollSec $IsoReadyPollSec | Out-Null
            # VSA: the product installs its services after the console is up - wait for its own port too.
            if ($vsa) { Wait-VsaService -Row $Row -Product $vsa -TimeoutSec $IsoReadyTimeoutSec -PollSec $IsoReadyPollSec | Out-Null }
        }
        catch {
            $shotPath = Save-VmConsoleScreenshot -Vm (Get-VM -Name $Row.hostname -ErrorAction SilentlyContinue) -OutDir (Split-Path -Parent $IsoPath) -Name $Row.hostname
            if ($shotPath) { Write-Log "Console screenshot of '$($Row.hostname)' saved to $shotPath for troubleshooting." 'WARN' }
            throw
        }
        if ($PostReadySettleSec -gt 0) {
            Write-Log "Settling ${PostReadySettleSec}s so the first-boot Initial Configuration can complete..." 'INFO'
            Start-Sleep -Seconds $PostReadySettleSec
        }
        Get-CDDrive -VM $vm | Set-CDDrive -NoMedia -Confirm:$false | Out-Null
        if (-not $KeepIso) {
            Remove-IsoFromDatastore -Hostname $Row.hostname -Datastore $isoDs
            Remove-Item -LiteralPath $IsoPath -Force -ErrorAction SilentlyContinue
            Write-Log "Removed staged ISO '$IsoPath' (it embeds the answer file)." 'INFO'
        }
        Write-Log "Detached ISO from '$($Row.hostname)'." 'OK'
    }
}

# ---------------------------------------------------------------------------
# Stage B - VBR registration with certificate trust (Veeam PowerShell)
# ---------------------------------------------------------------------------
function Invoke-StageB-Register {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param($Row)

    $regName = Get-RegistrationName -Row $Row
    Write-Log "Stage B (cmdlet): registering '$regName' to VBR (certificate-based trust)" 'STEP'

    # Idempotency - skip if already added
    if (Get-VBRServer -Name $regName -ErrorAction SilentlyContinue) {
        Write-Log "'$regName' already registered to this VBR - skipping add." 'WARN'
    }
    elseif ($PSCmdlet.ShouldProcess($regName, "Add-VBRLinux -UseCertificate -HandshakeCode -ForceDeployerFingerprint")) {
        # Veeam Add-VBRLinux (v13): "To add a Veeam Infrastructure Appliance, use the set of
        # parameters for the certificate-based authentication." -ForceDeployerFingerprint skips the
        # interactive fingerprint dialog; a first pairing uses handshake code 000000.
        $code = Resolve-HandshakeCode -Row $Row
        if ($script:Owned) { $script:Owned.VbrAdded = $true }
        Add-VBRLinux -Name $regName -UseCertificate -HandshakeCode $code -ForceDeployerFingerprint `
            -Description "$(Get-RoleLabel -Row $Row) $($Row.hostname) (autodeploy)" | Out-Null
        Write-Log "Added Linux host '$regName'." 'OK'
    }
    # Gateway on the cmdlet path = managed server only ('gatewayrepo' is refused at start: REST path only).
    if ((Get-RowRoles -Row $Row).Gateway) { Write-Log "'$regName' can be selected as gateway server for a Data Domain / StoreOnce repository." 'INFO' }

    # VMware Linux proxy role + transport + task slots (Add-VBRViLinuxProxy v13: -MaxTasks 1-100).
    if ((Get-RowRoles -Row $Row).Proxy -and $PSCmdlet.ShouldProcess($regName, "Add-VBRViLinuxProxy (MaxTasks=$($Row.tasks), $TransportMode)")) {
        $srv = Get-VBRServer -Name $regName -ErrorAction Stop
        if (Get-VBRViProxy -ErrorAction SilentlyContinue | Where-Object { $_.Host.Name -eq $regName }) {
            Write-Log "Proxy already registered on '$($Row.hostname)' - skipping." 'WARN'
            return
        }
        $p = @{
            Server        = $srv
            MaxTasks      = [int]$Row.tasks
            TransportMode = $TransportMode
            Description   = "VIA proxy $($Row.hostname) (autodeploy)"
            Force         = $true
        }
        if ($NoFailoverToNbd) { $p.EnableFailoverToNBD = $false }
        Add-VBRViLinuxProxy @p | Out-Null
        Write-Log "Assigned VMware Linux proxy role ($($Row.tasks) tasks, $TransportMode) to '$($Row.hostname)'." 'OK'
    }
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
function Test-ProxyRegistered {
    param($Row)
    $regName = Get-RegistrationName -Row $Row
    $srv = Get-VBRServer -Name $regName -ErrorAction SilentlyContinue
    if (-not $srv) { return $false }
    if (-not (Get-RowRoles -Row $Row).Proxy) { return $true }   # gateway-only row: the managed server is the role
    $proxy = Get-VBRViProxy -ErrorAction SilentlyContinue | Where-Object { $_.Host.Name -eq $regName }
    return [bool]$proxy
}

# ---------------------------------------------------------------------------
# Rollback / teardown
# ---------------------------------------------------------------------------
function New-RowOwnership {
    # What THIS run created for one row. Stage A and Stage B fill it in as they go; -RollbackOnFailure removes
    # only what is recorded here. VmId (not the name) identifies the VM, because another run or a person can own
    # a VM with the same name.
    return [ordered]@{ VmId = $null; IsoDatastore = $null; StagedIso = $null; VbrAdded = $false }
}

function Remove-RowFromVbr {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param($Row)
    if ($RegisterVia -eq 'Rest') {
        Remove-VbrRestHost -Row $Row
    }
    else {
        $regName = Get-RegistrationName -Row $Row
        $srv = Get-VBRServer -Name $regName -ErrorAction SilentlyContinue
        if ($srv -and $PSCmdlet.ShouldProcess($regName, "Remove from VBR")) {
            Remove-VBRServer -Server $srv -Confirm:$false
            Write-Log "Removed '$regName' from VBR." 'OK'
        }
    }
}

function Get-ExistingTargetConflicts {
    # Rows whose names are already taken: a VM in vCenter, or a managed server in the VBR. A fresh deploy can
    # never take either over (-Replace does that on purpose), so the row would fail anyway - but only after the
    # ISO build, the upload and a 20-minute install. Checked for all rows up front instead (lab 2026-10-14:
    # stale 'Unavailable' objects for three proxies surfaced only at Stage B). Returns hostname -> reason.
    param($Rows, [switch]$CheckVm, [switch]$CheckVbr)
    $out = [ordered]@{}
    foreach ($r in $Rows) {
        $why = [System.Collections.Generic.List[string]]::new()
        if ($CheckVm) {
            $vm = Get-VM -Name $r.hostname -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($vm) { $why.Add(("a VM named '{0}' already exists in vCenter ({1}, folder '{2}')" -f $r.hostname, $vm.PowerState, $vm.Folder.Name)) }
        }
        if ($CheckVbr -and -not (Get-RowVsaProduct -Row $r)) {
            $regName = Get-RegistrationName -Row $r
            if ($RegisterVia -eq 'Rest') {
                $hostId = Find-VbrRestManagedServer -Name $regName
                if ($hostId) {
                    $ms = Invoke-VbrRest -Method GET -Path ("/api/v1/backupInfrastructure/managedServers/{0}" -f [uri]::EscapeDataString($hostId))
                    $st = if ($ms.PSObject.Properties['status']) { [string]$ms.status } else { 'unknown' }
                    $why.Add(("'{0}' already exists in the VBR as a managed server (status {1})" -f $regName, $st))
                }
            }
            elseif (Get-VBRServer -Name $regName -ErrorAction SilentlyContinue) {
                $why.Add(("'{0}' already exists in the VBR as a managed server" -f $regName))
            }
        }
        if ($why.Count) { $out[[string]$r.hostname] = ($why -join '; ') }
    }
    return $out
}

function Invoke-Rollback {
    # Two callers. -Rollback (the operator asked to tear these rows down) removes whatever carries the row's
    # names. -RollbackOnFailure passes -Owned and removes ONLY what this run created for the row. Lab 2026-10-14:
    # a by-name cleanup after "A VM named ... already exists" deleted another run's healthy appliances, their VBR
    # objects and the datastore ISO a running install was booting from. Returns $true when it removed something
    # (-Owned only).
    [CmdletBinding(SupportsShouldProcess = $true)]
    param($Row, [switch]$IncludeVBR, [System.Collections.IDictionary]$Owned)

    if ($Owned) {
        if (-not ($Owned.VmId -or $Owned.IsoDatastore -or $Owned.StagedIso -or $Owned.VbrAdded)) {
            Write-Log "Rollback: this run created nothing for '$($Row.hostname)' - nothing removed (an existing VM or VBR object with that name is left alone)." 'INFO'
            return $false
        }
        Write-Log "Rollback: removing what this run created for '$($Row.hostname)'" 'WARN'
        if ($IncludeVBR -and $Owned.VbrAdded) { Remove-RowFromVbr -Row $Row }
        if ($Owned.VmId) {
            $vm = Get-VM -Id $Owned.VmId -ErrorAction SilentlyContinue
            if ($vm -and $PSCmdlet.ShouldProcess($Row.hostname, "Power off + delete the VM this run created ($($Owned.VmId))")) {
                if ($vm.PowerState -eq 'PoweredOn') { Stop-VM -VM $vm -Confirm:$false | Out-Null }
                Remove-VM -VM $vm -DeletePermanently -Confirm:$false
                Write-Log "Deleted VM '$($Row.hostname)' ($($Owned.VmId))." 'OK'
            }
        }
        if ($Owned.IsoDatastore) {
            try { Remove-IsoFromDatastore -Hostname $Row.hostname -Datastore $Owned.IsoDatastore }
            catch { Write-Log "Rollback: datastore ISO cleanup skipped ($($_.Exception.Message))." 'WARN' }
        }
        if ($Owned.StagedIso -and (Test-Path -LiteralPath $Owned.StagedIso) -and $PSCmdlet.ShouldProcess($Row.hostname, "Remove staged ISO")) {
            Remove-Item -LiteralPath $Owned.StagedIso -Force -ErrorAction SilentlyContinue
            Write-Log "Removed staged ISO '$($Owned.StagedIso)'." 'OK'
        }
        return $true
    }

    Write-Log "Rollback: tearing down '$($Row.hostname)'" 'WARN'

    if ($IncludeVBR) { Remove-RowFromVbr -Row $Row }

    $vm = Get-VM -Name $Row.hostname -ErrorAction SilentlyContinue
    if ($vm -and $PSCmdlet.ShouldProcess($Row.hostname, "Power off + delete VM")) {
        if ($vm.PowerState -eq 'PoweredOn') { Stop-VM -VM $vm -Confirm:$false | Out-Null }
        Remove-VM -VM $vm -DeletePermanently -Confirm:$false
        Write-Log "Deleted VM '$($Row.hostname)'." 'OK'
    }

    # ISO cleanup (datastore copy + staged file), best-effort.
    try {
        $isoDs = Resolve-IsoDatastore -Row $Row
        Remove-IsoFromDatastore -Hostname $Row.hostname -Datastore $isoDs
    }
    catch { Write-Log "Rollback: datastore ISO cleanup skipped ($($_.Exception.Message))." 'WARN' }
    if ($IsoStagingDir) {
        $staged = Join-Path $IsoStagingDir ("{0}.iso" -f $Row.hostname)
        if ((Test-Path $staged) -and $PSCmdlet.ShouldProcess($Row.hostname, "Remove staged ISO")) {
            Remove-Item $staged -Force -ErrorAction SilentlyContinue
            Write-Log "Removed staged ISO '$staged'." 'OK'
        }
    }
}

# ---------------------------------------------------------------------------
# Parallel run (-Parallel N): orchestrate one worker process per row
# ---------------------------------------------------------------------------
function Invoke-ParallelRun {
    # One worker = this script with a one-row CSV, its own -IsoStagingDir (<staging>/<host>) and -ReportPath,
    # credentials handed over as encrypted files. Returns the workers' report rows. The per-row logic is the
    # sequential code path, unchanged.
    param([Parameter(Mandatory)][object[]]$Rows, [Parameter(Mandatory)][int]$Throttle)
    # Inside the staging folder, so a run the deployment server cancels (kills) is scrubbed by its clean-up too.
    $tmp = Join-Path $IsoStagingDir ("_parallel-" + [guid]::NewGuid().ToString('N').Substring(0, 10))
    New-Item -ItemType Directory -Path $tmp -Force -WhatIf:$false | Out-Null
    if (-not $script:IsWindowsHost) { & chmod 700 $tmp }
    $script:ParallelTmp = $tmp                      # removed in the main finally block, also after Ctrl-C

    # Key for the hand-over files: the operator's -SecretsKeyFile, else a throw-away key in the private folder.
    $key = $SecretsKeyFile
    if (-not $key) {
        $key = Join-Path $tmp 'worker.key'
        Set-Content -LiteralPath $key -Value ([Convert]::ToBase64String([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32))) -WhatIf:$false
        if (-not $script:IsWindowsHost) { & chmod 600 $key }
    }
    $credArgs = [System.Collections.Generic.List[string]]::new()
    $credArgs.AddRange([string[]]@('-SecretsKeyFile', $key))
    $needVc  = -not $SkipDeploy
    $needVbr = -not $SkipRegister
    if ($needVc) {
        if ($vCenterCredentialFile -and -not $vCenterCredential) { $credArgs.AddRange([string[]]@('-vCenterCredentialFile', $vCenterCredentialFile)) }
        else {
            $c = if ($vCenterCredential) { $vCenterCredential } elseif ($vCenterUser) { Get-Credential -UserName $vCenterUser -Message "vCenter $vCenterServer - password for $vCenterUser" } else { Get-Credential -Message "vCenter $vCenterServer - user name and password" }
            $f = Join-Path $tmp 'vcenter.cred'; Write-WorkerSecretFile -Path $f -KeyFile $key -Text ("{0}`n{1}`n" -f $c.UserName, $c.GetNetworkCredential().Password)
            $credArgs.AddRange([string[]]@('-vCenterCredentialFile', $f))
        }
    }
    if ($needVbr) {
        if ($VBRCredentialFile -and -not $VBRCredential) { $credArgs.AddRange([string[]]@('-VBRCredentialFile', $VBRCredentialFile)) }
        else {
            $c = if ($VBRCredential) { $VBRCredential } elseif ($VBRUser) { Get-Credential -UserName $VBRUser -Message "VBR $VBRServer - password for $VBRUser" } else { Get-Credential -Message "VBR $VBRServer - user name and password" }
            $f = Join-Path $tmp 'vbr.cred'; Write-WorkerSecretFile -Path $f -KeyFile $key -Text ("{0}`n{1}`n" -f $c.UserName, $c.GetNetworkCredential().Password)
            $credArgs.AddRange([string[]]@('-VBRCredentialFile', $f))
        }
        if ($VBRMfaSecret) { $f = Join-Path $tmp 'vbr.mfa'; Write-WorkerSecretFile -Path $f -KeyFile $key -Text $VBRMfaSecret; $credArgs.AddRange([string[]]@('-VBRMfaSecretFile', $f)) }
        elseif ($VBRMfaSecretFile) { $credArgs.AddRange([string[]]@('-VBRMfaSecretFile', $VBRMfaSecretFile)) }
        $credArgs.AddRange([string[]]@('-TotpLockFile', (Join-Path $tmp 'totp.lock')))
    }

    # Everything else the operator passed goes to every worker as given.
    $skip = @('CsvPath', 'IsoStagingDir', 'ReportPath', 'Parallel', 'ParallelStaggerSec', 'TotpLockFile', 'ParallelWorker', 'SecretsKeyFile',
              'vCenterCredential', 'vCenterCredentialFile', 'vCenterUser', 'VBRCredential', 'VBRCredentialFile', 'VBRUser',
              'VBRMfaSecret', 'VBRMfaSecretFile', 'Confirm', 'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction')
    $base = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $script:BoundParams.Keys) {
        if ($k -in $skip) { continue }
        $v = $script:BoundParams[$k]
        if ($v -is [System.Management.Automation.SwitchParameter]) { if ($v.IsPresent) { $base.Add("-$k") } }
        elseif ($v -is [bool]) { if ($v) { $base.Add("-$k") } }
        else { $base.Add("-$k"); $base.Add([string]$v) }
    }
    # Values the run itself settled (defaults the operator did not pass, the VSA settings) go explicitly.
    foreach ($k in @('ApplianceRole', 'IsoLabel')) { if (-not $script:BoundParams.ContainsKey($k)) { $base.Add("-$k"); $base.Add([string](Get-Variable -Name $k -ValueOnly)) } }
    $base.AddRange($credArgs)
    # Workers run non-interactively: never let one stop at a confirmation prompt (the script is ConfirmImpact High).
    $base.Add('-Confirm:$false'); $base.Add('-ParallelWorker')

    $items = for ($i = 0; $i -lt $Rows.Count; $i++) {
        $r = $Rows[$i]; $h = [string]$r.hostname; $safe = $h -replace '[^A-Za-z0-9._-]', '_'
        $csv = Join-Path $tmp "$safe.csv"; @($r) | Export-Csv -LiteralPath $csv -NoTypeInformation -WhatIf:$false
        [pscustomobject]@{ Index = $i; Host = $h; Csv = $csv; Staging = (Join-Path $IsoStagingDir $safe); Report = (Join-Path $tmp "$safe.report.csv") }
    }
    $pwshExe = (Get-Process -Id $PID).Path
    Write-Log ("Parallel: {0} row(s), up to {1} at a time, starts {2}s apart. Each line below is prefixed with its host." -f $Rows.Count, $Throttle, $ParallelStaggerSec) 'STEP'
    $baseArr = $base.ToArray(); $stagger = $ParallelStaggerSec; $self = $PSCommandPath
    $items | ForEach-Object -ThrottleLimit $Throttle -Parallel {
        $it = $_
        # Stagger the first wave (later rows start when a slot frees, which spreads them already).
        if ($it.Index -gt 0 -and $it.Index -lt $using:Throttle) { Start-Sleep -Seconds ($it.Index * $using:stagger) }
        $short = ($it.Host -split '\.')[0]
        $args2 = @($using:baseArr) + @('-CsvPath', $it.Csv, '-IsoStagingDir', $it.Staging, '-ReportPath', $it.Report)
        & $using:pwshExe -NoProfile -NonInteractive -File $using:self @args2 2>&1 | ForEach-Object { "[$short] $_" }
        "[$short] worker exit code $LASTEXITCODE"
    } | ForEach-Object { Write-Host $_ }

    $out = foreach ($it in $items) {
        if (Test-Path -LiteralPath $it.Report) { Import-Csv -LiteralPath $it.Report }
        else { [pscustomobject][ordered]@{ vbr = ''; hostname = $it.Host; ip = ''; deploy = 'unknown'; register = 'unknown'; validate = 'n/a'; error = 'worker ended without a report - see its log lines above' } }
    }
    # Each worker cleared its own staging folder; remove the empty per-host folders.
    foreach ($it in $items) { if ((Test-Path -LiteralPath $it.Staging) -and -not (Get-ChildItem -LiteralPath $it.Staging -Force -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $it.Staging -Force -ErrorAction SilentlyContinue -WhatIf:$false } }
    return @($out)
}

# ===========================================================================
# MAIN
# ===========================================================================
$report = [System.Collections.Generic.List[object]]::new()
$vcConn = $null
$vbrConn = $null
$vbrConnected = $false   # true once connected to VBR (either REST or cmdlet); gates rollback
$script:Owned = $null     # per-row record of what this run created (New-RowOwnership); limits -RollbackOnFailure
$script:PreCheck = [ordered]@{}   # hostname -> why its name is already taken (Get-ExistingTargetConflicts)

try {
    Write-Log "=== Veeam v13.1 Proxy Mass-Deployment ===" 'STEP'
    Write-Log "CSV: $CsvPath | Vbr: $Vbr | Mode: $(
        if ($IsoOnly){"IsoOnly$(if ($SingleIso) { ' (single ISO)' } elseif ($PromptIso) { ' (prompt ISO)' })"} elseif ($ValidateOnly){'ValidateOnly'} elseif($Rollback){'Rollback'}
        elseif($SkipDeploy){'Register-only'} elseif($SkipRegister){'Deploy-only'} else {'Full'})" 'INFO'

    if (-not $CsvPath -and -not ($IsoOnly -and $PromptIso)) { throw "-CsvPath is required (only -IsoOnly -PromptIso can run without a CSV)." }
    $rows = if ($CsvPath) { Import-DeploymentCsv -Path $CsvPath -VbrFilter $Vbr } else { @() }

    if ($LogsOnDataDisk -and -not $MultiDisk) { throw "-LogsOnDataDisk needs -MultiDisk: the log volume goes on disk 2, which only the multi-disk layout has." }
    if ($PromptIso -and -not $IsoOnly) { throw "-PromptIso works together with -IsoOnly only (it builds one generic ISO that asks for name and network at install time)." }
    if ($PromptIso -and $SingleIso) { throw "-PromptIso and -SingleIso are two different ISO types - pick one: -SingleIso bakes every CSV row into a boot menu, -PromptIso asks at install time." }
    if ($SingleIso -and -not $IsoOnly) { throw "-SingleIso works together with -IsoOnly only (a full run builds, uploads and removes one ISO per node)." }
    if ($IsoOnly -and ($SkipDeploy -or $ValidateOnly -or $Rollback -or $Replace)) {
        throw "-IsoOnly only builds ISOs; it cannot be combined with -SkipDeploy, -ValidateOnly, -Rollback or -Replace."
    }

    # --- Software Appliance run (CSV role vbr / em): same Stage A, product picked per row, no Stage B ---
    $script:VsaRun = [bool]($rows.Count -and (Get-RowVsaProduct -Row $rows[0]))
    if ($script:VsaRun) {
        if ($SkipDeploy -and -not $Rollback) { throw "CSV roles vbr / em are Software Appliances: there is nothing to register to a VBR, so -SkipDeploy leaves nothing to do." }
        if ($Replace)   { throw "-Replace re-homes a PROXY inside its VBR; it does not apply to Software Appliance rows (vbr / em). Use -Rollback, then a normal run." }
        if ($SingleIso -or $PromptIso) { throw "-SingleIso / -PromptIso are built for Infrastructure Appliance rows only. For vbr / em rows use -IsoOnly (one ISO per row)." }
        if ($LogsOnDataDisk) { throw "-LogsOnDataDisk is for the Infrastructure Appliance; the Software Appliance already puts /var/log on disk 2." }
        if ($script:BoundParams.ContainsKey('ApplianceRole') -and $ApplianceRole -ne 'None') { throw "-ApplianceRole is an Infrastructure Appliance setting; the Software Appliance product comes from the CSV role (vbr / em)." }
        $ApplianceRole = 'None'      # no applianceRole.* keys: the boot entry picks the product
        if (-not $script:BoundParams.ContainsKey('IsoLabel')) { $IsoLabel = 'VeeamSA' }
        foreach ($r in $rows) {
            $sz = Get-RowVmSize -Row $r
            if ($sz.DiskGB -lt $script:VsaMinDiskGB -or $sz.DataDiskGB -lt $script:VsaMinDiskGB) {
                throw "Row '$($r.hostname)': the Software Appliance needs two disks of at least $($script:VsaMinDiskGB) GB each (given $($sz.DiskGB) + $($sz.DataDiskGB) GB) - raise -VmDiskGB / -VmDataDiskGB or leave them unset."
            }
        }
        $SkipRegister = $true
        Write-Log ("Software Appliance run: {0}. Built from the VeeamSoftwareAppliance ISO (label {1}); the boot entry picks the product; no VBR registration." -f
                   (($rows | ForEach-Object { "$($_.hostname) = $(Get-RoleLabel -Row $_)" }) -join ', '), $IsoLabel) 'INFO'
    }

    # --- Parallel (-Parallel N): hand the rows to worker processes, then report ---
    if ($Parallel -gt 1 -and -not $ParallelWorker) {
        $parSkip = if ($ValidateOnly -or $Rollback -or $IsoOnly) { 'this mode runs sequentially' } elseif ($rows.Count -lt 2) { 'the selection has only one row' } else { $null }
        if ($parSkip) { Write-Log "-Parallel $Parallel ignored: $parSkip." 'INFO' }
        else {
            # Two appliances updating the SAME list at once would overwrite each other's change.
            if ($Replace) { throw "-Replace cannot run in parallel: it re-pins job proxy lists that several proxies can share (two replacements at once would overwrite each other's job edits). Run -Replace without -Parallel." }
            if (@($rows | Where-Object { @(Get-GatewayRepoNames -Row $_).Count }).Count) { throw "Rows with 'gatewayrepo' cannot run in parallel: they edit repository gateway lists that several rows can share. Run them in a separate run without -Parallel." }
            if (-not $SkipRegister -and $RegisterVia -ne 'Rest') { throw "-Parallel needs -RegisterVia Rest (the cmdlet path is not supported in parallel)." }
            # Fail ONCE here instead of in every worker.
            if (-not $SkipDeploy) {
                if (-not $BaseIso)              { throw "-BaseIso is required for the deploy stage." }
                if (-not $ApplianceSecretsFile) { throw "-ApplianceSecretsFile is required for the deploy stage." }
                if (-not $vCenterServer)        { throw "-vCenterServer is required for the deploy stage." }
                $null = Get-ApplianceSecrets -Path $ApplianceSecretsFile
            }
            if (-not $SkipRegister -and -not $VBRServer) { throw "-VBRServer is required for the register stage." }
            if (-not $IsoStagingDir) { $IsoStagingDir = Join-Path (Split-Path -Parent (Resolve-Path $CsvPath)) 'iso-staging' }
            if (-not (Test-Path -LiteralPath $IsoStagingDir)) { New-Item -ItemType Directory -Path $IsoStagingDir -Force -WhatIf:$false | Out-Null }
            # Every worker builds its own copy of the base ISO at the same time.
            if (-not $SkipDeploy) {
                $full = (Resolve-Path -LiteralPath $IsoStagingDir).Path
                $drive = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and $full.StartsWith($_.RootDirectory.FullName) } | Sort-Object { $_.RootDirectory.FullName.Length } -Descending | Select-Object -First 1
                $isoSize = (Get-Item -LiteralPath $BaseIso).Length; $wave = [math]::Min($Parallel, $rows.Count)
                if ($drive -and $drive.AvailableFreeSpace -lt ($wave * $isoSize + 2GB)) {
                    $fit = [math]::Max(1, [math]::Floor(($drive.AvailableFreeSpace - 2GB) / $isoSize))
                    throw ("-Parallel {0}: the staging folder '{1}' has {2:N0} GB free, {0} simultaneous ISO builds need about {3:N0} GB ({4:N1} GB each + 2 GB). Use -Parallel {5} or free some space." -f
                           $wave, $IsoStagingDir, ($drive.AvailableFreeSpace / 1GB), (($wave * $isoSize + 2GB) / 1GB), ($isoSize / 1GB), $fit)
                }
            }
            foreach ($e in @(Invoke-ParallelRun -Rows $rows -Throttle $Parallel)) { $report.Add($e) }
            $failed = @($report | Where-Object { $_.error }).Count
            Write-Log ("Parallel run finished: {0} row(s), {1} failed." -f $report.Count, $failed) $(if ($failed) { 'ERROR' } else { 'OK' })
            exit $(if ($failed) { 2 } else { 0 })     # the finally block below still writes the merged report and cleans up
        }
    }

    if ($Vbr -eq '*' -and -not $SkipRegister -and -not $ValidateOnly -and -not $IsoOnly) {
        Write-Log ("Vbr='*' with registration enabled: all rows will be registered to the SINGLE " +
                   "connected VBR '$VBRServer'. A VIA binds to one VBR - make sure that is intended.") 'WARN'
    }

    # --- Bootstrap dependencies (this is the install-if-missing part) ---
    $needDeploy   = -not $SkipDeploy   -and -not $ValidateOnly -and -not $IsoOnly
    $needRegister = -not $SkipRegister -and -not $ValidateOnly -and -not $IsoOnly
    if ($Replace -and -not $ValidateOnly -and ($SkipRegister -or $RegisterVia -ne 'Rest' -or $Rollback)) {
        throw "-Replace needs registration on the REST path: it removes and re-adds the appliance in VBR and re-pins its jobs (not with -SkipRegister, -RegisterVia Cmdlet or -Rollback)."
    }
    if ($needRegister -and $RegisterVia -ne 'Rest' -and @($rows | Where-Object { @(Get-GatewayRepoNames -Row $_).Count }).Count) {
        throw "CSV 'gatewayrepo' needs -RegisterVia Rest: the repository gateway list is set over the REST API. Clear the column to only add the gateway as a managed server."
    }

    if ($needDeploy -or $Rollback) { Initialize-PowerCLI }
    if ($needDeploy -or $IsoOnly) { Initialize-IsoToolchain }   # xorriso (via WSL on Windows) - required to build ISOs
    # Veeam PowerShell module is only needed for the cmdlet registration path.
    if (($needRegister -or $Rollback) -and $RegisterVia -eq 'Cmdlet' -and -not $script:VsaRun) { Initialize-VeeamModule }

    # --- Validate required inputs per mode ---
    if ($needDeploy) {
        if (-not $BaseIso)              { throw "-BaseIso is required for the deploy stage." }
        if (-not $ApplianceSecretsFile) { throw "-ApplianceSecretsFile is required for the deploy stage." }
        if (-not $vCenterServer)        { throw "-vCenterServer is required for the deploy stage." }
        if (-not $IsoStagingDir) {
            $IsoStagingDir = Join-Path (Split-Path -Parent (Resolve-Path $CsvPath)) 'iso-staging'
            Write-Log "IsoStagingDir not set; defaulting to $IsoStagingDir." 'INFO'
        }
    }
    if ($IsoOnly) {
        if (-not $BaseIso)              { throw "-BaseIso is required for -IsoOnly." }
        if (-not $ApplianceSecretsFile) { throw "-ApplianceSecretsFile is required for -IsoOnly." }
        $csvDir = if ($CsvPath) { Split-Path -Parent (Resolve-Path $CsvPath) } else { (Get-Location).Path }
        if (-not $IsoStagingDir) { $IsoStagingDir = Join-Path $csvDir 'iso-staging' }
        if (-not $IsoOutDir)     { $IsoOutDir     = Join-Path $csvDir 'iso-out' }
        # The end-of-run scrub deletes <hostname>.iso from the staging dir - the output must live elsewhere.
        if ([IO.Path]::GetFullPath($IsoOutDir).TrimEnd('/', '\') -eq [IO.Path]::GetFullPath($IsoStagingDir).TrimEnd('/', '\')) {
            throw "-IsoOutDir must differ from -IsoStagingDir: the staging dir is cleared of ISOs at the end of the run."
        }
    }
    if ($needRegister) {
        if (-not $VBRServer) { throw "-VBRServer is required for the register stage." }
        # Both paths trust the appliance certificate non-interactively (REST: fingerprint via
        # /connectionCertificate; cmdlet: -ForceDeployerFingerprint). No known-hosts pre-seed needed.
        if ($HandshakeCode -notmatch '^\d{6}$') { throw "-HandshakeCode must be a 6-digit code (000000 for a first pairing)." }
    }

    # --- ValidateOnly: offline checks of the deploy artifacts (no infra touched) ---
    if ($ValidateOnly -and -not $SkipDeploy) {
        if (-not $ApplianceSecretsFile) { throw "ValidateOnly: -ApplianceSecretsFile is required to validate the deploy artifacts." }
        $toolchainOk = $true
        try { Initialize-IsoToolchain } catch { $toolchainOk = $false; Write-Log "ValidateOnly: toolchain check failed - $($_.Exception.Message)" 'WARN' }
        $vdir = Join-Path ([System.IO.Path]::GetTempPath()) ("veeam-iso-validate-{0}" -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
        try {
            $secrets = Get-ApplianceSecrets -Path $ApplianceSecretsFile     # validates password / MFA / token rules
            $ws = Initialize-IsoWorkspace -TemplateDir $TemplateDir -Secrets $secrets -OutDir $vdir -Role $ApplianceRole
            $r0 = $rows | Select-Object -First 1
            $null = ConvertTo-RenderedTemplate -TemplatePath (Join-Path $TemplateDir 'network-line.template') -Tokens @{
                HOSTNAME = $r0.hostname; IP = $r0.ip; NETMASK = $r0.netmask; GATEWAY = $r0.gateway; DNS = $r0.dns }
            $null = Build-KickstartPost -SharedArtifacts $ws
            Write-Log "ValidateOnly: secrets valid, templates render, staging writable (workspace OK)." 'OK'

            if ($BaseIso -and $toolchainOk) {
                # Dry-run the real extract + patch for the first row into a persistent folder so the
                # operator can diff it against the pristine files. No repack, no VM, no VBR.
                $stage = if ($IsoStagingDir) { $IsoStagingDir } else { Join-Path (Split-Path -Parent (Resolve-Path $CsvPath)) 'iso-staging' }
                $vout  = Join-Path $stage ("_validate_{0}" -f $r0.hostname)
                if (Test-Path $vout) { Remove-Item $vout -Recurse -Force }
                $cfg = Get-PatchedApplianceConfigs -Row $r0 -BaseIso $BaseIso -Scratch $vout -SharedArtifacts $ws
                Write-Log "ValidateOnly: patched $($cfg.KsName) + grub.cfg for '$($r0.hostname)' written to $vout (init block after: $($cfg.Anchor); grub default: $($cfg.GrubDefault); inst.assumeyes on $($cfg.KernelLines) kernel line(s)). The kickstart EMBEDS THE SECRETS - delete the folder after review." 'OK'
            }
            elseif (-not $BaseIso) { Write-Log "ValidateOnly: -BaseIso not provided - skipped the extract/patch dry run (required for a real deploy)." 'WARN' }
        }
        finally { if (Test-Path $vdir) { Remove-Item $vdir -Recurse -Force -ErrorAction SilentlyContinue } }
    }

    # --- Connect ---
    if (($needDeploy -or $Rollback) -and -not $ValidateOnly) {
        if (-not $vCenterCredential -and $vCenterCredentialFile) { $vCenterCredential = Read-CredentialFile -Path $vCenterCredentialFile -Purpose 'vCenter credential file' }
        if (-not $vCenterCredential) {
            # Interactive: password-only prompt when -vCenterUser is given, else user + password.
            $vCenterCredential = if ($vCenterUser) { Get-Credential -UserName $vCenterUser -Message "vCenter $vCenterServer - password for $vCenterUser" }
                                 else { Get-Credential -Message "vCenter $vCenterServer - user name and password" }
        }
        $vcConn = Connect-VIServer -Server $vCenterServer -Credential $vCenterCredential
        Write-Log "Connected to vCenter $vCenterServer." 'OK'
        if ($needDeploy) { Test-VspherePlacement -Rows $rows }   # fail fast on CSV placement typos
    }
    # DNS preflight for the names the VBR will use - every registering mode, incl. register-only (warning only).
    if ($needRegister -and -not $ValidateOnly) { Test-RegistrationNames -Rows $rows }
    # Software Appliance rows are never in a VBR: their rollback only removes the VM.
    if (($needRegister -or $Rollback) -and -not $ValidateOnly -and -not $script:VsaRun) {
        if (-not $VBRCredential -and $VBRCredentialFile) { $VBRCredential = Read-CredentialFile -Path $VBRCredentialFile -Purpose 'VBR credential file' }
        if (-not $VBRCredential) {
            $VBRCredential = if ($VBRUser) { Get-Credential -UserName $VBRUser -Message "VBR $VBRServer - password for $VBRUser" }
                             else { Get-Credential -Message "VBR $VBRServer - user name and password" }
        }
        if ($RegisterVia -eq 'Rest') {
            Connect-VbrRest                 # sets $script:Rest; used by rollback + register
            $vbrConnected = $true
        }
        else {
            $vbrConn = Connect-VBRServer -Server $VBRServer -Credential $VBRCredential
            $vbrConnected = $true
            Write-Log "Connected to VBR $VBRServer (cmdlet path: Add-VBRLinux -UseCertificate -ForceDeployerFingerprint, no known-hosts pre-seed needed)." 'OK'
        }
    }

    # --- Pre-check: names already taken in vCenter / the VBR. Those rows are skipped before anything is built,
    #     and nothing is created or removed for them. -Replace takes the names over on purpose. ---
    if ($needDeploy -and -not $Replace -and -not $ValidateOnly) {   # read-only, so -WhatIf shows it too
        $script:PreCheck = Get-ExistingTargetConflicts -Rows $rows -CheckVm -CheckVbr:($needRegister -and $vbrConnected)
        foreach ($k in $script:PreCheck.Keys) {
            Write-Log ("Pre-check '{0}': {1}. The row is skipped: nothing is created or removed for it. Remove the leftover first, or rerun the row with -Replace." -f $k, $script:PreCheck[$k]) 'ERROR'
        }
        if (-not $script:PreCheck.Count) { Write-Log "Pre-check passed: no VM or VBR object uses the name of any of the $($rows.Count) row(s)." 'OK' }
    }
    # ValidateOnly: the same check, read-only, when credentials were given (never prompts; skipped without them).
    # Only for a deploying selection, as in a real run: -SkipDeploy registers existing appliances on purpose.
    if ($ValidateOnly -and -not $Replace -and -not $SkipDeploy) {
        $vcOk = $false; $vbrOk = $false
        if ($vCenterServer -and ($vCenterCredential -or $vCenterCredentialFile)) {
            try {
                Initialize-PowerCLI
                if (-not $vCenterCredential) { $vCenterCredential = Read-CredentialFile -Path $vCenterCredentialFile -Purpose 'vCenter credential file' }
                $vcConn = Connect-VIServer -Server $vCenterServer -Credential $vCenterCredential
                $vcOk = $true
            }
            catch { Write-Log "ValidateOnly: could not connect to vCenter $vCenterServer for the name check - $($_.Exception.Message)" 'WARN' }
        }
        if (-not $SkipRegister -and -not $script:VsaRun -and $RegisterVia -eq 'Rest' -and $VBRServer -and ($VBRCredential -or $VBRCredentialFile)) {
            try {
                if (-not $VBRCredential) { $VBRCredential = Read-CredentialFile -Path $VBRCredentialFile -Purpose 'VBR credential file' }
                Connect-VbrRest
                $vbrOk = $true
            }
            catch { Write-Log "ValidateOnly: could not connect to VBR $VBRServer for the name check - $($_.Exception.Message)" 'WARN' }
        }
        if ($vcOk -or $vbrOk) {
            $script:PreCheck = Get-ExistingTargetConflicts -Rows $rows -CheckVm:$vcOk -CheckVbr:$vbrOk
            $where = (@($(if ($vcOk) { 'vCenter' }), $(if ($vbrOk) { 'the VBR' })) | Where-Object { $_ }) -join ' and '
            if ($script:PreCheck.Count) { Write-Log "ValidateOnly: $($script:PreCheck.Count) row(s) use a name that is already taken in $where - a deploy would skip them (see below)." 'WARN' }
            else { Write-Log "ValidateOnly: no VM or VBR object uses the name of any row (checked in $where)." 'OK' }
        }
        else { Write-Log "ValidateOnly: no vCenter / VBR credentials given - existing VMs and VBR objects were not checked." 'INFO' }
    }

    # --- Prepare the shared ISO workspace once (rendered answer file + first-boot artifacts) ---
    $script:IsoWorkspace = $null
    if ($needDeploy -or $IsoOnly) {
        $secrets = Get-ApplianceSecrets -Path $ApplianceSecretsFile
        if ($script:VsaRun -and [string]$secrets['VEEAMADMIN_MFA_ENABLED'] -ne 'true') {
            Write-Log ("VEEAMADMIN_MFA_ENABLED is not true: a Software Appliance keeps Veeam Backup & Replication / Enterprise Manager unavailable " +
                       "until veeamadmin sets up MFA in the Host Management Console (https://<ip>:10443). Set it to true with a TOTP seed for a hands-off install.") 'WARN'
        }
        $script:IsoWorkspace = Initialize-IsoWorkspace -TemplateDir $TemplateDir -Secrets $secrets -OutDir $IsoStagingDir -Role $ApplianceRole
    }

    # --- IsoOnly: build the ISO(s) + VM build sheet, touch no infrastructure ---
    if ($IsoOnly) {
        if ($rows.Count -and -not $PromptIso) { Test-CsvAddressesFree -Rows $rows }
        $baseName = if ($Vbr -ne '*') { "AutoDeploy-$Vbr" } elseif ($CsvPath) { 'AutoDeploy-' + [IO.Path]::GetFileNameWithoutExtension($CsvPath) } else { 'AutoDeploy' }
        $items = [System.Collections.Generic.List[object]]::new()
        if ($PromptIso) {
            $r0 = if ($rows.Count) { $rows[0] } else { $null }
            $pv = { param($k) if ($r0 -and $r0.PSObject.Properties[$k]) { [string]$r0.$k } else { '' } }
            $pseudo = [pscustomobject]@{ hostname = "$baseName-prompt"; _prompt = $true
                _defaults = [pscustomobject]@{ netmask = (& $pv 'netmask'); gateway = (& $pv 'gateway'); dns = (& $pv 'dns'); dnssearch = (& $pv 'dnssearch'); netmask2 = (& $pv 'netmask2') } }
            $iso = New-ApplianceIso -Row $pseudo -BaseIso $BaseIso -OutDir $IsoOutDir -SharedArtifacts $script:IsoWorkspace -Force
            $report.Add([pscustomobject][ordered]@{ vbr = $Vbr; hostname = '(asked at install)'; ip = '(asked at install)'; deploy = 'prompt iso'; register = 'skipped'; validate = 'n/a'; error = '' })
            foreach ($row in $rows) { $items.Add([pscustomobject]@{ Row = $row; Iso = $iso; Boot = '(type at the prompt)' }) }
            if (-not $WhatIfPreference) {
                Write-IsoVmSpec -Items @($items) -OutDir $IsoOutDir -BaseName $baseName -Prompt
                Write-Log "Prompt ISO '$iso': the install stops on the VM console and asks for hostname, NIC 1 and NIC 2 settings. It holds the appliance passwords and MFA seeds in clear text: hand it over directly, delete it after the installs." 'WARN'
            }
        }
        elseif ($SingleIso) {
            $multi = New-MultiNodeApplianceIso -Rows $rows -BaseIso $BaseIso -OutDir $IsoOutDir -Name "$baseName-$($rows.Count)nodes.iso" -SharedArtifacts $script:IsoWorkspace
            foreach ($e in $multi.Entries) {
                $items.Add([pscustomobject]@{ Row = $e.Row; Iso = $multi.Path; Boot = $e.Title })
                $report.Add([pscustomobject][ordered]@{ vbr = $e.Row.vbr; hostname = $e.Row.hostname; ip = $e.Row.ip
                    deploy = "iso (boot entry $($e.Title.Substring(0, 2)))"; register = 'skipped'; validate = 'n/a'; error = '' })
            }
        }
        else {
            foreach ($row in $rows) {
                $entry = [ordered]@{ vbr = $row.vbr; hostname = $row.hostname; ip = $row.ip; deploy = 'skipped'; register = 'skipped'; validate = 'n/a'; error = '' }
                try {
                    $iso = New-ApplianceIso -Row $row -BaseIso $BaseIso -OutDir $IsoOutDir -SharedArtifacts $script:IsoWorkspace -Force
                    $items.Add([pscustomobject]@{ Row = $row; Iso = $iso; Boot = '(unattended, no pick)' })
                    $entry.deploy = 'iso'
                }
                catch { $entry.error = $_.Exception.Message; Write-Log "Row '$($row.hostname)' FAILED: $($_.Exception.Message)" 'ERROR' }
                finally { $report.Add([pscustomobject]$entry) }
            }
        }
        if ($items.Count -and -not $WhatIfPreference -and -not $PromptIso) {
            Write-IsoVmSpec -Items $items -OutDir $IsoOutDir -BaseName $baseName -Single:$SingleIso
            Write-Log "ISO(s) in '$IsoOutDir' hold the appliance passwords and MFA seeds in clear text: hand them over directly, delete them after the install." 'WARN'
        }
    }

    # --- Process rows (none for -IsoOnly: handled above) ---
    foreach ($row in $(if ($IsoOnly) { @() } else { $rows })) {
        $entry = [ordered]@{
            vbr = $row.vbr; hostname = $row.hostname; ip = $row.ip
            deploy = 'skipped'; register = 'skipped'; validate = 'n/a'; error = ''
        }
        $script:Owned = New-RowOwnership
        try {
            if ($Rollback) {
                Invoke-Rollback -Row $row -IncludeVBR:$vbrConnected
                $entry.deploy = 'rolled-back'; $entry.register = 'rolled-back'
            }
            elseif ($ValidateOnly) {
                $gwRepos = @(Get-GatewayRepoNames -Row $row)
                $as = Get-RoleLabel -Row $row
                if ($gwRepos.Count) { $as += ' (gateway of: ' + ($gwRepos -join ', ') + ')' }
                $sz = Get-RowVmSize -Row $row
                $hw = "$($sz.Cpu) vCPU/$($sz.MemoryGB) GB/$($sz.DiskGB) GB$(if ($sz.MultiDisk) { " + $($sz.DataDiskGB) GB" })"
                $entry.validate = if (Get-RowVsaProduct -Row $row) { "would build ISO ($(Get-RowKickstart -Row $row)) + create UEFI VM ($hw) on $($row.cluster)/$($row.datastore) as $as; no registration" }
                                  else { "would build ISO + create UEFI VM ($hw) on $($row.cluster)/$($row.datastore); register to $($row.vbr) via $RegisterVia as $as" }
                Write-Log "VALIDATE '$($row.hostname)': $($entry.validate)" 'INFO'
                if ($script:PreCheck.Contains([string]$row.hostname)) {
                    $entry.error = "Pre-check: $($script:PreCheck[[string]$row.hostname]) - a deploy would skip this row (remove the leftover, or use -Replace)."
                    Write-Log "VALIDATE '$($row.hostname)': $($entry.error)" 'WARN'
                }
            }
            elseif ($script:PreCheck.Contains([string]$row.hostname)) {
                throw "Pre-check: $($script:PreCheck[[string]$row.hostname]) - row skipped, nothing created or removed. Remove the leftover first, or rerun the row with -Replace."
            }
            else {
                # --- Replace: capture + release BEFORE the new appliance is built ---
                $manifest = $null
                if ($Replace -and $needRegister) {
                    $manifest = Get-ReplaceManifest -Row $row
                    if ($manifest) { Invoke-ReplaceRelease -Manifest $manifest }
                    else {
                        $mp = Get-ReplaceManifestPath -Row $row
                        if (Test-Path -LiteralPath $mp) {
                            $manifest = Get-Content -LiteralPath $mp -Raw | ConvertFrom-Json
                            Write-Log "Replace: '$($row.hostname)' is no longer in the VBR, but a manifest from an interrupted run exists ($($manifest.jobs.Count) job list(s)) - it will be restored after registration." 'WARN'
                        }
                        else { Write-Log "Replace: '$($row.hostname)' is not registered in this VBR - nothing to release, deploying as new." 'INFO' }
                    }
                }
                if ($needDeploy) {
                    $isoPath = New-ApplianceIso -Row $row -BaseIso $BaseIso -OutDir $IsoStagingDir -SharedArtifacts $script:IsoWorkspace
                    $script:Owned.StagedIso = $isoPath
                    Invoke-StageA-Deploy -Row $row -IsoPath $isoPath
                    $entry.deploy = 'ok'
                    $vsaP = Get-RowVsaProduct -Row $row
                    if ($vsaP) {
                        $entry.register = 'n/a (software appliance)'
                        if (-not $WhatIfPreference) { $entry.validate = "$($vsaP.Label) up (HMC :$HmcPort, :$($vsaP.ServicePort))" }
                    }
                }
                if ($needRegister) {
                    if ($RegisterVia -eq 'Rest') { Invoke-StageB-Register-Rest -Row $row } else { Invoke-StageB-Register -Row $row }
                    $entry.register = 'ok'
                    # --- Replace: put the new appliance back into the jobs and repository gateway lists of the old one ---
                    if ($manifest) {
                        $newHostId = Find-VbrRestManagedServer -Name (Get-RegistrationName -Row $row)
                        if (-not $newHostId -and $row.ip) { $newHostId = Find-VbrRestManagedServer -Name ([string]$row.ip) }
                        $newProxyId = if ($newHostId) { Find-VbrRestProxyByHost -HostId $newHostId } else { $null }
                        $mJobs = @($manifest.jobs); $mGws = @(Get-ManifestList -Manifest $manifest -Key 'gateways')
                        $needProxyId = [bool]$manifest.oldProxyId -or $mJobs.Count
                        if ($WhatIfPreference) { Write-Log "WHATIF: would re-pin $($mJobs.Count) job list(s) to the new proxy and $($mGws.Count) repository gateway list(s) to the new appliance." 'INFO' }
                        elseif (-not $newHostId) { throw "Replace: the new managed server was not found after registration - pins NOT restored; manifest kept at $(Get-ReplaceManifestPath -Row $row). Rerun with -Replace -SkipDeploy." }
                        elseif ($needProxyId -and -not $newProxyId) { throw "Replace: the new proxy id was not found after registration - job pins NOT restored; manifest kept at $(Get-ReplaceManifestPath -Row $row). Rerun with -Replace -SkipDeploy once the proxy role exists (CSV role viproxy)." }
                        else {
                            # The VBR may hand the re-added host (and possibly the proxy) the SAME ids as before
                            # (seen 2026-09-28: managed server id identical after remove + add). The job lists
                            # were emptied during release regardless, so always re-pin.
                            if ($newProxyId -and $newProxyId -eq $manifest.oldProxyId) { Write-Log "Replace: the VBR reused the previous proxy id $newProxyId." 'INFO' }
                            $res = Invoke-ReplaceRestore -Manifest $manifest -NewProxyId $newProxyId -NewHostId $newHostId
                            $entry.register = "ok (replaced; $($res.Jobs) job list(s)$(if ($mGws.Count) { ", $($res.Gateways) repository gateway list(s)" }) re-pinned)"
                        }
                    }
                }
                if ($needRegister -and -not $WhatIfPreference) {
                    $registered = if ($RegisterVia -eq 'Rest') { Test-ProxyRegisteredRest -Row $row } else { Test-ProxyRegistered -Row $row }
                    $entry.validate = if ($registered) { 'registered' } else { 'NOT FOUND' }
                }
            }
        }
        catch {
            $entry.error = $_.Exception.Message
            Write-Log "Row '$($row.hostname)' FAILED: $($_.Exception.Message)" 'ERROR'
            if ($RollbackOnFailure -and -not $Rollback -and -not $ValidateOnly) {
                if ($entry.deploy -eq 'ok') {
                    # The VM installed fine and only the VBR registration failed (DNS, credentials, VBR
                    # down...). Deleting a good appliance would waste the 20-minute install: keep it and
                    # let the operator fix the cause and rerun with -SkipDeploy (idempotent).
                    $entry.register = 'FAILED'
                    Write-Log "RollbackOnFailure: deploy of '$($row.hostname)' succeeded, only registration failed - VM KEPT. Fix the cause and rerun with -SkipDeploy." 'WARN'
                }
                else {
                    Write-Log "RollbackOnFailure: cleaning up what this run created for '$($row.hostname)'..." 'WARN'
                    try {
                        $removed = @(Invoke-Rollback -Row $row -IncludeVBR:$vbrConnected -Owned $script:Owned)[-1] -eq $true   # last item: helpers may emit output
                        $entry.error += $(if ($removed) { ' (rolled back)' } else { ' (nothing created, nothing removed)' })
                    }
                    catch { Write-Log "Cleanup of '$($row.hostname)' also failed: $($_.Exception.Message)" 'ERROR' }
                }
            }
        }
        finally {
            $report.Add([pscustomobject]$entry)
        }
    }
}
finally {
    # --- Run report ---
    if ($report.Count) {
        if (-not $ReportPath) {
            $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
            # Default next to the input CSV (predictable + writable), not the CWD.
            $reportDir = if ($CsvPath) { Split-Path -Parent (Resolve-Path $CsvPath) } else { (Get-Location).Path }
            $ReportPath = Join-Path $reportDir ("DeployReport_{0}_{1}.csv" -f ($Vbr -replace '\*', 'all'), $stamp)
        }
        # A parallel worker always writes its report: the orchestrator reads it (also under -WhatIf).
        $report | Export-Csv -Path $ReportPath -NoTypeInformation -WhatIf:$($WhatIfPreference -and -not $ParallelWorker)
        if ($WhatIfPreference -and -not $ParallelWorker) { Write-Log "WHATIF: run report would be written to $ReportPath" 'INFO' } else { Write-Log "Run report written: $ReportPath" 'OK' }
        $report | Format-Table -AutoSize | Out-String | Write-Host
    }

    # --- Scrub rendered secrets from the staging dir ---
    # Initialize-IsoWorkspace renders the answer file (passwords, TOTP seed) in plaintext next to the
    # per-node ISOs so the build can embed it. Nothing needs it after the run: remove it, the rendered
    # first-boot script/unit, any per-node build scratch and - unless -KeepIso - the per-node ISOs of
    # this run's rows (each embeds the answer file). Runs always, also after a failure or Ctrl-C.
    if ($IsoStagingDir -and (Test-Path -LiteralPath $IsoStagingDir -PathType Container)) {
        foreach ($f in @('vbr_init.cfg', 'veeam-init.sh', 'veeam-init.service')) {
            $p = Join-Path $IsoStagingDir $f
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -WhatIf:$false -ErrorAction SilentlyContinue }
        }
        Get-ChildItem -LiteralPath $IsoStagingDir -Directory -Filter '_build_*' -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -WhatIf:$false -ErrorAction SilentlyContinue
        if (-not $KeepIso) {
            foreach ($h in @($report | ForEach-Object { $_.hostname } | Where-Object { $_ })) {
                $p = Join-Path $IsoStagingDir "$h.iso"
                if (Test-Path -LiteralPath $p) {
                    Remove-Item -LiteralPath $p -Force -WhatIf:$false -ErrorAction SilentlyContinue
                    Write-Log "Removed staged ISO '$p' (it embeds the answer file)." 'INFO'
                }
            }
        }
        Write-Log "Removed the rendered answer file and build scratch from '$IsoStagingDir'." 'INFO'
    }

    # --- Disconnect ---
    if ($vbrConn) { Disconnect-VBRServer -ErrorAction SilentlyContinue }
    if ($vcConn)  { Disconnect-VIServer -Server $vCenterServer -Confirm:$false -ErrorAction SilentlyContinue }
    # Parallel run: the private hand-over folder (worker CSVs, encrypted credential files, throw-away key).
    if ($script:ParallelTmp -and (Test-Path -LiteralPath $script:ParallelTmp)) { Remove-Item -LiteralPath $script:ParallelTmp -Recurse -Force -WhatIf:$false -ErrorAction SilentlyContinue }
    Write-Log "Done." 'STEP'
}

# Exit code for callers (the deployment server, CI, wrappers): 0 = every row succeeded,
# 2 = one or more rows failed (their errors are in the run report and the log above).
$failedRows = @($report | Where-Object { $_.error })
if ($failedRows.Count) {
    Write-Log "$($failedRows.Count) row(s) failed - see the run report." 'ERROR'
    exit 2
}
