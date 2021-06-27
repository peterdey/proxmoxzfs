#!/bin/bash
set -e
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;31m'
NC='\033[0m' # No Color

#ln -s /proc/self/mounts /etc/mtab
sed -i 's/127.0.0.1/1.1.1.1/' /etc/resolv.conf
echo 'deb http://download.proxmox.com/debian/pve buster pve-no-subscription' > /etc/apt/sources.list.d/pve-no-subscription.list
rm -f /etc/apt/sources.list.d/pve-enterprise.list

echo 'deb http://au.archive.ubuntu.com/ubuntu bionic main' >> /etc/apt/sources.list
echo 'deb http://au.archive.ubuntu.com/ubuntu bionic-security main' >> /etc/apt/sources.list

cat >> /etc/apt/preferences << EOF
Package: *
Pin: release n=bionic
Pin-Priority: 400

Package: grub-*
Pin: release n=bionic
Pin-Priority: 1100

Package: grub2-*
Pin: release n=bionic
Pin-Priority: 1100
EOF

cat >> /etc/apt/apt.conf.d/90norecommends  <<EOF
Aptitude::Recommends-Important "false";
APT::Install-Recommends "false";
APT::Install-Suggests "false";
EOF

apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 3B4FE6ACC0B21F32
apt-get update

echo -e "${GREEN}Setting timezone...${NC}"
ln --force --symbolic '/usr/share/zoneinfo/Australia/Canberra' '/etc/localtime'
echo "Australia/Canberra" > /etc/timezone
dpkg-reconfigure -f noninteractive tzdata

echo -e "${GREEN}Setting locale...${NC}"
locale-gen --purge en_AU.UTF-8
echo -e 'LANG="en_AU.UTF-8"\nLANGUAGE="en_AU:en"\n' > /etc/default/locale
sed -i -e 's/# en_AU.UTF-8 UTF-8/en_AU.UTF-8 UTF-8/' /etc/locale.gen
echo 'LANG="en_AU.UTF-8"' > /etc/default/locale
dpkg-reconfigure --frontend=noninteractive locales
update-locale LANG=en_AU.UTF-8

#echo -e "${GREEN}Installing kernel image & zfs utils...${NC}"
#apt install --yes --no-install-recommends nano openssh-server linux-image-generic zfs-initramfs
#apt install --yes --no-install-recommends nano openssh-server #linux-image-generic zfs-initramfs
echo -e "${GREEN}Installing grub-efi...${NC}"
#DEBIAN_FRONTEND=noninteractive apt --yes -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install grub-pc
mkdir /boot/efi
DISK=${DISKS% *}
echo PARTUUID=$(blkid -s PARTUUID -o value $DISK-part1) /boot/efi vfat nofail,x-systemd.device-timeout=1 0 1 > /etc/fstab
mount /boot/efi

sed -i 's/GRUB_HIDDEN_TIMEOUT=0/#GRUB_HIDDEN_TIMEOUT=0/' /etc/default/grub 
sed -i 's/GRUB_TIMEOUT=5/GRUB_TIMEOUT=3\nGRUB_RECORDFAIL_TIMEOUT=3/' /etc/default/grub 
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/GRUB_CMDLINE_LINUX_DEFAULT=""/' /etc/default/grub 
sed -i 's/#GRUB_TERMINAL=console/GRUB_TERMINAL=console/' /etc/default/grub 
perl -i -pe 's/(GRUB_CMDLINE_LINUX=")/${1}root=ZFS=rpool /' /etc/default/grub
echo 'GRUB_DISABLE_OS_PROBER=true' >> /etc/default/grub

update-initramfs -c -k all

update-grub
grub-install
#grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck --no-floppy

## For OVMF/QEMU - only boots from /EFI/BOOT/BOOTx64.EFI.  shim-signed does this automagically.
#mkdir /boot/efi/EFI/BOOT
#cp /boot/efi/EFI/proxmox/grubx64.efi /boot/efi/EFI/BOOT/BOOTx64.EFI

echo -e "${GREEN}Installing Ubuntu's grub-efi-amd64-signed...${NC}"
#apt-get remove --yes grub-pc grub-pc-bin grub-common grub2-common grub-efi-amd64-bin grub-efi-ia32-bin
#apt-get install --yes grub-efi-amd64-signed shim-signed
apt-get remove --yes grub-pc grub-pc-bin
DEBIAN_FRONTEND=noninteractive apt-get --target-release=bionic --yes --allow-downgrades --option Dpkg::Options::="--force-confold" --force-yes install shim-signed grub-efi-amd64-signed grub-common grub2-common

# Ubuntu version of GRUB looks for its config in /EFI/ubuntu/grub.cfg - Add a redirector config here.
mkdir /boot/efi/EFI/ubuntu
cp /boot/efi/EFI/proxmox/grub.cfg /boot/efi/EFI/ubuntu/grub.cfg

echo -e "${GREEN}Configuring ZFS services & mountpoints...${NC}"
cat > /etc/systemd/system/zfs-import-bpool.service <<UNIT
[Unit]
DefaultDependencies=no
Before=zfs-import-scan.service
Before=zfs-import-cache.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/zpool import -N -o cachefile=none bpool

[Install]
WantedBy=zfs-import.target
UNIT

systemctl enable zfs-import-bpool.service

# Configure ZFS mountpoints
zfs set mountpoint=legacy bpool
echo "bpool /boot zfs nodev,relatime,x-systemd.requires=zfs-import-bpool.service 0 0" >> /etc/fstab

zfs set mountpoint=legacy rpool/var/log
cat >> /etc/fstab <<EOF
rpool/var/log /var/log zfs defaults 0 0
EOF

# Configure the swap volume
echo /dev/zvol/rpool/swap none swap discard 0 0 >> /etc/fstab

# Disable suspend/resume from/to disk
echo RESUME=none > /etc/initramfs-tools/conf.d/resume


echo -e "${GREEN}Initializing Proxmox database...${NC}"
mkdir /tmp/pve;

# write vnc keymap to datacenter.cfg
cat >> /tmp/pve/datacenter.cfg <<EOF
keyboard: en-us
EOF

# save admin email
cat >> /tmp/pve/user.cfg <<EOF
user:root@pam:1:0:::${MAILTO}::
EOF

# write storage.cfg
cat >> /tmp/pve/storage.cfg <<__EOD__
dir: local
	path /var/lib/vz
	content iso,vztmpl,backup

zfspool: local-zfs
	pool rpool/data
	sparse
	content images,rootdir
__EOD__


/usr/bin/create_pmxcfs_db /tmp/pve /var/lib/pve-cluster/config.db
rm -rf /tmp/pve

echo -e "${GREEN}Removing the Proxmox subscription nag...${NC}"
# Remove the Proxmox "no subscription" warning
sed -Ezi.bak "s/(Ext.Msg.show\(\{\s+title: gettext\('No valid sub)/void\(\{ \/\/\1/g" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js

echo -e "${GREEN}Done! ${NC}"
exit 0