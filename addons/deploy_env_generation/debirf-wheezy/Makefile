MODULES_DIR:=/usr/share/debirf/modules/
MODULES:=a0_add_extra_repos a0_motd install-kernel network serial-terminal z1_clean-root a0_prep-root z0_remove-locales

all: modlinks build

modlinks:
	@$(foreach module,$(MODULES), ln -sf $(MODULES_DIR)$(module) kadeploy-deploy-kernel/modules;)

build:
	debirf make -r kadeploy-deploy-kernel

clean:
	(cd kadeploy-deploy-kernel ; find -maxdepth 1 -mindepth 1 ! -iname 'kadeploy_specific' ! -iname 'modules' ! -iname 'debirf.conf' -exec rm -rf '{}' \+)
