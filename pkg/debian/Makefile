KADEPLOY_ROOT=../..
MAJOR_VERSION:=$(shell cat ../../major_version)
MINOR_VERSION:=$(shell cat ../../minor_version)
RELEASE_VERSION:=$(shell cat ../../release_version)
ifeq ($(strip $(RELEASE_VERSION)),stable)
	RELEASE_VERSION:=
else
	ifeq ($(strip $(RELEASE_VERSION)),git)
		RELEASE_VERSION:=~git$(shell git log --pretty=format:'%H' -n 1)
	else
		ifeq ($(findstring rc,$(strip $(RELEASE_VERSION))),rc)
			RELEASE_VERSION:=$(addprefix ~,$(RELEASE_VERSION))
		else
			RELEASE_VERSION:=$(addprefix .,$(RELEASE_VERSION))
		endif
	endif
endif
PWD:=$(shell pwd)
ifndef BUILD_DIR
BUILD_DIR=$(PWD)/build
endif
VERSION=$(MAJOR_VERSION).$(MINOR_VERSION)$(RELEASE_VERSION)
DEPLOY_USER=deploy
DEB_TEMPLATE_CLIENT=kadeploy-client
DEB_TEMPLATE_SERVER=kadeploy-server
DEB_TEMPLATE_COMMON=kadeploy-common
SRC=$(KADEPLOY_ROOT)/lib
BIN=$(KADEPLOY_ROOT)/bin
SBIN=$(KADEPLOY_ROOT)/sbin
CONF=$(KADEPLOY_ROOT)/conf
ADDONS=$(KADEPLOY_ROOT)/addons
DB=$(KADEPLOY_ROOT)/db
TEST=$(KADEPLOY_ROOT)/test
MAN=$(KADEPLOY_ROOT)/man
SCRIPTS=$(KADEPLOY_ROOT)/scripts
LIBS_PATH=\/usr\/local\/kadeploy3
SED_LIBS=/KADEPLOY3_LIBS/ s/$(LIBS_PATH)/$(LIBS_PATH)$(SUFFIX)/g
CONFIGS_PATH=\/etc\/kadeploy3
SED_CONFIGS=/KADEPLOY3_CONFIG_DIR/ s/$(CONFIGS_PATH)/$(CONFIGS_PATH)$(SUFFIX)/g

SUFFIX = ""
ifdef DEV
SUFFIX = "-dev"
endif
DEB_ROOT_CLIENT=$(BUILD_DIR)/kadeploy-client$(SUFFIX)
DEB_ROOT_SERVER=$(BUILD_DIR)/kadeploy-server$(SUFFIX)
DEB_ROOT_COMMON=$(BUILD_DIR)/kadeploy-common$(SUFFIX)

ifndef PKG_DIR
PKG_DIR=.
endif


default: package_all

build:
	@mkdir -p $(BUILD_DIR)

build-clean:
	@rm -rf $(BUILD_DIR)

install_log:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 640 /dev/null $(DEB_ROOT_SERVER)/var/log/kadeploy3$(SUFFIX)/output.log
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 640 /dev/null $(DEB_ROOT_SERVER)/var/log/kadeploy3$(SUFFIX)/error.log
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 640 /dev/null $(DEB_ROOT_SERVER)/var/log/kadeploy3$(SUFFIX)/httpd.log
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 640 /dev/null $(DEB_ROOT_SERVER)/var/log/kadeploy3$(SUFFIX)/access.log
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 640 /dev/null $(DEB_ROOT_SERVER)/var/log/kadeploy3$(SUFFIX)/kadeploy.log
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 640 /dev/null $(DEB_ROOT_SERVER)/var/log/kadeploy3$(SUFFIX)/kadeploy.debug
install_src:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 644 $(SRC)/kadeploy3/*.rb $(DEB_ROOT_COMMON)/usr/local/kadeploy3$(SUFFIX)/lib/kadeploy3/
	@sed "$(SED_CONFIGS)" -i $(DEB_ROOT_COMMON)/usr/local/kadeploy3$(SUFFIX)/lib/kadeploy3/*.rb

install_conf_client:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 644 $(CONF)/client_conf.yml $(DEB_ROOT_CLIENT)/etc/kadeploy3$(SUFFIX)/client_conf.yml

install_conf_server:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 640 $(CONF)/server_conf.yml $(DEB_ROOT_SERVER)/etc/kadeploy3$(SUFFIX)
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 640 $(CONF)/clusters.yml $(DEB_ROOT_SERVER)/etc/kadeploy3$(SUFFIX)
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 640 $(CONF)/cluster_conf*.yml $(DEB_ROOT_SERVER)/etc/kadeploy3$(SUFFIX)
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 640 $(CONF)/cmd.yml $(DEB_ROOT_SERVER)/etc/kadeploy3$(SUFFIX)
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 640 $(SCRIPTS)/bootloader/install_grub $(DEB_ROOT_SERVER)/etc/kadeploy3$(SUFFIX)
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 640 $(SCRIPTS)/bootloader/install_grub2 $(DEB_ROOT_SERVER)/etc/kadeploy3$(SUFFIX)
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 640 $(SCRIPTS)/partitioning/parted-sample $(DEB_ROOT_SERVER)/etc/kadeploy3$(SUFFIX)
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 640 $(SCRIPTS)/partitioning/fdisk-sample $(DEB_ROOT_SERVER)/etc/kadeploy3$(SUFFIX)

install_bin:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 755 $(BIN)/kaconsole3 $(DEB_ROOT_CLIENT)/usr/bin/kaconsole3$(SUFFIX)
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 755 $(BIN)/kadeploy3 $(DEB_ROOT_CLIENT)/usr/bin/kadeploy3$(SUFFIX)
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 755 $(BIN)/kaenv3 $(DEB_ROOT_CLIENT)/usr/bin/kaenv3$(SUFFIX)
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 755 $(BIN)/kanodes3 $(DEB_ROOT_CLIENT)/usr/bin/kanodes3$(SUFFIX)
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 755 $(BIN)/kapower3 $(DEB_ROOT_CLIENT)/usr/bin/kapower3$(SUFFIX)
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 755 $(BIN)/kareboot3 $(DEB_ROOT_CLIENT)/usr/bin/kareboot3$(SUFFIX)
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 755 $(BIN)/kastat3 $(DEB_ROOT_CLIENT)/usr/bin/kastat3$(SUFFIX)
	@sed "$(SED_LIBS)" $(DEB_ROOT_CLIENT)/usr/bin/ka* -i

install_sbin_server:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 750 $(SBIN)/kadeploy3d $(DEB_ROOT_SERVER)/usr/sbin/kadeploy3d$(SUFFIX)
	@sed "$(SED_LIBS)" $(DEB_ROOT_SERVER)/usr/sbin/ka* -i

install_sbin_client:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 750 $(SBIN)/karights3 $(DEB_ROOT_CLIENT)/usr/sbin/karights3$(SUFFIX)
	@sed "$(SED_LIBS)" $(DEB_ROOT_CLIENT)/usr/sbin/ka* -i

install_kastafior:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 755 $(ADDONS)/kastafior/kastafior $(DEB_ROOT_SERVER)/usr/bin/kastafior$(SUFFIX)

install_test:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 755 $(TEST)/blackbox_tests.rb $(DEB_ROOT_COMMON)/usr/local/kadeploy3$(SUFFIX)/test
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 644 $(TEST)/automata.txt $(DEB_ROOT_COMMON)/usr/local/kadeploy3$(SUFFIX)/test

install_rc_script:
	@install -m 755 $(ADDONS)/rc/debian/kadeploy3d $(DEB_ROOT_SERVER)/etc/init.d/kadeploy3d$(SUFFIX)
ifdef DEV
	@sed "s/NAME=kadeploy3d/NAME=kadeploy3d$(SUFFIX)/" -i $(DEB_ROOT_SERVER)/etc/init.d/kadeploy3d$(SUFFIX)
endif

install_db_script:
	@install -m 644 $(DB)/db_creation.sql $(DEB_ROOT_COMMON)/usr/local/kadeploy3$(SUFFIX)/db

install_ssh_key:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 400 $(ADDONS)/ssh/id_deploy $(DEB_ROOT_SERVER)/etc/kadeploy3$(SUFFIX)/keys
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 400 $(ADDONS)/ssh/id_deploy.pub $(DEB_ROOT_SERVER)/etc/kadeploy3$(SUFFIX)/keys

install_version:
	@echo $(VERSION) > $(DEB_ROOT_SERVER)/etc/kadeploy3$(SUFFIX)/version
	@chown $(DEPLOY_USER):$(DEPLOY_USER) $(DEB_ROOT_SERVER)/etc/kadeploy3$(SUFFIX)/version

install_man:
ifndef DEV
	@(cd $(MAN); sh generate.sh $(DEB_ROOT_COMMON)/usr/local/man)
endif

install_scripts:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 644 $(SCRIPTS)/bootloader/install_grub $(DEB_ROOT_SERVER)/usr/local/kadeploy3$(SUFFIX)/scripts/bootloader
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 644 $(SCRIPTS)/bootloader/install_grub2 $(DEB_ROOT_SERVER)/usr/local/kadeploy3$(SUFFIX)/scripts/bootloader
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 644 $(SCRIPTS)/partitioning/parted-sample $(DEB_ROOT_SERVER)/usr/local/kadeploy3$(SUFFIX)/scripts/partitioning
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 644 $(SCRIPTS)/partitioning/fdisk-sample $(DEB_ROOT_SERVER)/usr/local/kadeploy3$(SUFFIX)/scripts/partitioning

tree_client:
	@mkdir -p $(DEB_ROOT_CLIENT)/usr/bin
	@mkdir -p $(DEB_ROOT_CLIENT)/usr/sbin
	@mkdir -p $(DEB_ROOT_CLIENT)/etc/kadeploy3$(SUFFIX)

tree_server:
	@mkdir -p $(DEB_ROOT_SERVER)/usr/bin
	@mkdir -p $(DEB_ROOT_SERVER)/usr/sbin
	@mkdir -p $(DEB_ROOT_SERVER)/etc/init.d
	@mkdir -p $(DEB_ROOT_SERVER)/etc/kadeploy3$(SUFFIX)
	@mkdir -p $(DEB_ROOT_SERVER)/etc/kadeploy3$(SUFFIX)/keys
	@mkdir -p $(DEB_ROOT_SERVER)/usr/local/kadeploy3$(SUFFIX)/scripts
	@mkdir -p $(DEB_ROOT_SERVER)/usr/local/kadeploy3$(SUFFIX)/scripts/bootloader
	@mkdir -p $(DEB_ROOT_SERVER)/usr/local/kadeploy3$(SUFFIX)/scripts/partitioning
	@mkdir -p $(DEB_ROOT_SERVER)/var/log/kadeploy3$(SUFFIX)

tree_common:
	@mkdir -p $(DEB_ROOT_COMMON)/usr/local/kadeploy3$(SUFFIX)
	@mkdir -p $(DEB_ROOT_COMMON)/usr/local/kadeploy3$(SUFFIX)/lib
	@mkdir -p $(DEB_ROOT_COMMON)/usr/local/kadeploy3$(SUFFIX)/lib/kadeploy3
	@mkdir -p $(DEB_ROOT_COMMON)/usr/local/kadeploy3$(SUFFIX)/db
	@mkdir -p $(DEB_ROOT_COMMON)/usr/local/kadeploy3$(SUFFIX)/test
	#@mkdir -p $(DEB_ROOT_COMMON)/usr/local/kadeploy3$(SUFFIX)/src/contrib
	@mkdir -p $(DEB_ROOT_COMMON)/etc/kadeploy3$(SUFFIX)
ifndef DEV
	@mkdir -p $(DEB_ROOT_COMMON)/usr/local/man
endif

package_client: build-clean build tree_client install_conf_client install_bin install_sbin_client
	@mkdir -p $(DEB_ROOT_CLIENT)
	@cp -r $(DEB_TEMPLATE_CLIENT)/* $(DEB_ROOT_CLIENT)
ifdef DEV
	@echo DEV_CLIENT
	@cp $(DEB_TEMPLATE_CLIENT)/DEBIAN/conffiles-dev $(DEB_ROOT_CLIENT)/DEBIAN/conffiles
	@cp $(DEB_TEMPLATE_CLIENT)/DEBIAN/preinst-dev $(DEB_ROOT_CLIENT)/DEBIAN/preinst
endif
	@sh set_control.sh kadeploy-client-control.in kadeploy-client $(SUFFIX) > $(DEB_ROOT_CLIENT)/DEBIAN/control
	@dpkg-deb --build $(DEB_ROOT_CLIENT) $(PKG_DIR)/kadeploy-client$(SUFFIX)-$(VERSION).deb
	@$(MAKE) build-clean

package_server: build-clean build tree_server install_log install_conf_server install_rc_script install_ssh_key install_sbin_server install_kastafior install_version install_scripts
	@mkdir -p $(DEB_ROOT_SERVER)
	@cp -r $(DEB_TEMPLATE_SERVER)/* $(DEB_ROOT_SERVER)
ifdef DEV
	@cp $(DEB_TEMPLATE_SERVER)/DEBIAN/conffiles-dev $(DEB_ROOT_SERVER)/DEBIAN/conffiles
	@cp $(DEB_TEMPLATE_SERVER)/DEBIAN/preinst-dev $(DEB_ROOT_SERVER)/DEBIAN/preinst
	@cp $(DEB_TEMPLATE_SERVER)/DEBIAN/postinst-dev $(DEB_ROOT_SERVER)/DEBIAN/postinst
	@cp $(DEB_TEMPLATE_SERVER)/DEBIAN/prerm-dev $(DEB_ROOT_SERVER)/DEBIAN/prerm
endif
	@sh set_control.sh kadeploy-server-control.in kadeploy-server $(SUFFIX) > $(DEB_ROOT_SERVER)/DEBIAN/control
	@dpkg-deb --build $(DEB_ROOT_SERVER) $(PKG_DIR)/kadeploy-server$(SUFFIX)-$(VERSION).deb
	@$(MAKE) build-clean


package_common: build-clean build tree_common install_src install_test install_db_script install_man
	#@mkdir -p $(DEB_ROOT_COMMON)
	#@cp -rf $(DEB_TEMPLATE_COMMON)/* $(DEB_ROOT_COMMON)
	@mkdir -p $(DEB_ROOT_COMMON)/DEBIAN
	@sh set_control.sh kadeploy-common-control.in kadeploy-common $(SUFFIX) > $(DEB_ROOT_COMMON)/DEBIAN/control
	@dpkg-deb --build $(DEB_ROOT_COMMON) $(PKG_DIR)/kadeploy-common$(SUFFIX)-$(VERSION).deb
	@$(MAKE) build-clean

package_all: build-clean build package_client package_server package_common
	@$(MAKE) build-clean

clean:
	@rm -rf $(BUILD_DIR)
	@rm -rf $(DEB_ROOT_CLIENT)
	@rm -rf $(DEB_ROOT_SERVER)
	@rm -rf $(DEB_ROOT_COMMON)
	@rm -f $(PKG_DIR)/kadeploy-client-$(VERSION).deb
	@rm -f $(PKG_DIR)/kadeploy-server-$(VERSION).deb
	@rm -f $(PKG_DIR)/kadeploy-common-$(VERSION).deb
	@rm -f $(PKG_DIR)/kadeploy-client-dev-$(VERSION).deb
	@rm -f $(PKG_DIR)/kadeploy-server-dev-$(VERSION).deb
	@rm -f $(PKG_DIR)/kadeploy-common-dev-$(VERSION).deb

