#!/bin/bash -ex

# Build a new CentOS7 install on EBS volume in a chroot
# Run from RHEL7 or CentOS7 instance

DEVICE=/dev/xvdb
ROOTFS=/rootfs
IXGBEVF_VER=3.3.2
ENA_VER=1.0.0
ENA_COMMIT=b594ac1
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
  http://mirror.bytemark.co.uk/centos/7.3.1611/os/x86_64/Packages/centos-release-7-3.1611.el7.centos.x86_64.rpm
# Install necessary packages
yum --installroot=$ROOTFS --nogpgcheck -y groupinstall core
yum --installroot=$ROOTFS --nogpgcheck -y install openssh-server grub2 acpid tuned kernel deltarpm epel-release
yum --installroot=$ROOTFS -C -y remove NetworkManager --setopt="clean_requirements_on_remove=1"

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
# Install cloud-init from epel
chroot ${ROOTFS} yum --nogpgcheck -y install cloud-init cloud-utils-growpart gdisk
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

# Add additional AWS drivers
KVER=$(chroot $ROOTFS rpm -q kernel | sed -e 's/^kernel-//')
# Enable sr-iov
yum --installroot=$ROOTFS --nogpgcheck -y install dkms make
curl -L http://sourceforge.net/projects/e1000/files/ixgbevf%20stable/${IXGBEVF_VER}/ixgbevf-${IXGBEVF_VER}.tar.gz/download > /tmp/ixgbevf.tar.gz
tar zxf /tmp/ixgbevf.tar.gz -C ${ROOTFS}/usr/src
cat > ${ROOTFS}/usr/src/ixgbevf-${IXGBEVF_VER}/dkms.conf << END
PACKAGE_NAME="ixgbevf"
PACKAGE_VERSION="${IXGBEVF_VER}"
CLEAN="cd src/; make clean"
MAKE="cd src/; make BUILD_KERNEL=\${kernelver}"
BUILT_MODULE_LOCATION[0]="src/"
BUILT_MODULE_NAME[0]="ixgbevf"
DEST_MODULE_LOCATION[0]="/updates"
DEST_MODULE_NAME[0]="ixgbevf"
AUTOINSTALL="yes"
END
chroot $ROOTFS dkms add -m ixgbevf -v ${IXGBEVF_VER}
chroot $ROOTFS dkms build -m ixgbevf -v ${IXGBEVF_VER} -k $KVER
chroot $ROOTFS dkms install -m ixgbevf -v ${IXGBEVF_VER} -k $KVER
echo "options ixgbevf InterruptThrottleRate=1,1,1,1,1,1,1,1" > ${ROOTFS}/etc/modprobe.d/ixgbevf.conf
# Enable Amazon ENA
# Create an archive file locally from git first
yum -y install git
mkdir -p ${TMPDIR}/ena
git clone https://github.com/amzn/amzn-drivers.git ${TMPDIR}/ena
cd ${TMPDIR}/ena
git archive --prefix ena-${ENA_VER}/ ${ENA_COMMIT} | tar xC ${ROOTFS}/usr/src
cat > ${ROOTFS}/usr/src/ena-${ENA_VER}/dkms.conf << END
PACKAGE_NAME="ena"
PACKAGE_VERSION="${ENA_VER}"
CLEAN="make -C kernel/linux/ena clean"
MAKE="make -C kernel/linux/ena/ BUILD_KERNEL=\${kernelver}"
BUILT_MODULE_NAME[0]="ena"
BUILT_MODULE_LOCATION="kernel/linux/ena"
DEST_MODULE_LOCATION[0]="/updates"
DEST_MODULE_NAME[0]="ena"
AUTOINSTALL="yes"
END
chroot $ROOTFS dkms add -m ena -v ${ENA_VER}
chroot $ROOTFS dkms dkms build -m ena -v ${ENA_VER} -k ${KVER}
chroot $ROOTFS dkms install -m ena -v ${ENA_VER} -k ${KVER}

#Disable SELinux
sed -i -e 's/^\(SELINUX=\).*/\1disabled/' ${ROOTFS}/etc/selinux/config

# Remove EPEL
yum --installroot=$ROOTFS -C -y remove epel-release --setopt="clean_requirements_on_remove=1"

# We're done!
for d in $BINDMNTS ; do
  umount ${ROOTFS}/${d}
done
umount ${ROOTFS}/proc
sync
umount ${ROOTFS}

# Snapshot the volume then create the AMI with:
# aws ec2 register-image --name 'CentOS-7.0-test' --description 'Unofficial CentOS7 + cloud-init' --virtualization-type hvm --root-device-name /dev/sda1 --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs": { "SnapshotId": "snap-7f042d5f", "VolumeSize":5,  "DeleteOnTermination": true, "VolumeType": "gp2"}}, { "DeviceName":"/dev/xvdb","VirtualName":"ephemeral0"}, { "DeviceName":"/dev/xvdc","VirtualName":"ephemeral1"}]' --architecture x86_64 --sriov-net-support simple --ena-support

