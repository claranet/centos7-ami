# CentOS 7 AMI

This is the shell script used to build the Bashton CentOS 7 AMIs we have
made publicly available.  To use, start a RHEL7 or CentOS 7 instance,
attach a blank EBS volume at /dev/xvdb and the script will do the rest.

If you just want to run the images, or modify using
[Packer](http://packer.io/), you can find AMI ids at
https://www.bashton.com/blog/2017/centos-7.3-ami/

## Differences from official CentOS marketplace AMI

- Uses gpt partitioning - supports root volumes over 2TB
- Includes [out of tree ixgbevf
  driver](http://sourceforge.net/projects/e1000/files/ixgbevf%20stable/3.2.2/)
  providing [enhanced
networking](http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/enhanced-networking.html)
- Includes [Elastic Network
  Adapter](https://aws.amazon.com/blogs/aws/elastic-network-adapter-high-performance-network-interface-for-amazon-ec2/)
support
- Local ephemeral storage mounted at `/media/ephemeral0`
- Default user account `ec2-user`

