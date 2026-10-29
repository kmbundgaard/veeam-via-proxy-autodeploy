# Deploy-VeeamProxies.ps1 — Usage Guide (VIA 13.1)

CSV-driven mass-deployment and registration of **Veeam Infrastructure Appliance (VIA) 13.1
backup proxies** on VMware vSphere, one VBR at a time. Build the CSV with the offline
**`Fleet-Planner.html`** (open it in any browser, no network needed), then hand the CSV to
this script.

| Stage | What it does | Tech |
|-------|--------------|------|
| **A — Deploy** | Build a per-node **unattended ISO** from the pristine 13.1 VIA ISO: patch `/proxy-ks.cfg` (static network + the documented Initial-Configuration block: answer file with accounts / optional MFA / NTP / appliance role, and a one-shot `veeam-init.service`), patch `/EFI/BOOT/grub.cfg` (single-disk fresh install, timeout, `inst.assumeyes`), repack. Create a **UEFI + Secure Boot** VM on the row's cluster + datastore (or SDRS cluster), attach, boot, wait for the Host Management Console, detach. | **PowerCLI** + **xorriso** |
| **B — Register** | Add the appliance to its owning VBR with **certificate-based trust** (no username/password; first pairing uses handshake code `000000`), then, per the CSV `role`, assign the VMware Linux proxy role, transport mode and task slots and/or make the appliance a **gateway server** of Data Domain / StoreOnce repositories. | **REST** `:9419` (default) or Veeam PowerShell |

> **A VIA binds to exactly ONE VBR** (a property of the appliance, not of this toolkit). One
> deployment server and one CSV serve all your VBRs; each run works against one VBR — point `-Vbr` at the owning VBR key
> and the script processes only the CSV rows that match.

> **Why the ISO path?** Veeam documents unattended install **with initial configuration** only
> for the modified ISO (answer file + first-boot service). The OVA path is interactive-only.

---

## 1. Prerequisites

- **PowerShell 7.x** (`pwsh`). Windows PowerShell 5.1 is no longer supported (PowerCLI import
  clashes).
- **Deploy host = Linux VM (recommended)**: native `pwsh` + native `xorriso`, no WSL. Stage B must
  then use `-RegisterVia Rest` (the Veeam PowerShell module is Windows-only). A Windows host
  works too (xorriso through WSL2, which needs nested virtualization when the host is a VM).
- **PowerCLI** — pre-stage it (`Save-Module VCF.PowerCLI` on a connected box, copy across). The
  script imports only `VMware.VimAutomation.Core` and sets `-Scope User` certificate handling.
- **xorriso** — required by Stage A. Never auto-installed; `Initialize-IsoToolchain` preflights it.
- **Base ISO** — the pristine **Veeam Infrastructure Appliance 13.1** ISO, e.g.
  `VeeamInfrastructureAppliance_13.1.1.18_20260825.iso` (13.1.1.18 re-issue) or
  `VeeamInfrastructureAppliance_13.1.0.411_20260723.iso` (13.1 GA). Not the Software Appliance ISO.
- **Appliance settings file** (`-ApplianceSecretsFile`) — see `appliance-secrets.example.conf`.
  One file per VBR, protected, never in the CSV or in source control.
- Network access from the deploy host to vCenter, to the VBR (`:9419`) and to each new proxy
  (`:10443` readiness check).

---

## 1a. Dark-site / air-gapped runs

The script makes **no internet calls**. Everything it needs is local: PowerCLI (pre-staged),
xorriso (pre-installed), the base ISO, the CSV, the settings file. Nothing depends on git or
any online service at run time.

| Prereq | Pre-stage |
|--------|-----------|
| PowerCLI | Connected box: `Save-Module VCF.PowerCLI -Path ./stage` → copy into a `$env:PSModulePath` dir on the deploy host. Verify `Get-Module -ListAvailable VMware.VimAutomation.Core` **and `VMware.VimAutomation.Vds`** (the latter is needed for distributed port groups; without it only standard port groups resolve). |
| xorriso | `dnf install xorriso` / `apt install xorriso` from local media, or pass `-XorrisoCommand`. |
| Base ISO | Copy the pristine 13.1 VIA ISO; the script never edits it in place. |
| Veeam PowerShell *(cmdlet path only)* | Install the VBR console on a Windows host. The default REST path avoids this. |

`-ValidateOnly` is the offline smoke test: it needs no vCenter, no VBR and, without `-BaseIso`,
not even xorriso. Given vCenter and/or VBR credential files (or the deployment server's Validate with
credentials filled in), it also checks, read-only, that no VM and no VBR managed server already uses a
row's name. It never prompts for them.

---

## 1b. Secrets at rest — no clear-text passwords on the deploy host

Three kinds of secrets exist: the appliance settings file (veeamadmin password, TOTP seed), the
vCenter and VBR account passwords, and optionally the VBR account's TOTP seed.

**Simplest for an attended run: prompt.** Give only the user names and the script asks for the two
passwords when it starts; nothing is written anywhere:

```bash
pwsh -File ./Deploy-VeeamProxies.ps1 -CsvPath ./proxies.csv -Vbr vbr01 \
     -vCenterServer vc01.example.local -vCenterUser svc-autodeploy@vsphere.local \
     -VBRServer vbr01.example.local -VBRUser svc-autodeploy \
     -BaseIso ./VeeamInfrastructureAppliance_13.1.1.18_20260825.iso -ApplianceSecretsFile ./appliance-secrets-vbr01.enc -SecretsKeyFile /secure/vbr01.key
```

**For unattended runs: encrypted files.** All three secret kinds can be stored **encrypted** with
the companion `Protect-DeploymentSecrets.ps1` (AES-256-CBC + HMAC-SHA256, built-in .NET, no
modules). The deploy script decrypts them in memory when you pass `-SecretsKeyFile`; a plaintext
file still works but is flagged with a warning. The appliance settings file always has to be a
file, because its values go into the answer file; encrypt it either way.

```bash
# once per VBR: a key, kept APART from the encrypted files (vault, removable media, tight ACL)
pwsh -File ./Protect-DeploymentSecrets.ps1 -NewKey -KeyFile /secure/vbr01.key

# a fresh shared TOTP seed for VEEAMADMIN_MFA_SECRET (the same value goes into your authenticator app)
pwsh -File ./Protect-DeploymentSecrets.ps1 -NewTotpSeed

# only with VEEAMSO_ENABLED = true: the Security Officer needs its own password, its own TOTP seed
# (-NewTotpSeed again) and a recovery token for VEEAMSO_RECOVERY_TOKEN. Store the token in your vault:
# it is the SO break-glass token and cannot be read back from the appliance later.
pwsh -File ./Protect-DeploymentSecrets.ps1 -NewRecoveryToken      # prints e.g. 3F2A9C1E-7B4D-4E8A-9C21-5D6E7F8A9B0C

# the appliance settings file: start from appliance-secrets.example.conf and replace EVERY example
# value (password, seed, NTP servers) - the script refuses the example values, because an unmodified
# copy makes the appliance's first-boot configuration fail (see section 8)
pwsh -File ./Protect-DeploymentSecrets.ps1 -Encrypt -KeyFile /secure/vbr01.key \
     -In appliance-secrets-vbr01.conf -Out appliance-secrets-vbr01.enc     # then shred the .conf

# service accounts (prompts for the password, stores "user + password" encrypted)
pwsh -File ./Protect-DeploymentSecrets.ps1 -Credential -KeyFile /secure/vbr01.key \
     -UserName 'svc-autodeploy@vsphere.local' -Out vcenter.cred
pwsh -File ./Protect-DeploymentSecrets.ps1 -Credential -KeyFile /secure/vbr01.key \
     -UserName 'svc-autodeploy' -Out vbr01.cred

# check without revealing values
pwsh -File ./Protect-DeploymentSecrets.ps1 -Show -KeyFile /secure/vbr01.key -In appliance-secrets-vbr01.enc

# run
pwsh -File ./Deploy-VeeamProxies.ps1 -CsvPath ./proxies.csv -Vbr vbr01 \
     -SecretsKeyFile /secure/vbr01.key -ApplianceSecretsFile ./appliance-secrets-vbr01.enc \
     -vCenterCredentialFile ./vcenter.cred -VBRCredentialFile ./vbr01.cred ...
```

What stays clear-text, by design of the Veeam mechanism: the answer file **inside each per-node
ISO** and, briefly, on the appliance. The script limits that exposure: the ISO lives in the
protected staging folder, is deleted from the datastore and from staging after the deploy (unless
`-KeepIso`), and `veeam-init.sh` shreds `/etc/veeam/vbr_init.cfg` on the appliance after a
successful apply (`CLEANUP_ANSWER_FILE = true`). Use a distinct veeamadmin password per VBR, and
remember that whoever holds both the key file and the encrypted files can read them.

---

## 1c. Deployment server on Rocky Linux (web front end with a Run button)

`Start-DeploymentServer.ps1` serves `Fleet-Planner.html` and a small JSON API from PowerShell's
built-in HTTP listener, so no web server package is needed. When the planner is opened through
that server it shows a **Deploy from this server** panel: pick the VBR key and mode, the ISO and the
encrypted settings file on the server, type the vCenter and VBR passwords, press **Run**, and follow
the live log and run report in the page. The same page still works as a plain offline file.

The panel also has three **ISO only** modes (one ISO per node, one ISO for all nodes with a boot menu,
the generic prompt ISO) that need no vCenter and no VBR, and every run takes the planner's sizing (vCPU,
RAM, disk 1, extra data disk, logs on disk 2). The run view then lists the ISO output: the VM build sheet
downloads from the page, the ISOs are copied with the `scp` command shown there (the listener serves one
request at a time, so multi-GB files go over SSH), and *Delete ISO output on the server* removes them
afterwards - they hold the appliance passwords in clear text.

**Build the server from your laptop, unattended (recommended).** The same trick as the proxies:
`Build-DeployServerIso.ps1` repacks the official Rocky 9 minimal ISO with a kickstart, your SSH
public key, the project, the pwsh/xorriso RPMs and the PowerCLI modules; `New-DeployServerVm.ps1`
creates the VM, lets the install run, detaches the ISO and waits for SSH. Works offline once the
Rocky ISO and the RPMs are on the laptop. The build machine needs PowerShell 7, PowerCLI and
xorriso: native on Linux/macOS, or inside WSL on Windows (`-WslDistro <name>` when it is not the
default distro; paths are translated automatically). The RPM folder must hold all seven packages
(powershell, xorriso, libisoburn, libisofs, libburn, libicu, rsync); the build lists what is missing.
Take rsync for the same Rocky minor as the ISO (9.8: `rsync-3.2.5-7.el9_8.2`); the kickstart installs it
in its own step, so a mismatched build only costs rsync, not PowerShell.

```bash
# once: Rocky 9 minimal ISO (https://rockylinux.org/download - verify against its CHECKSUM file) + seven
#   RPMs into a folder: powershell-7.x-1.rh.x86_64.rpm (https://github.com/PowerShell/PowerShell/releases);
#   xorriso, libisoburn, libisofs, libburn (https://dl.rockylinux.org/pub/rocky/9/AppStream/x86_64/os/Packages/);
#   libicu + rsync (https://dl.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/Packages/l/ and .../r/). PowerCLI comes from the
#   build host (or -PowerCliModulesDir = a Save-Module VCF.PowerCLI folder). PowerCLI and the appliance ISO
#   are vendor-licensed: use the customer's own downloads when building for a customer.
pwsh -File ./Build-DeployServerIso.ps1 -RockyIso ~/iso/Rocky-9.8-x86_64-minimal.iso -OutIso ~/iso/deploy-server.iso \
     -Hostname deploy01.lab.example -Ip 10.10.1.20 -Gateway 10.10.1.1 -Dns 10.10.1.5 \
     -RpmDir ~/payload/rpms -IncludeIso ~/iso/VeeamInfrastructureAppliance_13.1.1.18_20260825.iso
pwsh -File ./New-DeployServerVm.ps1 -vCenterServer vc01.lab.example -vCenterUser administrator@vsphere.local \
     -Name deploy01 -Cluster Prod-Cluster -Datastore SSD-2 -Portgroup 'VM Network' -Folder Veeam \
     -IsoPath ~/iso/deploy-server.iso -Ip 10.10.1.20
```

Login is `deploy` with your key and passwordless sudo, root is locked; add `-DeployPasswordHash`
(a sha512-crypt string) to the build if you also want console login. `-SshPublicKeyFile` takes one
or more key files as a single quoted, comma-separated value without spaces (`"a.pub,b.pub"`), one
authorized key each, so every admin who needs the server is baked in at build time. The build
refuses to continue if a stray token lands in a network parameter. A rebuilt server has a new SSH host key: `ssh-keygen -R <ip>` on the
workstations first, and re-upload the settings file afterwards, since `server-data/` lives on the
server that was replaced. The install ends with a
power-off; the VM script then detaches the ISO and boots from disk, so the installer can never loop.

**Or by hand** on an existing Rocky 9 host:

```bash
# Rocky Linux 9, as root
dnf install -y https://packages.microsoft.com/config/rhel/9/packages-microsoft-prod.rpm && dnf install -y powershell xorriso
useradd -m deploy
mkdir -p /opt/autodeploy && cp -r "AutoDeploy Proxies"/* /opt/autodeploy/ && chown -R deploy:deploy /opt/autodeploy
# as deploy: PowerCLI (from a connected machine: Save-Module VCF.PowerCLI, copy to ~/.local/share/powershell/Modules)
mkdir -p /opt/autodeploy/server-data/iso && cp VeeamInfrastructureAppliance_13.1.1.18_20260825.iso /opt/autodeploy/server-data/iso/
cp /opt/autodeploy/deployment-server.service.example /etc/systemd/system/deployment-server.service
systemctl enable --now deployment-server
```

Use it from your workstation with an SSH tunnel, then open `http://127.0.0.1:8080`:

```bash
ssh -L 8080:127.0.0.1:8080 deploy@<server>
```

Upload the plaintext appliance settings file once through the panel; the server encrypts it with
its own key (`server-data/secrets/server.key`, created on first start) and never keeps the
plaintext. The upload is checked first: missing values and the **example values** from
`appliance-secrets.example.conf` (example password or seed, `example.local` NTP names) are rejected
with the reasons, because an unmodified example file makes every proxy fail its first-boot
configuration. A non-secret summary (MFA on/off, Security Officer on/off, NTP servers, password
length) is kept next to the encrypted file and shown under the selector, so you see
`dk.pool.ntp.org`, not `example.local`, before pressing Run. Passwords typed for a run are stored
encrypted for that run only and deleted when it ends; they never appear in logs. Run folders live
under `server-data/runs/<id>/` with the CSV, log, staging area and run report; when a run ends or
is cancelled the server removes that run's staged ISOs and rendered answer file.

**Security model.** The listener binds to 127.0.0.1 by default and has no authentication of its
own, because a run can create and delete VMs. Keep it that way and use the SSH tunnel. If several
people need it on the LAN, put nginx with TLS and authentication in front and still bind the
listener to localhost. Do not pass `-ListenAddress 0.0.0.0` without that.

What the built server enforces (checked live on 2026-09-28): the only listening ports are SSH on
the network and the web API on localhost; the firewall allows SSH alone; SSH accepts the `deploy`
account with a key only (password and keyboard-interactive authentication off, root login off, X11
forwarding off), so a user-name-and-password SSH attempt is refused; root is locked; SELinux is
enforcing; the service runs as `deploy` under systemd sandboxing (`ProtectSystem=strict`,
`NoNewPrivileges`, `PrivateTmp`); settings files are encrypted at rest with a key readable only by
`deploy`; per-run credential files are deleted when the run ends. A console password given at build
time enables VM-console login and password-protected sudo, never SSH passwords; without one, sudo
is passwordless for the single key holder, so guard that key like a root credential. Not covered by
design: disk encryption (use vSphere VM encryption if the datastore is a concern, since the
encryption key sits on the same disk as the encrypted files) and automatic OS patching (the server
is dark-site capable; patch it with `dnf update` from your own repository on your own schedule).

### HTTPS on the LAN with client certificates (optional)

If people should reach the page from their workstations without an SSH tunnel, put nginx in front of
the server with TLS **and client-certificate authentication**. Only a browser that presents a client
certificate issued by your CA gets through. The deployment server itself stays on 127.0.0.1:8080, and
everything else stays as described above. `deploy-server/enable-https-client-cert.sh` does the server
side. Verified on 2026-10-16:
- Without a client certificate, nginx answers HTTP 400.
- With a client certificate, the page and the API work.
- nginx logs who connected, e.g. `client="CN=karsten,O=kabun lab" verify=SUCCESS`.

A **private CA** is the right fit here. The client certificate has to be installed in each browser
anyway, so installing the CA next to it also makes the server certificate trusted. A private CA also
means no public DNS token on the deployment server, and the server's name stays out of the public
Certificate Transparency logs. Keep the CA key off the deployment server.

1. **CA (on an admin workstation, once):**
   ```bash
   umask 077
   openssl ecparam -name prime256v1 -genkey -noout | openssl ec -aes256 -out ca.key   # asks for a passphrase
   printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n' > ca.ext
   openssl req -new -key ca.key -subj "/O=Example/CN=AutoDeploy CA" -out ca.csr
   openssl x509 -req -in ca.csr -signkey ca.key -days 3650 -sha256 -extfile ca.ext -out ca.crt
   ```
2. **Server key and request, on the deployment server.** The private key never leaves it:
   ```bash
   sudo bash /opt/autodeploy/deploy-server/enable-https-client-cert.sh --make-csr --name deploy01.corp.local > server.csr
   ```
3. **Sign the server certificate (on the workstation).** Use 397 days at most, the limit browsers accept:
   ```bash
   printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:deploy01.corp.local\n' > server.ext
   openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 397 -sha256 -extfile server.ext -out server.crt
   ```
4. **Turn it on (on the server):** copy `server.crt` and `ca.crt` over, then run:
   ```bash
   sudo bash /opt/autodeploy/deploy-server/enable-https-client-cert.sh --name deploy01.corp.local --cert server.crt --ca ca.crt
   ```
   This installs nginx from AppStream if needed, writes `/etc/nginx/conf.d/autodeploy-https.conf`, sets the
   SELinux boolean `httpd_can_network_connect` (nginx → 127.0.0.1:8080) and opens `https` in firewalld.
5. **One client certificate per person (on the workstation).** Hand over the `.p12` and its password separately:
   ```bash
   printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n' > client.ext
   openssl ecparam -name prime256v1 -genkey -noout -out alice.key
   openssl req -new -key alice.key -subj "/O=Example/CN=alice" -out alice.csr
   openssl x509 -req -in alice.csr -CA ca.crt -CAkey ca.key -CAserial ca.srl -days 397 -sha256 -extfile client.ext -out alice.crt
   openssl pkcs12 -export -in alice.crt -inkey alice.key -certfile ca.crt -name "alice (AutoDeploy)" -out alice.p12 && rm alice.key
   ```
6. **In each browser:**
   - Windows (Edge, Chrome): import `ca.crt` into *Trusted Root Certification Authorities* and `alice.p12` into *Personal*. Use the certificate import wizard: double-click the file and choose the store.
   - macOS: add both files to the login keychain and set `ca.crt` to *Always Trust*.
   - Firefox has its own store: Settings > Privacy & Security > Certificates.
   - Then open `https://deploy01.corp.local/`. The browser asks once which certificate to use.

Notes:
- **Removing a person:** remove their certificate. There's no revocation list, so for an immediate stop,
  issue new client certificates from a new CA, or switch `ssl_verify_client` off until then.
- **Renewal:** renew the server and client certificates before the 397 days run out, with steps 2–5
  (step 2 can reuse the key).
- **A rebuild of the server from the ISO does not keep this setup.** Run steps 2–4 again after a rebuild.

---

## 1d. DNS records from the same CSV (Microsoft AD DNS)

If the proxies should be registered by name rather than by IP (`vbrname` empty), the VBR must
resolve them. `New-ProxyDnsRecords.ps1` creates the A and PTR records for a CSV's rows on an AD
DNS server, idempotently, and can remove them again. It needs the Windows-only `DnsServer` module,
so run it on a domain controller or a Windows admin host with RSAT "DNS Server Tools"
(`Install-WindowsFeature RSAT-DNS-Server` on Windows Server, `Add-WindowsCapability -Online -Name
Rsat.Dns.Tools~~~~0.0.1.0` on Windows 10/11), with DnsAdmins or Domain Admins rights.

```powershell
# zone derived from FQDN hostnames; short hostnames need -ZoneName
.\New-ProxyDnsRecords.ps1 -CsvPath .\proxies.csv -Vbr vbr01 -DnsServer dc01.lab.example -Credential (Get-Credential) -WhatIf
.\New-ProxyDnsRecords.ps1 -CsvPath .\proxies.csv -Vbr vbr01 -DnsServer dc01.lab.example -Credential (Get-Credential)
.\New-ProxyDnsRecords.ps1 -CsvPath .\proxies.csv -Vbr vbr01 -DnsServer dc01 -ZoneName lab.example        # short names
.\New-ProxyDnsRecords.ps1 -CsvPath .\proxies.csv -Vbr vbr01 -DnsServer dc01 -Remove                       # undo
```

Existing A records with the same IP are skipped; a different IP is a CONFLICT unless
`-UpdateExisting`. PTRs are created when a matching `in-addr.arpa` zone exists (/24, /16 or /8) and
skipped with a warning otherwise, or with `-NoPtr`. The script verifies resolution afterwards and
writes `DnsReport_<vbr>_<timestamp>.csv` next to the CSV. The planner prints the command as step 0
when you fill in the "AD DNS server" field.

---

## 1e. Handing the toolkit to a customer

`New-HandoverPackage.ps1` builds the customer hand-out: a versioned zip with exactly the files a
customer needs (`START-HERE.md`, this guide, the scripts, the planner, `templates/`,
`deploy-server/`, the example settings file, the CSV template and sample) plus a `.sha256` file for
the transfer. Internal material (`CLAUDE.md`, `.github/`) is left out unless you pass
`-IncludeInternalDocs`; settings, credential, key, ISO and report files can never end up in it. The
server ISO build takes its project files from the same list, so a customer's deployment server
carries the same set as the zip.

```bash
pwsh -File ./New-HandoverPackage.ps1 -OutDir ~/handover -Version 1.0.0
```

The customer adds the licensed or vendor pieces themselves: the VIA 13.1 ISO from Veeam,
PowerShell 7, PowerCLI (`Save-Module VCF.PowerCLI`, which includes the distributed-switch module),
xorriso, and the Rocky 9 minimal ISO if they build the deployment server. `START-HERE.md` walks
them through it in seven steps.

---

## 2. The CSV

One row per appliance (proxy, gateway, or both). `datastore` may be a datastore **or** a datastore cluster (SDRS). Build and
validate it with **`Fleet-Planner.html`** (duplicate hostnames/IPs, IPv4 syntax, gateway/subnet
match, per-VBR totals), or start from `proxies-template.csv` / `proxies-vbr01.sample.csv`.

```
vbr,hostname,ip,netmask,gateway,dns,cluster,datastore,folder,portgroup,role,tasks
vbr01,prx-cl-prod01-01,10.10.1.11,255.255.255.0,10.10.1.1,10.10.1.53,CL-Prod01,DS-Backup01,Veeam-Proxies,DPG-Backup,viproxy,12
vbr01,prx-cl-prod01-02,10.10.1.12,255.255.255.0,10.10.1.1,10.10.1.53,CL-Prod01,SDRS-Backup,Veeam-Proxies,DPG-Backup,viproxy,12
vbr02,prx-vbr02-01,10.10.2.11,255.255.255.0,10.10.2.1,10.10.2.53,CL-Prod02,DS-Backup02,Veeam-Proxies,DPG-Backup,viproxy,12
```

| Column | Used by | Notes |
|--------|---------|-------|
| `vbr` | filter | Owning VBR key; `-Vbr` matches on this. |
| `hostname` | A + B | **Unique across the network** (enforced). Becomes the kickstart `--hostname` and the VBR server name. |
| `ip` `netmask` `gateway` `dns` | A | Static network for the kickstart line. `dns` may be comma-separated. |
| `dnssearch` | A | *Optional.* DNS search domain(s) for NIC 1, `,`-separated (kickstart `--ipv4-dns-search`). Empty = none. |
| `cluster` `datastore` `folder` `portgroup` | A | Pure vSphere placement; Veeam never sees these. |
| `role` | B | `viproxy` = VMware Linux proxy. `gateway` = gateway server for deduplicating storage (see 2a). `viproxy+gateway` = both on one appliance. `vbr` / `em` = a **Veeam Software Appliance**: a Backup & Replication server or Enterprise Manager, Stage A only (see 4e). Anything else is refused at load. |
| `tasks` | B | Concurrent proxy task slots (`maxTaskCount` / `-MaxTasks`, 1-100). Leave empty on a `gateway`-only row. |
| `gatewayrepo` | B | *Optional, gateway rows only.* Names of existing Dell Data Domain / HPE StoreOnce repositories, `;`-separated. The appliance is added to each one's gateway server list. REST path only. |
| `handshakecode` | B | *Optional.* Pairing code for an appliance that was previously paired to a **different** VBR. Fresh appliances need none (`000000`). |
| `vbrname` | B | *Optional.* FQDN or IP the VBR should use to add the proxy when it differs from the kickstart hostname, for example when DNS has no record yet, or `hostname.<search domain>` when `hostname` is a short name. Defaults to `hostname`. |
| `vmname` | A | *Optional.* The VM name in vCenter when it follows another naming standard than the host name, e.g. `ros_km_vpr-nodspa0101` for hostname `vpr-nodspa0101`. Underscores are allowed; at most 80 characters, no `%`, `/` or `\`; unique. Empty = `hostname`. |
| `vmgroup` | A | *Optional.* An existing DRS VM group (cluster → Configure → VM/Host Groups) in the row's cluster. The VM is added right after it is created. Checked before anything is built. |
| `ip2` `netmask2` `portgroup2` | A | *Optional, all three together.* A second network adapter: the VM gets adapter 2 on `portgroup2`, the installer gives it a static address with no gateway, no DNS and no default route (NIC 1 keeps the only default route). Typical use: a backup / storage network. See §4d. |

## 2a. Gateway servers for deduplicating storage (`role` = `gateway`)

The Infrastructure Server install of the VIA can hold the **Gateway Server** role
([VIA roles](https://helpcenter.veeam.com/docs/vbr/userguide/linux_infrastructure_appliance_byb.html?ver=13),
[gateway requirements](https://helpcenter.veeam.com/docs/vbr/userguide/system_requirements_gateway.html?ver=13)),
so the same ISO, VM and registration are used. Only two deduplicating appliances use a gateway:

| Appliance | Gateway | CSV |
|---|---|---|
| Dell Data Domain (DD Boost) | required, Linux supported | `gateway` (+ `gatewayrepo`) |
| HPE StoreOnce (Catalyst) | required, Linux supported | `gateway` (+ `gatewayrepo`) |
| ExaGrid, Quantum DXi, Fsas ETERNUS CS800, Infinidat InfiniGuard | none (the Data Mover runs on the appliance) | not applicable; the script refuses such a repository in `gatewayrepo` |

What Stage B does for a gateway row:

- **Without `gatewayrepo`:** the appliance is added as a managed server and nothing else changes.
  Pick it as gateway in the repository settings (or in the wizard of a new repository).
- **With `gatewayrepo`:** for each named repository, `GET` it, add the appliance's managed-server id to
  `<dellDataDomain|hpeStoreOnce>.gatewayServer.gatewayServerIds`, set `autoSelection` to false and
  `PUT` the repository back. Existing gateways in the list are kept. A repository that was on automatic
  selection now uses the explicit list (logged as a warning), so add **every** gateway it should use.
  Rerunning is idempotent.
- The repository must already exist. Creating a Data Domain / StoreOnce repository needs the
  appliance credentials and stays in the console.

```
vbr,hostname,ip,netmask,gateway,dns,cluster,datastore,folder,portgroup,role,tasks,gatewayrepo
vbr01,gw-dd-01,10.10.1.21,255.255.255.0,10.10.1.1,10.10.1.53,CL-Prod01,DS-Backup01,Veeam-Proxies,DPG-Backup,gateway,,DD-Repo01
vbr01,prx-gw-01,10.10.1.22,255.255.255.0,10.10.1.1,10.10.1.53,CL-Prod01,DS-Backup01,Veeam-Proxies,DPG-Backup,viproxy+gateway,12,DD-Repo01;StoreOnce-Repo01
```

Things to check (from the Data Domain and StoreOnce pages of the user guide):

- **Fibre Channel:** a repository that connects over FC needs an explicitly selected gateway with FC
  access to the appliance: keep `-ApplianceRole InfrastructureServerIscsi` and give the VM an FC path.
  The script warns when the repository has `useFCConnectivity` set.
- **Ports** from the gateway: Data Domain TCP 111, 2049, 2052; StoreOnce TCP 9387, 9388
  ([used ports](https://helpcenter.veeam.com/docs/vbr/userguide/used_ports.html?ver=13)).
- **Placement:** a gateway close to the source (the proxies) for backup, close to the target for restore.
- **Lab-confirm first:** the repository field names come from the `1.3-rev2` OpenAPI spec and have not
  yet been run against a real Data Domain or StoreOnce. Try one row with `-WhatIf` and then for real
  before a fleet run.

---

## 3. Parameters

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `-CsvPath` | *(required)* | Deployment CSV. |
| `-Vbr` | `*` | Which VBR key to process. `*` = every row (one-VBR warning applies). |
| `-VBRServer` / `-VBRCredential` | — / *(prompts)* | VBR for Stage B. |
| `-vCenterServer` / `-vCenterCredential` | — / *(prompts)* | vCenter for Stage A. |
| `-BaseIso` | — | Pristine 13.1 **VIA** ISO. |
| `-KickstartName` | `proxy-ks.cfg` | Kickstart inside the ISO (13.1 unified file). 13.0.x used `vmware-proxy-ks.cfg`. |
| `-IsoLabel` | `VeeamJeOS` | ISO volume label referenced by the grub kernel lines. |
| `-ApplianceSecretsFile` | — | Appliance accounts / MFA / NTP settings (validated before any build). Plaintext or encrypted (§1b). |
| `-SecretsKeyFile` | — | Key from `Protect-DeploymentSecrets.ps1 -NewKey`; unlocks any encrypted secret file (§1b). |
| `-vCenterCredentialFile` / `-VBRCredentialFile` | — | Two-line (user, password) files, plaintext or encrypted, used instead of the interactive credential prompt. |
| `-vCenterUser` / `-VBRUser` | — | Interactive alternative: give the user names and the run prompts for the **passwords only**; nothing is stored. Omit everything and it prompts for user name and password. |
| `-ApplianceRole` | `InfrastructureServerIscsi` | Role written to the answer file. `InfrastructureServer` = plain proxy; the iSCSI variant keeps Direct SAN / storage-snapshot backup open; `None` omits the role keys (13.0.x ISOs choose the role by kickstart file). |
| `-GrubDefaultEntry` | *(13.1 titles)* | Override the boot entry as `<submenu>><entry>` for an ISO whose menu differs from 13.1. Still asserted against the extracted grub. |
| `-TemplateDir` | `<script>/templates` | Answer-file / network-line / first-boot templates. |
| `-IsoStagingDir` | `<CSV dir>/iso-staging` | Per-node `<hostname>.iso` workspace. Protect it: rendered files hold the passwords. |
| `-IsoDatastore` | *(row datastore)* | Where per-node ISOs are uploaded for the CD drive. |
| `-VmCpu` `-VmMemoryGB` `-VmDiskGB` | `6` / `12` / `120` | VM sizing. Single 120 GB thin disk by default. |
| `-MultiDisk` `-VmDataDiskGB` | off / `120` | Extra data disk: use the multi-disk boot entry and add a second thin disk of that size. Works with `-IsoOnly` too (the build sheet asks for disk 2). |
| `-LogsOnDataDisk` | off | With `-MultiDisk`: set the appliance's *Logs location* (Host Management Console setting) to the data volume on disk 2, `/var/lib/veeam/VeeamBackupLogFolder`, before first boot (§4d). |
| `-NoSecureBoot` | off | Secure Boot is **on** by default (Veeam requirement for the VIA). |
| `-GrubTimeout` | `5` | grub menu timeout (seconds). |
| `-GuestId` / `-HardwareVersion` | `rhel9_64Guest` / *(host default)* | `New-VM` guest id / HW version. |
| `-HmcPort` | `10443` | Host Management Console port polled for readiness. |
| `-IsoReadyTimeoutSec` `-IsoReadyPollSec` | `1800` / `20` | Readiness wait. |
| `-PostReadySettleSec` | `90` | Extra wait after the HMC answers so `veeam-init.service` can finish. |
| `-KeepIso` | off | Keep staged + datastore ISOs after a successful deploy (they embed the answer file). |
| `-WslDistro` / `-XorrisoCommand` | — | Run xorriso through WSL (Windows) or by explicit path. |
| `-RegisterVia` | `Rest` | `Rest` or `Cmdlet`. |
| `-VBRRestPort` | `9419` | VBR REST port. |
| `-ApiVersion` | `1.3-rev2` | `x-api-version` for **13.1**. Use `1.3-rev1` against a 13.0 VBR (see §6). |
| `-SkipTlsVerify` | off | Skip TLS validation on `:9419` (self-signed lab certs). |
| `-VBRMfaSecret` / `-VBRMfaSecretFile` | — | TOTP seed of the VBR service account, for MFA-enforced VBRs (§6a). |
| `-HandshakeCode` | `000000` | First-pairing code. Per-row `handshakecode` overrides. |
| `-RegisterTimeoutSec` | `3600` | Max wait for the VBR's async add. When the appliance build is older than the VBR, the add includes an appliance OS upgrade and can take 15 to 30 minutes. |
| `-TransportMode` | `Auto` | `Auto` / `HotAdd` / `Nbd` / `DirectStorageAccess`. |
| `-NoFailoverToNbd` | off | Disable failover to network mode. |
| `-SkipDeploy` / `-SkipRegister` | off | Run only Stage B / only Stage A. |
| `-IsoOnly` | off | Build the ISO(s) and a VM build sheet, then stop: no vCenter, no VBR (§4c). |
| `-SingleIso` | off | With `-IsoOnly`: one ISO for all rows, the node is picked in the boot menu (§4c). |
| `-PromptIso` | off | With `-IsoOnly`: one generic ISO that asks for hostname, NIC 1 and NIC 2 at install time; `-CsvPath` optional (first row = default netmask / gateway / DNS / dnssearch) (§4c). |
| `-IsoOutDir` | `<CSV dir>/iso-out` | Output of `-IsoOnly`. Must differ from `-IsoStagingDir`. |
| `-ValidateOnly` | off | Offline checks: CSV, secrets rules, template rendering, and (with `-BaseIso`) a real extract + patch dry run into `<staging>/_validate_<host>/`. With `-vCenterCredentialFile` / `-VBRCredentialFile` also the read-only name pre-check (existing VMs / VBR managed servers). |
| `-Rollback` / `-RollbackOnFailure` | off | `-Rollback`: tear down all rows **by name** (VM, VBR managed server, datastore ISO). `-RollbackOnFailure`: clean up a failed row, removing **only what this run created** for it (the VM by its id, its datastore ISO, a VBR add it sent). A VM or VBR object that already existed is never touched. |
| `-Parallel` | `1` | Deploy up to N rows at the same time (1–16), §4f. Each row runs as its own worker process; one merged report. Not with `-Replace` or `gatewayrepo` rows. |
| `-ParallelStaggerSec` | `45` | Seconds between the starts of the first N workers (spreads ISO uploads and logins). |
| `-Replace` | off | Redeploy over a proxy that already exists in VBR and keep its job assignments: capture the job lists that pin it, remove it, move the old VM aside, deploy + register the new appliance, re-pin (§4b). REST path only. |
| `-ReplaceJobPolicy` | `Auto` | While the proxy is rebuilt, jobs pinned only to it switch to automatic proxy selection (`Auto`) or are disabled and re-enabled afterwards (`Disable`). |
| `-PurgeOldVm` | off | With `-Replace`: delete the old VM instead of shutting it down and renaming it `<old name>_ToBeDeleted`. |
| `-ReplaceShutdownTimeoutSec` | `300` | With `-Replace`: how long the guest shutdown of the old VM may take before a hard power-off. |
| `-Tag` | — | vSphere tags for every VM of the run, `'Category=Tag'` pairs: an array or one string separated by `;`, e.g. `-Tag 'Team=IT Operations;Service=Veeam;Role=Proxy'`. Categories and tags are checked before anything is built; a missing one stops the run. Assigned right after the VM is created. Not applied with `-IsoOnly`. |
| `-CreateMissingTags` | off | With `-Tag`: create a missing tag inside its existing category (e.g. a new admin under *Provisioned By*) instead of stopping. Categories are never created. |
| `-ReportPath` | *next to CSV* | Run-report CSV. |
| `-WhatIf` | — | Dry-run every state-changing action. |

---

## 4. Common recipes

**Offline validation incl. the kickstart/grub dry run (no infra):**
```bash
pwsh -File ./Deploy-VeeamProxies.ps1 -CsvPath ./proxies.csv -Vbr vbr01 \
  -ApplianceSecretsFile ./appliance-secrets-vbr01.conf \
  -BaseIso ./VeeamInfrastructureAppliance_13.1.1.18_20260825.iso -ValidateOnly
# then inspect ./iso-staging/_validate_<first-host>/proxy-ks.cfg and grub.cfg, and DELETE the folder
```

**Dry-run the whole thing (`-WhatIf`):**
```bash
pwsh -File ./Deploy-VeeamProxies.ps1 -CsvPath ./proxies.csv -Vbr vbr01 \
  -vCenterServer vc01.lab.local -BaseIso ./VeeamInfrastructureAppliance_13.1.1.18_20260825.iso \
  -ApplianceSecretsFile ./appliance-secrets-vbr01.conf \
  -VBRServer vbr01.lab.local -SkipTlsVerify -WhatIf
```

**Deploy only, one row, keep the ISO for inspection (first lab boot):**
```bash
pwsh -File ./Deploy-VeeamProxies.ps1 -CsvPath ./one-row.csv -Vbr vbr01 \
  -vCenterServer vc01.lab.local -BaseIso ./VeeamInfrastructureAppliance_13.1.1.18_20260825.iso \
  -ApplianceSecretsFile ./appliance-secrets-vbr01.conf -SkipRegister -KeepIso
```

**Register only over REST (appliances already up):**
```bash
pwsh -File ./Deploy-VeeamProxies.ps1 -CsvPath ./proxies.csv -Vbr vbr01 -SkipDeploy \
  -VBRServer vbr01.lab.local -SkipTlsVerify -VBRMfaSecretFile ./vbr01-svc-totp.txt
```

**Full deploy + register, one VBR, HotAdd standard:**
```bash
pwsh -File ./Deploy-VeeamProxies.ps1 -CsvPath ./proxies.csv -Vbr vbr01 \
  -vCenterServer vc01.lab.local -BaseIso ./VeeamInfrastructureAppliance_13.1.1.18_20260825.iso \
  -ApplianceSecretsFile ./appliance-secrets-vbr01.conf \
  -VBRServer vbr01.lab.local -SkipTlsVerify -TransportMode HotAdd -RollbackOnFailure
```

**Register with the Veeam cmdlets (Windows host with the VBR console):**
```powershell
pwsh -File .\Deploy-VeeamProxies.ps1 -CsvPath .\proxies.csv -Vbr vbr01 -SkipDeploy `
  -RegisterVia Cmdlet -VBRServer vbr01.lab.local
```

**Tear down a VBR's rows (always dry-run first):**
```bash
pwsh -File ./Deploy-VeeamProxies.ps1 -CsvPath ./proxies.csv -Vbr vbr01 \
  -vCenterServer vc01.lab.local -VBRServer vbr01.lab.local -SkipTlsVerify -Rollback -WhatIf
```

---

## 4a. What Stage A (ISO) does

Once per run: validate the settings file (password / MFA / token rules), render the shared
answer file and first-boot artifacts (`Initialize-IsoWorkspace`). Then per row:

1. **Extract** `/proxy-ks.cfg` and `/EFI/BOOT/grub.cfg` from `-BaseIso` (read-only).
2. **Kickstart**: replace the `%pre` DHCP network line with the row's static line; insert the
   Initial-Configuration block inside the appliance `%post` (after
   `log "Veeam post install commands"`, with two fallbacks; the build fails if no anchor is found).
3. **grub**: default = `Single-Disk Deployment>Install - fresh install, wipes everything on all
   devices` (asserted against the real titles), `set timeout`, `inst.assumeyes` on the kickstart
   kernel lines.
4. **Repack** `<hostname>.iso` with xorriso (`-boot_image any replay`).
5. **VM**: `New-VM` on the row's cluster/datastore/folder (least-loaded host), EFI firmware +
   **Secure Boot**, `disk.EnableUUID=TRUE`, thin disk(s), ISO attached, power on. Before the first
   ISO is built, a **placement preflight** checks that every cluster, datastore or SDRS cluster, VM
   folder and port group in the CSV exists in vCenter, and lists what does exist if not; `-WhatIf`
   runs it too. In the web front end, "Load vSphere inventory" fills the placement fields with the
   real names and flags unknown ones.
6. **Wait** for guest IP/hostname (when open-vm-tools reports) **and** the HMC on `-HmcPort`,
   then settle `-PostReadySettleSec` for the first-boot configuration.
7. **Detach** the ISO and delete both the datastore copy and the staged file unless `-KeepIso`.

Details and the lab confirm-list: `templates/README.md`.

---

## 4b. Replacing a running proxy (`-Replace`)

Redeploying instead of troubleshooting is the intended way to fix a broken proxy. Two facts make
that more than "run the row again":

- The VBR keeps the **old appliance identity** under the name. A fresh appliance with the same name
  and address shows up as *Unavailable* ("Failed to update identity service configuration") until the
  old managed server is removed and a new pairing is made.
- **Removing a proxy drops it from every job that pins it.** Jobs on automatic proxy selection are
  unaffected; jobs with an explicit proxy list lose the entry and would run on whatever is left.

`-Replace` handles both, per CSV row:

1. **Capture**: the managed server and proxy ids, the proxy settings, and every job list that pins
   the proxy: `storage.backupProxies` of vSphere backup jobs, `dataTransfer.sourceProxies` and
   `targetProxies` of replication jobs, and the gateway server list of every Data Domain / StoreOnce
   repository that holds the managed server. Written to `<staging>/<host>.replace.json` before anything
   changes.
2. **Release**: the old id is removed from those lists (a list that would become empty switches to
   automatic selection, or the job is disabled with `-ReplaceJobPolicy Disable`), the managed server
   is taken out of repository gateway lists (an emptied list switches to automatic selection), then the proxy role
   and the managed server are deleted from VBR.
3. **Old VM**: the VM that VMware Tools report with the row's `ip` (or `ip2`), or the VM that carries
   the row's VM name. Finding it by address means a proxy that gets a new name under a new naming
   standard is still replaced, not deployed next to its predecessor. It is shut down from the guest
   (a hard power-off after `-ReplaceShutdownTimeoutSec`, 300 s by default, or right away when VMware
   Tools do not run) and renamed `<old name>_ToBeDeleted`, with the date appended when that name is
   already taken; deleted right away with `-PurgeOldVm`. Delete the renamed VM yourself once the new
   proxy has proven itself. The VM is looked up **before** step 2, and the row stops with nothing
   changed when several VMs match, or when the address answers a ping but no VM reports it (another
   device, or a VM without VMware Tools). In the VBR the old proxy is found by the row's registration
   name, its IP, or the old VM's guest host name or VM name.
4. **Deploy and register** exactly as for a new node. The fresh appliance pairs with handshake
   `000000`.
5. **Restore**: the new proxy id is put back into every captured job list, the new managed-server id
   into every captured repository gateway list, the original automatic/manual
   setting is restored, disabled jobs are re-enabled, and the manifest is deleted. The run report
   says `ok (replaced; N job list(s) re-pinned)`, plus the repository gateway lists when there were any.

```bash
# CLI: same row, same CSV, plus -Replace
pwsh -File ./Deploy-VeeamProxies.ps1 -CsvPath ./proxies.csv -Vbr vbr01 ... -Replace
# web page: tick "Replace existing proxies" under Run commands, choose the job policy, Run
```

If the run is interrupted after step 2, rerun the row with `-Replace -SkipDeploy` (or `-Replace`
for a full rebuild): the manifest on disk is picked up and restored after registration.

You may power off and rename the old VM yourself before the run; a powered-off VM reports no
address, so with `-Replace` the script then finds nothing to move aside and continues. Do not leave it powered on, since the new VM
takes the same IP. Without `-Replace`, a run against a proxy whose VBR object is not *Available*
stops with a message pointing at `-Replace`, instead of skipping the add and reporting a success
that the VBR console would contradict. CSV `tasks`
and `-TransportMode` are applied to the new proxy; the log warns when they differ from the old one.
Not covered, because the REST API has no field for it: **repository proxy affinity**. Check
repositories that restrict proxies by hand, or use the Veeam PowerShell cmdlets on a Windows host.

---

## 4c. No vCenter access: build the ISO only (`-IsoOnly`)

For when you may not sign in to vCenter and the vSphere team creates the VMs. The run validates the
CSV and the settings file, patches the kickstart exactly as Stage A does, and writes to `-IsoOutDir`:

- the ISO: one `<hostname>.iso` per row, or with `-SingleIso` **one** ISO for all rows;
- `AutoDeploy-<vbr>-VM-SPEC.txt` and `.csv`, the build sheet for the vSphere team: hardware (vCPU,
  RAM, disk 1 and, with `-MultiDisk`, disk 2), EFI + Secure Boot, `disk.EnableUUID=TRUE`, placement
  per VM, which ISO or boot entry belongs to which VM, and what to do after the install.

No vCenter or VBR connection is made. Before building, every CSV address is pinged once from the
build host and a warning lists the ones that answer (a live machine there means an IP conflict).
No answer is not proof the address is free.

**One ISO for many nodes (`-SingleIso`).** Each row's patched kickstart is stored as
`/autodeploy/nNNN.cfg` and the boot menu gets an extra submenu, *AutoDeploy: N node(s), fresh install
wipes all disks - pick THIS VM*, with one entry per row: `01  <hostname>  <ip>` (plus `/ <ip2>` for a
second adapter). The entries use the same
kernel line as Veeam's own Install entry for the chosen disk layout, pointing at their own kickstart.
The menu timeout is `-1`: **nothing installs until someone picks an entry in the VM console**, so a
VM can never take another node's name and IP on its own. Picking the wrong entry does exactly that,
so the build sheet lists the entry per VM. Veeam's own entries and `/proxy-ks.cfg` are unchanged
below the new submenu. The settings file stays one per VBR; only the network line differs per entry.

The per-node ISOs install unattended as in Stage A (5 s timeout, no keypress).

```bash
# 1. here (no vCenter): ISO + build sheet in ./iso-out/
pwsh -File ./Deploy-VeeamProxies.ps1 -CsvPath ./proxies.csv -Vbr vbr01 -IsoOnly -SingleIso \
  -BaseIso ./VeeamInfrastructureAppliance_13.1.1.18_20260825.iso -ApplianceSecretsFile ./appliance-secrets-vbr01.conf
# add -MultiDisk -VmDataDiskGB 200 for an extra data disk
# 2. vSphere team: create the VMs from the build sheet, boot, pick the entry, wait for :10443
# 3. here (VBR access only): register
pwsh -File ./Deploy-VeeamProxies.ps1 -CsvPath ./proxies.csv -Vbr vbr01 -VBRServer vbr01.example.local -SkipDeploy
```

The ISOs are the output, so they are **not** deleted at the end of the run. Like every per-node
ISO they contain the appliance passwords and MFA seeds in clear text: hand them over directly
(not by e-mail), and delete them from the datastore and the build folder after the install.

**Generic ISO, values typed at install (`-PromptIso`).** No node data in the ISO: after about a
minute the installer stops on its own console and asks for the hostname (FQDN), NIC 1 IP, netmask,
gateway, DNS and DNS search domain(s) (default: the domain part of the hostname; `-` = none), and - when the VM has a second adapter - NIC 2 IP and netmask (`-` = leave NIC 2
unconfigured). Enter keeps the value in [brackets] (defaults from the first CSV row when one is given).
Every answer is checked, a summary is shown, and nothing installs until `y`; anything else starts over
with the previous answers prefilled. One ISO serves any number of nodes; the person at the console is
responsible for unique names and addresses. Register afterwards with a CSV of what was typed and
`-SkipDeploy`.

```bash
pwsh -File ./Deploy-VeeamProxies.ps1 -CsvPath ./proxies.csv -Vbr vbr01 -IsoOnly -PromptIso \
  -BaseIso ./VeeamInfrastructureAppliance_13.1.1.18_20260825.iso -ApplianceSecretsFile ./appliance-secrets-vbr01.conf
```

Verified in the lab on 2026-09-30: the single ISO (real xorriso repack, built on macOS) and the prompt
ISO (built on macOS and on Windows with xorriso in WSL) boot with Secure Boot on; the menu entry or the
typed values set hostname, NIC 1 and NIC 2; the settings file is applied (veeamadmin password and TOTP
work); registration with `-SkipDeploy` and a backup job ran. The DNS search domain question
(`--ipv4-dns-search`) was confirmed working on 2026-10-01 with the `prompt-search` test ISO; the
first-boot failure first blamed on it (`prx-lab-04`, 2026-09-30) had another cause.

---

## 4d. Two network adapters, two disks, logs on disk 2

Three independent options; combine as needed. All of them work in a full run and with `-IsoOnly`
(the VM build sheet then lists adapter 2 and disk 2 for the vSphere team).

**Second network adapter** - CSV columns `ip2`, `netmask2`, `portgroup2` (all three, or none). In a
full run Stage A adds adapter 2 (VMXNET3) on `portgroup2` after the first one. The kickstart gets a
second `network` line with a static address, `--nodefroute` and no gateway or DNS: NIC 1 keeps the
only default route. The adapters are not named `ens192` / `ens224` in the kickstart: the build inserts
a small block into Veeam's `%pre` that lists the VM's network devices in **PCI order** and uses the
first as NIC 1 and the second as NIC 2, so adapter 1 of the VM is always the management NIC. A VM
that has only one adapter fails the install with a message on the console instead of coming up half
configured. The planner's "Second network adapter" fields fill the columns, count the IP up per node
and flag a partial set, a duplicate address or an `ip2` in the same subnet as `ip`.

**Two disks** - `-MultiDisk -VmDataDiskGB <GiB>` (planner: "Extra data disk GB"). Veeam's
`Standard (Multi-Disk) Deployment` install: disk 1 = system volumes, disk 2 = the `datavol` VG with
`/var/lib/veeam`. Disk 2 must be at least 120 GB (Veeam's minimum for the data disk).

**Logs on disk 2** - `-LogsOnDataDisk` (needs `-MultiDisk`; planner: "Logs on disk 2"). The appliance
has a **Logs location** setting in the Host Management Console with two possible targets: the default
`/var/log/VeeamBackup` on disk 1 (the `/var/log` volume: 20 GiB or 17 % of disk 1, at most 100 GiB),
and the data volume `/var/lib/veeam`, which the multi-disk layout puts on disk 2, with the fixed
folder `/var/lib/veeam/VeeamBackupLogFolder`. Changing it in the console writes `rootLogDirPath` to
`/etc/veeam/veeam_global.conf` (the key the host manager and the Veeam deployment service read),
creates the folder (`root:veeam-grp-log`, mode `02770`, like `/var/log/VeeamBackup`) and repoints the
rsyslog and logrotate rules for the Veeam services. The build does the same before first boot, in the
kickstart: the generated `%post` block creates the folder and writes the key, and the kickstart's own
rsyslog / logrotate / retention setup (`VEEAM_LOG_DIR`, `VEEAM_LEGACY_LOG_DIR`) is patched to the new
folder. The host manager reads the key when it first starts and shows the location in the console,
where it can also be changed back.

Nothing in the disk layout changes: disk 1 keeps Veeam's volumes, disk 2 is the standard data volume
(120 GB minimum, `/var/lib/veeam` grows into whatever size you give it). The host manager's own log
(`/var/log/VeeamBackup/veeam_hostmanager`) and the system journal stay on disk 1.

Verified in the lab on 2026-09-30 (`prx-lab-05`, VIA 13.1.1.18, host manager 13.1.1.9, registered to a
13.1.1.18 VBR, one HotAdd backup job run): the web UI shows *Logs directory:
/var/lib/veeam/VeeamBackupLogFolder*; the host manager took the location into its database at first boot
("Logs location: /var/lib/veeam/VeeamBackupLogFolder"); every component writes there
(`VeeamTransportSvc.log`, `VeeamDeploymentSvc.log`, `VeeamEnvironmentSvc.log`, the host manager logs and
the job logs); `/var/log/VeeamBackup` stays empty. No component file needs its own log path.

> **Log collection with logs on disk 2 (13.1.1.18):** the appliance's own **support bundle** (Host
> Management web UI → Logs and Services → Logs → *Create support bundle*) collects everything from
> disk 2. **VBR's *Export logs*** (console → Help → Support Information) does **not**: for the proxy it
> only returns `/var/log/veeam/veeam-updater`. The same happens when the location is changed in the web
> UI, so this is VBR behaviour, not the build. For a support case on such a proxy, attach the support
> bundle from the web UI. Reported to Veeam as a candidate defect; keep `-LogsOnDataDisk` off unless the
> customer accepts that.

```bash
# two adapters (from the CSV), 200 GiB disk 2 with the Veeam logs on it, one ISO for all nodes
pwsh -File ./Deploy-VeeamProxies.ps1 -CsvPath ./proxies.csv -Vbr vbr01 -IsoOnly -SingleIso \
  -BaseIso ./VeeamInfrastructureAppliance_13.1.1.18_20260825.iso -ApplianceSecretsFile ./appliance-secrets-vbr01.conf \
  -MultiDisk -VmDataDiskGB 200 -LogsOnDataDisk
```

## 4e. Veeam Software Appliance: backup server or Enterprise Manager (`role` = `vbr` / `em`)

The same Stage A also deploys the **Veeam Software Appliance (VSA)**, the Linux appliance that runs
the backup server itself. Set the row's `role` to:

| `role` | Product | Kickstart on the ISO | Boot entry the build selects | Default VM |
|---|---|---|---|---|
| `vbr` | Veeam Backup & Replication | `/vbr-ks.cfg` | `Veeam Backup & Replication > Install - fresh install, wipes everything (including local backups)` | 8 vCPU / 16 GB, 240 + 240 GB |
| `em` | Veeam Backup Enterprise Manager | `/vbem-ks.cfg` | `Veeam Backup Enterprise Manager > Install - fresh install, wipes everything` | 4 vCPU / 16 GB, 240 + 240 GB |

How it differs from a proxy run:

- **Base ISO** = `VeeamSoftwareAppliance_13.1.x.iso` (label `VeeamSA`). Both products come from that one
  ISO. Unlike the 13.1 VIA, the **boot menu** picks the product, so no `applianceRole.*` keys are written.
  The rest of the answer file (accounts, MFA, NTP), the static network line and `veeam-init.service` are
  the same mechanism as on the VIA (Help Center "Automating Installation with Initial Configuration").
- The stock grub default of the VSA ISO is the **Reinstall** entry. The build always sets the product's
  **fresh install** entry and checks that both titles exist.
- **Two disks are required** (system + data, at least 240 GB each). The VSA has no single-disk layout,
  and the installer stops on a smaller or missing disk. `-VmCpu` / `-VmMemoryGB` / `-VmDiskGB` /
  `-VmDataDiskGB` override the per-product sizing when you pass them. The backup server needs
  +500 MB RAM per concurrent job on top of 16 GB.
- **Install time:** much longer than a proxy (about 770 packages). VSA rows wait up to **2 hours** for the
  Host Management Console (`-IsoReadyTimeoutSec` overrides it); proxies keep 30 minutes. With
  *Rollback on failure* a timeout deletes the VM, so for a first test leave it off and look at the console.
- **No Stage B.** These *are* the servers: there is nothing to register to a VBR. The run waits for the
  Host Management Console (`:10443`) and then for the product on `:443` (VBR web UI + REST API, or the
  Enterprise Manager web UI). The run report shows `register = n/a (software appliance)`.
- Set **`VEEAMADMIN_MFA_ENABLED=true`** with a TOTP seed in the settings file. Without MFA, the appliance
  keeps VBR / Enterprise Manager unavailable until veeamadmin enrols in the Host Management Console.
  The run warns about this.
- One run = one base ISO. `vbr` / `em` rows cannot share a `vbr` key with proxy rows; give them their
  own key (for example `servers`) and run them with `-Vbr servers`. `vbr` and `em` rows may be mixed.
- Works with: Full (deploy), `-WhatIf`, `-ValidateOnly`, `-IsoOnly` (one ISO per row), `-Rollback`
  (deletes the VM; nothing to remove from a VBR), `-RollbackOnFailure`. Refused: `-SkipDeploy`,
  `-Replace`, `-SingleIso`, `-PromptIso`, `-LogsOnDataDisk`, `-ApplianceRole`.

```bash
# servers.csv
vbr,hostname,ip,netmask,gateway,dns,cluster,datastore,folder,portgroup,role,tasks
servers,vbr01.corp.local,10.10.0.21,255.255.255.0,10.10.0.1,10.10.0.53,CL-Mgmt,DS-Mgmt01,Veeam,DPG-Mgmt,vbr,
servers,em01.corp.local,10.10.0.20,255.255.255.0,10.10.0.1,10.10.0.53,CL-Mgmt,DS-Mgmt01,Veeam,DPG-Mgmt,em,

pwsh -File ./Deploy-VeeamProxies.ps1 -CsvPath ./servers.csv -Vbr servers -ValidateOnly \
  -BaseIso ./VeeamSoftwareAppliance_13.1.1.18_20260825.iso -ApplianceSecretsFile ./appliance-secrets-servers.conf
pwsh -File ./Deploy-VeeamProxies.ps1 -CsvPath ./servers.csv -Vbr servers -vCenterServer vc01.corp.local \
  -BaseIso ./VeeamSoftwareAppliance_13.1.1.18_20260825.iso -ApplianceSecretsFile ./appliance-secrets-servers.conf
```

Afterwards: log in as veeamadmin at `https://<ip>` (VBR web UI / Enterprise Manager) or
`https://<ip>:10443` (Host Management). Add the backup servers to Enterprise Manager under
**Configuration > Backup Servers** (a Linux VBR is added on port 443), and install licenses there.
That step is not automated yet. Enterprise Manager has a REST call for it (`POST :9398/api/backupServers?action=create`).

## 4f. Parallel deployment (`-Parallel`)

By default a run deploys its rows one after the other (about 25 minutes per proxy). For a large fleet,
`-Parallel N` deploys up to N appliances at the same time. In Fleet-Planner, set it under *Run commands*
→ **Appliances at a time**; the commands and the Run button pick it up.

```bash
pwsh -File ./Deploy-VeeamProxies.ps1 -CsvPath ./proxies.csv -Vbr vbr01 -vCenterServer vc01.corp.local \
  -BaseIso ./VeeamInfrastructureAppliance_13.1.1.18_20260825.iso -ApplianceSecretsFile ./appliance-secrets-vbr01.enc \
  -SecretsKeyFile /secure/vbr01.key -VBRServer vbr01.corp.local -VBRUser svc-autodeploy -Parallel 4
```

How it works:

- **The run becomes an orchestrator.** It checks the CSV, the settings file and the input parameters
  once, then starts one **worker** per row. A worker is this same script with a one-row CSV, its own
  staging folder, its own vCenter and VBR sessions and its own report. At most N workers run at once; when
  one finishes, the next row starts. The per-row logic (deploy, register, rollback on failure) is the normal
  sequential code, unchanged.
- **Credentials are asked for once.** If you are prompted, the answer is handed to the workers as encrypted
  files (`-SecretsKeyFile`, or a throw-away key) in a private folder under the staging folder. The folder is
  deleted at the end, also after Ctrl-C or when the deployment server cancels the run.
- **Staggered starts:** the first N workers start `-ParallelStaggerSec` apart (default 45 s), so ISO uploads
  and logins do not all hit vCenter and the VBR in the same second.
- **MFA:** every worker logs in to the same VBR account. A TOTP code is only valid once per 30-second window
  on some MFA servers, so the workers share a lock file and each one uses its own time step (a worker may
  wait up to 30 s for a fresh code).
- **Output:** every log line carries the row's host name (`[prx-vbr01-07] ...`). At the end there is one
  merged run report; the exit code is 2 when any row failed.
- **One run per appliance.** Never start a second run for the same rows while one is running: each run's
  pre-check and rollback would act on the other's VMs (lab 2026-10-14, before 1.3.1: a sequential and a
  parallel run of the same four proxies deleted each other's appliances). The deployment server refuses a
  Full / DeployOnly / RegisterOnly / Rollback run that shares a host name or IP with one still running.

Limits and sizing:

- **Disk:** every running worker builds its own copy of the base ISO, so the staging folder needs about
  N × the ISO size free (VIA 13.1: 2.6 GB, VSA: 15 GB). The run checks this first and tells you the largest
  N that fits.
- **Refused in parallel:** `-Replace`, and rows with `gatewayrepo`. Both edit lists that several appliances
  can share (a job's proxy list, a repository's gateway list), and two workers writing the same list at once
  would overwrite each other's change. Run those rows without `-Parallel`. `-RegisterVia Cmdlet` is also
  not supported in parallel.
- **Sequential anyway:** `-ValidateOnly`, `-Rollback` and the `-IsoOnly` modes ignore `-Parallel` (they are
  quick or touch nothing).
- **Choosing N:** 4 is a good start. Each worker uploads one ISO and creates one VM at a time, so more
  workers mostly load the datastore and the vCenter upload path. 100 proxies at N = 4 take about
  10–11 hours instead of about 42.

---

## 5. What Stage B (REST) does

Per row (`-RegisterVia Rest`):

1. `POST /api/oauth2/token` → bearer token (two-leg TOTP when the account is MFA-enforced; auto
   re-auth on 401).
2. `POST /api/v1/connectionCertificate` with only `serverName` + `type` → the appliance TLS
   certificate (`certificateUpload`, PEM). The script computes the **SHA-256** hash of that
   certificate, uppercase hex, and uses it as `sshFingerprint`. The VBR's own
   `certificate.thumbprint` field is SHA-1 and is **rejected** with 400 "Invalid TLS key certificate
   fingerprint ... <SHA-256>" (seen live on 13.1.1.18). This replaces the interactive "do you
   trust this fingerprint" dialog. Do not add `credentialsStorageType` to this request: the VBR
   then answers 400 "SingleUseCredentials property must be set".
3. `POST /api/v1/backupInfrastructure/managedServers` — `LinuxHostSpec`: `type: LinuxHost`,
   `credentialsStorageType: Certificate`, `sshFingerprint` = that thumbprint, `handshakeCode`
   (`000000` for a fresh appliance) → async session, polled. Retried up to 3 times 60 s apart,
   because the HMC can answer a little before the first-boot configuration has finished.
4. `POST /api/v1/backupInfrastructure/proxies` — `ViProxySpec`: `type: ViProxy` and everything
   else inside `server`: `hostId`, `maxTaskCount`, `transportMode` (`Auto` / `DirectAccess` /
   `VirtualAppliance` / `Network`), `failoverToNetwork`, `hostToProxyEncryption`,
   `connectedDatastores.autoSelectEnabled` → async session. Field names and enums taken from the
   live `1.3-rev2` OpenAPI spec (`https://<vbr>:9419/swagger/v1.3-rev2/swagger.json`). Only for
   `viproxy` rows.
5. Gateway rows with `gatewayrepo`: `GET` + `PUT /api/v1/backupInfrastructure/repositories/{id}`
   with the managed-server id added to `gatewayServer.gatewayServerIds` (see 2a).

All adds are idempotent (find-before-add), so re-runs never create duplicates.

`-RegisterVia Cmdlet` does the same with `Add-VBRLinux -UseCertificate -HandshakeCode <code>
-ForceDeployerFingerprint` and `Add-VBRViLinuxProxy -MaxTasks -TransportMode`. No known-hosts
pre-seeding is needed on either path.

> **Bulk alternative (not used):** the REST **Automation** section can import a whole fleet from
> one JSON (`/api/v1/automation/proxies/import`). This build uses per-row calls for per-row
> reporting and rollback.

---

## 6. API version

`x-api-version` must be a revision the VBR supports, or every call fails with **HTTP 400 "does
not support the API version"**.

| VBR build | `-ApiVersion` |
|-----------|---------------|
| **13.1.x** (GA 2026-07-29) | **`1.3-rev2`** (script default; the current Help Center REST reference) |
| 13.0.x GA | `1.3-rev1` (verified 2026-07-06 on the lab VBR; it rejects `1.3-rev2`) |

Discover the ceiling on any VBR (401 = supported, 400 = rejected):
```bash
for v in 1.3-rev0 1.3-rev1 1.3-rev2; do
  echo -n "$v -> "; curl -sk -o /dev/null -w "%{http_code}\n" \
    -X POST "https://<vbr>:9419/api/oauth2/token" -H "x-api-version: $v" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=Password&username=x&password=y"
done
```

---

## 6a. MFA — when the VBR account is MFA-enforced

The token exchange is two legs (RFC 6238 TOTP): `grant_type=Password` returns an `mfa_token`;
the script computes the current 6-digit code from the account's Base32 seed and posts
`grant_type=Mfa` + `mfa_token` + `code`. Supply the seed with `-VBRMfaSecret` or
`-VBRMfaSecretFile` (protected file, first non-comment line). A non-MFA service account needs
neither (verified against a lab VBR with a non-MFA service account).

This is the **VBR** account's seed. It is unrelated to the appliance `veeamadmin`/`veeamso`
MFA seeds in `-ApplianceSecretsFile`.

**Which account to use.** Two ways work:

1. **A dedicated account without MFA (recommended).** In the VBR console (*Users and Roles*), mark the
   account the toolkit uses as a service account so that MFA does not apply to it, give it a long random
   password and use it for nothing else. No seed is needed; in Fleet-Planner leave **VBR MFA seed file** at
   *(none)*. Runs show up under their own name in the VBR audit trail, and no seed sits on the deploy host.
2. **An account with MFA.** Supply its seed as below. Whoever holds the seed file *and* the key can generate
   valid codes for that account, which weakens what MFA protects.

Registration adds managed servers and assigns the proxy role, which normally needs the *Veeam Backup
Administrator* role on that VBR. *(Service-account option and role from field experience; confirm them
against the VBR 13.1 user guide for your build.)*

**Getting the seed.** It is the Base32 secret behind the QR code VBR shows when MFA is set up for the
account (the "enter the key manually" text). If the account is enrolled and the key was not kept, reset
MFA for the user in VBR and enrol again, noting the key. Add the same key to an authenticator app so a person
can still sign in. After a later MFA reset the stored seed stops working: runs then fail at the token call.

**Command line.** Store the seed in a file (first non-comment line) and encrypt it (§1b):

```bash
pwsh -File ./Protect-DeploymentSecrets.ps1 -Encrypt -KeyFile /secure/vbr01.key -In vbr01-svc.mfa.txt -Out vbr01-svc.mfa.enc
pwsh -File ./Deploy-VeeamProxies.ps1 ... -VBRCredentialFile ./vbr01.cred -VBRMfaSecretFile ./vbr01-svc.mfa.enc -SecretsKeyFile /secure/vbr01.key
```

**Deployment server (§1c).** The page cannot upload seed files: put one into `<DataDir>/secrets/`
yourself, encrypted with the server's key. The file name must contain **`.mfa`**: that is how the server
tells it from the appliance settings files and lists it under **VBR MFA seed file** in the Run panel (and
in the per-VBR table, which preselects it). Example for `vbr01`, as the service user, without the clear-text
seed ever touching the disk or the shell history:

```bash
cd /opt/autodeploy && umask 077
read -rs SEED && printf '%s\n' "$SEED" > /dev/shm/vbr01.mfa.txt && unset SEED
pwsh -File ./Protect-DeploymentSecrets.ps1 -Encrypt -KeyFile server-data/secrets/server.key \
  -In /dev/shm/vbr01.mfa.txt -Out server-data/secrets/vbr01.mfa.enc
shred -u /dev/shm/vbr01.mfa.txt
pwsh -File ./Protect-DeploymentSecrets.ps1 -Show -KeyFile server-data/secrets/server.key -In server-data/secrets/vbr01.mfa.enc
```

Then reload the page, pick the file, enter the MFA account as **VBR user**, and test with **What-if**: the
log must show `Authenticated to VBR REST https://<vbr>:9419`.

What is in the server's `secrets/` folder:

| File | Holds |
|------|-------|
| `server.key` | Only the random key that encrypts / decrypts the files below - no password, no seed. Owner-only; never copy it off the server. |
| `*.enc` (the **Settings file**) | The *appliances'* accounts: veeamadmin password and MFA seed, Security Officer, NTP. |
| `*.mfa*` (optional) | The TOTP seed of the *VBR account* the toolkit logs in with. |
| `runs/<id>/vcenter.cred`, `vbr.cred` (in the run folder) | The vCenter / VBR user and password of one run, encrypted; deleted when the run ends. |

With `-Parallel`, all workers log in with the same account; they share a lock file so that no two of them
use the same 30-second code (§4f).

---

## 6b. Pairing / handshake code

Per the Veeam docs (13.1): *"The first time you add a specific Veeam Infrastructure Appliance
component to Veeam Backup & Replication, a connection is automatically established. If you later
add the component to a different Veeam Backup & Replication installation, you must first delete
the previous connection and generate a pairing code."* The `Add-VBRLinux` reference adds: *"The
first time a server is paired, the code is 000000."*

So: fresh appliances → default `000000`, nothing to collect. Re-homing an appliance to another
VBR → delete the old connection in its HMC, generate a pairing code there, and put it in the
row's `handshakecode` column.

---

## 7. Run report

Every run writes a per-row CSV (`deploy` / `register` / `validate` / `error`) next to the input
CSV, or at `-ReportPath`. `-RollbackOnFailure` appends `(rolled back)` to a row it cleaned up, or
`(nothing created, nothing removed)` when the row failed before this run created anything (for example a
pre-check failure).

---

## 8. Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `ApplianceSecretsFile ... failed validation` | The listed values break the appliance rules (15+ chars, classes, max 4 same-class in a row, admin ≠ so, 16-char Base32 seed, hex-GUID token). Fix the file; nothing was built. |
| `Could not extract /proxy-ks.cfg` | Not a 13.1 VIA ISO, or a 13.0.x ISO (`-KickstartName vmware-proxy-ks.cfg -ApplianceRole None -GrubDefaultEntry '...'`). List the root with `xorriso -indev <iso> -find / -maxdepth 1`. |
| Installer console: `At least 2 disks are required ... "System" at least 120 GB, "Data" at least 120 GB` | You booted a **13.0.x** ISO with one disk. Single-disk deployment exists only from 13.1; add `-MultiDisk` for 13.0.x (seen live on 13.0.2.29). |
| `No insertion anchor found inside a %post block` | The kickstart layout changed. Inspect the extracted file from a `-ValidateOnly` run and update the anchors in `Get-PatchedApplianceConfigs`. |
| `grub.cfg has no menu title ...` | The boot menu titles differ on this build; the message lists what it found. Toggle `-MultiDisk` or update the expected titles. |
| VM console shows the **Initial Configuration Wizard** (License, Appliance Role, ...) and the run ends with `not ready within N s` | The answer file was **not applied** at first boot. Seen live (2026-09-25, two nodes): the settings file was an unmodified `appliance-secrets.example.conf`; with `NTP_RUNSYNC = true` the unresolvable `ntp01.example.local` fails the whole Initial Configuration. The script and the server upload now refuse the example values. Also make sure the appliance's DNS (CSV `dns`) resolves your NTP names, or use IP addresses. Delete the VM (or `-Rollback`) and re-run with a real settings file. |
| VM boots into the interactive **installer** (not the wizard) | `inst.assumeyes` or the grub default did not take. Check the patched files from the dry run; confirm the anchor landed inside the chroot `%post`. |
| Web page: `Inventory failed: ... Invalid server certificate. Use Set-PowerCLIConfiguration ...` | Server code before 2026-09-25 skipped the certificate setting on a fresh server (PowerShell auto-loaded PowerCLI, so the "first import" block never ran). Update `Start-DeploymentServer.ps1` and restart the service. Workaround on an old build: as the service user run `pwsh -c "Import-Module VMware.VimAutomation.Core; Set-PowerCLIConfiguration -Scope User -InvalidCertificateAction Ignore -Confirm:$false"` once. |
| `The term 'Get-VDPortgroup' is not recognized` (inventory or placement check) | `VMware.VimAutomation.Vds` (+ `.Storage`) is not installed. Copy those two module folders from a host with full PowerCLI into the module path (`~/.local/share/powershell/Modules` for the `deploy` user). ISOs built from 2026-09-25 include them. Code from that date no longer crashes without them; it then resolves standard port groups only. |
| Rocky **deployment server** comes up with a DHCP address instead of the static one | ISO built before 2026-09-25: the kickstart's `bootloader --append="net.ifnames=0"` renamed the NIC to `eth0` on the installed system, while the installer had written the static profile for `ens192`. Rebuild the ISO with the current template, or fix the running server: `sudo grubby --update-kernel=ALL --remove-args=net.ifnames=0`, `sudo nmcli con delete 'Wired connection 1'`, reboot. |
| VM will not boot the ISO with Secure Boot on | Confirm the ISO was repacked with `-boot_image any replay`. As a diagnostic only, `-NoSecureBoot` (Veeam requires Secure Boot on the VIA). |
| Appliance `not ready within N s` | Install/first boot slower than the timeout, or the HMC / guest tools not up. The script saves a **console screenshot** (`<host>-console-<time>.png`, next to the staging ISOs) before any rollback: a wizard means the answer file was not applied (row above); an installer or boot error points at the ISO. Otherwise raise `-IsoReadyTimeoutSec`. |
| `HTTP 400 ... does not support the API version` | Wrong `-ApiVersion` for this VBR (§6). |
| `401` on the token call / `mfa_token` message | Bad VBR credentials, or the account is MFA-enforced and `-VBRMfaSecret*` is missing (§6a). |
| `POST /api/v1/connectionCertificate -> HTTP 500 : Failed to get certificate from: https://<name>:443/` | The VBR cannot resolve or reach the appliance under that name: no DNS record, or a record pointing at a dead address. The script now falls back to the row's IP with a warning instead of retrying; "Test connections" and the run preflight resolve the names first. Create the A records (`New-ProxyDnsRecords.ps1`) or set `vbrname`. |
| `managedServers -> HTTP 400 : Failed to connect to deployer service ... Failed to verify the client connection token` | The appliance is already paired. If someone added it to this VBR meanwhile (for example by hand in the console), the script now detects the existing managed server and continues with the proxy role. If it is paired with **another** VBR, re-home it with the pairing code from the appliance console (CSV `handshakecode`) or redeploy it fresh. |
| Console: proxy **Unavailable**, Host Discovery "Failed to update identity service configuration" after a redeploy | The VBR still holds the previous appliance's identity for that name. Rerun the row with `-Replace` (§4b): it captures the job pinning, removes the old object, and pairs the fresh appliance. Without `-Replace` you would remove it by hand and re-pin the jobs by hand. |
| `Replace: managed server ... is still present after the DELETE` | The VBR refused or could not finish the removal (check its session log). Remove the host in the console, then rerun with `-Replace`; the manifest in staging still holds the job pinning. |
| `DNS mismatch: from '<name>' the VBR gets certificate X, from <ip> it gets Y` | The name points at a different machine than the CSV IP, typically a stale record left by the proxy being replaced (seen live 2026-09-28). The script refuses to register that machine and does not retry. Fix the record (`New-ProxyDnsRecords.ps1 -UpdateExisting`) or set `vbrname` to the IP. If you logged in to the appliance by that name, you were on the other machine too. |
| `managedServers` add fails on a fresh appliance | Wait and retry (first-boot config still running); confirm the appliance was never paired before (else `handshakecode`). The log now includes the VBR's own message, e.g. `Invalid TLS key certificate fingerprint` (wrong hash form). |
| Add session runs 15+ minutes, log shows "Appliance OS upgrade is required" | The appliance ISO build is older than the VBR, so the VBR upgrades it during the add and restarts it. Normal; covered by `-RegisterTimeoutSec`. Use the ISO matching the VBR build to avoid it at fleet scale. |
| `Veeam.Backup.PowerShell module not found` | `-RegisterVia Cmdlet` needs the VBR console on a Windows host. Use the REST path. |
| Deploy lands on the wrong datastore | Set `datastore` per row; SDRS cluster names are auto-detected. |
| `Pre-check '<host>': a VM named '<host>' already exists in vCenter` and/or `... already exists in the VBR as a managed server (status ...)` | The name is taken by a leftover (an earlier run, a by-hand VM, a stale VBR object). The row is skipped before anything is built, and nothing is created or removed for it; the other rows carry on. Delete the leftover (or `-Rollback` that row), or redeploy over it with `-Replace`. A `-ValidateOnly` with credential files shows the same list without deploying. |
| `A VM named '<host>' already exists` (from Stage A, without a pre-check line) | Someone created the VM after the run's pre-check. Stage A refuses to overwrite; since 1.3.1 the rollback leaves that VM alone. |
| Deployment server: `Run <id> (...) is still running and handles <names>` | Another state-changing run is working on the same host names or IPs. Wait for it, or cancel it on the page, then start again. Validate and WhatIf runs are never blocked. |
| VM console still shows the **Initial Configuration Wizard / License** page while the run log shows `ready`, `Add accepted` and `Managed server ... present` | Seen live 2026-10-15 on one of four appliances of a parallel run: the answer file had been applied and the VBR paired the appliance; the console page did not refresh. Go by the run log and the VBR. Do **not** press Accept on the console during a run. |
| Duplicate hostname error at load | Hostnames must be unique across the network. |

---

## 9. Status (2026-10-14)

Added on 2026-10-14 (lab, release 1.3.0):

- ✅ Software Appliance rows (`vbr` / `em`): the kickstart and grub patch was checked against the real
  `VeeamSoftwareAppliance_13.1.1.18` ISO (`-ValidateOnly`, real xorriso), and `-WhatIf` passed against
  vCenter (placement, sizing 8/16 and 4/16 + 2 × 240 GB).
- ⏳ Full `vbr` / `em` install: blocked by the lab VPN (L2TP drops under large uploads). Next: run it from
  the deployment server inside the lab.
- ✅ Deployment server rebuilt from this release: Rocky 9.8, service active, key-only SSH, `rsync` installed
  offline.


Added on 2026-09-30 (lab, release 1.2.0):

- ✅ One ISO for all nodes (boot menu, real xorriso repack) and the generic prompt ISO: Secure Boot boot,
  per-node identity, second NIC (static, no default route), settings file applied, registration.
- ✅ Two disks with Veeam's standard layout; Veeam logs on disk 2 via the logs location (`prx-lab-05`).
- ✅ ISO build on Windows (vone, xorriso in WSL) after the `wsl.exe --exec` path fix.
- ⚠️ VBR *Export logs* does not collect a logs location on disk 2; the web UI support bundle does (§4d).
- ✅ DNS search domain (`--ipv4-dns-search`): prompt question and CSV column `dnssearch`; confirmed working
  2026-10-01 with the `prompt-search` ISO (the 2026-09-30 suspicion was wrong).

Added on 2026-09-25 (lab):

- ✅ **Rocky deployment server built unattended** with `Build-DeployServerIso.ps1` + `New-DeployServerVm.ps1`: kickstart install, power-off, ISO detach, boot; `deployment-server` active on first boot with pwsh 7.6, xorriso and PowerCLI from the offline payload. One fix on the way: the NIC-name mismatch (§8), template corrected.
- ✅ **Two failed web-run nodes traced to an unmodified example settings file** (console in the Initial Configuration Wizard). Example values are now refused at upload and before any build; a readiness timeout saves a console screenshot; all rendered secrets and staged ISOs are scrubbed at run end and on cancel.
- ⏳ Re-run those rows with a real settings file (delete the stranded VM first, or `-Rollback`).

Added on 2026-09-28 (lab):

- ✅ **Replace mode proven end to end** (§4b): a proxy the VBR showed as *Unavailable* was captured (pinned in two backup jobs), removed, its VM renamed, a fresh appliance deployed and registered under the same name and IP, and both jobs pinned to the new proxy again; report `ok (replaced; 2 job list(s) re-pinned)`. Observed: the VBR re-used the managed-server id but issued a new proxy id; jobs without a schedule cannot be disabled (handled).
- ✅ DNS safeguards: registration names are resolved and compared with the CSV address before a run; Stage B cross-checks the certificate by name and by IP and refuses a mismatch; an unresolvable name falls back to the IP.
- ✅ Deployment server hardening reviewed live: SSH key-only for `deploy`, firewall SSH-only, no X11, root locked (§1c).

Status as of 2026-09-24:

Resolved:

- ✅ Target = **VIA 13.1** (`1.3-rev2`), unified `/proxy-ks.cfg`, label `VeeamJeOS`, single-disk entry.
- ✅ Accounts / optional MFA / NTP / **role** preseeded through the documented answer file + `veeam-init.service`.
- ✅ Registration = certificate trust, handshake `000000` first time; no known-hosts pre-seed on either path.
- ✅ Settings validated before any build; Secure Boot on; `disk.EnableUUID`; staged ISOs deleted after use.
- ✅ Offline dry run of the real extract + patch via `-ValidateOnly -BaseIso` (tested locally against a synthetic 13.1 layout with a mock xorriso).

Verified in the lab on 2026-09-24 against the real **13.1.1.18 ISO**, vCenter 7.0.3 and a **13.1.1.18 VBR**:

- ✅ One full run (`deploy + register`, ~24 min for one node): unattended single-disk install with Secure Boot, first-boot answer file applied (hostname, iSCSI role visible on the console), certificate-trust registration with SHA-256 fingerprint, proxy role assigned. Run report `deploy=ok register=ok validate=registered`.
- ✅ Same flow on a 13.0.2 ISO with `-MultiDisk -KickstartName vmware-proxy-ks.cfg -ApplianceRole None -GrubDefaultEntry ...` (the VBR upgraded that appliance during the add).
- ✅ REST bodies confirmed from the live `1.3-rev2` OpenAPI spec and by successful POSTs.

Still open:

- ⏳ Independent confirmation that the preseeded veeamadmin password / TOTP are in effect (needs a console sign-in; the console web app returns 200 to any request, so a plain HTTP probe proves nothing).
- ⏳ Cmdlet registration path (`-RegisterVia Cmdlet`) on a Windows host with the VBR console.
- ⏳ Fleet decisions: task slots (8 observed vs 12 default), transport mode (HotAdd + NBD failover observed), fleet split across the 4 VBRs.

---

*Companion to `Deploy-VeeamProxies.ps1`. See `START-HERE.md` for the quick start,
`templates/README.md` for the ISO artifacts, and `Fleet-Planner.html` to build the CSV.*
