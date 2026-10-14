#Requires -Version 7.0
<#
.SYNOPSIS
    Build the customer hand-out of this toolkit: a versioned zip with exactly the files a customer
    needs, plus a SHA-256 file for the transfer.

.DESCRIPTION
    The project folder mixes customer-facing files with internal ones (engineering log, assistant
    instructions) and, on a working copy, with lab residue (settings files, run reports, staging).
    This script ships a fixed WHITELIST, so nothing else can slip in:

      START-HERE.md, Deploy-VeeamProxies.README.md, the scripts, Fleet-Planner.html, templates/,
      deploy-server/, deployment-server.service.example, appliance-secrets.example.conf, the CSV
      template + sample, and a VERSION.txt stamp.

    Left out unless -IncludeInternalDocs: CLAUDE.md and .github/ (internal). Never included, even if
    someone edits the list: *.enc / *.cred / *.key / *.iso / *.log, any *.conf other than the
    example, run reports. Build-DeployServerIso.ps1 uses the same list (-ListOnly) for the server
    payload, so a customer's deployment server carries the same set as the zip.

.EXAMPLE
    pwsh -File ./New-HandoverPackage.ps1 -OutDir ~/handover -Version 1.0.0
    pwsh -File ./New-HandoverPackage.ps1 -ListOnly          # what ships (relative paths)
#>
[CmdletBinding()]
param(
    [string]$ProjectDir = $PSScriptRoot,
    [string]$OutDir = (Join-Path $HOME 'AutoDeploy-Handover'),
    [string]$Version = (Get-Date).ToString('yyyy.MM.dd'),
    [switch]$IncludeInternalDocs,   # add CLAUDE.md + .github/ (engineering log, assistant instructions)
    [switch]$ListOnly,              # print the relative paths that ship, then exit
    [switch]$Force                  # overwrite an existing zip of the same version
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ship = @(
    'START-HERE.md'
    'Deploy-VeeamProxies.README.md'
    'Deploy-VeeamProxies.ps1'
    'Protect-DeploymentSecrets.ps1'
    'New-ProxyDnsRecords.ps1'
    'Start-DeploymentServer.ps1'
    'deployment-server.service.example'
    'Build-DeployServerIso.ps1'
    'New-DeployServerVm.ps1'
    'New-HandoverPackage.ps1'
    'Fleet-Planner.html'
    'appliance-secrets.example.conf'
    'proxies-template.csv'
    'proxies-vbr01.sample.csv'
    'templates/README.md'
    'templates/vbr_init.cfg.template'
    'templates/network-line.template'
    'templates/network-line-nic2.template'
    'templates/prompt-network.sh.template'
    'templates/veeam-init.sh.template'
    'templates/veeam-init.service'
    'deploy-server/ks.cfg.template'
)
$internal = @('CLAUDE.md', '.github/copilot-instructions.md')
$files = if ($IncludeInternalDocs) { $ship + $internal } else { $ship }

$missing = @($files | Where-Object { -not (Test-Path -LiteralPath (Join-Path $ProjectDir $_) -PathType Leaf) })
if ($missing.Count) { throw "Missing from '$ProjectDir': $($missing -join ', ')" }
foreach ($f in $files) {
    # Guard against a careless edit of the list above: these never ship.
    if ($f -match '\.(enc|cred|key|iso|log)$' -or ($f -like '*.conf' -and $f -ne 'appliance-secrets.example.conf') -or $f -like 'DeployReport_*') {
        throw "Refusing to ship '$f' - settings, credential, key, ISO, log and report files never go into the hand-out."
    }
}
if ($ListOnly) { $files; return }

$stage = Join-Path ([IO.Path]::GetTempPath()) ('autodeploy-handover-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$root  = Join-Path $stage "AutoDeploy-Proxies-$Version"
try {
    foreach ($f in $files) {
        $dst = Join-Path $root $f
        New-Item -ItemType Directory -Path (Split-Path $dst -Parent) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $ProjectDir $f) -Destination $dst
    }
    @("AutoDeploy Proxies toolkit - Veeam Infrastructure Appliance 13.1 backup proxies (+ Software Appliance VBR / Enterprise Manager) on vSphere",
      "Version: $Version", "Built:   $((Get-Date).ToString('yyyy-MM-dd HH:mm', [cultureinfo]::InvariantCulture))",
      "Files:   $($files.Count) (+ this file)", "Start with START-HERE.md.") -join "`n" | Set-Content -Path (Join-Path $root 'VERSION.txt')

    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $zip = Join-Path $OutDir "AutoDeploy-Proxies-$Version.zip"
    if ((Test-Path -LiteralPath $zip) -and -not $Force) { throw "'$zip' exists - pass -Force to overwrite or choose another -Version." }
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Compress-Archive -Path $root -DestinationPath $zip
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $(Split-Path $zip -Leaf)" | Set-Content -Path "$zip.sha256"

    Write-Host ("Package : {0} ({1} KB, {2} files + VERSION.txt)" -f $zip, [math]::Round((Get-Item -LiteralPath $zip).Length / 1KB), $files.Count)
    Write-Host ("SHA-256 : {0}  (also in {1}.sha256)" -f $hash, (Split-Path $zip -Leaf))
    Write-Host ("Internal docs (CLAUDE.md, .github/): {0}" -f $(if ($IncludeInternalDocs) { 'included' } else { 'left out (-IncludeInternalDocs to add)' }))
    Write-Host "The customer adds: the VIA 13.1 ISO, PowerShell 7, PowerCLI (Save-Module VCF.PowerCLI), xorriso, Rocky 9 minimal ISO + RPMs (incl. rsync) for the server; optional: the Software Appliance ISO for vbr / em rows - see START-HERE.md."
}
finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
}
