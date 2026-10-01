# ISO unattended-deploy templates (VIA 13.1)

These files drive Stage A of `Deploy-VeeamProxies.ps1`: per node, the script extracts the real
`/proxy-ks.cfg` and `/EFI/BOOT/grub.cfg` from the pristine 13.1 **Veeam Infrastructure
Appliance** ISO, patches them, and repacks `<hostname>.iso` with **xorriso**. Nothing here is
shipped as-is; everything is rendered or embedded at build time.

The mechanism is Veeam's documented **"Automating Installation with Initial Configuration"**
(Help Center, content for build 13.1.1.18): an answer file `/etc/veeam/vbr_init.cfg` plus a
one-shot `veeam-init.service` that runs `veeamhostmanager --apply_init_config` at first boot.
The docs show it on the Software Appliance ISO (`/vbr-ks.cfg`, label `VeeamSA`); the 13.1 VIA
ISO uses the same host manager with `/proxy-ks.cfg` and label `VeeamJeOS`, and adds the
`applianceRole.*` keys because the 13.1 boot menu no longer selects the role.

## Files

| File                       | Scope    | Rendered by                                  | Purpose                                                                                                                                                                                                                                       |
| -------------------------- | -------- | -------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `vbr_init.cfg.template`  | shared   | `Initialize-IsoWorkspace`, once per run    | Answer file:`veeamadmin` / `veeamso` passwords, optional MFA seeds, SO recovery token, NTP, **appliance role**, control flags. Embedded (comments stripped) into the kickstart `%post`, which writes `/etc/veeam/vbr_init.cfg`. |
| `network-line.template`  | per node | `Get-PatchedApplianceConfigs`, per CSV row | The single`network --bootproto=static ...` line that replaces the VIA's `%pre` DHCP line. Tokens `HOSTNAME IP NETMASK GATEWAY DNS`.                                                                                                     |
| `network-line-nic2.template` | per node | `Get-PatchedApplianceConfigs`, rows with `ip2` | The second `network` line (static, `--nodefroute`, no gateway / DNS) for CSV rows with `ip2` / `netmask2` / `portgroup2`. `DEVICE` is the literal `${VAD_NIC2}`, set by the PCI-order discovery block the build inserts into `%pre`. Tokens `DEVICE IP2 NETMASK2`. |
| `veeam-init.sh.template` | shared   | `Initialize-IsoWorkspace`                  | First-boot script: applies the answer file, disables its unit, optionally shreds the answer file (`CLEANUP_ANSWER_FILE`). Installed to `/etc/veeam/veeam-init.sh`.                                                                        |
| `veeam-init.service`     | shared   | copied                                       | systemd one-shot unit,`WantedBy=multi-user.target`, enabled in `%post`.                                                                                                                                                                   |

Secrets come from `../appliance-secrets.example.conf` (copy to a protected file, pass via
`-ApplianceSecretsFile`). The fleet list is the CSV (build it with `../Fleet-Planner.html`).

## What the build does to the two extracted files

**`/proxy-ks.cfg`**

1. Replace the first `network --bootproto=...` line (lives inside `%pre`) with the rendered
   static line. Rows with `ip2`: insert a discovery block before the `cat <<EOF > /tmp/pre-network.cfg`
   heredoc that lists the VM's network devices in PCI order into `VAD_NIC1` / `VAD_NIC2` (exit 1 when
   the VM has fewer than two), add `--device=${VAD_NIC1}` to the first line and write the rendered
   `network-line-nic2.template` line after it. With `-LogsOnDataDisk`: change `VEEAM_LOG_DIR` and
   `VEEAM_LEGACY_LOG_DIR` in the kickstart from `/var/log/VeeamBackup` to
   `/var/lib/veeam/VeeamBackupLogFolder`, and add to the generated `%post` block: create that folder
   (`root:veeam-grp-log`, `02770`) and write `rootLogDirPath` into `/etc/veeam/veeam_global.conf`
   (the console's "Logs location" setting, applied before first boot).
2. Insert the Initial-Configuration block **inside the appliance's own `%post`**. Anchor search
   order: `log "Veeam post install commands"` (the line the Veeam docs name), then
   `mkdir -p /var/log/veeam/` (the anchor community tooling uses on the 13.x VIA kickstart),
   then before `# post end`. The build fails if none is found inside a `%post`.
   The block: `touch /etc/veeam/host_management_disable_init` (plus the older
   `cockpit_auto_test_disable_init`), write `vbr_init.cfg` (mode 600), write
   `veeam-init.sh` (+x), write `veeam-init.service`, `systemctl enable veeam-init.service`.
   Heredocs use a quoted sentinel so `$` in passwords is never expanded.

**`/EFI/BOOT/grub.cfg`**

1. `set default="Single-Disk Deployment>Install - fresh install, wipes everything on all devices"`
   (or the `Standard (Multi-Disk) Deployment>Install - fresh install, wipes everything (including local backups)` entry with `-MultiDisk`). The build **asserts** both title parts exist in the
   extracted file and lists the titles it found if not.
2. `set timeout=<-GrubTimeout>` (default 5).
3. Append ` inst.assumeyes` to every kernel line referencing `LABEL=VeeamJeOS:/proxy-ks.cfg`.

Repack (in place on a copy of the base ISO, boot setup re-applied):

```
xorriso -dev <hostname>.iso -boot_image any replay \
  -rm /proxy-ks.cfg        -- -map <patched-ks>   /proxy-ks.cfg \
  -rm /EFI/BOOT/grub.cfg   -- -map <patched-grub> /EFI/BOOT/grub.cfg \
  -commit
```

## Dry run without touching infrastructure

```
pwsh -File ../Deploy-VeeamProxies.ps1 -CsvPath <csv> -Vbr <key> -ApplianceSecretsFile <conf> \
     -BaseIso <VeeamInfrastructureAppliance_13.1.x.iso> -ValidateOnly
```

writes the patched `proxy-ks.cfg` + `grub.cfg` for the first row to
`<staging>/_validate_<hostname>/` and reports which anchor and grub default were used. The
kickstart embeds the secrets - delete the folder after review.

## Confirm in the lab (13.1 ISO)

- [ ] `xorriso -indev <iso> -find / -maxdepth 1` shows `/proxy-ks.cfg` (13.0.x had
  `/vmware-proxy-ks.cfg`, `/proxy-ks.cfg`, `/hardened-repo-ks.cfg`).
- [ ] The dry run picks the **documented** anchor. If it falls back, inspect the kickstart and
  confirm the insertion point is inside the chroot `%post` after Veeam's `log()` is defined.
- [ ] grub titles: `Single-Disk Deployment`, `Standard (Multi-Disk) Deployment`, and the two
  `Install - fresh install ...` leaves (the build asserts these).
- [ ] First boot: `/var/log/veeam-init.log` shows `apply_init_config finished`; the HMC (TCP
  10443) accepts the `veeamadmin` password from the secrets file; the role shows as
  Infrastructure Server (with iSCSI/FC/NVMe-oF when `-ApplianceRole InfrastructureServerIscsi`).
- [ ] The repacked ISO boots with **UEFI Secure Boot ON** (Veeam requires Secure Boot for the VIA).
- [ ] `applianceRole.role=vbproxy` / `applianceRole.iSCSI=true` are honoured (they come from the
  13.1 ISO via community tooling, not the public docs).
- [ ] Rows with `ip2`: both adapters come up with their static addresses (`ip -br a`), NIC 1 has the
  only default route (`ip route`), and adapter 1 of the VM is NIC 1 (the installer's PCI-order match).
  A VM with one adapter must stop in `%pre` with the "set up for 2 network adapters" message.
- [ ] `-LogsOnDataDisk`: after registration and the first job, the console's Logs location shows the
  data volume, `/var/lib/veeam/VeeamBackupLogFolder` holds the transport logs and
  `/var/log/VeeamBackup` stays small. ✅ verified 2026-09-30; VBR *Export logs* does not collect it (README §4d).
