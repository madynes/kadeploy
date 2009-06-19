CURRENT_DIR:=$(shell pwd)
DEPLOY_USER=deploy
KADEPLOY_ROOT=$(CURRENT_DIR)
SRC=$(KADEPLOY_ROOT)/src
BIN=$(KADEPLOY_ROOT)/bin
SBIN=$(KADEPLOY_ROOT)/sbin
CONF=$(KADEPLOY_ROOT)/conf
ADDONS=$(KADEPLOY_ROOT)/addons
TEST=$(KADEPLOY_ROOT)/test
PKG=$(KADEPLOY_ROOT)/pkg

api: cleanapi
	@echo "Generating API"
	@rdoc --exclude src/contrib --exclude test --include src --all --diagram --line-numbers --inline-source -A cattr_accessor=object --op doc/api

cleanapi:
	@rm -rf doc/api


install_src:
	@install -o $(DEPLOY_USER) -m 644 $(SRC)/*.rb /usr/local/kadeploy3/src
	@install -o $(DEPLOY_USER) -m 644 $(SRC)/lib/*.rb /usr/local/kadeploy3/src/lib
	@install -o $(DEPLOY_USER) -m 644 $(SRC)/contrib/*.rb /usr/local/kadeploy3/src/contrib

install_conf_client:
	@install -o $(DEPLOY_USER) -m 644 $(CONF)/client_conf /etc/kadeploy3

install_conf_server:
	@install -o $(DEPLOY_USER) -m 600 $(CONF)/conf /etc/kadeploy3
	@install -o $(DEPLOY_USER) -m 600 $(CONF)/specific_conf* /etc/kadeploy3
	@install -o $(DEPLOY_USER) -m 600 $(CONF)/nodes /etc/kadeploy3
	@install -o $(DEPLOY_USER) -m 600 $(CONF)/cmd /etc/kadeploy3
	@install -o $(DEPLOY_USER) -m 600 $(CONF)/fdisk* /etc/kadeploy3

install_conf_common:
	@install -o $(DEPLOY_USER) -m 755 $(CONF)/load_kadeploy_env /etc/kadeploy3

install_bin:
	@install -o $(DEPLOY_USER) -m 755 $(BIN)/* /usr/bin

install_sbin:
	@install -o $(DEPLOY_USER) -m 700 $(SBIN)/* /usr/sbin

install_kastafior:
	@install -o $(DEPLOY_USER) -m 755 $(ADDONS)/kastafior/kastafior /usr/bin

install_debootstrap:
	@install -o $(DEPLOY_USER) -m 700 $(ADDONS)/deploy_env_generation/debootstrap/linuxrc /usr/local/kadeploy3/addons/deploy_env_generation/debootstrap
	@install -o $(DEPLOY_USER) -m 700 $(ADDONS)/deploy_env_generation/debootstrap/mkdev /usr/local/kadeploy3/addons/deploy_env_generation/debootstrap
	@install -o $(DEPLOY_USER) -m 700 $(ADDONS)/deploy_env_generation/debootstrap/make_debootstrap.sh /usr/local/kadeploy3/addons/deploy_env_generation/debootstrap
	@install -o $(DEPLOY_USER) -m 700 $(ADDONS)/deploy_env_generation/debootstrap/make_kernel.sh /usr/local/kadeploy3/addons/deploy_env_generation/debootstrap
	@install -o $(DEPLOY_USER) -m 700 $(ADDONS)/deploy_env_generation/debootstrap/scripts/* /usr/local/kadeploy3/addons/deploy_env_generation/debootstrap/scripts

install_test:
	@install -o $(DEPLOY_USER) -m 644 $(TEST)/envfile.dsc /usr/local/kadeploy3/test
	@install -o $(DEPLOY_USER) -m 700 $(TEST)/blackbox_tests.rb /usr/local/kadeploy3/test

install_rc_script:
	@install -m 644 $(ADDONS)/rc/kadeploy_server /etc/init.d

install_ssh_key:
	@install -o $(DEPLOY_USER) -m 400 $(ADDONS)/ssh/id_deploy /.keys

tree_client:
	@mkdir -p /usr/bin

tree_server:
	@mkdir -p /usr/sbin
	@mkdir -p /etc/init.d
	@mkdir -p /.keys

tree_common:
	@mkdir -p /usr/local/kadeploy3
	@mkdir -p /usr/local/kadeploy3/src
	@mkdir -p /usr/local/kadeploy3/src/lib
	@mkdir -p /usr/local/kadeploy3/addons
	@mkdir -p /usr/local/kadeploy3/addons/deploy_env_generation
	@mkdir -p /usr/local/kadeploy3/addons/deploy_env_generation/debootstrap
	@mkdir -p /usr/local/kadeploy3/addons/deploy_env_generation/debootstrap/scripts
	@mkdir -p /usr/local/kadeploy3/addons/deploy_env_generation/debootstrap/ssh
	@mkdir -p /usr/local/kadeploy3/db
	@mkdir -p /usr/local/kadeploy3/test
	@mkdir -p /usr/local/kadeploy3/src/contrib
	@if [ -d /etc/kadeploy3 ]; then  mv /etc/kadeploy3 /etc/kadeploy3-save-`date +"%s"`; fi
	@mkdir -p /etc/kadeploy3

install_common: tree_common install_conf_common install_src install_debootstrap install_test

install_client: tree_client install_conf_client install_bin

install_server: tree_server install_conf_server install_rc_script install_ssh_key install_sbin install_kastafior

install_all: install_common install_client install_server


uninstall:
	@rm -rf /usr/local/kadeploy3
	@rm -f /.keys/id_deploy
	@rm -f /usr/sbin/kadeploy_server /usr/sbin/karights
	@rm -f /usr/bin/kaconsole /usr/bin/kadeploy /usr/bin/kaenv /usr/bin/kanodes /usr/bin/kareboot /usr/bin/kastat

deb-pkg:
	@(cd $(PKG); make package_all; mv kadeploy-v3-*.deb $(CURRENT_DIR); make clean; cd $(CURRENT_DIR))

mrproper: cleanapi uninstall
	@find . -name '*~' | xargs rm -f	
