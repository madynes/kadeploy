MODULES_DIR:=/usr/share/debirf/modules/
MODULES:=a0_motd install-kernel network serial-terminal z1_clean-root a0_prep-root z0_remove-locales

all: modlinks build gen_initrd

modlinks:
	@$(foreach module,$(MODULES), ln -sf $(MODULES_DIR)$(module) kadeploy-deploy-kernel/modules;)

build:
	debirf make kadeploy-deploy-kernel

gen_initrd:
	(cd kadeploy-deploy-kernel/nest ; find | cpio -H newc -o | gzip -9 > ../initrd)

clean:
	(cd kadeploy-deploy-kernel ; find -maxdepth 1 -mindepth 1 ! -iname 'kadeploy_specific' ! -iname 'modules' ! -iname 'debirf.conf' -exec rm -rf '{}' \+)
test:
