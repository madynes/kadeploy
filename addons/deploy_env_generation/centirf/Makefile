all: build get_initrd

build:
	ruby centirf.rb

get_initrd:
	(cd nest ; find | cpio -H newc -o | gzip -9 > ../initrd)

clean:
	find -maxdepth 1 -mindepth 1 ! -iname 'kadeploy_specific' ! -iname 'centirf.rb' ! -iname 'Makefile' -exec rm -rf '{}' \+
