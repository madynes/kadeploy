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
VERSION=$(MAJOR_VERSION).$(MINOR_VERSION)$(RELEASE_VERSION)
DEPLOY_USER=deploy
DEB_ROOT_CLIENT=kadeploy-client
DEB_ROOT_SERVER=kadeploy-server
DEB_ROOT_COMMON=kadeploy-common
SRC=$(KADEPLOY_ROOT)/src
BIN=$(KADEPLOY_ROOT)/bin
SBIN=$(KADEPLOY_ROOT)/sbin
CONF=$(KADEPLOY_ROOT)/conf
ADDONS=$(KADEPLOY_ROOT)/addons
DB=$(KADEPLOY_ROOT)/db
TEST=$(KADEPLOY_ROOT)/test
MAN=$(KADEPLOY_ROOT)/man

SUFFIX = ""
ifeq ($(DEV),)
else
SUFFIX = "-dev"
endif


default: package_all

install_src:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 644 $(SRC)/*.rb $(DEB_ROOT_COMMON)$(SUFFIX)/usr/local/kadeploy3$(SUFFIX)/src
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 644 $(SRC)/lib/*.rb $(DEB_ROOT_COMMON)$(SUFFIX)/usr/local/kadeploy3$(SUFFIX)/src/lib
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 644 $(SRC)/contrib/*.rb $(DEB_ROOT_COMMON)$(SUFFIX)/usr/local/kadeploy3$(SUFFIX)/src/contrib

install_conf_client:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 644 $(CONF)/client_conf.yml $(DEB_ROOT_CLIENT)$(SUFFIX)/etc/kadeploy3$(SUFFIX)/client_conf.yml

install_conf_server:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 640 $(CONF)/server_conf.yml $(DEB_ROOT_SERVER)$(SUFFIX)/etc/kadeploy3$(SUFFIX)
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 640 $(CONF)/clusters.yml $(DEB_ROOT_SERVER)$(SUFFIX)/etc/kadeploy3$(SUFFIX)
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 640 $(CONF)/cluster_conf*.yml $(DEB_ROOT_SERVER)$(SUFFIX)/etc/kadeploy3$(SUFFIX)
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 640 $(CONF)/cmd.yml $(DEB_ROOT_SERVER)$(SUFFIX)/etc/kadeploy3$(SUFFIX)
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 640 $(CONF)/cluster_partition-* $(DEB_ROOT_SERVER)$(SUFFIX)/etc/kadeploy3$(SUFFIX)

install_conf_common:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 755 $(CONF)/load_kadeploy_env $(DEB_ROOT_COMMON)$(SUFFIX)/etc/kadeploy3$(SUFFIX)/load_kadeploy_env
	@sed "s/\/kadeploy3/\/kadeploy3$(SUFFIX)/g" -i $(DEB_ROOT_COMMON)$(SUFFIX)/etc/kadeploy3$(SUFFIX)/load_kadeploy_env

install_bin:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 755 $(BIN)/kaconsole3 $(DEB_ROOT_CLIENT)$(SUFFIX)/usr/bin/kaconsole3$(SUFFIX)
	@sed "s/\/etc\/kadeploy3/\/etc\/kadeploy3$(SUFFIX)/g" -i $(DEB_ROOT_CLIENT)$(SUFFIX)/usr/bin/kaconsole3$(SUFFIX)
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 755 $(BIN)/kadeploy3 $(DEB_ROOT_CLIENT)$(SUFFIX)/usr/bin/kadeploy3$(SUFFIX)
	@sed "s/\/etc\/kadeploy3/\/etc\/kadeploy3$(SUFFIX)/g" -i $(DEB_ROOT_CLIENT)$(SUFFIX)/usr/bin/kadeploy3$(SUFFIX)
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 755 $(BIN)/kaenv3 $(DEB_ROOT_CLIENT)$(SUFFIX)/usr/bin/kaenv3$(SUFFIX)
	@sed "s/\/etc\/kadeploy3/\/etc\/kadeploy3$(SUFFIX)/g" -i $(DEB_ROOT_CLIENT)$(SUFFIX)/usr/bin/kaenv3$(SUFFIX)
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 755 $(BIN)/kanodes3 $(DEB_ROOT_CLIENT)$(SUFFIX)/usr/bin/kanodes3$(SUFFIX)
	@sed "s/\/etc\/kadeploy3/\/etc\/kadeploy3$(SUFFIX)/g" -i $(DEB_ROOT_CLIENT)$(SUFFIX)/usr/bin/kanodes3$(SUFFIX)
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 755 $(BIN)/kapower3 $(DEB_ROOT_CLIENT)$(SUFFIX)/usr/bin/kapower3$(SUFFIX)
	@sed "s/\/etc\/kadeploy3/\/etc\/kadeploy3$(SUFFIX)/g" -i $(DEB_ROOT_CLIENT)$(SUFFIX)/usr/bin/kapower3$(SUFFIX)
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 755 $(BIN)/kareboot3 $(DEB_ROOT_CLIENT)$(SUFFIX)/usr/bin/kareboot3$(SUFFIX)
	@sed "s/\/etc\/kadeploy3/\/etc\/kadeploy3$(SUFFIX)/g" -i $(DEB_ROOT_CLIENT)$(SUFFIX)/usr/bin/kareboot3$(SUFFIX)
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 755 $(BIN)/kastat3 $(DEB_ROOT_CLIENT)$(SUFFIX)/usr/bin/kastat3$(SUFFIX)
	@sed "s/\/etc\/kadeploy3/\/etc\/kadeploy3$(SUFFIX)/g" -i $(DEB_ROOT_CLIENT)$(SUFFIX)/usr/bin/kastat3$(SUFFIX)

install_sbin_server:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 750 $(SBIN)/kadeploy3d $(DEB_ROOT_SERVER)$(SUFFIX)/usr/sbin/kadeploy3d$(SUFFIX)
	@sed "s/\/etc\/kadeploy3/\/etc\/kadeploy3$(SUFFIX)/g" -i $(DEB_ROOT_SERVER)$(SUFFIX)/usr/sbin/kadeploy3d$(SUFFIX)

install_sbin_client:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 750 $(SBIN)/karights3 $(DEB_ROOT_CLIENT)$(SUFFIX)/usr/sbin/karights3$(SUFFIX)
	@sed "s/\/etc\/kadeploy3/\/etc\/kadeploy3$(SUFFIX)/g" -i $(DEB_ROOT_CLIENT)$(SUFFIX)/usr/sbin/karights3$(SUFFIX)

install_kastafior:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 755 $(ADDONS)/kastafior/kastafior $(DEB_ROOT_SERVER)$(SUFFIX)/usr/bin/kastafior$(SUFFIX)

install_test:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 755 $(TEST)/blackbox_tests.rb $(DEB_ROOT_COMMON)$(SUFFIX)/usr/local/kadeploy3$(SUFFIX)/test
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 644 $(TEST)/automata.txt $(DEB_ROOT_COMMON)$(SUFFIX)/usr/local/kadeploy3$(SUFFIX)/test

install_rc_script:
	@install -m 755 $(ADDONS)/rc/debian/kadeploy3d $(DEB_ROOT_SERVER)$(SUFFIX)/etc/init.d/kadeploy3d$(SUFFIX)
ifeq (${DEV},)
else
	@sed "s/NAME=kadeploy3d/NAME=kadeploy3d$(SUFFIX)/" -i $(DEB_ROOT_SERVER)$(SUFFIX)/etc/init.d/kadeploy3d$(SUFFIX)
endif

install_db_script:
	@install -m 644 $(DB)/db_creation.sql $(DEB_ROOT_COMMON)$(SUFFIX)/usr/local/kadeploy3$(SUFFIX)/db

install_ssh_key:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 400 $(ADDONS)/ssh/id_deploy $(DEB_ROOT_SERVER)$(SUFFIX)/etc/kadeploy3$(SUFFIX)/keys
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 400 $(ADDONS)/ssh/id_deploy.pub $(DEB_ROOT_SERVER)$(SUFFIX)/etc/kadeploy3$(SUFFIX)/keys

install_version:
	@echo $(VERSION) > $(DEB_ROOT_SERVER)$(SUFFIX)/etc/kadeploy3$(SUFFIX)/version
	@chown $(DEPLOY_USER):$(DEPLOY_USER) $(DEB_ROOT_SERVER)$(SUFFIX)/etc/kadeploy3$(SUFFIX)/version

install_man:
ifeq (${DEV},)
	@(cd $(MAN); sh generate.sh $(PWD)/$(DEB_ROOT_COMMON)$(SUFFIX)/usr/local/man)
endif

tree_client:
	@mkdir -p $(DEB_ROOT_CLIENT)$(SUFFIX)/usr/bin
	@mkdir -p $(DEB_ROOT_CLIENT)$(SUFFIX)/usr/sbin
	@mkdir -p $(DEB_ROOT_CLIENT)$(SUFFIX)/etc/kadeploy3$(SUFFIX)

tree_server:
	@mkdir -p $(DEB_ROOT_SERVER)$(SUFFIX)/usr/bin
	@mkdir -p $(DEB_ROOT_SERVER)$(SUFFIX)/usr/sbin
	@mkdir -p $(DEB_ROOT_SERVER)$(SUFFIX)/etc/init.d
	@mkdir -p $(DEB_ROOT_SERVER)$(SUFFIX)/etc/kadeploy3$(SUFFIX)
	@mkdir -p $(DEB_ROOT_SERVER)$(SUFFIX)/etc/kadeploy3$(SUFFIX)/keys

tree_common:
	@mkdir -p $(DEB_ROOT_COMMON)$(SUFFIX)/usr/local/kadeploy3$(SUFFIX)
	@mkdir -p $(DEB_ROOT_COMMON)$(SUFFIX)/usr/local/kadeploy3$(SUFFIX)/src
	@mkdir -p $(DEB_ROOT_COMMON)$(SUFFIX)/usr/local/kadeploy3$(SUFFIX)/src/lib
	@mkdir -p $(DEB_ROOT_COMMON)$(SUFFIX)/usr/local/kadeploy3$(SUFFIX)/db
	@mkdir -p $(DEB_ROOT_COMMON)$(SUFFIX)/usr/local/kadeploy3$(SUFFIX)/test
	@mkdir -p $(DEB_ROOT_COMMON)$(SUFFIX)/usr/local/kadeploy3$(SUFFIX)/src/contrib
	@mkdir -p $(DEB_ROOT_COMMON)$(SUFFIX)/etc/kadeploy3$(SUFFIX)
ifeq (${DEV},)
	@mkdir -p $(DEB_ROOT_COMMON)$(SUFFIX)/usr/local/man
endif

package_client: tree_client install_conf_client install_bin install_sbin_client
ifeq (${DEV},)
else
	@cp -r ${DEB_ROOT_CLIENT}/* ${DEB_ROOT_CLIENT}$(SUFFIX)
	@cp ${DEB_ROOT_CLIENT}$(SUFFIX)/DEBIAN/conffiles-dev ${DEB_ROOT_CLIENT}$(SUFFIX)/DEBIAN/conffiles
	@cp ${DEB_ROOT_CLIENT}$(SUFFIX)/DEBIAN/preinst-dev ${DEB_ROOT_CLIENT}$(SUFFIX)/DEBIAN/preinst
endif
	@sh set_control.sh kadeploy-client-control.in kadeploy-client $(SUFFIX) > $(DEB_ROOT_CLIENT)$(SUFFIX)/DEBIAN/control
	@dpkg-deb --build $(DEB_ROOT_CLIENT)$(SUFFIX) kadeploy-client$(SUFFIX)-$(VERSION).deb

package_server: tree_server install_conf_server install_rc_script install_ssh_key install_sbin_server install_kastafior install_version
ifeq (${DEV},)
else
	@cp -r ${DEB_ROOT_SERVER}/* ${DEB_ROOT_SERVER}$(SUFFIX)
	@cp ${DEB_ROOT_SERVER}$(SUFFIX)/DEBIAN/conffiles-dev ${DEB_ROOT_SERVER}$(SUFFIX)/DEBIAN/conffiles
	@cp ${DEB_ROOT_SERVER}$(SUFFIX)/DEBIAN/preinst-dev ${DEB_ROOT_SERVER}$(SUFFIX)/DEBIAN/preinst
	@cp ${DEB_ROOT_SERVER}$(SUFFIX)/DEBIAN/postinst-dev ${DEB_ROOT_SERVER}$(SUFFIX)/DEBIAN/postinst
	@cp ${DEB_ROOT_SERVER}$(SUFFIX)/DEBIAN/prerm-dev ${DEB_ROOT_SERVER}$(SUFFIX)/DEBIAN/prerm
endif
	@sh set_control.sh kadeploy-server-control.in kadeploy-server $(SUFFIX) > $(DEB_ROOT_SERVER)$(SUFFIX)/DEBIAN/control
	@dpkg-deb --build $(DEB_ROOT_SERVER)$(SUFFIX) kadeploy-server$(SUFFIX)-$(VERSION).deb	


package_common: tree_common install_conf_common install_src install_test install_db_script install_man
ifeq (${DEV},)
else
	@cp -r ${DEB_ROOT_COMMON}/* ${DEB_ROOT_COMMON}$(SUFFIX)
endif
	@sh set_control.sh kadeploy-common-control.in kadeploy-common $(SUFFIX) > $(DEB_ROOT_COMMON)$(SUFFIX)/DEBIAN/control
	@dpkg-deb --build $(DEB_ROOT_COMMON)$(SUFFIX) kadeploy-common$(SUFFIX)-$(VERSION).deb

package_all: package_client package_server package_common

clean:
ifeq (${DEV},)
	@rm -rf $(DEB_ROOT_CLIENT)/usr $(DEB_ROOT_CLIENT)/etc $(DEB_ROOT_CLIENT)/DEBIAN/control
	@rm -rf $(DEB_ROOT_SERVER)/usr $(DEB_ROOT_SERVER)/etc $(DEB_ROOT_SERVER)/DEBIAN/control
	@rm -rf $(DEB_ROOT_COMMON)/usr $(DEB_ROOT_COMMON)/etc $(DEB_ROOT_COMMON)/DEBIAN/control
else
	@rm -rf $(DEB_ROOT_CLIENT)$(SUFFIX)
	@rm -rf $(DEB_ROOT_SERVER)$(SUFFIX)
	@rm -rf $(DEB_ROOT_COMMON)$(SUFFIX)
endif
	@rm -f kadeploy-client-$(VERSION).deb kadeploy-server-$(VERSION).deb kadeploy-common-$(VERSION).deb

