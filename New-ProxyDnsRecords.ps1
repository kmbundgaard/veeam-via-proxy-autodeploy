#Requires -Version 5.1
<#
.SYNOPSIS
    Create (or remove) the DNS A and PTR records for the proxies in a fleet CSV on a Microsoft
    Active Directory DNS server, idempotently, from the same CSV that drives Deploy-VeeamProxies.ps1.

.DESCRIPTION
    Runs on a Windows host with the DnsServer PowerShell module (RSAT "DNS Server Tools") or on a
    domain controller; Windows PowerShell 5.1 or PowerShell 7. Talks to the DNS server over WinRM/CIM.

    Per CSV row (filtered by -Vbr):
      * hostname 'prx-01.lab.example'  -> A record 'prx-01' in zone 'lab.example' (zone derived from the FQDN)
      * hostname 'prx-01'              -> needs -ZoneName
      * A record already present with the same IP -> skipped; different IP -> CONFLICT unless -UpdateExisting
      * PTR record in the matching in-addr.arpa zone (/24, /16 or /8) when that reverse zone exists,
        unless -NoPtr
      * -Remove deletes the A (and PTR) records instead
    Supports -WhatIf. Writes a per-row report CSV next to the input CSV. Verifies resolution afterwards.

    Run this BEFORE Deploy-VeeamProxies.ps1 when the fleet should be registered by name (then the CSV
    column 'vbrname' can stay empty). Requires DNS admin rights on the zone (DnsAdmins / Domain Admins).

.EXAMPLE
    .\New-ProxyDnsRecords.ps1 -CsvPath .\proxies.csv -Vbr vbr01 -DnsServer dc01.lab.example -WhatIf
    .\New-ProxyDnsRecords.ps1 -CsvPath .\proxies.csv -Vbr vbr01 -DnsServer dc01.lab.example -Credential (Get-Credential LAB\dnsadmin)
    .\New-ProxyDnsRecords.ps1 -CsvPath .\proxies.csv -Vbr vbr01 -DnsServer dc01 -ZoneName lab.example     # short hostnames in the CSV
    .\New-ProxyDnsRecords.ps1 -CsvPath .\proxies.csv -Vbr vbr01 -DnsServer dc01 -Remove -WhatIf           # undo
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)][ValidateScript({ Test-Path $_ -PathType Leaf })][string]$CsvPath,
    [string]$Vbr = '*',
    # DNS server or domain controller to manage (name or IP). The records are AD-integrated, so any
    # writable DC/DNS server of the domain works.
    [Parameter(Mandatory)][string]$DnsServer,
    # Zone for SHORT hostnames; for FQDN hostnames the zone is derived (override with this if needed).
    [string]$ZoneName,
    [pscredential]$Credential,
    [timespan]$Ttl = [timespan]::FromHours(1),
    [switch]$NoPtr,
    [switch]$UpdateExisting,     # replace an existing A record that points to a different IP
    [switch]$Remove,             # delete the records instead of creating them
    [string]$ReportPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log { param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'STEP')][string]$Level = 'INFO')
    $color = switch ($Level) { 'ERROR' { 'Red' }; 'WARN' { 'Yellow' }; 'OK' { 'Green' }; 'STEP' { 'Cyan' }; default { 'Gray' } }
    Write-Host ("[{0}] [{1,-5}] {2}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture), $Level, $Message) -ForegroundColor $color }

# --- prerequisites -------------------------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name DnsServer)) {
    throw "The 'DnsServer' PowerShell module is not available. Run this on a domain controller, or install RSAT 'DNS Server Tools' " +
          "(Windows Server: Install-WindowsFeature RSAT-DNS-Server; Windows 10/11: Add-WindowsCapability -Online -Name Rsat.Dns.Tools~~~~0.0.1.0)."
}
Import-Module DnsServer -ErrorAction Stop
$cimParams = @{ ComputerName = $DnsServer }
if ($Credential) { $cimParams.Credential = $Credential }
$cim = New-CimSession @cimParams -ErrorAction Stop
Write-Log "Connected to DNS server $DnsServer." 'OK'

# --- CSV -----------------------------------------------------------------------------------------------
$rows = @(Import-Csv -Path $CsvPath)
if (-not $rows.Count) { throw "CSV '$CsvPath' is empty." }
foreach ($c in @('vbr', 'hostname', 'ip')) { if ($c -notin $rows[0].PSObject.Properties.Name) { throw "CSV is missing the '$c' column." } }
if ($Vbr -ne '*') { $rows = @($rows | Where-Object { $_.vbr -eq $Vbr }); if (-not $rows.Count) { throw "No rows in the CSV match vbr = '$Vbr'." } }
Write-Log "Loaded $($rows.Count) row(s) for vbr '$Vbr'." 'OK'

# --- helpers -------------------------------------------------------------------------------------------
$zoneCache = @{}
function Test-Zone { param([string]$Name)
    if (-not $zoneCache.ContainsKey($Name)) { $zoneCache[$Name] = [bool](Get-DnsServerZone -Name $Name -CimSession $cim -ErrorAction SilentlyContinue) }
    return $zoneCache[$Name] }
function Split-HostName {
    # -> @{ Host = 'prx-01'; Zone = 'lab.example'; Fqdn = 'prx-01.lab.example' }
    param([string]$HostName)
    $h = $HostName.Trim().TrimEnd('.')
    if ($ZoneName) {
        $z = $ZoneName.Trim().TrimEnd('.')
        $short = if ($h -like "*.$z") { $h.Substring(0, $h.Length - $z.Length - 1) } elseif ($h.Contains('.')) { throw "hostname '$h' is an FQDN outside zone '$z'" } else { $h }
        return @{ Host = $short; Zone = $z; Fqdn = "$short.$z" }
    }
    if (-not $h.Contains('.')) { throw "hostname '$h' has no domain - pass -ZoneName" }
    $i = $h.IndexOf('.')
    return @{ Host = $h.Substring(0, $i); Zone = $h.Substring($i + 1); Fqdn = $h }
}
function Get-ReverseZone {
    # The in-addr.arpa zone that exists for this IP: tries /24, then /16, then /8. Returns @{ Zone; Name }
    param([string]$Ip)
    $o = $Ip.Split('.')
    foreach ($try in @(@{ Zone = "$($o[2]).$($o[1]).$($o[0]).in-addr.arpa"; Name = $o[3] },
                       @{ Zone = "$($o[1]).$($o[0]).in-addr.arpa";          Name = "$($o[3]).$($o[2])" },
                       @{ Zone = "$($o[0]).in-addr.arpa";                    Name = "$($o[3]).$($o[2]).$($o[1])" })) {
        if (Test-Zone $try.Zone) { return $try }
    }
    return $null
}

# --- main loop -----------------------------------------------------------------------------------------
$report = [System.Collections.Generic.List[object]]::new()
foreach ($row in $rows) {
    $entry = [ordered]@{ vbr = $row.vbr; hostname = $row.hostname; ip = $row.ip; zone = ''; a = ''; ptr = ''; resolves = ''; error = '' }
    try {
        if ($row.ip -notmatch '^(\d{1,3}\.){3}\d{1,3}$') { throw "ip '$($row.ip)' is not an IPv4 address" }
        $n = Split-HostName -HostName $row.hostname
        $entry.zone = $n.Zone
        if (-not (Test-Zone $n.Zone)) { throw "zone '$($n.Zone)' does not exist on $DnsServer" }
        $rev = if ($NoPtr) { $null } else { Get-ReverseZone -Ip $row.ip }
        if (-not $NoPtr -and -not $rev) { Write-Log "'$($n.Fqdn)': no reverse zone for $($row.ip) on $DnsServer - PTR skipped." 'WARN'; $entry.ptr = 'no reverse zone' }

        $existing = @(Get-DnsServerResourceRecord -ZoneName $n.Zone -Name $n.Host -RRType A -CimSession $cim -ErrorAction SilentlyContinue)
        $existingIps = @($existing | ForEach-Object { $_.RecordData.IPv4Address.IPAddressToString })

        if ($Remove) {
            if (-not $existing.Count) { $entry.a = 'absent' }
            elseif ($PSCmdlet.ShouldProcess("$($n.Fqdn) -> $($existingIps -join ',')", "Remove A record")) {
                foreach ($rec in $existing) { Remove-DnsServerResourceRecord -ZoneName $n.Zone -InputObject $rec -CimSession $cim -Force }
                $entry.a = 'removed'
            }
            if ($rev) {
                $p = @(Get-DnsServerResourceRecord -ZoneName $rev.Zone -Name $rev.Name -RRType Ptr -CimSession $cim -ErrorAction SilentlyContinue)
                if (-not $p.Count) { $entry.ptr = 'absent' }
                elseif ($PSCmdlet.ShouldProcess("$($row.ip) -> $($n.Fqdn)", "Remove PTR record")) {
                    foreach ($rec in $p) { Remove-DnsServerResourceRecord -ZoneName $rev.Zone -InputObject $rec -CimSession $cim -Force }
                    $entry.ptr = 'removed'
                }
            }
            Write-Log "'$($n.Fqdn)': A $($entry.a), PTR $($entry.ptr)." 'OK'
        }
        else {
            if ($existing.Count -and ($existingIps -contains $row.ip) -and $existingIps.Count -eq 1) {
                $entry.a = 'exists'
            }
            elseif ($existing.Count -and -not $UpdateExisting) {
                throw "A record exists with a different address ($($existingIps -join ',')); rerun with -UpdateExisting to replace it"
            }
            elseif ($PSCmdlet.ShouldProcess("$($n.Fqdn) -> $($row.ip)", "Create A record$(if ($rev) { ' + PTR' })")) {
                if ($existing.Count) { foreach ($rec in $existing) { Remove-DnsServerResourceRecord -ZoneName $n.Zone -InputObject $rec -CimSession $cim -Force } }
                Add-DnsServerResourceRecordA -ZoneName $n.Zone -Name $n.Host -IPv4Address $row.ip -TimeToLive $Ttl -CimSession $cim -CreatePtr:([bool]$rev) | Out-Null
                $entry.a = if ($existing.Count) { 'updated' } else { 'created' }
                if ($rev) { $entry.ptr = 'created' }
            }
            if ($rev -and $entry.ptr -ne 'created') {
                $p = @(Get-DnsServerResourceRecord -ZoneName $rev.Zone -Name $rev.Name -RRType Ptr -CimSession $cim -ErrorAction SilentlyContinue)
                if ($p.Count) { $entry.ptr = 'exists' }
                elseif ($entry.a -eq 'exists' -and $PSCmdlet.ShouldProcess("$($row.ip) -> $($n.Fqdn)", "Create PTR record")) {
                    Add-DnsServerResourceRecordPtr -ZoneName $rev.Zone -Name $rev.Name -PtrDomainName "$($n.Fqdn)." -TimeToLive $Ttl -CimSession $cim | Out-Null
                    $entry.ptr = 'created'
                }
            }
            if (-not $WhatIfPreference) {
                try { $r = Resolve-DnsName -Name $n.Fqdn -Type A -Server $DnsServer -DnsOnly -ErrorAction Stop; $entry.resolves = if (@($r | Where-Object { $_.IPAddress -eq $row.ip }).Count) { 'yes' } else { "other: $(($r.IPAddress) -join ',')" } }
                catch { $entry.resolves = 'not yet' }
            }
            Write-Log "'$($n.Fqdn)' -> $($row.ip): A $($entry.a), PTR $(if ($entry.ptr) { $entry.ptr } else { 'skipped' })$(if ($entry.resolves) { ", resolves: $($entry.resolves)" })." 'OK'
        }
    }
    catch {
        $entry.error = $_.Exception.Message
        Write-Log "Row '$($row.hostname)' FAILED: $($_.Exception.Message)" 'ERROR'
    }
    finally { $report.Add([pscustomobject]$entry) }
}

# --- report ----------------------------------------------------------------------------------------------
if (-not $ReportPath) {
    $ReportPath = Join-Path (Split-Path -Parent (Resolve-Path $CsvPath)) ("DnsReport_{0}_{1}.csv" -f ($Vbr -replace '\*', 'all'), (Get-Date).ToString('yyyyMMdd-HHmmss'))
}
if (-not $WhatIfPreference) { $report | Export-Csv -Path $ReportPath -NoTypeInformation; Write-Log "Report written: $ReportPath" 'OK' }
$report | Format-Table -AutoSize | Out-String | Write-Host
Remove-CimSession $cim -ErrorAction SilentlyContinue
$failed = @($report | Where-Object { $_.error })
if ($failed.Count) { Write-Log "$($failed.Count) row(s) failed." 'ERROR'; exit 2 }
