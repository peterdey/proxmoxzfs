# Proxmox VE with Encrypted ZFS Root

Bash script that deploys Proxmox VE 6.1 with:
- ZFS RAID1
- Native ZFS-encrypted root
- Ubuntu's signed GRUB EFI bootloader

## Prerequisites
- GPT disks.  This won't work for MBR disks.
- EFI Boot.  This won't work for old-school BIOSs.

This script tries to follow Proxmox's [proxinstall](https://github.com/proxmox/pve-installer/blob/master/proxinstall) installer's steps as closely as possible.

## Usage
1. Boot the Proxmox VE 6.1 ISO and select **"Install Proxmox VE (Debug mode)"** (second option in the bootloader menu)
2. Hit CTRL+D to the first prompt
3. At the second prompt ("Dropping ion debug shell before starting installation"):
   ```
   # dhclient
   # busybox wget https://git.io/proxmoxzfs.sh
   ```
4. Edit the variables at the top of the script (e.g. with `nano`).  Make sure to use `/dev/disk/by-id` paths for your disks (use ls -l `/dev/disk/by-id/` to find them)
5. Run the script:
   ```
   # bash proxmoxzfs.sh
   ```

## Some differences from the Proxmox installer - and some problems
- Since we're using GRUB, we need a ZFS bpool with only the [ZFS features that GRUB supports][1]
- There's no error handling.  If something unexpected happens, you're dumped back into the shell to figure it out.
- You'll need to enter the unlock passphrase at the console on bootup.  I haven't bothered adding dropbear-sshd for remote unlock.

## Why GRUB?  Why not systemd-boot?
Proxmox doesn't [offer signed kernels or bootloaders][2] ("yet").  If you want SecureBoot, you've got two options: sign your own bootloader (and maybe kernel), or use Ubuntu's signed Grub + Shim.

[1]: https://forum.proxmox.com/threads/how-to-enable-secure-boot-on-pve-6.55831/#post-257104
[2]: https://saveriomiroddi.github.io/Installing-Ubuntu-on-a-ZFS-root-with-encryption-and-mirroring/#grub