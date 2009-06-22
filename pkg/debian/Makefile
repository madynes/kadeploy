KADEPLOY_ROOT=..
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
	@install -o $(DEPLOY_USER) -m 644 $(SRC)/*.rb $(DEB_ROOT_COMMON)/usr/local/kadeploy3/src
	@install -o $(DEPLOY_USER) -m 644 $(SRC)/lib/*.rb $(DEB_ROOT_COMMON)/usr/local/kadeploy3/src/lib
	@install -o $(DEPLOY_USER) -m 644 $(SRC)/contrib/*.rb $(DEB_ROOT_COMMON)/usr/local/kadeploy3/src/contrib

install_conf_client:
	@install -o $(DEPLOY_USER) -m 644 $(CONF)/client_conf $(DEB_ROOT_CLIENT)/etc/kadeploy3

install_conf_server:
	@install -o $(DEPLOY_USER) -m 600 $(CONF)/conf $(DEB_ROOT_SERVER)/etc/kadeploy3
	@install -o $(DEPLOY_USER) -m 600 $(CONF)/specific_conf* $(DEB_ROOT_SERVER)/etc/kadeploy3
	@install -o $(DEPLOY_USER) -m 600 $(CONF)/nodes $(DEB_ROOT_SERVER)/etc/kadeploy3
	@install -o $(DEPLOY_USER) -m 600 $(CONF)/cmd $(DEB_ROOT_SERVER)/etc/kadeploy3
	@install -o $(DEPLOY_USER) -m 600 $(CONF)/fdisk* $(DEB_ROOT_SERVER)/etc/kadeploy3

install_conf_common:
	@install -o $(DEPLOY_USER) -m 755 $(CONF)/load_kadeploy_env $(DEB_ROOT_COMMON)/etc/kadeploy3

install_bin:
	@install -o $(DEPLOY_USER) -m 755 $(BIN)/* $(DEB_ROOT_CLIENT)/usr/bin

install_sbin:
	@install -o $(DEPLOY_USER) -m 700 $(SBIN)/* $(DEB_ROOT_SERVER)/usr/sbin

install_kastafior:
	@install -o $(DEPLOY_USER) -m 755 $(ADDONS)/kastafior/kastafior $(DEB_ROOT_SERVER)/usr/bin

install_debootstrap:
	@install -o $(DEPLOY_USER) -m 700 $(ADDONS)/deploy_env_generation/debootstrap/linuxrc $(DEB_ROOT_COMMON)/usr/local/kadeploy3/addons/deploy_env_generation/debootstrap
	@install -o $(DEPLOY_USER) -m 700 $(ADDONS)/deploy_env_generation/debootstrap/mkdev $(DEB_ROOT_COMMON)/usr/local/kadeploy3/addons/deploy_env_generation/debootstrap
	@install -o $(DEPLOY_USER) -m 700 $(ADDONS)/deploy_env_generation/debootstrap/make_debootstrap.sh $(DEB_ROOT_COMMON)/usr/local/kadeploy3/addons/deploy_env_generation/debootstrap
	@install -o $(DEPLOY_USER) -m 700 $(ADDONS)/deploy_env_generation/debootstrap/make_kernel.sh $(DEB_ROOT_COMMON)/usr/local/kadeploy3/addons/deploy_env_generation/debootstrap
	@install -o $(DEPLOY_USER) -m 700 $(ADDONS)/deploy_env_generation/debootstrap/scripts/* $(DEB_ROOT_COMMON)/usr/local/kadeploy3/addons/deploy_env_generation/debootstrap/scripts

install_test:
	@install -o $(DEPLOY_USER) -m 644 $(TEST)/envfile.dsc $(DEB_ROOT_COMMON)/usr/local/kadeploy3/test
	@install -o $(DEPLOY_USER) -m 700 $(TEST)/blackbox_tests.rb $(DEB_ROOT_COMMON)/usr/local/kadeploy3/test

install_rc_script:
	@install -m 755 $(ADDONS)/rc/kadeploy_server $(DEB_ROOT_SERVER)/etc/init.d

install_db_script:
	@install -m 644 $(DB)/db_creation.sql $(DEB_ROOT_COMMON)/usr/local/kadeploy3/db

install_ssh_key:
	@install -o $(DEPLOY_USER) -m 400 $(ADDONS)/ssh/id_deploy $(DEB_ROOT_SERVER)/.keys

tree_client:
	@mkdir -p $(DEB_ROOT_CLIENT)/usr/bin
	@mkdir -p $(DEB_ROOT_CLIENT)/etc/kadeploy3

tree_server:
	@mkdir -p $(DEB_ROOT_SERVER)/usr/bin
	@mkdir -p $(DEB_ROOT_SERVER)/usr/sbin
	@mkdir -p $(DEB_ROOT_SERVER)/etc/init.d
	@mkdir -p $(DEB_ROOT_SERVER)/.keys
	@mkdir -p $(DEB_ROOT_SERVER)/etc/kadeploy3

tree_common:
	@mkdir -p $(DEB_ROOT_COMMON)/usr/local/kadeploy3
	@mkdir -p $(DEB_ROOT_COMMON)/usr/local/kadeploy3/src
	@mkdir -p $(DEB_ROOT_COMMON)/usr/local/kadeploy3/src/lib
	@mkdir -p $(DEB_ROOT_COMMON)/usr/local/kadeploy3/addons
	@mkdir -p $(DEB_ROOT_COMMON)/usr/local/kadeploy3/addons/deploy_env_generation
	@mkdir -p $(DEB_ROOT_COMMON)/usr/local/kadeploy3/addons/deploy_env_generation/debootstrap
	@mkdir -p $(DEB_ROOT_COMMON)/usr/local/kadeploy3/addons/deploy_env_generation/debootstrap/scripts
	@mkdir -p $(DEB_ROOT_COMMON)/usr/local/kadeploy3/addons/deploy_env_generation/debootstrap/ssh
	@mkdir -p $(DEB_ROOT_COMMON)/usr/local/kadeploy3/db
	@mkdir -p $(DEB_ROOT_COMMON)/usr/local/kadeploy3/test
	@mkdir -p $(DEB_ROOT_COMMON)/usr/local/kadeploy3/src/contrib
	@mkdir -p $(DEB_ROOT_COMMON)/etc/kadeploy3

package_client: tree_client install_conf_client install_bin
	@dpkg-deb --build $(DEB_ROOT_CLIENT) kadeploy-v3-client.deb
package_server: tree_server install_conf_server install_rc_script install_ssh_key install_sbin install_kastafior
	@dpkg-deb --build $(DEB_ROOT_SERVER) kadeploy-v3-server.deb	
package_common: tree_common install_conf_common install_src install_debootstrap install_test install_db_script
	@dpkg-deb --build $(DEB_ROOT_COMMON) kadeploy-v3-common.deb

package_all: package_client package_server package_common

clean:
	@rm -rf $(DEB_ROOT_CLIENT)/usr $(DEB_ROOT_CLIENT)/etc
	@rm -rf $(DEB_ROOT_SERVER)/usr $(DEB_ROOT_SERVER)/etc $(DEB_ROOT_SERVER)/.keys
	@rm -rf $(DEB_ROOT_COMMON)/usr $(DEB_ROOT_COMMON)/etc
	@rm -f kadeploy-v3-client.deb kadeploy-v3-server.deb kadeploy-v3-common.deb
