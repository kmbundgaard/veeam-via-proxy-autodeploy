#Requires -Version 7.0
<#
.SYNOPSIS
    Local web front end for Deploy-VeeamProxies.ps1: serves Fleet-Planner.html and a small JSON API
    that starts, watches and cancels deployment runs. Built on .NET's HttpListener - nothing to install
    beyond PowerShell 7. Intended for a Rocky Linux deployment server (systemd unit in the README).

.DESCRIPTION
    SECURITY MODEL - read before changing the defaults:
      * Listens on 127.0.0.1 only. Reach it with an SSH tunnel:  ssh -L 8080:127.0.0.1:8080 deploy@server
        A run can create and DELETE VMs, so do not expose plain HTTP on the LAN. If you must, put nginx
        with TLS + authentication in front and still bind this listener to localhost.
      * Passwords typed in the page are used only to create per-run credential files encrypted with the
        server key (same format as Protect-DeploymentSecrets.ps1); they are deleted when the run ends and
        never appear in logs. Appliance settings files are encrypted with the server key on upload.
      * The server key lives in <DataDir>/secrets/server.key (created on first start, mode 600).

    Layout under -DataDir (default <Root>/server-data):
      iso/        base ISOs you copy here (shown in the page)
      secrets/    server.key, *.enc settings files, optional *.mfa TOTP seed files
      runs/<id>/  proxies.csv, run.log, run.err, run.json, staging/, DeployReport_*.csv

    API (JSON):  GET /api/status | POST /api/settings {name,content} | POST /api/run {...} |
                 GET /api/runs | GET /api/runs/{id} | GET /api/runs/{id}/log | POST /api/runs/{id}/cancel |
                 GET /api/runs/{id}/files/{name} (ISO-only output below 64 MB, e.g. the VM build sheet) |
                 POST /api/runs/{id}/files/delete (removes the run's ISO output: it holds the appliance passwords)

    ISO-only modes (IsoPerNode / IsoSingle / IsoPrompt) need no vCenter and no VBR. Their output lands in
    runs/<id>/iso-out/ and is NOT removed at run end (it is the result); the page shows an scp command for
    the ISOs (this listener serves one request at a time, so multi-GB files go over SSH, not HTTP).

.EXAMPLE
    pwsh -File ./Start-DeploymentServer.ps1                       # http://127.0.0.1:8080
    pwsh -File ./Start-DeploymentServer.ps1 -Port 8090 -XorrisoCommand /usr/bin/xorriso
#>
[CmdletBinding()]
param(
    [string]$ListenAddress = '127.0.0.1',
    [int]$Port = 8080,
    [string]$Root = $PSScriptRoot,
    [string]$DataDir = (Join-Path $PSScriptRoot 'server-data'),
    [string]$SecretsKeyFile,          # default: <DataDir>/secrets/server.key (created if missing)
    [string]$XorrisoCommand,          # passed through to every run (native xorriso path); default: xorriso on PATH
    [string]$ApiVersion = '1.3-rev2',
    [switch]$SkipTlsVerify            # default the VBR REST TLS check off for every run (lab certs)
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
$IsoDir = Join-Path $DataDir 'iso'; $SecretsDir = Join-Path $DataDir 'secrets'; $RunsDir = Join-Path $DataDir 'runs'
foreach ($d in @($DataDir, $IsoDir, $SecretsDir, $RunsDir)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
if (-not $IsWindows) { & chmod 700 $SecretsDir $RunsDir 2>$null }
if (-not $SecretsKeyFile) { $SecretsKeyFile = Join-Path $SecretsDir 'server.key' }
if (-not (Test-Path $SecretsKeyFile)) {
    [System.IO.File]::WriteAllText($SecretsKeyFile, ([Convert]::ToBase64String([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)) + "`n"))
    if (-not $IsWindows) { & chmod 600 $SecretsKeyFile }
}
$DeployScript = Join-Path $Root 'Deploy-VeeamProxies.ps1'
$PlannerPage  = Join-Path $Root 'Fleet-Planner.html'
if (-not (Test-Path $DeployScript)) { throw "Deploy-VeeamProxies.ps1 not found in $Root" }
if (-not (Test-Path $PlannerPage))  { throw "Fleet-Planner.html not found in $Root" }
$script:Procs = @{}   # run id -> System.Diagnostics.Process
$script:PowerCliConfigured = $false   # Set-PowerCLIConfiguration done once per server process

function Write-SrvLog { param([string]$Msg, [string]$Level = 'INFO')
    Write-Host ("[{0}] [{1,-5}] {2}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture), $Level, $Msg) }

# --- crypto (byte-compatible with Protect-DeploymentSecrets.ps1 / Read-ProtectedText) ---------------
function Protect-Text {
    param([string]$Text)
    $raw = [Convert]::FromBase64String((Get-Content -LiteralPath $SecretsKeyFile -Raw).Trim())
    $hk = [System.Security.Cryptography.HMACSHA256]::new($raw)
    try { $encKey = $hk.ComputeHash([Text.Encoding]::UTF8.GetBytes('veeam-autodeploy-enc')); $macKey = $hk.ComputeHash([Text.Encoding]::UTF8.GetBytes('veeam-autodeploy-mac')) } finally { $hk.Dispose() }
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.KeySize = 256; $aes.Key = $encKey; $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'; $aes.GenerateIV()
        $plain = [Text.Encoding]::UTF8.GetBytes($Text)
        $ct = $aes.CreateEncryptor().TransformFinalBlock($plain, 0, $plain.Length)
        [byte[]]$ivct = $aes.IV + $ct
    }
    finally { $aes.Dispose() }
    $hm = [System.Security.Cryptography.HMACSHA256]::new($macKey)
    try { $tag = $hm.ComputeHash($ivct) } finally { $hm.Dispose() }
    return "VEEAMENC1`n" + [Convert]::ToBase64String([byte[]]($ivct + $tag)) + "`n"
}
function Write-SecretFile { param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, (Protect-Text $Text), [System.Text.UTF8Encoding]::new($false))
    if (-not $IsWindows) { & chmod 600 $Path } }

# --- appliance settings files: check on upload, keep a NON-secret summary next to the encrypted file ---------
function Test-SettingsText {
    # A first-line check of an uploaded settings file (the deploy script's Test-ApplianceSecrets does the
    # full rule set before any ISO is built). Its main job is to refuse an UNMODIFIED copy of
    # appliance-secrets.example.conf: that file passes every syntax rule, but its NTP names never resolve
    # inside the appliance, first-boot Initial Configuration fails and the proxy sits in the interactive
    # wizard until the readiness timeout (lab, 2026-09-25). Returns @{ errors = [string[]]; summary = @{} }.
    param([string]$Text)
    $kv = @{}; $seen = @{}
    foreach ($l in ($Text -split "`r?`n")) {
        if ($l -match '^\s*([A-Za-z0-9_]+)\s*=\s*(.*?)\s*$' -and -not $l.TrimStart().StartsWith('#')) {
            $k = $Matches[1].ToUpperInvariant(); $kv[$k] = $Matches[2]; $seen[$k] = 1 + $(if ($seen.ContainsKey($k)) { $seen[$k] } else { 0 })
        }
    }
    $g = { param($k, $d = '') if ($kv.ContainsKey($k) -and $kv[$k] -ne '') { $kv[$k] } else { $d } }
    $errors = [System.Collections.Generic.List[string]]::new()
    # A key that appears twice is almost always an edit added below the example line; the LAST line
    # wins, so the operator sees "still the example value" although they typed a new one. Say so.
    foreach ($k in ($seen.Keys | Sort-Object)) { if ($seen[$k] -gt 1) { $errors.Add("$k appears $($seen[$k]) times - keep one line (the last one is used)") } }
    if ($Text -match '^\xEF\xBB\xBF' -or $Text -match '\x00') { $errors.Add('file is not plain UTF-8 text (BOM or UTF-16) - save it as UTF-8 / ANSI') }
    $examplePw = @('Ex@mp13-Adm1n-Pa55w0rd!', 'Ex@mp13-S3cur1ty-0ff1cer!')
    $adminPw = & $g 'VEEAMADMIN_PASSWORD'; $mfaOn = ((& $g 'VEEAMADMIN_MFA_ENABLED' 'true') -eq 'true'); $soOn = ((& $g 'VEEAMSO_ENABLED' 'false') -eq 'true')
    if ($kv.Count -eq 0)          { $errors.Add('no KEY = VALUE lines found - upload the plaintext .conf (see appliance-secrets.example.conf)') }
    if (-not $adminPw)            { $errors.Add('VEEAMADMIN_PASSWORD is missing') }
    elseif ($adminPw.Length -lt 15) { $errors.Add('VEEAMADMIN_PASSWORD is shorter than 15 characters') }
    if ($adminPw -cin $examplePw) { $errors.Add('VEEAMADMIN_PASSWORD is still the example value - set your real veeamadmin password') }
    if ($soOn -and ((& $g 'VEEAMSO_PASSWORD') -cin $examplePw)) { $errors.Add('VEEAMSO_PASSWORD is still the example value') }
    if ($mfaOn -and ((& $g 'VEEAMADMIN_MFA_SECRET') -eq 'JBSWY3DPEHPK3PXP')) { $errors.Add('VEEAMADMIN_MFA_SECRET is still the example seed - generate a fresh one (Protect-DeploymentSecrets.ps1 -NewTotpSeed)') }
    # ',' or ';' like the deploy script (Get-ApplianceSecrets); the answer file gets ';'.
    $ntp = @((& $g 'NTP_SERVERS') -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (-not $ntp.Count) { $errors.Add('NTP_SERVERS is missing') }
    # The Security Officer's break-glass token: required when the SO is on (same rule as Test-ApplianceSecrets).
    $soTok = & $g 'VEEAMSO_RECOVERY_TOKEN'
    $soTokOk = $soTok -match '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
    if ($soOn -and -not $soTok)  { $errors.Add('VEEAMSO_RECOVERY_TOKEN is missing (needed with VEEAMSO_ENABLED = true) - create one with Protect-DeploymentSecrets.ps1 -NewRecoveryToken and keep it in your vault') }
    elseif ($soOn -and -not $soTokOk) { $errors.Add('VEEAMSO_RECOVERY_TOKEN must be a GUID like 1A2B3C4D-1A2B-1A2B-1A2B-1A2B3C4D5E6F (Protect-DeploymentSecrets.ps1 -NewRecoveryToken)') }
    foreach ($n in $ntp) { if ($n -match '(^|\.)example\.(local|com|net|org)$') { $errors.Add("NTP_SERVERS still lists the example host '$n' - the appliance cannot resolve it and Initial Configuration fails") } }
    @{
        errors  = @($errors)
        summary = [ordered]@{ mfa = $mfaOn; securityOfficer = $soOn; recoveryToken = $(if (-not $soOn) { 'n/a' } elseif ($soTokOk) { 'set' } else { 'missing' }); ntp = $ntp; ntpRunSync = ((& $g 'NTP_RUNSYNC' 'true') -eq 'true'); passwordLength = $adminPw.Length; uploaded = (Get-Date).ToString('o') }
    }
}
function Get-SettingsInfo {
    # name -> summary from the sidecar written at upload time (files uploaded before this version have none).
    $out = [ordered]@{}
    foreach ($f in @(Get-ChildItem $SecretsDir -Filter '*.enc.info.json' -ErrorAction SilentlyContinue)) {
        try { $out[($f.Name -replace '\.info\.json$', '')] = Get-Content $f.FullName -Raw | ConvertFrom-Json -AsHashtable } catch { }
    }
    $out
}

# --- HTTP helpers ------------------------------------------------------------------------------------
function Send-Bytes { param($Ctx, [int]$Code, [byte[]]$Bytes, [string]$Type)
    $Ctx.Response.StatusCode = $Code; $Ctx.Response.ContentType = $Type; $Ctx.Response.ContentLength64 = $Bytes.Length
    $Ctx.Response.Headers['Cache-Control'] = 'no-store'; $Ctx.Response.Headers['X-Content-Type-Options'] = 'nosniff'
    $Ctx.Response.OutputStream.Write($Bytes, 0, $Bytes.Length); $Ctx.Response.OutputStream.Close() }
function Send-Json { param($Ctx, [int]$Code, $Obj) Send-Bytes $Ctx $Code ([Text.Encoding]::UTF8.GetBytes(($Obj | ConvertTo-Json -Depth 8 -Compress))) 'application/json; charset=utf-8' }
function Send-Text { param($Ctx, [int]$Code, [string]$Text) Send-Bytes $Ctx $Code ([Text.Encoding]::UTF8.GetBytes($Text)) 'text/plain; charset=utf-8' }
function Send-File { param($Ctx, [string]$Path)
    # Stream a (small) run output file as a download; never read into memory as a whole.
    $fi = Get-Item -LiteralPath $Path
    $Ctx.Response.StatusCode = 200; $Ctx.Response.ContentType = 'application/octet-stream'; $Ctx.Response.ContentLength64 = $fi.Length
    $Ctx.Response.Headers['Content-Disposition'] = 'attachment; filename="' + $fi.Name + '"'
    $Ctx.Response.Headers['Cache-Control'] = 'no-store'; $Ctx.Response.Headers['X-Content-Type-Options'] = 'nosniff'
    $fs = [IO.File]::OpenRead($fi.FullName)
    try { $fs.CopyTo($Ctx.Response.OutputStream, 1MB) } finally { $fs.Dispose(); $Ctx.Response.OutputStream.Close() } }
function Read-Body { param($Ctx) $r = [IO.StreamReader]::new($Ctx.Request.InputStream, $Ctx.Request.ContentEncoding); try { return $r.ReadToEnd() } finally { $r.Dispose() } }
$SafeName = '^[A-Za-z0-9][A-Za-z0-9._-]{0,120}$'
function Get-Field {
    # StrictMode-safe access to optional JSON fields: (Get-Field $req 'vcenter.server') -> value or $null
    param($Obj, [string]$Path)
    foreach ($k in $Path -split '\.') { if ($null -eq $Obj -or -not ($Obj -is [hashtable]) -or -not $Obj.ContainsKey($k)) { return $null }; $Obj = $Obj[$k] }
    return $Obj
}

# --- runs ----------------------------------------------------------------------------------------------
function Get-RunList {
    Get-ChildItem $RunsDir -Directory | Sort-Object Name -Descending | ForEach-Object {
        $j = Join-Path $_.FullName 'run.json'; if (Test-Path $j) { Get-RunInfo -Id $_.Name -Brief } }
}
function Complete-Run {
    # Called once when a run's child process is gone (finished, failed or killed by cancel): record the
    # outcome and scrub everything under the run dir that holds secrets - the per-run credential files,
    # the rendered answer file / first-boot artifacts and any per-node ISO still in staging (each embeds
    # the answer file). A killed run never reaches the deploy script's own end-of-run cleanup.
    param([string]$Id, [int]$Exit, [switch]$Cancelled)
    $dir = Join-Path $RunsDir $Id; $exitFile = Join-Path $dir 'exit.json'
    if (Test-Path $exitFile) { return }
    @{ exit = $Exit; cancelled = [bool]$Cancelled; ended = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content $exitFile
    Clear-RunSecrets -Dir $dir
}
function Clear-RunSecrets {
    # Everything under a run dir that holds secrets: per-run credential files, the rendered answer file and
    # first-boot artifacts, per-node ISOs (each embeds the answer file) and a parallel run's hand-over folder.
    # -Recurse: a parallel run keeps one staging folder per host (<staging>/<host>/<host>.iso).
    param([string]$Dir)
    Get-ChildItem $Dir -Filter '*.cred' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    $stg = Join-Path $Dir 'staging'
    if (Test-Path $stg) {
        Get-ChildItem $stg -Directory -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '_build_*' -or $_.Name -like '_validate_*' -or $_.Name -like '_parallel-*' } |
            Sort-Object { $_.FullName.Length } -Descending | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Get-ChildItem $stg -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.iso', '.cred', '.mfa', '.key') -or $_.Name -in @('vbr_init.cfg', 'veeam-init.sh', 'veeam-init.service') } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
}
function Invoke-RunSweep {
    # Finalise every run whose process has ended, whether or not anyone is looking at the page. Before this,
    # Complete-Run ran only when the page asked for a run's status, so a run that ended with nobody watching
    # kept its per-run credential files until the next look (lab 2026-10-14: vcenter.cred left behind).
    foreach ($id in @($script:Procs.Keys)) {
        $p = $script:Procs[$id]
        if ($p.HasExited) { Complete-Run -Id $id -Exit $p.ExitCode; [void]$script:Procs.Remove($id) }
    }
}
function Get-RunInfo {
    param([string]$Id, [switch]$Brief)
    $dir = Join-Path $RunsDir $Id; $j = Join-Path $dir 'run.json'
    if (-not (Test-Path $j)) { return $null }
    $info = Get-Content $j -Raw | ConvertFrom-Json
    $state = 'unknown'; $exit = $null
    $exitFile = Join-Path $dir 'exit.json'
    if ($script:Procs.ContainsKey($Id) -and -not $script:Procs[$Id].HasExited) { $state = 'running' }
    else {
        if ($script:Procs.ContainsKey($Id)) { Complete-Run -Id $Id -Exit $script:Procs[$Id].ExitCode }
        if (Test-Path $exitFile) {
            $e = Get-Content $exitFile -Raw | ConvertFrom-Json -AsHashtable
            $exit = $e['exit']
            $state = if ($e['cancelled']) { 'cancelled' } elseif ($exit -eq 0) { 'finished' } else { 'failed' }
        }
        else { $state = 'interrupted' }   # server restarted while it ran
    }
    $out = [ordered]@{ id = $Id; vbr = $info.vbr; mode = $info.mode; started = $info.started; state = $state; exit = $exit; rows = $info.rows }
    if (-not $Brief) {
        $out.cmd = $info.cmd
        $rep = Get-ChildItem $dir -Filter 'DeployReport_*.csv' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $out.report = @(if ($rep) { Import-Csv $rep.FullName })   # keep it an array even for one row
        $io = Join-Path $dir 'iso-out'
        $out.files = @(Get-ChildItem $io -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
            [ordered]@{ name = $_.Name; bytes = $_.Length; path = $_.FullName; download = ($_.Length -lt 64MB) } })
    }
    return $out
}
function Get-RunLog { param([string]$Id)
    $dir = Join-Path $RunsDir $Id; $t = ''
    foreach ($f in @('run.log', 'run.err')) { $p = Join-Path $dir $f; if ((Test-Path $p) -and (Get-Item $p).Length -gt 0) { if ($f -eq 'run.err') { $t += "`n--- stderr ---`n" }; $t += Get-Content $p -Raw } }
    return $t }

function New-Run {
    param($Req)
    $mode = [string](Get-Field $Req 'mode')
    if ($mode -notin @('Validate', 'WhatIf', 'DeployOnly', 'Full', 'RegisterOnly', 'Rollback', 'IsoPerNode', 'IsoSingle', 'IsoPrompt')) { throw "Unknown mode '$mode'." }
    $isoMode      = $mode -like 'Iso*'   # build ISO(s) + VM build sheet only: no vCenter, no VBR
    if (-not (Get-Field $Req 'csv')) { throw 'No CSV content.' }
    if (-not (Get-Field $Req 'vbr') -or ([string](Get-Field $Req 'vbr')) -notmatch '^[A-Za-z0-9._-]+$') { throw 'A VBR key is required.' }
    $needDeploy   = $mode -in @('WhatIf', 'DeployOnly', 'Full')
    $needRegister = $mode -in @('WhatIf', 'Full', 'RegisterOnly')
    $needVc       = $mode -in @('WhatIf', 'DeployOnly', 'Full', 'Rollback')
    $needVbr      = $mode -in @('WhatIf', 'Full', 'RegisterOnly', 'Rollback')

    $id = (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + (Get-Field $Req 'vbr')
    $dir = Join-Path $RunsDir $id; New-Item -ItemType Directory -Path $dir -Force | Out-Null; if (-not $IsWindows) { & chmod 700 $dir }
    $csvPath = Join-Path $dir 'proxies.csv'
    [System.IO.File]::WriteAllText($csvPath, (([string](Get-Field $Req 'csv')) -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
    $rows = @((Get-Content $csvPath | Where-Object { $_.Trim() })).Count - 1
    # Software Appliance rows (role vbr / em): Stage A only - no VBR connection, product sizing from the script.
    $vsa = [bool]@(Import-Csv $csvPath | Where-Object { ([string]$_.role).Trim().ToLowerInvariant() -in @('vbr', 'em') }).Count
    if ($vsa) {
        if ($mode -in @('RegisterOnly', 'IsoSingle', 'IsoPrompt')) { throw "Mode $mode does not apply to Software Appliance rows (vbr / em)." }
        $needVbr = $false
    }

    $q = { param($s) "'" + ([string]$s -replace "'", "''") + "'" }
    $a = [System.Collections.Generic.List[string]]::new()
    $a.Add("-CsvPath $(& $q $csvPath)"); $a.Add("-Vbr $(& $q (Get-Field $Req 'vbr'))"); $a.Add("-IsoStagingDir $(& $q (Join-Path $dir 'staging'))"); $a.Add("-ApiVersion $(& $q $ApiVersion)")
    $a.Add("-SecretsKeyFile $(& $q $SecretsKeyFile)")   # once: unlocks the settings file and the per-run credential files
    if ($XorrisoCommand) { $a.Add("-XorrisoCommand $(& $q $XorrisoCommand)") }
    if ($SkipTlsVerify -or (Get-Field $Req 'skipTls')) { $a.Add('-SkipTlsVerify') }
    if ((Get-Field $Req 'settingsFile')) {
        if (([string](Get-Field $Req 'settingsFile')) -notmatch $SafeName) { throw 'Bad settings file name.' }
        $sf = Join-Path $SecretsDir (Get-Field $Req 'settingsFile'); if (-not (Test-Path $sf)) { throw "Settings file not found on server: $((Get-Field $Req 'settingsFile'))" }
        $a.Add("-ApplianceSecretsFile $(& $q $sf)")
    }
    elseif ($needDeploy -or $isoMode -or $mode -eq 'Validate') { throw 'An appliance settings file is required for this mode.' }
    if ((Get-Field $Req 'iso')) {
        if (([string](Get-Field $Req 'iso')) -notmatch $SafeName) { throw 'Bad ISO name.' }
        $iso = Join-Path $IsoDir (Get-Field $Req 'iso'); if (-not (Test-Path $iso)) { throw "ISO not found on server: $((Get-Field $Req 'iso'))" }
        $a.Add("-BaseIso $(& $q $iso)")
    }
    elseif ($needDeploy -or $isoMode) { throw 'A base ISO is required for this mode.' }
    if ($needVc) {
        if (-not (Get-Field $Req 'vcenter.server')) { throw 'vCenter server is required.' }
        $a.Add("-vCenterServer $(& $q (Get-Field $Req 'vcenter.server'))")
        if ((Get-Field $Req 'vcenter.user') -and (Get-Field $Req 'vcenter.password')) {
            Write-SecretFile -Path (Join-Path $dir 'vcenter.cred') -Text ("{0}`n{1}`n" -f (Get-Field $Req 'vcenter.user'), (Get-Field $Req 'vcenter.password'))
            $a.Add("-vCenterCredentialFile $(& $q (Join-Path $dir 'vcenter.cred'))")
        } else { throw 'vCenter user and password are required for this mode (the server cannot prompt).' }
    }
    if ($needVbr) {
        if (-not (Get-Field $Req 'vbrServer.server')) { throw 'VBR server is required.' }
        $a.Add("-VBRServer $(& $q (Get-Field $Req 'vbrServer.server'))")
        if ((Get-Field $Req 'vbrServer.user') -and (Get-Field $Req 'vbrServer.password')) {
            Write-SecretFile -Path (Join-Path $dir 'vbr.cred') -Text ("{0}`n{1}`n" -f (Get-Field $Req 'vbrServer.user'), (Get-Field $Req 'vbrServer.password'))
            $a.Add("-VBRCredentialFile $(& $q (Join-Path $dir 'vbr.cred'))")
        } else { throw 'VBR user and password are required for this mode (the server cannot prompt).' }
        if ((Get-Field $Req 'vbrServer.mfaFile')) { if (([string](Get-Field $Req 'vbrServer.mfaFile')) -notmatch $SafeName) { throw 'Bad MFA file name.' }; $a.Add("-VBRMfaSecretFile $(& $q (Join-Path $SecretsDir (Get-Field $Req 'vbrServer.mfaFile')))") }
    }
    if (-not $vsa -and (Get-Field $Req 'transportMode') -and (Get-Field $Req 'transportMode') -ne 'Auto') { if (([string](Get-Field $Req 'transportMode')) -notin @('HotAdd', 'Nbd', 'DirectStorageAccess')) { throw 'Bad transport mode.' }; $a.Add("-TransportMode $((Get-Field $Req 'transportMode'))") }
    if (-not $vsa -and (Get-Field $Req 'applianceRole') -and (Get-Field $Req 'applianceRole') -ne 'InfrastructureServerIscsi') { if (([string](Get-Field $Req 'applianceRole')) -notin @('InfrastructureServer', 'None')) { throw 'Bad appliance role.' }; $a.Add("-ApplianceRole $((Get-Field $Req 'applianceRole'))") }
    if ((Get-Field $Req 'rollbackOnFailure') -and $mode -in @('DeployOnly', 'Full')) { $a.Add('-RollbackOnFailure') }
    # Appliances at a time (-Parallel): deploy / register modes only; the deploy script refuses unsafe combinations.
    $par = Get-Field $Req 'parallel'
    if ($null -ne $par -and [string]$par -ne '') {
        $pn = 0; if (-not [int]::TryParse([string]$par, [ref]$pn) -or $pn -lt 1 -or $pn -gt 16) { throw 'Bad value for parallel (allowed 1-16).' }
        if ($pn -gt 1 -and $mode -in @('WhatIf', 'DeployOnly', 'Full', 'RegisterOnly')) { $a.Add("-Parallel $pn") }
    }
    # VM sizing and disk layout from the planner's sizing panel (script defaults: 6 vCPU / 12 GB / 120 GB, one disk).
    # It is the PROXY sizing: Software Appliance rows keep the script's per-product sizing (two disks of 240 GB+).
    $int = { param($k, [int]$min, [int]$max)
        if ($vsa) { return 0 }
        $v = Get-Field $Req $k; if ($null -eq $v -or [string]$v -eq '') { return 0 }
        $n = 0; if (-not [int]::TryParse([string]$v, [ref]$n) -or $n -lt $min -or $n -gt $max) { throw "Bad value for $k (allowed $min-$max)." }; $n }
    $cpu = & $int 'vmCpu' 2 64;          if ($cpu -and $cpu -ne 6)    { $a.Add("-VmCpu $cpu") }
    $ram = & $int 'vmMemoryGB' 8 512;    if ($ram -and $ram -ne 12)   { $a.Add("-VmMemoryGB $ram") }
    $dsk = & $int 'vmDiskGB' 120 4096;   if ($dsk -and $dsk -ne 120)  { $a.Add("-VmDiskGB $dsk") }
    $dat = & $int 'dataDiskGB' 0 65536
    if ($dat) { if ($dat -lt 120) { throw 'The extra data disk must be 120 GB or more (Veeam minimum for the data disk).' }; $a.Add('-MultiDisk'); $a.Add("-VmDataDiskGB $dat") }
    if (-not $vsa -and (Get-Field $Req 'logsOnDataDisk')) { if (-not $dat) { throw 'Logs on disk 2 needs an extra data disk.' }; $a.Add('-LogsOnDataDisk') }
    if (-not $vsa -and (Get-Field $Req 'replace') -and $mode -in @('Full', 'RegisterOnly', 'WhatIf')) {
        # Replace mode: capture job pinning -> remove old proxy/host -> (redeploy) -> register -> re-pin.
        $a.Add('-Replace')
        $pol = [string](Get-Field $Req 'replaceJobPolicy')
        if ($pol -and $pol -ne 'Auto') { if ($pol -ne 'Disable') { throw 'Bad replace job policy.' }; $a.Add('-ReplaceJobPolicy Disable') }
        if ((Get-Field $Req 'purgeOldVm')) { $a.Add('-PurgeOldVm') }
    }
    switch ($mode) {
        'Validate'     { $a.Add('-ValidateOnly') }
        'WhatIf'       { $a.Add('-WhatIf') }
        'DeployOnly'   { $a.Add('-SkipRegister') }
        'RegisterOnly' { $a.Add('-SkipDeploy') }
        'Rollback'     { $a.Add('-Rollback') }
        { $_ -like 'Iso*' } {
            $a.Add('-IsoOnly'); $a.Add("-IsoOutDir $(& $q (Join-Path $dir 'iso-out'))")
            if ($mode -eq 'IsoSingle') { $a.Add('-SingleIso') }
            if ($mode -eq 'IsoPrompt') { $a.Add('-PromptIso') }
        }
    }
    $cmd = "`$PSStyle.OutputRendering = 'PlainText'; `$ConfirmPreference = 'None'; & $(& $q $DeployScript) " + ($a -join ' ')
    @{ id = $id; vbr = (Get-Field $Req 'vbr'); mode = $mode; started = (Get-Date).ToString('o'); rows = $rows; cmd = $cmd } | ConvertTo-Json | Set-Content (Join-Path $dir 'run.json')
    $p = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $cmd) -WorkingDirectory $dir `
        -RedirectStandardOutput (Join-Path $dir 'run.log') -RedirectStandardError (Join-Path $dir 'run.err') -PassThru
    $script:Procs[$id] = $p
    Write-SrvLog "run $id started (pid $($p.Id)) mode=$mode vbr=$((Get-Field $Req 'vbr')) rows=$rows"
    return $id
}

function Get-Status {
    $xo = if ($XorrisoCommand) { $XorrisoCommand } else { (Get-Command xorriso -ErrorAction SilentlyContinue).Source }
    [ordered]@{
        ok = $true; version = 1; host = [Environment]::MachineName; user = [Environment]::UserName; listen = "$ListenAddress`:$Port"; root = $Root; dataDir = $DataDir
        isoFiles = @(Get-ChildItem $IsoDir -Filter '*.iso' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -ExpandProperty Name)
        settingsFiles = @(Get-ChildItem $SecretsDir -Filter '*.enc' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*.cred' -and $_.Name -notlike '*.mfa*' } | Sort-Object Name | Select-Object -ExpandProperty Name)
        mfaFiles = @(Get-ChildItem $SecretsDir -Filter '*.mfa*' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -ExpandProperty Name)
        settingsInfo = (Get-SettingsInfo)
        xorriso = $xo; powercli = [bool](Get-Module -ListAvailable VMware.VimAutomation.Core -ErrorAction SilentlyContinue)
        pwsh = $PSVersionTable.PSVersion.ToString(); apiVersion = $ApiVersion; skipTlsDefault = [bool]$SkipTlsVerify
        runs = @(Get-RunList | Select-Object -First 20)
    }
}

# --- router --------------------------------------------------------------------------------------------
function Handle-Request { param($Ctx)
    $m = $Ctx.Request.HttpMethod; $path = $Ctx.Request.Url.AbsolutePath
    switch -Regex ("$m $path") {
        '^GET /(index\.html|Fleet-Planner\.html)?$' { Send-Bytes $Ctx 200 ([IO.File]::ReadAllBytes($PlannerPage)) 'text/html; charset=utf-8'; return }
        '^GET /api/status$'  { Send-Json $Ctx 200 (Get-Status); return }
        '^GET /api/runs$'    { Send-Json $Ctx 200 @(Get-RunList); return }
        '^GET /api/runs/([^/]+)$' { $i = Get-RunInfo -Id $Matches[1]; if ($i) { Send-Json $Ctx 200 $i } else { Send-Json $Ctx 404 @{ error = 'no such run' } }; return }
        '^GET /api/runs/([^/]+)/log$' { if (Test-Path (Join-Path $RunsDir $Matches[1])) { Send-Text $Ctx 200 (Get-RunLog -Id $Matches[1]) } else { Send-Json $Ctx 404 @{ error = 'no such run' } }; return }
        '^GET /api/runs/([^/]+)/files/([^/]+)$' {
            $rid = $Matches[1]; $fn = [uri]::UnescapeDataString($Matches[2])
            if ($rid -notmatch $SafeName -or $fn -notmatch $SafeName) { Send-Json $Ctx 400 @{ error = 'bad name' }; return }
            $fp = Join-Path (Join-Path (Join-Path $RunsDir $rid) 'iso-out') $fn
            if (-not (Test-Path -LiteralPath $fp -PathType Leaf)) { Send-Json $Ctx 404 @{ error = 'no such file' }; return }
            if ((Get-Item -LiteralPath $fp).Length -ge 64MB) { Send-Json $Ctx 413 @{ error = 'too large for the page - copy it with scp (the run view shows the command)' }; return }
            Send-File $Ctx $fp; return }
        '^POST /api/runs/([^/]+)/files/delete$' {
            $rid = $Matches[1]; if ($rid -notmatch $SafeName) { Send-Json $Ctx 400 @{ error = 'bad name' }; return }
            $io = Join-Path (Join-Path $RunsDir $rid) 'iso-out'
            if (Test-Path $io) { Remove-Item $io -Recurse -Force; Write-SrvLog "run $rid ISO output deleted" }
            Send-Json $Ctx 200 @{ ok = $true }; return }
        '^POST /api/runs/([^/]+)/cancel$' {
            $id = $Matches[1]
            if ($script:Procs.ContainsKey($id) -and -not $script:Procs[$id].HasExited) {
                $script:Procs[$id].Kill($true); [void]$script:Procs[$id].WaitForExit(15000)
                Write-SrvLog "run $id cancelled" 'WARN'
                Complete-Run -Id $id -Exit 130 -Cancelled     # also scrubs the run's ISOs / rendered answer file
                Send-Json $Ctx 200 @{ ok = $true }
            }
            else { Send-Json $Ctx 409 @{ error = 'run is not running' } }; return }
        '^POST /api/vsphere/inventory$' {
            $b = Read-Body $Ctx | ConvertFrom-Json -AsHashtable
            $srvName = [string](Get-Field $b 'server'); $user = [string](Get-Field $b 'user'); $pw = [string](Get-Field $b 'password')
            if (-not $srvName -or -not $user -or -not $pw) { Send-Json $Ctx 400 @{ error = 'server, user and password are required' }; return }
            # Guard on the LOADED module, not on 'Get-Command Connect-VIServer': that lookup auto-loads the
            # module and made this block skip on a fresh server, so the certificate setting was never
            # applied -> "Invalid server certificate" on the first inventory load (deploy01, 2026-09-25).
            if (-not (Get-Module VMware.VimAutomation.Core)) {
                $core = Get-Module -ListAvailable VMware.VimAutomation.Core | Sort-Object Version -Descending | Select-Object -First 1
                if (-not $core) { Send-Json $Ctx 500 @{ error = 'PowerCLI (VMware.VimAutomation.Core) is not installed on the server' }; return }
                Import-Module $core -ErrorAction Stop | Out-Null
            }
            if (-not $script:PowerCliConfigured) {
                # -Scope User: on PowerCLI Core the Session scope does not reliably apply InvalidCertificateAction.
                Set-PowerCLIConfiguration -Scope User -InvalidCertificateAction Ignore -ParticipateInCeip $false -Confirm:$false 3>$null | Out-Null
                $script:PowerCliConfigured = $true
            }
            $cred = [pscredential]::new($user, (ConvertTo-SecureString $pw -AsPlainText -Force)); $pw = $null
            try {
                $vi = Connect-VIServer -Server $srvName -Credential $cred -ErrorAction Stop 3>$null
                try {
                    # Distributed port groups need VMware.VimAutomation.Vds; without it 'Get-VDPortgroup' is a
                    # command-not-found error that -ErrorAction cannot swallow (deploy01, 2026-09-25) - check first.
                    $hasVds = [bool](Get-Command Get-VDPortgroup -ErrorAction SilentlyContinue)
                    $pgs = @(Get-VirtualPortGroup -Server $vi -Standard -ErrorAction SilentlyContinue | ForEach-Object { [ordered]@{ name = $_.Name; kind = 'standard'; vlan = $_.VLanId } })
                    if ($hasVds) { $pgs += @(Get-VDPortgroup -Server $vi -ErrorAction SilentlyContinue | ForEach-Object { [ordered]@{ name = $_.Name; kind = 'distributed'; vlan = $_.VlanConfiguration.VlanId } }) }
                    $inv = [ordered]@{
                        vcenter = "$($vi.Name) (vCenter $($vi.Version))"
                        clusters = @(Get-Cluster -Server $vi | ForEach-Object { $h = @($_ | Get-VMHost); [ordered]@{ name = $_.Name; hosts = $h.Count; freeMemGB = [math]::Round(($h | Measure-Object -Property MemoryTotalGB -Sum).Sum - ($h | Measure-Object -Property MemoryUsageGB -Sum).Sum) } })
                        datastores = @(Get-Datastore -Server $vi | Sort-Object Name | ForEach-Object { [ordered]@{ name = $_.Name; type = $_.Type; freeGB = [math]::Round($_.FreeSpaceGB); capacityGB = [math]::Round($_.CapacityGB) } })
                        datastoreClusters = @(Get-DatastoreCluster -Server $vi -ErrorAction SilentlyContinue | ForEach-Object { [ordered]@{ name = $_.Name; freeGB = [math]::Round($_.FreeSpaceGB) } })
                        folders = @(Get-Folder -Server $vi -Type VM | Where-Object { $_.Name -ne 'vm' } | Sort-Object Name | ForEach-Object { [ordered]@{ name = $_.Name; parent = $_.Parent.Name } })
                        portgroups = @($pgs | Sort-Object { $_.name } -Unique)
                        vdsModule = $hasVds   # false = distributed port groups not listed (VMware.VimAutomation.Vds missing)
                    }
                    Send-Json $Ctx 200 $inv
                }
                finally { Disconnect-VIServer -Server $vi -Confirm:$false -ErrorAction SilentlyContinue }
            }
            catch { Send-Json $Ctx 502 @{ error = "vCenter inventory failed: $($_.Exception.Message)" } }
            return }
        '^POST /api/dns$' {
            # Resolve the proxies' registration names the way the VBR most likely will (this server usually
            # shares the VBR's DNS). "Test connections" calls it so a missing record shows up BEFORE a 25-minute
            # deploy ends in "Failed to get certificate from: https://<name>:443/" (lab, 2026-09-28).
            $b = Read-Body $Ctx | ConvertFrom-Json -AsHashtable
            # Body: { rows: [{ name, ip }] } (ip optional -> also checks the record points at the CSV address) or { names: [...] }.
            $items = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($r in @(Get-Field $b 'rows'))  { if ($r -and (Get-Field $r 'name')) { $items.Add(@{ name = [string](Get-Field $r 'name'); ip = [string](Get-Field $r 'ip') }) } }
            foreach ($n in @(Get-Field $b 'names')) { if ($n) { $items.Add(@{ name = [string]$n; ip = '' }) } }
            $out = foreach ($it in ($items | Select-Object -First 500)) {
                $n = $it.name
                if ($n -match '^\d{1,3}(\.\d{1,3}){3}$') { [ordered]@{ name = $n; resolves = $true; address = $n; matchesRow = $true; note = 'ip address' }; continue }
                try {
                    $a = @([System.Net.Dns]::GetHostAddresses($n) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.IPAddressToString })
                    [ordered]@{ name = $n; resolves = [bool]$a.Count; address = ($a -join ','); matchesRow = $(if ($it.ip -and $a.Count) { $a -contains $it.ip } else { $null }); note = '' }
                }
                catch { [ordered]@{ name = $n; resolves = $false; address = ''; matchesRow = $null; note = $_.Exception.Message } }
            }
            Send-Json $Ctx 200 @{ results = @($out) }; return }
        '^POST /api/probe$' {
            $b = Read-Body $Ctx | ConvertFrom-Json -AsHashtable
            $hostName = [string](Get-Field $b 'host'); $port = [int](Get-Field $b 'port')
            if (-not $hostName -or $port -lt 1) { Send-Json $Ctx 400 @{ error = 'host and port required' }; return }
            $open = $false; $detail = ''
            try {
                $ips = [System.Net.Dns]::GetHostAddresses($hostName) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
                if (-not $ips) { throw 'no IPv4 address' }
                $c = [System.Net.Sockets.TcpClient]::new()
                try { $iar = $c.BeginConnect($ips, $port, $null, $null); if ($iar.AsyncWaitHandle.WaitOne(3000)) { $c.EndConnect($iar); $open = $true } else { $detail = 'timeout' } } finally { $c.Close() }
                $detail = if ($open) { "$ips`:$port open" } else { "$ips`:$port $(if ($detail) { $detail } else { 'closed' })" }
            } catch { $detail = "DNS/connect failed: $($_.Exception.Message)" }
            Send-Json $Ctx 200 @{ host = $hostName; port = $port; open = $open; detail = $detail }; return }
        '^POST /api/settings$' {
            $b = Read-Body $Ctx | ConvertFrom-Json -AsHashtable
            if (-not (Get-Field $b 'name') -or ([string](Get-Field $b 'name')) -notmatch $SafeName) { Send-Json $Ctx 400 @{ error = 'bad name' }; return }
            if (-not (Get-Field $b 'content')) { Send-Json $Ctx 400 @{ error = 'empty content' }; return }
            if (([string](Get-Field $b 'content')) -match '^\s*VEEAMENC1') { Send-Json $Ctx 400 @{ error = 'already encrypted with another key - upload the plaintext' }; return }
            $chk = Test-SettingsText -Text ([string](Get-Field $b 'content'))
            if ($chk.errors.Count) {
                Write-SrvLog "settings file rejected ($($chk.errors.Count) problem(s)): $($chk.errors -join ' | ')" 'WARN'   # key names only, never values
                Send-Json $Ctx 400 @{ error = ('Settings file rejected: ' + ($chk.errors -join '; ')); problems = $chk.errors }; return
            }
            $name = ([string](Get-Field $b 'name') -replace '\.enc$', '') + '.enc'
            Write-SecretFile -Path (Join-Path $SecretsDir $name) -Text ([string](Get-Field $b 'content'))
            $chk.summary | ConvertTo-Json -Compress | Set-Content -Path (Join-Path $SecretsDir "$name.info.json")   # non-secret sidecar
            Write-SrvLog "settings file stored encrypted: $name (mfa=$($chk.summary.mfa) so=$($chk.summary.securityOfficer) ntp=$($chk.summary.ntp -join ','))"
            Send-Json $Ctx 200 @{ ok = $true; name = $name; summary = $chk.summary }; return }
        '^POST /api/run$' {
            $req = Read-Body $Ctx | ConvertFrom-Json -AsHashtable
            try { $id = New-Run -Req $req; Send-Json $Ctx 200 @{ id = $id } } catch { Send-Json $Ctx 400 @{ error = $_.Exception.Message } }; return }
        default { Send-Json $Ctx 404 @{ error = "no route for $m $path" } }
    }
}

# --- main ----------------------------------------------------------------------------------------------
$listener = [System.Net.HttpListener]::new()
$prefix = "http://$ListenAddress`:$Port/"
$listener.Prefixes.Add($prefix)
$listener.Start()
Write-SrvLog "Deployment server listening on $prefix  (root=$Root, data=$DataDir, key=$SecretsKeyFile)" 'OK'
if ($ListenAddress -notin @('127.0.0.1', 'localhost', '::1')) { Write-SrvLog "Listening on a non-loopback address WITHOUT TLS or authentication. Put nginx (TLS + auth) in front." 'WARN' }
# Runs left without exit.json by a previous server process (restart / crash while they ran): no process is
# left to wait for, so scrub their secrets now. They keep the state 'interrupted' (no exit.json is written).
foreach ($d in @(Get-ChildItem $RunsDir -Directory -ErrorAction SilentlyContinue)) {
    if (Test-Path (Join-Path $d.FullName 'exit.json')) { continue }
    $left = @(Get-ChildItem $d.FullName -Filter '*.cred' -ErrorAction SilentlyContinue) + @(Get-ChildItem (Join-Path $d.FullName 'staging') -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.iso', '.cred', '.mfa', '.key') -or $_.Name -in @('vbr_init.cfg', 'veeam-init.sh', 'veeam-init.service') })
    if ($left.Count) { Clear-RunSecrets -Dir $d.FullName; Write-SrvLog "run $($d.Name): interrupted by a server restart - $($left.Count) per-run credential / staged file(s) removed" 'WARN' }
}
try {
    # Wait for requests with a timeout instead of blocking forever, so finished runs are swept between requests.
    $pending = $null
    while ($listener.IsListening) {
        if (-not $pending) { $pending = $listener.GetContextAsync() }
        if ($pending.Wait(30000)) {
            $ctx = $pending.Result; $pending = $null
            try { Handle-Request $ctx } catch { try { Send-Json $ctx 500 @{ error = $_.Exception.Message } } catch { } ; Write-SrvLog "request failed: $($_.Exception.Message)" 'ERROR' }
        }
        Invoke-RunSweep
    }
}
finally { $listener.Stop(); Write-SrvLog 'stopped.' }
