#Requires -Version 7.0
<#
.SYNOPSIS
    Encrypt the deployment's secret files at rest (appliance settings, vCenter/VBR credentials,
    VBR TOTP seed) with a SEPARATE key file. Deploy-VeeamProxies.ps1 decrypts them in memory.

.DESCRIPTION
    Format: AES-256-CBC + HMAC-SHA256 (encrypt-then-MAC), keys derived from a 256-bit random key
    file. Built-in .NET only - works identically on Linux, macOS and Windows, nothing to install.
    The key file is the secret: keep it apart from the encrypted files (removable media, a vault,
    or a path only the deploy account can read). Whoever has both can decrypt.

    Modes:
      -NewKey     -KeyFile k.key                          create a new random key (mode 600)
      -Encrypt    -KeyFile k.key -In plain.conf -Out x.enc encrypt any text file (e.g. the settings file)
      -Credential -KeyFile k.key -UserName u -Out x.cred   prompt for a password, store "user\npassword" encrypted
      -Show       -KeyFile k.key -In x.enc                 decrypt and print with values masked (-Reveal shows them)
      -NewTotpSeed                                          print a fresh 16-character Base32 TOTP seed (for
                                                            VEEAMADMIN_MFA_SECRET / an authenticator entry)
      -NewRecoveryToken                                     print a fresh Security Officer recovery token
                                                            (GUID, for VEEAMSO_RECOVERY_TOKEN)

.EXAMPLE
    ./Protect-DeploymentSecrets.ps1 -NewKey -KeyFile /secure/vbr01.key
    ./Protect-DeploymentSecrets.ps1 -Encrypt -KeyFile /secure/vbr01.key -In appliance-secrets-vbr01.conf -Out appliance-secrets-vbr01.enc
    ./Protect-DeploymentSecrets.ps1 -Credential -KeyFile /secure/vbr01.key -UserName 'svc-autodeploy@vsphere.local' -Out vcenter.cred
    pwsh -File Deploy-VeeamProxies.ps1 ... -SecretsKeyFile /secure/vbr01.key -ApplianceSecretsFile appliance-secrets-vbr01.enc `
         -vCenterCredentialFile vcenter.cred -VBRCredentialFile vbr01.cred
#>
[CmdletBinding(DefaultParameterSetName = 'Encrypt')]
param(
    [Parameter(ParameterSetName = 'NewKey', Mandatory)][switch]$NewKey,
    [Parameter(ParameterSetName = 'Encrypt', Mandatory)][switch]$Encrypt,
    [Parameter(ParameterSetName = 'Credential', Mandatory)][switch]$Credential,
    [Parameter(ParameterSetName = 'Show', Mandatory)][switch]$Show,
    [Parameter(ParameterSetName = 'NewTotpSeed', Mandatory)][switch]$NewTotpSeed,
    [Parameter(ParameterSetName = 'NewRecoveryToken', Mandatory)][switch]$NewRecoveryToken,
    [Parameter(ParameterSetName = 'NewKey', Mandatory)][Parameter(ParameterSetName = 'Encrypt', Mandatory)]
    [Parameter(ParameterSetName = 'Credential', Mandatory)][Parameter(ParameterSetName = 'Show', Mandatory)]
    [string]$KeyFile,
    [Parameter(ParameterSetName = 'Encrypt', Mandatory)][Parameter(ParameterSetName = 'Show', Mandatory)][string]$In,
    [Parameter(ParameterSetName = 'Encrypt', Mandatory)][Parameter(ParameterSetName = 'Credential', Mandatory)][string]$Out,
    [Parameter(ParameterSetName = 'Credential', Mandatory)][string]$UserName,
    [Parameter(ParameterSetName = 'Credential')][securestring]$Password,
    [Parameter(ParameterSetName = 'Show')][switch]$Reveal,
    [switch]$Force
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$MAGIC = 'VEEAMENC1'

function Get-DerivedKeys {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Key file not found: $Path" }
    $raw = [Convert]::FromBase64String((Get-Content -LiteralPath $Path -Raw).Trim())
    if ($raw.Length -lt 32) { throw "Key file '$Path' is too short - create one with -NewKey." }
    $h = [System.Security.Cryptography.HMACSHA256]::new($raw)
    try {
        return @{
            Enc = $h.ComputeHash([Text.Encoding]::UTF8.GetBytes('veeam-autodeploy-enc'))
            Mac = $h.ComputeHash([Text.Encoding]::UTF8.GetBytes('veeam-autodeploy-mac'))
        }
    }
    finally { $h.Dispose() }
}

function Protect-Text {
    param([string]$Text, [string]$Path)
    $k = Get-DerivedKeys $Path
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.KeySize = 256; $aes.Key = $k.Enc; $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'; $aes.GenerateIV()
        $plain = [Text.Encoding]::UTF8.GetBytes($Text)
        $ct = $aes.CreateEncryptor().TransformFinalBlock($plain, 0, $plain.Length)
        [byte[]]$ivct = $aes.IV + $ct
    }
    finally { $aes.Dispose() }
    $hm = [System.Security.Cryptography.HMACSHA256]::new($k.Mac)
    try { $tag = $hm.ComputeHash($ivct) } finally { $hm.Dispose() }
    return "$MAGIC`n" + [Convert]::ToBase64String([byte[]]($ivct + $tag)) + "`n"
}

function Unprotect-Text {
    param([string]$Blob, [string]$Path)
    $lines = $Blob -split "`r?`n"
    if ($lines[0].Trim() -ne $MAGIC) { throw "Not a $MAGIC encrypted file." }
    $data = [Convert]::FromBase64String((($lines[1..($lines.Count - 1)]) -join '').Trim())
    if ($data.Length -lt 16 + 16 + 32) { throw "Encrypted blob too short." }
    $k = Get-DerivedKeys $Path
    [byte[]]$ivct = $data[0..($data.Length - 33)]
    [byte[]]$tag  = $data[($data.Length - 32)..($data.Length - 1)]
    $hm = [System.Security.Cryptography.HMACSHA256]::new($k.Mac)
    try { $calc = $hm.ComputeHash($ivct) } finally { $hm.Dispose() }
    if (-not [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals($calc, $tag)) {
        throw "Integrity check failed - wrong key file or the encrypted file was modified."
    }
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.KeySize = 256; $aes.Key = $k.Enc; $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'
        $aes.IV = [byte[]]$ivct[0..15]
        [byte[]]$ct = $ivct[16..($ivct.Length - 1)]
        return [Text.Encoding]::UTF8.GetString($aes.CreateDecryptor().TransformFinalBlock($ct, 0, $ct.Length))
    }
    finally { $aes.Dispose() }
}

function Write-Protected {
    param([string]$Path, [string]$Content)
    if ((Test-Path -LiteralPath $Path) -and -not $Force) { throw "'$Path' exists - use -Force to overwrite." }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
    if (-not $IsWindows) { & chmod 600 $Path }
    else { Write-Warning "Windows: restrict '$Path' to the deploy account (icacls <file> /inheritance:r /grant `"$env:USERNAME`:F`")." }
}

switch ($PSCmdlet.ParameterSetName) {
    'NewTotpSeed' {
        # 80 random bits -> 16 Base32 chars (A-Z, 2-7), the format the appliance answer file expects.
        $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
        $rnd = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(16)
        $seed = -join ($rnd | ForEach-Object { $alphabet[$_ % 32] })
        Write-Output $seed
        Write-Host "New TOTP seed above (16-char Base32). Put it in VEEAMADMIN_MFA_SECRET and add it to your authenticator as a 'time-based' entry; every proxy built from that settings file shares it." -ForegroundColor DarkGray
    }
    'NewRecoveryToken' {
        # The answer file's veeamso.recoveryToken: a hex GUID (Veeam Help Center, "Automating Installation
        # with Initial Configuration"). Upper case, the form Deploy-VeeamProxies.ps1 writes.
        Write-Output ([guid]::NewGuid().ToString().ToUpperInvariant())
        Write-Host "New recovery token above. Put it in VEEAMSO_RECOVERY_TOKEN (needed only with VEEAMSO_ENABLED = true) and store it in your password vault: it is the Security Officer's break-glass token and cannot be read back from the appliance later." -ForegroundColor DarkGray
    }
    'NewKey' {
        $bytes = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
        Write-Protected -Path $KeyFile -Content ([Convert]::ToBase64String($bytes) + "`n")
        Write-Host "Key written: $KeyFile  (256-bit). Keep it apart from the encrypted files; back it up - without it they cannot be decrypted."
    }
    'Encrypt' {
        $text = Get-Content -LiteralPath $In -Raw
        if ($text -match "^\s*$MAGIC") { throw "'$In' is already encrypted." }
        Write-Protected -Path $Out -Content (Protect-Text -Text $text -Path $KeyFile)
        Write-Host "Encrypted '$In' -> '$Out'. Verify with -Show, then delete the plaintext (e.g. 'shred -u' / 'rm -P')."
    }
    'Credential' {
        if (-not $Password) { $Password = Read-Host -AsSecureString -Prompt "Password for $UserName" }
        $plain = [System.Net.NetworkCredential]::new('', $Password).Password
        Write-Protected -Path $Out -Content (Protect-Text -Text ("{0}`n{1}`n" -f $UserName, $plain) -Path $KeyFile)
        Write-Host "Credential for '$UserName' written encrypted to '$Out'."
    }
    'Show' {
        $text = Unprotect-Text -Blob (Get-Content -LiteralPath $In -Raw) -Path $KeyFile
        if ($Reveal) { Write-Output (($text -split "`r?`n") | Where-Object { $_ -ne '' }) }   # one line per output object
        else {
            foreach ($l in ($text -split "`r?`n")) {
                if ($l -match '^\s*([A-Za-z0-9_.-]+)\s*=\s*(.*)$') { Write-Output ("{0} = <{1} chars>" -f $matches[1], $matches[2].Length) }
                elseif ($l.Trim()) { Write-Output ("<line, {0} chars>" -f $l.Length) }
            }
        }
    }
}
