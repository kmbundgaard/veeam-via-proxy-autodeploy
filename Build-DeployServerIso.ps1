#Requires -Version 7.0
<#
.SYNOPSIS
    Build an unattended Rocky Linux 9 installer ISO that turns a fresh VM into the deployment server:
    pwsh 7 + xorriso + PowerCLI + this project + the deployment-server service, all from the ISO.

.DESCRIPTION
    Same technique as the proxies: take the official Rocky 9 minimal ISO, embed a kickstart and a
    payload folder, point grub at the kickstart, repack with xorriso ('-boot_image any replay').
    Nothing is downloaded at install time unless an RPM dependency is missing (then dnf goes online).

    Payload assembled by this script:
      /payload/project/             this folder (scripts, templates, planner, docs; no secrets/CSVs)
      /payload/rpms/*.rpm           powershell-7.x rh, xorriso, libisoburn, libisofs, libburn, libicu, rsync  (-RpmDir)
      /payload/powershell-modules/  VMware.VimAutomation.Core + .Vds and their dependency closure (from the build host's PowerCLI)
      /payload/iso/*.iso            optional appliance ISOs to pre-load into server-data/iso (-IncludeIso)

    Login: user 'deploy' with your SSH public key; root locked; SSH is key-only for that one account
    (password and keyboard-interactive authentication off, no root login, no X11 forwarding). Without a
    password on the account sudo is passwordless (it could not ask for one). Give -DeployPasswordHash
    (a sha512-crypt string, e.g. from 'openssl passwd -6' on Linux) if you also want VM-console login;
    sudo then asks for that password, and SSH STAYS key-only. Firewall: SSH only. SELinux enforcing.
    The install ends with POWER OFF; New-DeployServerVm.ps1 detaches the ISO and powers the VM on again.

.EXAMPLE
    pwsh -File ./Build-DeployServerIso.ps1 -RockyIso ~/iso/Rocky-9.8-x86_64-minimal.iso -OutIso ~/iso/deploy-server.iso `
        -Hostname deploy01.lab.example -Ip 10.10.1.20 -Netmask 255.255.255.0 -Gateway 10.10.1.1 -Dns 10.10.1.5 `
        -RpmDir ~/payload/rpms -IncludeIso ~/iso/VeeamInfrastructureAppliance_13.1.1.18_20260825.iso,~/iso/VeeamSoftwareAppliance_13.1.1.18_20260825.iso
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateScript({ Test-Path $_ -PathType Leaf })][string]$RockyIso,
    [Parameter(Mandatory)][string]$OutIso,
    [Parameter(Mandatory)][string]$Hostname,
    [Parameter(Mandatory)][string]$Ip,
    [string]$Netmask = '255.255.255.0',
    [Parameter(Mandatory)][string]$Gateway,
    [Parameter(Mandatory)][string]$Dns,
    [string]$Timezone = 'Europe/Copenhagen',
    [string]$Keyboard = 'us',
    [string[]]$SshPublicKeyFile = @((Join-Path $HOME '.ssh/id_rsa.pub')),   # one or more OpenSSH public keys for the deploy account
    [string]$DeployPasswordHash,          # sha512-crypt ($6$...): VM-console login + password-protected sudo; SSH stays key-only
    [string]$ProjectDir = $PSScriptRoot,
    [Parameter(Mandatory)][ValidateScript({ Test-Path $_ -PathType Container })][string]$RpmDir,
    [string]$PowerCliModulesDir,          # default: auto-detect from this host's installed PowerCLI
    [string[]]$IncludeIso = @(),
    [string]$XorrisoCommand,
    [string]$WslDistro,                   # Windows: WSL distro that has xorriso (default distro when empty)
    [switch]$Force
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Log { param([string]$m, [string]$l = 'INFO') $c = switch ($l) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Gray' } }; Write-Host ("[{0}] [{1,-5}] {2}" -f (Get-Date).ToString('HH:mm:ss'), $l, $m) -ForegroundColor $c }
# xorriso runs natively (Linux/macOS, or -XorrisoCommand) or, on Windows, inside WSL - the same pattern as
# Deploy-VeeamProxies.ps1. Windows paths handed to a WSL xorriso are translated (C:\x -> /mnt/c/x).
$script:UseWsl = ($IsWindows -and -not $XorrisoCommand)
# Absolute path against the PowerShell location ($PWD). [IO.Path]::GetFullPath alone resolves against the .NET
# process directory, which is C:\Windows\system32 in an elevated shell - './iso/x.iso' then pointed there.
function Get-AbsolutePath { param([string]$Path) $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) }
function Resolve-ToolPath {
    param([Parameter(Mandatory)][string]$Path)
    if ($IsWindows -and $XorrisoCommand) {
        # Native Windows xorriso (Cygwin / MSYS2 build) does not understand 'C:\x\y': it treats it as a relative
        # name and prefixes the current directory (seen on a Windows build host). Use the build's own cygpath when it ships
        # one, else the mixed form 'C:/x/y', which both runtimes accept.
        $abs = Get-AbsolutePath $Path
        $cyg = Join-Path (Split-Path -Parent (Get-AbsolutePath $XorrisoCommand)) 'cygpath.exe'
        if (Test-Path -LiteralPath $cyg) { $u = (& $cyg -u $abs 2>$null | Select-Object -First 1); if ($LASTEXITCODE -eq 0 -and $u) { return ([string]$u).Trim() } }
        return ($abs -replace '\\', '/')
    }
    if (-not $script:UseWsl) { return $Path }
    $abs = Get-AbsolutePath $Path
    # Drive paths are translated directly (C:\x\y -> /mnt/c/x/y, WSL's default automount). Calling wslpath
    # through wsl.exe proved unreliable (it failed on an existing file on a Windows build host). wslpath is kept
    # only for the rare UNC path.
    if ($abs -match '^([A-Za-z]):\\(.*)$') { return ('/mnt/{0}/{1}' -f $Matches[1].ToLowerInvariant(), ($Matches[2] -replace '\\', '/')) }
    # wslpath needs an existing path: for a file that is yet to be created, translate its parent.
    $probe = if (Test-Path -LiteralPath $abs) { $abs } else { Split-Path -Parent $abs }
    $wslArgs = @(); if ($WslDistro) { $wslArgs += @('-d', $WslDistro) }; $wslArgs += @('--', 'wslpath', '-a', $probe)
    $out = (& wsl.exe @wslArgs 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or -not $out) { throw "wslpath could not translate '$probe' (is a WSL distro installed? -WslDistro?)." }
    $out = ([string]$out).Trim()
    if ($probe -ne $abs) { $out = $out.TrimEnd('/') + '/' + (Split-Path -Leaf $abs) }
    return $out
}
function Xorriso {
    param([string[]]$Arguments)
    $out = if ($XorrisoCommand)    { & $XorrisoCommand @Arguments 2>&1 }
           elseif ($script:UseWsl) { $w = @(); if ($WslDistro) { $w += @('-d', $WslDistro) }; $w += @('--', 'xorriso') + $Arguments; & wsl.exe @w 2>&1 }
           else                    { & xorriso @Arguments 2>&1 }
    $out | Where-Object { $_ -match 'error|fail|cannot' -and $_ -notmatch 'NOTE|UPDATE' } | ForEach-Object { Log $_ 'WARN' }
    if ($LASTEXITCODE -ne 0) { throw "xorriso failed (exit $LASTEXITCODE): $($Arguments -join ' ')" }
}

if ((Test-Path $OutIso) -and -not $Force) { throw "'$OutIso' exists - use -Force." }
if ($script:UseWsl) {
    $probe = @(); if ($WslDistro) { $probe += @('-d', $WslDistro) }; $probe += @('--', 'xorriso', '-version')
    & wsl.exe @probe 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw ("This build needs xorriso. On Windows it runs inside WSL: install a distro ('wsl --install -d Ubuntu', reboot if asked), " +
               "run 'sudo apt install xorriso' in it, and pass -WslDistro <name> if it is not your default distro. Or build on Linux/macOS with xorriso installed.")
    }
    Log "xorriso: via WSL$(if ($WslDistro) { " ($WslDistro)" }); Windows paths are translated with wslpath" 'INFO'
}
elseif (-not (Get-Command ($(if ($XorrisoCommand) { $XorrisoCommand } else { 'xorriso' })) -ErrorAction SilentlyContinue)) { throw "xorriso not found - install it (brew/apt/dnf install xorriso) or pass -XorrisoCommand." }
foreach ($addr in @($Ip, $Gateway)) { if ($addr -notmatch '^(\d{1,3}\.){3}\d{1,3}$') { throw "'$addr' is not an IPv4 address" } }   # NOT '$ip': PowerShell variables are case-insensitive and would clobber $Ip
# Every key file becomes its own kickstart 'sshkey' line (the operators' laptops, the customer's admins),
# so nobody has to be added to authorized_keys by hand after a rebuild (lesson of 2026-09-28).
# Sanity: with 'pwsh -File', a stray extra token (e.g. a second key file given after a comma AND a space)
# lands in the next positional parameter - Netmask - and would silently produce a broken network line.
foreach ($pair in @(@('Ip', $Ip), @('Netmask', $Netmask), @('Gateway', $Gateway), @('Dns', $Dns))) {
    if ($pair[1] -notmatch '^\d{1,3}(\.\d{1,3}){3}(\s*[;,]\s*\d{1,3}(\.\d{1,3}){3})*$') {
        throw "-$($pair[0]) '$($pair[1])' is not an IPv4 address. (Several SSH key files? Pass them as ONE comma-separated value without spaces: -SshPublicKeyFile 'a.pub,b.pub'.)"
    }
}
# 'pwsh -File' hands arrays over as plain strings ("a," "b"), so also accept one comma/semicolon-separated value.
$keyFiles = @($SshPublicKeyFile | ForEach-Object { $_ -split '[,;]' } | ForEach-Object { $_.Trim() } | Where-Object { $_ } |
               ForEach-Object { if ($_ -match '^~[\\/]') { Join-Path $HOME $_.Substring(2) } else { $_ } })   # '~' inside quotes is not expanded by the shell
# Same for the appliance ISOs (-IncludeIso 'via.iso,vsa.iso'); checked here, before the slow payload copy.
$IncludeIso = @($IncludeIso | ForEach-Object { $_ -split '[,;]' } | ForEach-Object { $_.Trim() } | Where-Object { $_ } |
               ForEach-Object { if ($_ -match '^~[\\/]') { Join-Path $HOME $_.Substring(2) } else { $_ } })
foreach ($i in $IncludeIso) { if (-not (Test-Path -LiteralPath $i -PathType Leaf)) { throw "-IncludeIso: ISO not found: $i" } }
$sshKeyLines = foreach ($kf in $keyFiles) {
    if (-not (Test-Path -LiteralPath $kf -PathType Leaf)) { throw "SSH public key file not found: '$kf'" }
    $raw = Get-Content -LiteralPath $kf -Raw
    if ($raw -match 'BEGIN SSH2 PUBLIC KEY')      { throw "'$kf' is an RFC 4716 / PuTTYgen 'Save public key' file. Use the OpenSSH one-line form ('ssh-ed25519 AAAA... comment'): PuTTYgen shows it in the box 'Public key for pasting into OpenSSH authorized_keys file', or convert with 'ssh-keygen -i -f <file>'." }
    if ($raw -match '^\s*\d{3,5} \d+ \d+')        { throw "'$kf' looks like an SSH1-style 'bits exponent modulus' key, not an OpenSSH public key. Generate one with 'ssh-keygen -t ed25519' and use its .pub file." }
    if ($raw -match 'PuTTY-User-Key-File')        { throw "'$kf' is a PuTTY .ppk private key. Export the public key in OpenSSH format (PuTTYgen: 'Public key for pasting into OpenSSH authorized_keys file')." }
    foreach ($line in (($raw -split "`r?`n") | Where-Object { $_.Trim() })) {
        $k = $line.Trim()
        if ($k -notmatch '^(ssh-(rsa|ed25519)|ecdsa-sha2-\S+) \S+') { throw "'$kf' does not look like an OpenSSH public key file (line starts: '$($k.Substring(0, [math]::Min(30, $k.Length)))...'). Expected 'ssh-ed25519 AAAA... comment' or 'ssh-rsa AAAA... comment'." }
        'sshkey --username=deploy "{0}"' -f $k
    }
}
$sshKeyLines = @($sshKeyLines)
if (-not $sshKeyLines.Count) { throw "No SSH public key found in: $($keyFiles -join ', ')" }
$rpms = @(Get-ChildItem -LiteralPath $RpmDir -Filter '*.rpm')
$missingRpms = @(foreach ($need in @('powershell-', 'xorriso-', 'libisoburn-', 'libisofs-', 'libburn-', 'libicu-', 'rsync-')) { if (-not ($rpms | Where-Object { $_.Name -like "$need*" })) { $need + '*.rpm' } })
if ($missingRpms.Count) {
    throw (("RpmDir '{0}' is missing: {1}. Present: {2}. Needed: powershell (github.com/PowerShell/PowerShell/releases, the .rh.x86_64.rpm), " +
            "xorriso + libisoburn + libisofs + libburn (Rocky 9 AppStream), libicu and rsync (Rocky 9 BaseOS; rsync built for the SAME Rocky minor as -RockyIso, " +
            "e.g. rsync-3.2.5-7.el9_8.2 for 9.8 - 3.2.7 needs a newer libacl than the 9.8 ISO installs) - see START-HERE.md for the download links.") -f $RpmDir, ($missingRpms -join ', '), $(if ($rpms.Count) { ($rpms.Name -join ', ') } else { 'nothing' }))
}

# --- work dir + payload -------------------------------------------------------------------------------
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("deploy-server-iso-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$payload = Join-Path $work 'payload'
New-Item -ItemType Directory -Path (Join-Path $payload 'project'), (Join-Path $payload 'rpms'), (Join-Path $payload 'powershell-modules') -Force | Out-Null
try {
    # The project files come from the SAME whitelist as the customer hand-out zip (New-HandoverPackage.ps1
    # -ListOnly), so the server and the zip carry an identical set and lab residue (a settings file left in
    # the folder, run reports, staging) or internal docs can never ride along.
    $pkg = Join-Path $ProjectDir 'New-HandoverPackage.ps1'
    if (-not (Test-Path $pkg)) { throw "New-HandoverPackage.ps1 not found in $ProjectDir - it defines which project files ship to the server." }
    $ship = @(& $pkg -ProjectDir $ProjectDir -ListOnly)
    Log "Payload: project files from $ProjectDir ($($ship.Count) files from the hand-out list)"
    foreach ($f in $ship) {
        $dst = Join-Path (Join-Path $payload 'project') $f
        New-Item -ItemType Directory -Path (Split-Path $dst -Parent) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $ProjectDir $f) -Destination $dst
    }

    Log "Payload: RPMs from $RpmDir ($($rpms.Count))"
    $rpms | Copy-Item -Destination (Join-Path $payload 'rpms')

    # PowerCLI: VMware.VimAutomation.Core + .Vds and everything they require, newest version of each
    if (-not $PowerCliModulesDir) {
        $core = Get-Module -ListAvailable VMware.VimAutomation.Core | Sort-Object Version -Descending | Select-Object -First 1
        if (-not $core) { throw "PowerCLI not found on this host - pass -PowerCliModulesDir (a Save-Module output folder)." }
        $PowerCliModulesDir = Split-Path (Split-Path $core.ModuleBase -Parent) -Parent
    }
    # Seed with Core AND Vds: the deploy script and the server resolve DISTRIBUTED port groups with
    # Get-VDPortgroup, which lives in VMware.VimAutomation.Vds (+ its Storage dependency, ~10 MB).
    # A server built without it lists/uses standard port groups only (found the hard way, 2026-09-25).
    $queue = [System.Collections.Generic.Queue[string]]::new(); $queue.Enqueue('VMware.VimAutomation.Core'); $done = @{}
    if (Test-Path (Join-Path $PowerCliModulesDir 'VMware.VimAutomation.Vds')) { $queue.Enqueue('VMware.VimAutomation.Vds') }
    else { Log "PowerCLI module VMware.VimAutomation.Vds not found under $PowerCliModulesDir - the server will not see distributed port groups" }
    while ($queue.Count) {
        $n = $queue.Dequeue(); if ($done.ContainsKey($n)) { continue }
        $ver = Get-ChildItem (Join-Path $PowerCliModulesDir $n) -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
        if (-not $ver) { throw "PowerCLI module '$n' not found under $PowerCliModulesDir" }
        $done[$n] = $ver.FullName
        $psd = Join-Path $ver.FullName "$n.psd1"
        if (Test-Path $psd) {
            $manifest = Import-PowerShellDataFile $psd   # hashtable; StrictMode forbids .Key on a missing key
            if ($manifest.ContainsKey('RequiredModules')) { foreach ($r in @($manifest['RequiredModules'])) { $rn = if ($r -is [hashtable]) { $r['ModuleName'] } else { [string]$r }; if ($rn) { $queue.Enqueue($rn) } } }
        }
    }
    foreach ($n in $done.Keys) { $dst = Join-Path (Join-Path $payload 'powershell-modules') $n; New-Item -ItemType Directory -Path $dst -Force | Out-Null; Copy-Item $done[$n] $dst -Recurse }
    Log "Payload: PowerCLI modules: $($done.Keys -join ', ')"

    if ($IncludeIso.Count) { New-Item -ItemType Directory -Path (Join-Path $payload 'iso') -Force | Out-Null; foreach ($i in $IncludeIso) { if (-not (Test-Path $i)) { throw "ISO not found: $i" }; Copy-Item $i (Join-Path $payload 'iso'); Log "Payload: appliance ISO $(Split-Path $i -Leaf)" } }
    $mb = [math]::Round((Get-ChildItem $payload -Recurse -File | Measure-Object Length -Sum).Sum / 1MB); Log "Payload size: $mb MB"

    # --- kickstart ----------------------------------------------------------------------------------------
    $userLine = if ($DeployPasswordHash) { "user --name=deploy --groups=wheel --iscrypted --password=$DeployPasswordHash" } else { 'user --name=deploy --groups=wheel --lock' }
    $tpl = Get-Content -Raw (Join-Path $ProjectDir 'deploy-server/ks.cfg.template')
    $tok = @{ HOSTNAME = $Hostname; IP = $Ip; NETMASK = $Netmask; GATEWAY = $Gateway; DNS = $Dns; TIMEZONE = $Timezone; KEYBOARD = $Keyboard
              SSH_KEY_LINES = ($sshKeyLines -join "`n"); USER_LINE = $userLine; SUDO_NOPASSWD = $(if ($DeployPasswordHash) { 'no' } else { 'yes' }) }
    $ks = $tpl
    foreach ($k in $tok.Keys) { $ks = $ks.Replace('{{' + $k + '}}', [string]$tok[$k]) }
    $left = [regex]::Matches($ks, '\{\{[A-Z_]+\}\}') | ForEach-Object { $_.Value } | Sort-Object -Unique
    if ($left) { throw "Unrendered kickstart tokens: $($left -join ', ')" }
    $ksPath = Join-Path $work 'ks.cfg'
    [System.IO.File]::WriteAllText($ksPath, ($ks -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))

    # --- grub: default = Install entry, timeout 5, inst.ks on every kernel line --------------------------------
    $grubPath = Join-Path $work 'grub.cfg'
    Xorriso @('-indev', (Resolve-ToolPath $RockyIso), '-osirrox', 'on', '-extract', '/EFI/BOOT/grub.cfg', (Resolve-ToolPath $grubPath))
    (Get-Item $grubPath).IsReadOnly = $false          # xorriso preserves the ISO's read-only mode (444)
    $grub = (Get-Content -Raw $grubPath) -replace "`r`n", "`n"
    $label = [regex]::Match($grub, 'inst\.stage2=hd:LABEL=(\S+)').Groups[1].Value
    if (-not $label) { throw "Could not find inst.stage2=hd:LABEL=... in the Rocky grub.cfg" }
    $grub = [regex]::Replace($grub, '(?m)^\s*set\s+timeout=.*$', 'set timeout=5')
    $grub = [regex]::Replace($grub, '(?m)^\s*set\s+default=.*$', 'set default="0"')
    $grub = [regex]::Replace($grub, "(?m)^(\s*linux(efi)?\s+.*inst\.stage2=hd:LABEL=$([regex]::Escape($label)).*)$", { param($m) if ($m.Value -match 'inst\.ks=') { $m.Value } else { $m.Value.TrimEnd() + " inst.ks=hd:LABEL=${label}:/ks.cfg" } })
    [System.IO.File]::WriteAllText($grubPath, $grub, [System.Text.UTF8Encoding]::new($false))
    $volid = $label -replace '\\x20', ' '
    Log "grub: default=0 (Install), timeout=5, inst.ks=hd:LABEL=${label}:/ks.cfg; volume id '$volid'"

    # --- repack (out of place; boot equipment replayed) ------------------------------------------------------
    if (Test-Path $OutIso) { Remove-Item $OutIso -Force }
    Log "Repacking -> $OutIso (this copies the whole Rocky image plus $mb MB payload)"
    Xorriso @('-indev', (Resolve-ToolPath $RockyIso), '-outdev', (Resolve-ToolPath $OutIso), '-boot_image', 'any', 'replay', '-volid', $volid,
              '-map', (Resolve-ToolPath $ksPath), '/ks.cfg', '-map', (Resolve-ToolPath $payload), '/payload',
              '-rm', '/EFI/BOOT/grub.cfg', '--', '-map', (Resolve-ToolPath $grubPath), '/EFI/BOOT/grub.cfg', '-commit')
    Log "Built $OutIso ($([math]::Round((Get-Item $OutIso).Length / 1MB)) MB). Next: New-DeployServerVm.ps1 -IsoPath $OutIso -Ip $Ip ..." 'OK'
    Log "Server will come up as deploy@$Ip ($Hostname); tunnel: ssh -L 8080:127.0.0.1:8080 deploy@$Ip" 'OK'
}
finally { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
