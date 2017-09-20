# CentOS 7 AMI

This is the shell script used to build the Bashton CentOS 7 AMIs we have
made publicly available.  To use, start a RHEL7 or CentOS 7 instance,
attach a blank EBS volume at /dev/xvdb and the script will do the rest.

If you just want to run the images, or modify using
[Packer](http://packer.io/), you can find AMI ids at
https://www.bashton.com/blog/2017/centos-7.3-ami/

## Differences from official CentOS marketplace AMI

- Uses gpt partitioning - supports root volumes over 2TB
- Local ephemeral storage mounted at `/media/ephemeral0`
- Default user account `ec2-user`

