all: build gen_initrd

build:
	debirf make kadeploy-deploy-kernel

gen_initrd:
	(cd kadeploy-deploy-kernel/nest ; find | cpio -H newc -o | gzip -9 > ../initrd)

clean:
	(cd kadeploy-deploy-kernel ; find -maxdepth 1 -mindepth 1 ! -iname 'kadeploy_specific' ! -iname 'modules' ! -iname 'debirf.conf' -exec rm -rf '{}' \+)
