#!/bin/bash -ex

# Build a new CentOS7 install on EBS volume in a chroot
# Run from RHEL7 or CentOS7 instance

DEVICE=/dev/xvdb
ROOTFS=/rootfs
TMPDIR=/tmp

cat | parted ${DEVICE} << END
mktable gpt
mkpart primary ext2 1 2
set 1 bios_grub on
mkpart primary xfs 2 100%
quit


END
mkfs.xfs -L root ${DEVICE}2
mkdir -p $ROOTFS
mount ${DEVICE}2 $ROOTFS

### Basic CentOS Install
rpm --root=$ROOTFS --initdb
rpm --root=$ROOTFS -ivh \
  https://mirror.bytemark.co.uk/centos/7.4.1708/os/x86_64/Packages/centos-release-7-4.1708.el7.centos.x86_64.rpm
# Install necessary packages
yum --installroot=$ROOTFS --nogpgcheck -y groupinstall core
yum --installroot=$ROOTFS --nogpgcheck -y install openssh-server grub2 acpid deltarpm cloud-init cloud-utils-growpart gdisk dracut-config-generic
# Remove unnecessary packages
UNNECESSARY="NetworkManager firewalld linux-firmware ivtv-firmware iwl*firmware"
yum --installroot=$ROOTFS -C -y remove $UNNECESSARY --setopt="clean_requirements_on_remove=1"

# Create homedir for root
cp -a /etc/skel/.bash* ${ROOTFS}/root

## Networking setup
cat > ${ROOTFS}/etc/hosts << END
127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
::1         localhost localhost.localdomain localhost6 localhost6.localdomain6
END
touch ${ROOTFS}/etc/resolv.conf
cat > ${ROOTFS}/etc/sysconfig/network << END
NETWORKING=yes
NOZEROCONF=yes
END
cat > ${ROOTFS}/etc/sysconfig/network-scripts/ifcfg-eth0  << END
DEVICE=eth0
ONBOOT=yes
BOOTPROTO=dhcp
END

cp /usr/share/zoneinfo/UTC ${ROOTFS}/etc/localtime

echo 'ZONE="UTC"' > ${ROOTFS}/etc/sysconfig/clock

# fstab
cat > ${ROOTFS}/etc/fstab << END
LABEL=root /         xfs    defaults,relatime  1 1
tmpfs   /dev/shm  tmpfs   defaults           0 0
devpts  /dev/pts  devpts  gid=5,mode=620     0 0
sysfs   /sys      sysfs   defaults           0 0
proc    /proc     proc    defaults           0 0
END

#grub config taken from /etc/sysconfig/grub on RHEL7 AMI
cat > ${ROOTFS}/etc/default/grub << END
GRUB_TIMEOUT=1
GRUB_DEFAULT=saved
GRUB_DISABLE_SUBMENU=true
GRUB_TERMINAL_OUTPUT="console"
GRUB_CMDLINE_LINUX="crashkernel=auto console=ttyS0,115200n8 console=tty0 net.ifnames=0"
GRUB_DISABLE_RECOVERY="true"
END
echo 'RUN_FIRSTBOOT=NO' > ${ROOTFS}/etc/sysconfig/firstboot

BINDMNTS="dev sys etc/hosts etc/resolv.conf"

for d in $BINDMNTS ; do
  mount --bind /${d} ${ROOTFS}/${d}
done
mount -t proc none ${ROOTFS}/proc
# Install grub2
chroot ${ROOTFS} grub2-mkconfig -o /boot/grub2/grub.cfg
chroot ${ROOTFS} grub2-install $DEVICE

# Startup services
chroot ${ROOTFS} systemctl enable sshd.service
chroot ${ROOTFS} systemctl enable cloud-init.service
chroot ${ROOTFS} systemctl mask tmp.mount

# Configure cloud-init
cat > ${ROOTFS}/etc/cloud/cloud.cfg << END
users:
 - default

disable_root: 1
ssh_pwauth:   0

mount_default_fields: [~, ~, 'auto', 'defaults,nofail', '0', '2']
resize_rootfs_tmp: /dev
ssh_svcname: sshd
ssh_deletekeys:   True
ssh_genkeytypes:  [ 'rsa', 'ecdsa', 'ed25519' ]
syslog_fix_perms: ~

cloud_init_modules:
 - migrator
 - bootcmd
 - write-files
 - growpart
 - resizefs
 - set_hostname
 - update_hostname
 - update_etc_hosts
 - rsyslog
 - users-groups
 - ssh

cloud_config_modules:
 - mounts
 - locale
 - set-passwords
 - yum-add-repo
 - package-update-upgrade-install
 - timezone
 - puppet
 - chef
 - salt-minion
 - mcollective
 - disable-ec2-metadata
 - runcmd

cloud_final_modules:
 - rightscale_userdata
 - scripts-per-once
 - scripts-per-boot
 - scripts-per-instance
 - scripts-user
 - ssh-authkey-fingerprints
 - keys-to-console
 - phone-home
 - final-message

system_info:
  default_user:
    name: ec2-user
    lock_passwd: true
    gecos: Cloud User
    groups: [wheel, adm, systemd-journal]
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    shell: /bin/bash
  distro: rhel
  paths:
    cloud_dir: /var/lib/cloud
    templates_dir: /etc/cloud/templates
  ssh_svcname: sshd

mounts:
 - [ ephemeral0, /media/ephemeral0 ]
 - [ ephemeral1, /media/ephemeral1 ]
 - [ swap, none, swap, sw, "0", "0" ]

datasource_list: [ Ec2, None ]

# vim:syntax=yaml
END

#Disable SELinux
sed -i -e 's/^\(SELINUX=\).*/\1disabled/' ${ROOTFS}/etc/selinux/config
# Clean up
yum --installroot=$ROOTFS clean all
truncate -c -s 0 ${ROOTFS}/var/log/yum.log


# We're done!
for d in $BINDMNTS ; do
  umount ${ROOTFS}/${d}
done
umount ${ROOTFS}/proc
sync
umount ${ROOTFS}

# Snapshot the volume then create the AMI with:
# aws ec2 register-image --name 'CentOS-7.0-test' --description 'Unofficial CentOS7 + cloud-init' --virtualization-type hvm --root-device-name /dev/sda1 --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs": { "SnapshotId": "snap-7f042d5f", "VolumeSize":5,  "DeleteOnTermination": true, "VolumeType": "gp2"}}, { "DeviceName":"/dev/xvdb","VirtualName":"ephemeral0"}, { "DeviceName":"/dev/xvdc","VirtualName":"ephemeral1"}]' --architecture x86_64 --sriov-net-support simple --ena-support

