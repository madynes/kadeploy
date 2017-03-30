MODULES_DIR:=/usr/share/debirf/modules/
MODULES:=a0_add_extra_repos a0_motd network serial-terminal z1_clean-root a0_prep-root z0_remove-locales
MAKEFILE_PATH:=$(shell pwd)
VERSION:=$(shell cat ${MAKEFILE_PATH}/version)

all: modlinks build copy

modlinks:
	cp -R kadeploy-deploy-kernel /tmp
	@$(foreach module,$(MODULES), ln -sf $(MODULES_DIR)$(module) /tmp/kadeploy-deploy-kernel/modules;)

build:
	debirf make -r /tmp/kadeploy-deploy-kernel

clean:
	(cd /tmp/kadeploy-deploy-kernel ; find -maxdepth 1 -mindepth 1 ! -iname 'kadeploy_specific' ! -iname 'modules' ! -iname 'debirf.conf' -exec rm -rf '{}' \+)

copy:
	mv /tmp/kadeploy-deploy-kernel/debirf-kadeploy-deploy-kernel_wheezy_3.2.0-4-amd64.cgz /vagrant/kernel/deploy-wheezy-initrd-$(VERSION)-g5k
	mv /tmp/kadeploy-deploy-kernel/vmlinuz-3.2.0-4-amd64 /vagrant/kernel/deploy-wheezy-vmlinuz-$(VERSION)-g5k
