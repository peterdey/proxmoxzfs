#!/bin/bash
set -e

###### EDIT THESE VARIABLES ######
DISKS="/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0 /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1"
PASSWORD="12345678"
MAILTO=mail@example.invalid
############ OPTIONAL ############
INITCONFIG=https://raw.githubusercontent.com/peterdey/proxmoxzfs/main/initconfig.sh
##################################

# Log everything.
TIMESTAMP=`date +'%Y%m%d'`
LOGFILE=/tmp/deployzfs.log.${TIMESTAMP}
exec 3>&2
exec > >(tee -a ${LOGFILE}) 2> >(tee -a ${LOGFILE} >&3)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;31m'
NC='\033[0m' # No Color

modprobe zfs

for DISK in $DISKS
do
    if [ ! -b "$DISK" ]
    then
        echo -e "${RED}Target disk $DISK not found!${NC}"
        exit 99
    fi
done

if [ "$(zpool status |grep bpool |wc -l)" -gt "0" ]
then
    echo -e "${YELLOW}Active bpool found.  Exporting.${NC}"
    zpool export bpool
fi

if [ "$(zpool status |grep rpool |wc -l)" -gt "0" ]
then
    echo -e "${YELLOW}Active rpool found.  Exporting.${NC}"
    zpool export rpool
fi

echo -e "${YELLOW}Clearing partition table...${NC}"
# from https://saveriomiroddi.github.io/Installing-Ubuntu-on-a-ZFS-root-with-encryption-and-mirroring/#procedure
for DISK in $DISKS
do
    sgdisk --zap-all $DISK
    sgdisk -n1:1M:+512M   -t1:EF00 $DISK # EFI boot
    sgdisk -n2:0:+512M    -t2:BF01 $DISK # Boot pool
    sgdisk -n3:0:0        -t3:BF01 $DISK # Root pool
    BPOOL="${BPOOL} ${DISK}-part2"
    RPOOL="${RPOOL} ${DISK}-part3"
done

sync
#partprobe $DISK
service udev restart
#systemctl daemon-reload
sleep 3
udevadm trigger
udevadm settle --timeout 10

while [ ! -b ${DISK}-part2 ]
do
  sleep 1
done
ls -l ${DISK}

echo -e "${YELLOW}Creating bpool...${NC}"
zpool create -f -o ashift=12 -d \
    -o feature@async_destroy=enabled \
    -o feature@bookmarks=enabled \
    -o feature@embedded_data=enabled \
    -o feature@empty_bpobj=enabled \
    -o feature@enabled_txg=enabled \
    -o feature@extensible_dataset=enabled \
    -o feature@filesystem_limits=enabled \
    -o feature@hole_birth=enabled \
    -o feature@large_blocks=enabled \
    -o feature@lz4_compress=enabled \
    -o feature@spacemap_histogram=enabled \
    -o feature@userobj_accounting=enabled \
    -O acltype=posixacl -O canmount=off -O compression=lz4 -O devices=off \
    -O normalization=formD -O relatime=on -O xattr=sa \
    -O mountpoint=/ -R /target bpool mirror $BPOOL

echo -e "${YELLOW}Creating rpool...${NC}"
# Mostly from https://github.com/zfsonlinux/zfs/wiki/Ubuntu-18.04-Root-on-ZFS
echo $PASSWORD | \
zpool create -f -o ashift=12 \
    -O acltype=posixacl -O canmount=off -O compression=lz4 \
    -O dnodesize=auto -O normalization=formD -O relatime=on -O xattr=sa \
    -O encryption=on -O keylocation=prompt -O keyformat=passphrase \
    -O mountpoint=/ -R /target rpool mirror $RPOOL

echo -e "${YELLOW}Making Swap zvol...${NC}"
zfs create -V 4G -b $(getconf PAGESIZE) -o compression=zle \
    -o logbias=throughput -o sync=always \
    -o primarycache=metadata -o secondarycache=none \
    -o com.sun:auto-snapshot=false rpool/swap
mkswap -f /dev/zvol/rpool/swap

echo -e "${YELLOW}Setting up rpool...${NC}"
zfs create -o canmount=off -o mountpoint=none rpool/ROOT
zfs create -o mountpoint=/ rpool/ROOT/pve-1
#zfs mount rpool/ROOT/ubuntu

zfs create -o setuid=off                                rpool/home
zfs create -o mountpoint=/root                          rpool/home/root
zfs create                                              rpool/var
zfs create -o com.sun:auto-snapshot=false  -o atime=off rpool/var/cache
zfs create                                 -o atime=off rpool/var/log
zfs create -o mountpoint=none                           rpool/data
mkdir /target/var/lib
zfs create -o mountpoint=/var/lib/vz                    rpool/vz

mkdir /target/tmp /target/var/tmp
chmod 1777 /tmp /target/var/tmp
mkdir /target/mnt

echo -e "${YELLOW}EFI Boot partition...${NC}"
for DISK in $DISKS
do
    mkfs.fat -F 32 -n EFI ${DISK}-part1
done

echo -e "${YELLOW}Setting up bpool...${NC}"
zfs create -o canmount=off -o mountpoint=none bpool/BOOT
zfs create -o mountpoint=/boot bpool/BOOT/proxmox
#zfs mount bpool/BOOT/ubuntu


echo -e "${GREEN}Unpacking base system...${NC}"
unsquashfs -f -dest /target /cdrom/pve-base.squashfs

echo -e "${GREEN}Copying packages...${NC}"
mkdir /target/tmp/packages
cp /cdrom/proxmox/packages/*.deb /target/tmp/packages/

# In outer system
mount --bind /dev  /target/dev
mount --bind /proc /target/proc
mount --bind /sys  /target/sys
#mount -n -t tmpfs tmpfs /target/tmp
mount -n -t efivarfs efivarfs /target/sys/firmware/efi/efivars

echo -e "${GREEN}Configuring network...${NC}"
# Ideally we'd do this in the chroot *after* the packages are extracted... But proxmox and postfix demand some network config (yes, even to extract the packages...)

INTERFACE=`ip route ls default |awk '{print $5}'`
IPADDR=`ip -4 addr ls $INTERFACE | grep -Po 'inet \K[\d.]+'`
IPCIDR=`ip -4 addr ls $INTERFACE | grep -Po 'inet \K[\d./]+'`
GATEWAY=`ip -4 route ls default |grep -Po 'default via \K[\d.]+'`
SUFFIX=`grep domain /etc/resolv.conf |awk '{print $2}'`

cat > /target/etc/hosts <<EOF
127.0.0.1 localhost.localdomain localhost
${IPADDR} pve.${SUFFIX} pve

# The following lines are desirable for IPv6 capable hosts

::1     ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
ff02::3 ip6-allhosts
EOF

echo pve > /target/etc/hostname
chroot /target /bin/hostname pve

cat > /target/etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto vmbr0
iface vmbr0 inet dhcp
    address ${IPCIDR}
    gateway ${GATEWAY}
    bridge_ports ${INTERFACE}
    bridge_stp off
    bridge_fd 0

EOF

cp /etc/resolv.conf /target/etc/resolv.conf

chroot /target ifup lo

echo -e "${GREEN}Extracting packages...${NC}"
cp /var/lib/pve-installer/policy-disable-rc.d /target/usr/sbin/policy-rc.d
cp /var/lib/pve-installer/fake-start-stop-daemon /target/sbin/
chroot /target dpkg-divert --package proxmox --add --rename /sbin/start-stop-daemon
chroot /target ln -sf /sbin/fake-start-stop-daemon /sbin/start-stop-daemon

cat > /target/tmp/debconf.txt <<_EOD
locales                 locales/default_environment_locale      select en_US.UTF-8
locales                 locales/locales_to_be_generated         select en_US.UTF-8 UTF-8
samba-common            samba-common/dhcp                       boolean false
samba-common            samba-common/workgroup                  string WORKGROUP
postfix                 postfix/mailname                        string pve.${SUFFIX}
postfix                 postfix/main_mailer_type                select 'No configuration'
keyboard-configuration  keyboard-configuration/xkb-keymap       select us
keyboard-configuration  keyboard-configuration/variant          select 'English (US)'
console-setup           console-setup/charmap47                 select UTF-8
console-setup           console-setup/codeset47                 select Lat15
d-i                     debian-installer/locale                 select en_US.UTF-8
grub-pc                 grub-pc/install_devices                 select $DISK
_EOD

chroot /target debconf-set-selections /tmp/debconf.txt
chroot /target sh -c 'DEBIAN_FRONTEND=noninteractive dpkg  --force-depends --no-triggers --unpack /tmp/packages/*.deb'

echo -e "${GREEN}Configuring packages...${NC}"
chroot /target debconf-set-selections /tmp/debconf.txt
#DEBIAN_FRONTEND=noninteractive 
chroot /target sh -c 'dpkg  --force-confold --configure -a'

cat > /target/etc/postfix/main.cf <<_EOD
# See /usr/share/postfix/main.cf.dist for a commented, more complete version

myhostname=__FQDN__

smtpd_banner = \$myhostname ESMTP \$mail_name (Debian/GNU)
biff = no

# appending .domain is the MUA's job.
append_dot_mydomain = no

# Uncomment the next line to generate "delayed mail" warnings
#delay_warning_time = 4h

alias_maps = hash:/etc/aliases
alias_database = hash:/etc/aliases
mydestination = \$myhostname, localhost.\$mydomain, localhost
relayhost =
mynetworks = 127.0.0.0/8
inet_interfaces = loopback-only
recipient_delimiter = +

compatibility_level = 2

_EOD

echo -e "${GREEN}Configuring new system...${NC}"
zfs set devices=off rpool

mv /target/sbin/start-stop-daemon.distrib /target/sbin/start-stop-daemon
chroot /target dpkg-divert --remove /sbin/start-stop-daemon

echo "root:${PASSWORD}" |chroot /target /usr/sbin/chpasswd

rm -f /target/initconfig.sh
if [ "${INITCONFIG%:*}" = "https" ]
then
    busybox wget -qO /target/initconfig.sh "${INITCONFIG}"
else
    cp "$INITCONFIG" /target/initconfig.sh
fi
chmod a+x /target/initconfig.sh

LANG=en_AU.UTF-8 DISKS="$DISKS" MAILTO="$MAILTO" chroot /target /initconfig.sh
echo -e "${RED}Exit code: $? ${NC}"

echo -e "${GREEN}Unmounting filesystems...${NC}"
umount /target/boot/efi
zpool export bpool
umount /target/sys/firmware/efi/efivars
umount /target/proc /target/sys /target/dev
zpool export rpool

echo -e "${GREEN}Not starting Proxmox installer...${NC}"
echo exit > /.xinitrc

exit 0