KADEPLOY_ROOT=../..
MAJOR_VERSION:=$(shell cat ../../major_version)
MINOR_VERSION:=$(shell cat ../../minor_version)
VERSION=$(MAJOR_VERSION)-$(MINOR_VERSION)
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

default: package_all

install_src:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 644 $(SRC)/*.rb $(DEB_ROOT_COMMON)/usr/local/kadeploy3/src
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 644 $(SRC)/lib/*.rb $(DEB_ROOT_COMMON)/usr/local/kadeploy3/src/lib
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 644 $(SRC)/contrib/*.rb $(DEB_ROOT_COMMON)/usr/local/kadeploy3/src/contrib

install_conf_client:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 644 $(CONF)/client_conf $(DEB_ROOT_CLIENT)/etc/kadeploy3

install_conf_server:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 600 $(CONF)/conf $(DEB_ROOT_SERVER)/etc/kadeploy3
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 600 $(CONF)/clusters $(DEB_ROOT_SERVER)/etc/kadeploy3
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 600 $(CONF)/specific_conf* $(DEB_ROOT_SERVER)/etc/kadeploy3
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 600 $(CONF)/nodes $(DEB_ROOT_SERVER)/etc/kadeploy3
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 600 $(CONF)/cmd $(DEB_ROOT_SERVER)/etc/kadeploy3
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 600 $(CONF)/partition_file_* $(DEB_ROOT_SERVER)/etc/kadeploy3

install_conf_common:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 755 $(CONF)/load_kadeploy_env $(DEB_ROOT_COMMON)/etc/kadeploy3

install_bin:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 755 $(BIN)/* $(DEB_ROOT_CLIENT)/usr/bin

install_sbin:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 750 $(SBIN)/* $(DEB_ROOT_SERVER)/usr/sbin

install_kastafior:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 755 $(ADDONS)/kastafior/kastafior $(DEB_ROOT_SERVER)/usr/bin

install_test:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 755 $(TEST)/blackbox_tests.rb $(DEB_ROOT_COMMON)/usr/local/kadeploy3/test

install_rc_script:
	@install -m 755 $(ADDONS)/rc/debian/kadeploy3d $(DEB_ROOT_SERVER)/etc/init.d

install_db_script:
	@install -m 644 $(DB)/db_creation.sql $(DEB_ROOT_COMMON)/usr/local/kadeploy3/db

install_ssh_key:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 400 $(ADDONS)/ssh/id_deploy $(DEB_ROOT_SERVER)/etc/kadeploy3/keys
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 400 $(ADDONS)/ssh/id_deploy.pub $(DEB_ROOT_SERVER)/etc/kadeploy3/keys

install_version:
	@echo $(VERSION) > $(DEB_ROOT_SERVER)/etc/kadeploy3/version
	@chown $(DEPLOY_USER):$(DEPLOY_USER) $(DEB_ROOT_SERVER)/etc/kadeploy3/version

tree_client:
	@mkdir -p $(DEB_ROOT_CLIENT)/usr/bin
	@mkdir -p $(DEB_ROOT_CLIENT)/etc/kadeploy3

tree_server:
	@mkdir -p $(DEB_ROOT_SERVER)/usr/bin
	@mkdir -p $(DEB_ROOT_SERVER)/usr/sbin
	@mkdir -p $(DEB_ROOT_SERVER)/etc/init.d
	@mkdir -p $(DEB_ROOT_SERVER)/etc/kadeploy3
	@mkdir -p $(DEB_ROOT_SERVER)/etc/kadeploy3/keys

tree_common:
	@mkdir -p $(DEB_ROOT_COMMON)/usr/local/kadeploy3
	@mkdir -p $(DEB_ROOT_COMMON)/usr/local/kadeploy3/src
	@mkdir -p $(DEB_ROOT_COMMON)/usr/local/kadeploy3/src/lib
	@mkdir -p $(DEB_ROOT_COMMON)/usr/local/kadeploy3/db
	@mkdir -p $(DEB_ROOT_COMMON)/usr/local/kadeploy3/test
	@mkdir -p $(DEB_ROOT_COMMON)/usr/local/kadeploy3/src/contrib
	@mkdir -p $(DEB_ROOT_COMMON)/etc/kadeploy3

package_client: tree_client install_conf_client install_bin
	@sh set_version.sh kadeploy-client-control.in > $(DEB_ROOT_CLIENT)/DEBIAN/control
	@dpkg-deb --build $(DEB_ROOT_CLIENT) kadeploy-client-$(VERSION).deb
package_server: tree_server install_conf_server install_rc_script install_ssh_key install_sbin install_kastafior install_version
	@sh set_version.sh kadeploy-server-control.in > $(DEB_ROOT_SERVER)/DEBIAN/control
	@dpkg-deb --build $(DEB_ROOT_SERVER) kadeploy-server-$(VERSION).deb	
package_common: tree_common install_conf_common install_src install_test install_db_script
	@sh set_version.sh kadeploy-common-control.in > $(DEB_ROOT_COMMON)/DEBIAN/control
	@dpkg-deb --build $(DEB_ROOT_COMMON) kadeploy-common-$(VERSION).deb

package_all: package_client package_server package_common

clean:
	@rm -rf $(DEB_ROOT_CLIENT)/usr $(DEB_ROOT_CLIENT)/etc $(DEB_ROOT_CLIENT)/DEBIAN/control
	@rm -rf $(DEB_ROOT_SERVER)/usr $(DEB_ROOT_SERVER)/etc $(DEB_ROOT_SERVER)/DEBIAN/control
	@rm -rf $(DEB_ROOT_COMMON)/usr $(DEB_ROOT_COMMON)/etc $(DEB_ROOT_COMMON)/DEBIAN/control
	@rm -f kadeploy-client-$(VERSION).deb kadeploy-server-$(VERSION).deb kadeploy-common-$(VERSION).deb
