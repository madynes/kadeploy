---
name: wheezy-min
version: 1
description: Debian 7.
author: support-staff@lists.grid5000.fr
visibility: public
destructive: false
os: linux
image:
  file: http://kadeploy3.gforge.inria.fr/files/wheezy-x64-min-1.4.tgz
  kind: tar
  compression: gzip
boot:
  kernel: /vmlinuz
  initrd: /initrd.img
filesystem: ext4
partition_type: 131
multipart: false
