KADEPLOY_ROOT=../..
DEPLOY_USER=deploy
BUILD_ROOT=`pwd`/build
SRC=$(KADEPLOY_ROOT)/src
BIN=$(KADEPLOY_ROOT)/bin
SBIN=$(KADEPLOY_ROOT)/sbin
CONF=$(KADEPLOY_ROOT)/conf
ADDONS=$(KADEPLOY_ROOT)/addons
DB=$(KADEPLOY_ROOT)/db
TEST=$(KADEPLOY_ROOT)/test
default: package_all

install_src:
	@cp $(SRC)/*.rb $(BUILD_ROOT)/usr/local/kadeploy3/src
	@cp $(SRC)/lib/*.rb $(BUILD_ROOT)/usr/local/kadeploy3/src/lib
	@cp $(SRC)/contrib/*.rb $(BUILD_ROOT)/usr/local/kadeploy3/src/contrib

install_conf_client:
	@cp $(CONF)/client_conf $(BUILD_ROOT)/etc/kadeploy3

install_conf_server:
	@cp $(CONF)/conf $(BUILD_ROOT)/etc/kadeploy3
	@cp $(CONF)/specific_conf* $(BUILD_ROOT)/etc/kadeploy3
	@cp $(CONF)/nodes $(BUILD_ROOT)/etc/kadeploy3
	@cp $(CONF)/cmd $(BUILD_ROOT)/etc/kadeploy3
	@cp $(CONF)/fdisk* $(BUILD_ROOT)/etc/kadeploy3

install_conf_common:
	@cp $(CONF)/load_kadeploy_env $(BUILD_ROOT)/etc/kadeploy3

install_bin:
	@cp $(BIN)/* $(BUILD_ROOT)/usr/bin

install_sbin:
	@cp $(SBIN)/* $(BUILD_ROOT)/usr/sbin

install_kastafior:
	@cp $(ADDONS)/kastafior/kastafior $(BUILD_ROOT)/usr/bin

install_debootstrap:
	@cp $(ADDONS)/deploy_env_generation/debootstrap/linuxrc $(BUILD_ROOT)/usr/local/kadeploy3/addons/deploy_env_generation/debootstrap
	@cp $(ADDONS)/deploy_env_generation/debootstrap/mkdev $(BUILD_ROOT)/usr/local/kadeploy3/addons/deploy_env_generation/debootstrap
	@cp $(ADDONS)/deploy_env_generation/debootstrap/make_debootstrap.sh $(BUILD_ROOT)/usr/local/kadeploy3/addons/deploy_env_generation/debootstrap
	@cp $(ADDONS)/deploy_env_generation/debootstrap/make_kernel.sh $(BUILD_ROOT)/usr/local/kadeploy3/addons/deploy_env_generation/debootstrap
	@cp $(ADDONS)/deploy_env_generation/debootstrap/scripts/* $(BUILD_ROOT)/usr/local/kadeploy3/addons/deploy_env_generation/debootstrap/scripts

install_test:
	@cp $(TEST)/blackbox_tests.rb $(BUILD_ROOT)/usr/local/kadeploy3/test

install_rc_script:
	@cp $(ADDONS)/rc/kadeploy_server $(BUILD_ROOT)/etc/init.d

install_db_script:
	@cp $(DB)/db_creation.sql $(BUILD_ROOT)/usr/local/kadeploy3/db

install_ssh_key:
	@cp $(ADDONS)/ssh/id_deploy $(BUILD_ROOT)/.keys

tree_client:
	@mkdir -p $(BUILD_ROOT)/usr/bin
	@mkdir -p $(BUILD_ROOT)/etc/kadeploy3

tree_server:
	@mkdir -p $(BUILD_ROOT)/usr/bin
	@mkdir -p $(BUILD_ROOT)/usr/sbin
	@mkdir -p $(BUILD_ROOT)/etc/init.d
	@mkdir -p $(BUILD_ROOT)/.keys
	@mkdir -p $(BUILD_ROOT)/etc/kadeploy3

tree_common:
	@mkdir -p $(BUILD_ROOT)/usr/local/kadeploy3
	@mkdir -p $(BUILD_ROOT)/usr/local/kadeploy3/src
	@mkdir -p $(BUILD_ROOT)/usr/local/kadeploy3/src/lib
	@mkdir -p $(BUILD_ROOT)/usr/local/kadeploy3/addons
	@mkdir -p $(BUILD_ROOT)/usr/local/kadeploy3/addons/deploy_env_generation
	@mkdir -p $(BUILD_ROOT)/usr/local/kadeploy3/addons/deploy_env_generation/debootstrap
	@mkdir -p $(BUILD_ROOT)/usr/local/kadeploy3/addons/deploy_env_generation/debootstrap/scripts
	@mkdir -p $(BUILD_ROOT)/usr/local/kadeploy3/db
	@mkdir -p $(BUILD_ROOT)/usr/local/kadeploy3/test
	@mkdir -p $(BUILD_ROOT)/usr/local/kadeploy3/src/contrib
	@mkdir -p $(BUILD_ROOT)/etc/kadeploy3

clean_build_root:
	@rm -rf $(BUILD_ROOT)

package_client: clean_build_root tree_client install_conf_client install_bin
	@rpmbuild -bb --buildroot $(BUILD_ROOT) kadeploy-client.spec
package_server: clean_build_root tree_server install_conf_server install_rc_script install_ssh_key install_sbin install_kastafior
	@rpmbuild -bb --buildroot $(BUILD_ROOT) kadeploy-server.spec
package_common: clean_build_root tree_common install_conf_common install_src install_debootstrap install_test install_db_script
	@rpmbuild -bb --buildroot $(BUILD_ROOT) kadeploy-common.spec
package_all: package_client package_server package_common

clean: clean_build_root
