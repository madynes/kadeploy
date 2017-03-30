# Grid5000 deployment kernel generation

## Create the vagrant virtual machine

    $ vagrant up
    $ vagrant ssh

## Gerenate kernel

    $ sudo su -
    $ cd /vagrant/debirf-wheezy
    $ make all

Kernel files will be available into `kernel` directory, ready to copy on kadeploy servers into `/var/lib/tftpboot/kernels`

## Release a new version

Edit the file `debirf-wheezy/version` before generation.
Commit changes and :

    $ git add debirf-wheezy/version
    $ git commit -m "Release debirf-wheezy 1.0.1"
    $ git tags debirf-wheezy-1.0.1
    $ git push
    $ git push tags


