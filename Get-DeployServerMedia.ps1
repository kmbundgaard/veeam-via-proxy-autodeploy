<#
.SYNOPSIS
    Download everything the deployment-server build needs, verify it, and lay it out in one folder that
    can be carried to a site without internet.

.DESCRIPTION
    Run on any machine WITH internet (Windows PowerShell 5.1 or PowerShell 7, Windows/Linux/macOS).
    Result (default .\autodeploy-media):

      iso\Rocky-<ver>-x86_64-minimal.iso   the Rocky minimal ISO, SHA-256 checked against Rocky's CHECKSUM file
      rpms\                                the seven RPMs for -RpmDir, each SHA-256 checked against the Rocky
                                           repository metadata of THE SAME MINOR (or GitHub's digest for PowerShell)
      PowerCLI\                            Save-Module VCF.PowerCLI output, for -PowerCliModulesDir
      tools\PowerShell-<ver>-win-x64.msi   PowerShell 7 for a Windows build host (the ISO build needs pwsh 7)
      veeam-iso\                           empty: put the Veeam appliance ISOs here (veeam.com, your own account)
      keys\                                empty: put the OpenSSH public keys (.pub, one-line format) here
      SHA256SUMS.txt                       every file + hash, to re-check the copy at the site
      NEXT-STEPS.txt                       the build commands with these paths filled in

    Rocky ISO and RPMs always come from the same Rocky minor (-RockyVersion, default 9.8, the tested set).
    A minor mismatch between the installed Rocky and the RPMs is what makes the offline RPM install fail
    (server then has no pwsh and the deployment-server service cannot start).
    Files that are already present with the right hash are kept; interrupted downloads resume (curl).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Get-DeployServerMedia.ps1 -Destination D:\autodeploy-media

.EXAMPLE
    pwsh -File ./Get-DeployServerMedia.ps1 -Destination ~/autodeploy-media -SkipPowerCli -SkipWindowsPwsh
#>
[CmdletBinding()]
param(
    [string]$Destination = (Join-Path (Get-Location).Path 'autodeploy-media'),
    [ValidatePattern('^9\.\d+$')][string]$RockyVersion = '9.8',
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$PowerShellVersion = '7.6.6',
    [string]$RockyMirror = 'https://dl.rockylinux.org',
    [switch]$SkipRockyIso,
    [switch]$SkipPowerCli,
    [switch]$SkipWindowsPwsh
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'     # Invoke-WebRequest in 5.1 is many times slower with the progress bar
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

function Log { param([string]$m, [string]$l = 'INFO') $c = switch ($l) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Gray' } }; Write-Host ("[{0}] [{1,-5}] {2}" -f (Get-Date).ToString('HH:mm:ss'), $l, $m) -ForegroundColor $c }

# The RPM set tested end to end on Rocky 9.8. For another minor the newest build of each name in THAT
# minor's repository is taken instead (untested - warned).
$pinned = @{
    '9.8' = @{
        'xorriso'    = 'xorriso-1.5.4-5.el9.x86_64.rpm'
        'libisoburn' = 'libisoburn-1.5.4-5.el9.x86_64.rpm'
        'libisofs'   = 'libisofs-1.5.4-4.el9.x86_64.rpm'
        'libburn'    = 'libburn-1.5.4-5.el9.x86_64.rpm'
        'libicu'     = 'libicu-67.1-10.el9_6.x86_64.rpm'
        'rsync'      = 'rsync-3.2.5-7.el9_8.2.x86_64.rpm'
    }
}
$wanted = @(
    @{ Name = 'xorriso';    Repo = 'AppStream' }
    @{ Name = 'libisoburn'; Repo = 'AppStream' }
    @{ Name = 'libisofs';   Repo = 'AppStream' }
    @{ Name = 'libburn';    Repo = 'AppStream' }
    @{ Name = 'libicu';     Repo = 'BaseOS' }
    @{ Name = 'rsync';      Repo = 'BaseOS' }
)

$curl = Get-Command curl.exe, curl -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
function Get-Url {
    # Download $Url to $OutFile (curl with resume when available, else Invoke-WebRequest).
    param([string]$Url, [string]$OutFile)
    $part = "$OutFile.part"
    if ($curl) {
        & $curl.Source -L --fail --silent --show-error --retry 5 --retry-delay 5 -C - -o $part $Url
        if ($LASTEXITCODE -ne 0) { throw "download failed (curl exit $LASTEXITCODE): $Url" }
    } else {
        Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $part
    }
    Move-Item -LiteralPath $part -Destination $OutFile -Force
}
function Get-Text {
    # Windows PowerShell 5.1 returns .Content as byte[] for a non-text content type (Rocky's CHECKSUM file)
    param([string]$Url)
    $c = (Invoke-WebRequest -UseBasicParsing -Uri $Url).Content
    if ($c -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($c) }
    return [string]$c
}
function Get-Sha256 { param([string]$Path) (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Save-Verified {
    # Keep an existing file with the right hash; else download and check. A wrong hash is fatal.
    param([string]$Url, [string]$OutFile, [string]$Sha256)
    $leaf = Split-Path $OutFile -Leaf
    if ((Test-Path -LiteralPath $OutFile) -and (Get-Sha256 $OutFile) -eq $Sha256) { Log "$leaf already present, hash OK" 'OK'; return }
    if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force }
    Log "Downloading $leaf"
    Get-Url -Url $Url -OutFile $OutFile
    $got = Get-Sha256 $OutFile
    if ($got -ne $Sha256) {
        Remove-Item -LiteralPath $OutFile -Force
        throw "SHA-256 mismatch for $leaf (expected $Sha256, got $got) - file deleted. Retry; if it repeats, use another -RockyMirror."
    }
    Log "$leaf downloaded, SHA-256 OK" 'OK'
}

# Rocky keeps the current minors under /pub and moves older ones to /vault.
function Resolve-RockyBase {
    foreach ($b in @("$RockyMirror/pub/rocky/$RockyVersion", "$RockyMirror/vault/rocky/$RockyVersion")) {
        try { $null = Invoke-WebRequest -UseBasicParsing -Method Head -Uri "$b/BaseOS/x86_64/os/repodata/repomd.xml"; return $b } catch { }
    }
    throw "Rocky $RockyVersion not found under $RockyMirror/pub or /vault."
}

function Get-RepoPackages {
    # name -> list of @{File; Href; Sha256; Ver; Rel} from the repository's primary.xml.gz
    param([string]$RepoUrl, [string[]]$Names)
    $repomd = [xml](Get-Text "$RepoUrl/repodata/repomd.xml")
    $ns = New-Object Xml.XmlNamespaceManager $repomd.NameTable
    $ns.AddNamespace('r', 'http://linux.duke.edu/metadata/repo')
    $href = $repomd.SelectSingleNode("//r:data[@type='primary']/r:location", $ns).GetAttribute('href')
    $tmp = [IO.Path]::GetTempFileName()
    try {
        Get-Url -Url "$RepoUrl/$href" -OutFile $tmp
        $fs = [IO.File]::OpenRead($tmp)
        $gz = New-Object IO.Compression.GZipStream($fs, [IO.Compression.CompressionMode]::Decompress)
        $settings = New-Object Xml.XmlReaderSettings
        $settings.DtdProcessing = [Xml.DtdProcessing]::Ignore
        $reader = [Xml.XmlReader]::Create($gz, $settings)
        $result = @{}; foreach ($n in $Names) { $result[$n] = New-Object System.Collections.ArrayList }
        try {
            # ReadOuterXml already moves past the element, so test the current node before reading on
            # (ReadToFollowing would skip a <package> that follows directly).
            while (-not $reader.EOF) {
                if ($reader.NodeType -ne [Xml.XmlNodeType]::Element -or $reader.LocalName -ne 'package') { [void]$reader.Read(); continue }
                $p = [xml]$reader.ReadOuterXml()
                $pkg = $p.DocumentElement
                $name = $pkg['name'].InnerText
                if (-not $result.ContainsKey($name)) { continue }
                if ($pkg['arch'].InnerText -ne 'x86_64') { continue }
                $loc = $pkg['location'].GetAttribute('href')
                [void]$result[$name].Add(@{ File = (Split-Path $loc -Leaf); Href = $loc; Sha256 = $pkg['checksum'].InnerText.ToLowerInvariant()
                        Ver = $pkg['version'].GetAttribute('ver'); Rel = $pkg['version'].GetAttribute('rel') })
            }
        } finally { $reader.Close(); $gz.Dispose(); $fs.Dispose() }
        return $result
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

function Compare-RpmVersion {
    # rpmvercmp-light: compare dot/underscore separated numeric and alpha segments
    param([string]$A, [string]$B)
    $sa = [regex]::Matches($A, '\d+|[a-zA-Z]+') | ForEach-Object Value
    $sb = [regex]::Matches($B, '\d+|[a-zA-Z]+') | ForEach-Object Value
    for ($i = 0; $i -lt [Math]::Max(@($sa).Count, @($sb).Count); $i++) {
        if ($i -ge @($sa).Count) { return -1 }; if ($i -ge @($sb).Count) { return 1 }
        $x = @($sa)[$i]; $y = @($sb)[$i]
        if ($x -match '^\d+$' -and $y -match '^\d+$') { $c = ([long]$x).CompareTo([long]$y) } else { $c = [string]::CompareOrdinal($x, $y) }
        if ($c -ne 0) { return [Math]::Sign($c) }
    }
    return 0
}

# ---------------------------------------------------------------------------------------------------
$Destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
foreach ($d in 'iso', 'rpms', 'PowerCLI', 'tools', 'veeam-iso', 'keys') { New-Item -ItemType Directory -Path (Join-Path $Destination $d) -Force | Out-Null }
Log "Destination: $Destination  (Rocky $RockyVersion, PowerShell $PowerShellVersion)"
if (-not $pinned.ContainsKey($RockyVersion)) { Log "Rocky $RockyVersion is not the tested set (9.8): the newest RPM of each name in the $RockyVersion repositories is taken. Test the server build before going to site." 'WARN' }

$base = Resolve-RockyBase
Log "Rocky repository: $base"

# 1. Rocky minimal ISO, verified against the CHECKSUM file of the same folder
$isoName = "Rocky-$RockyVersion-x86_64-minimal.iso"
$isoPath = Join-Path (Join-Path $Destination 'iso') $isoName
if ($SkipRockyIso) { Log 'Rocky ISO skipped (-SkipRockyIso)' 'WARN' } else {
    $sums = Get-Text "$base/isos/x86_64/CHECKSUM"
    $m = [regex]::Match($sums, "SHA256 \($([regex]::Escape($isoName))\) = ([0-9a-fA-F]{64})")
    if (-not $m.Success) { throw "$isoName not listed in $base/isos/x86_64/CHECKSUM" }
    Save-Verified -Url "$base/isos/x86_64/$isoName" -OutFile $isoPath -Sha256 $m.Groups[1].Value.ToLowerInvariant()
}

# 2. RPMs from the same minor's BaseOS / AppStream, verified against the repository metadata
$rpmDir = Join-Path $Destination 'rpms'
foreach ($repo in 'BaseOS', 'AppStream') {
    $names = @($wanted | Where-Object { $_.Repo -eq $repo } | ForEach-Object { $_.Name })
    $repoUrl = "$base/$repo/x86_64/os"
    Log "Reading $repo package list"
    $pkgs = Get-RepoPackages -RepoUrl $repoUrl -Names $names
    foreach ($n in $names) {
        $cands = @($pkgs[$n])
        if (-not $cands.Count) { throw "Package '$n' not found in $repoUrl" }
        if ($pinned.ContainsKey($RockyVersion)) {
            $pick = $cands | Where-Object { $_.File -eq $pinned[$RockyVersion][$n] } | Select-Object -First 1
            if (-not $pick) { throw "Tested build $($pinned[$RockyVersion][$n]) is no longer in $repoUrl (available: $(($cands | ForEach-Object { $_.File }) -join ', '))." }
        } else {
            $pick = $cands[0]
            foreach ($c in $cands) { $v = Compare-RpmVersion $c.Ver $pick.Ver; if ($v -gt 0 -or ($v -eq 0 -and (Compare-RpmVersion $c.Rel $pick.Rel) -gt 0)) { $pick = $c } }
        }
        Save-Verified -Url "$repoUrl/$($pick.Href)" -OutFile (Join-Path $rpmDir $pick.File) -Sha256 $pick.Sha256
    }
}

# 3. PowerShell RPM (server) + MSI (Windows build host), verified against GitHub's release asset digests
$rel = Invoke-RestMethod -UseBasicParsing -Uri "https://api.github.com/repos/PowerShell/PowerShell/releases/tags/v$PowerShellVersion" -Headers @{ 'User-Agent' = 'autodeploy-media' }
$assets = @(@{ Name = "powershell-$PowerShellVersion-1.rh.x86_64.rpm"; Dir = $rpmDir })
if (-not $SkipWindowsPwsh) { $assets += @{ Name = "PowerShell-$PowerShellVersion-win-x64.msi"; Dir = (Join-Path $Destination 'tools') } }
foreach ($a in $assets) {
    $asset = @($rel.assets | Where-Object { $_.name -eq $a.Name }) | Select-Object -First 1
    if (-not $asset) { throw "Release v$PowerShellVersion has no asset $($a.Name)" }
    $digest = if ($asset.PSObject.Properties['digest'] -and $asset.digest -match '^sha256:([0-9a-f]{64})$') { $Matches[1] } else { $null }
    $out = Join-Path $a.Dir $a.Name
    if ($digest) { Save-Verified -Url $asset.browser_download_url -OutFile $out -Sha256 $digest }
    else {
        if (-not (Test-Path -LiteralPath $out)) { Log "Downloading $($a.Name)"; Get-Url -Url $asset.browser_download_url -OutFile $out }
        Log "$($a.Name): GitHub gives no digest for this release - not verified" 'WARN'
    }
}
# Older Rocky-repo PowerShell RPMs left in rpms\ would give the build two powershell packages
Get-ChildItem -LiteralPath $rpmDir -Filter 'powershell-*.rpm' | Where-Object { $_.Name -ne "powershell-$PowerShellVersion-1.rh.x86_64.rpm" } | ForEach-Object { Log "Removing other PowerShell RPM $($_.Name)" 'WARN'; Remove-Item -LiteralPath $_.FullName }

# 4. PowerCLI (Broadcom, from the PowerShell Gallery)
$pcliDir = Join-Path $Destination 'PowerCLI'
if ($SkipPowerCli) { Log 'PowerCLI skipped (-SkipPowerCli)' 'WARN' }
elseif (Test-Path (Join-Path $pcliDir 'VMware.VimAutomation.Core')) { Log 'PowerCLI already present in PowerCLI\' 'OK' }
else {
    Log 'Saving VCF.PowerCLI from the PowerShell Gallery (several minutes)'
    if ($PSVersionTable.PSVersion.Major -lt 6 -and -not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
    }
    Save-Module -Name VCF.PowerCLI -Path $pcliDir -Repository PSGallery -Force
    if (-not (Test-Path (Join-Path $pcliDir 'VMware.VimAutomation.Core'))) { throw "PowerCLI saved, but VMware.VimAutomation.Core is missing under $pcliDir" }
    Log 'PowerCLI saved' 'OK'
}

# 5. Hash list and next steps
$sumFile = Join-Path $Destination 'SHA256SUMS.txt'
Get-ChildItem -LiteralPath $Destination -Recurse -File | Where-Object { $_.FullName -ne $sumFile -and $_.Name -ne 'NEXT-STEPS.txt' -and $_.Directory.FullName -notlike "$pcliDir*" } |
    ForEach-Object { '{0}  {1}' -f (Get-Sha256 $_.FullName), $_.FullName.Substring($Destination.Length + 1).Replace('\', '/') } |
    Set-Content -LiteralPath $sumFile -Encoding ASCII

@"
Deployment-server media - Rocky $RockyVersion, PowerShell $PowerShellVersion - $(Get-Date -Format 'yyyy-MM-dd HH:mm')

Re-check the copy at the site (PowerShell):
  Get-Content .\SHA256SUMS.txt | ForEach-Object { `$h,`$f = `$_ -split '  ',2; if ((Get-FileHash `$f -Algorithm SHA256).Hash -ne `$h) { "BAD  `$f" } }

1. Windows build host without PowerShell 7: install tools\PowerShell-$PowerShellVersion-win-x64.msi
2. Put the Veeam appliance ISO(s) in veeam-iso\ and the OpenSSH public key(s) in keys\
   (OpenSSH one-line format 'ssh-ed25519 AAAA...'; a PuTTY .ppk does NOT work - PuTTYgen > Conversions)
3. New-DeployServerVm.ps1 needs PowerCLI on the build host. Without installing it, in the same pwsh window:
     `$env:PSModulePath = '<media>\PowerCLI' + [IO.Path]::PathSeparator + `$env:PSModulePath
4. Build (from the toolkit folder; Windows without xorriso/WSL = -NoXorriso seed ISO):

   pwsh -File .\Build-DeployServerIso.ps1 -NoXorriso -OutIso <media>\deploy-server-seed.iso ``
        -Hostname <fqdn> -Ip <ip> -Netmask <mask> -Gateway <gw> -Dns <dns> ``
        -SshPublicKeyFile <media>\keys\<you>.pub -RpmDir <media>\rpms -PowerCliModulesDir <media>\PowerCLI

   pwsh -File .\New-DeployServerVm.ps1 -vCenterServer <vc> -vCenterUser <user> -Name <vm> -Cluster <cl> ``
        -Datastore <ds> -Portgroup <pg> -IsoPath <media>\iso\$isoName -SeedIsoPath <media>\deploy-server-seed.iso -Ip <ip>

   (<media> = $Destination)
   The server MUST be installed from iso\${isoName}: the RPMs in rpms\ are for Rocky $RockyVersion only.
"@ | Set-Content -LiteralPath (Join-Path $Destination 'NEXT-STEPS.txt') -Encoding UTF8

Log "Done. Media in $Destination - see NEXT-STEPS.txt" 'OK'
Get-ChildItem -LiteralPath (Join-Path $Destination 'rpms') | ForEach-Object { Log "  rpms\$($_.Name)" }
