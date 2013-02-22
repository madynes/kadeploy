CURRENT_DIR:=$(shell pwd)
DEPLOY_USER=deploy
KADEPLOY_ROOT=$(CURRENT_DIR)
SRC=$(KADEPLOY_ROOT)/src
DB=$(KADEPLOY_ROOT)/db
BIN=$(KADEPLOY_ROOT)/bin
SBIN=$(KADEPLOY_ROOT)/sbin
CONF=$(KADEPLOY_ROOT)/conf
ADDONS=$(KADEPLOY_ROOT)/addons
TEST=$(KADEPLOY_ROOT)/test
PKG=$(KADEPLOY_ROOT)/pkg
MAN=$(KADEPLOY_ROOT)/man
MAJOR_VERSION:=$(shell cat major_version)
MINOR_VERSION:=$(shell cat minor_version)
RELEASE_VERSION:=$(shell cat release_version)
DIST_DIR_NAME=kadeploy-$(MAJOR_VERSION).$(MINOR_VERSION)
DIST_DIR=$(KADEPLOY_ROOT)/$(DIST_DIR_NAME)
DIST_TGZ=$(KADEPLOY_ROOT)/$(DIST_DIR_NAME).tar.gz
ifndef BUILD_DIR
BUILD_DIR=$(CURRENT_DIR)/builds
endif
ifndef PKG_DIR
PKG_DIR=$(CURRENT_DIR)/packages
endif
ifndef AR_DIR
AR_DIR=$(CURRENT_DIR)/archives
endif


api: cleanapi
	@echo "Generating API"
	@rdoc --exclude src/contrib --exclude test --include src --all --diagram --line-numbers --inline-source -A cattr_accessor=object --op doc/api

cleanapi:
	@rm -rf doc/api


install_src:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 644 $(SRC)/*.rb $(DESTDIR)/usr/local/kadeploy3/src
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 644 $(SRC)/lib/*.rb $(DESTDIR)/usr/local/kadeploy3/src/lib
	#@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 644 $(SRC)/contrib/*.rb $(DESTDIR)/usr/local/kadeploy3/src/contrib

install_db:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 644 $(DB)/db_creation.sql $(DESTDIR)/usr/local/kadeploy3/db

install_conf_client:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 644 $(CONF)/client_conf.yml $(DESTDIR)/etc/kadeploy3

install_conf_server:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 640 $(CONF)/server_conf.yml $(DESTDIR)/etc/kadeploy3
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 640 $(CONF)/clusters.yml $(DESTDIR)/etc/kadeploy3
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 640 $(CONF)/cluster_conf*.yml $(DESTDIR)/etc/kadeploy3
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 640 $(CONF)/cmd.yml $(DESTDIR)/etc/kadeploy3
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 640 $(CONF)/cluster_partition-* $(DESTDIR)/etc/kadeploy3

install_conf_common:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 755 $(CONF)/load_kadeploy_env $(DESTDIR)/etc/kadeploy3

install_bin:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 755 $(BIN)/* $(DESTDIR)/usr/bin

install_sbin:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 750 $(SBIN)/* $(DESTDIR)/usr/sbin

install_kastafior:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 755 $(ADDONS)/kastafior/kastafior $(DESTDIR)/usr/bin

install_test:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 755 $(TEST)/blackbox_tests.rb $(DESTDIR)/usr/local/kadeploy3/test
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 644 $(TEST)/automata.txt $(DESTDIR)/usr/local/kadeploy3/test

install_rc_script:
ifeq ($(DISTRIB),debian)
	@install -m 755 $(ADDONS)/rc/debian/kadeploy3d $(DESTDIR)/etc/init.d
endif
ifeq ($(DISTRIB),fedora)
	@install -m 755 $(ADDONS)/rc/fedora/kadeploy3d $(DESTDIR)/etc/init.d
endif

install_ssh_key:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 400 $(ADDONS)/ssh/id_deploy $(DESTDIR)/etc/kadeploy3/keys
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 400 $(ADDONS)/ssh/id_deploy.pub $(DESTDIR)/etc/kadeploy3/keys

install_version:
	@echo "$(MAJOR_VERSION).$(MINOR_VERSION)" > $(DESTDIR)/etc/kadeploy3/version
	@chown $(DEPLOY_USER):$(DEPLOY_USER) $(DESTDIR)/etc/kadeploy3/version

install_man:
	@(cd $(MAN); sh generate.sh $(DESTDIR)/usr/local/man)

tree_client:
	@mkdir -p $(DESTDIR)/usr/bin
	@mkdir -p $(DESTDIR)/
tree_server:
	@mkdir -p $(DESTDIR)/usr/sbin
	@mkdir -p $(DESTDIR)/etc/init.d
	@mkdir -p $(DESTDIR)/etc/kadeploy3/keys

tree_common:
	@mkdir -p $(DESTDIR)/usr/local/kadeploy3
	@mkdir -p $(DESTDIR)/usr/local/kadeploy3/src
	@mkdir -p $(DESTDIR)/usr/local/kadeploy3/src/lib
	@mkdir -p $(DESTDIR)/usr/local/kadeploy3/db
	@mkdir -p $(DESTDIR)/usr/local/kadeploy3/test
	#@mkdir -p $(DESTDIR)/usr/local/kadeploy3/src/contrib
	@if [ -d $(DESTDIR)/etc/kadeploy3 ]; then  mv $(DESTDIR)/etc/kadeploy3 $(DESTDIR)/etc/kadeploy3-save-`date +"%s"`; fi
	@mkdir -p $(DESTDIR)/etc/kadeploy3

install_common: tree_common install_conf_common install_src install_test install_db install_man

install_client: tree_client install_conf_client install_bin

install_server: tree_server install_conf_server install_rc_script install_ssh_key install_sbin install_kastafior install_version

install_all: install_common install_client install_server


uninstall:
	@rm -rf $(DESTDIR)/usr/local/kadeploy3
	@rm -f $(DESTDIR)/usr/sbin/kadeploy3d
	@rm -f $(DESTDIR)/usr/bin/kaconsole3 $(DESTDIR)/usr/bin/kadeploy3 $(DESTDIR)/usr/bin/kaenv3 $(DESTDIR)/usr/bin/kanodes3 $(DESTDIR)/usr/bin/kareboot3 $(DESTDIR)/usr/bin/kastat3 $(DESTDIR)/usr/bin/kapower3 $(DESTDIR)/usr/sbin/karights3

dist: dist-clean
	@./make_dist_dir.sh $(DIST_DIR)

dist-tgz: dist
	@tar czf $(DIST_TGZ) $(DIST_DIR_NAME)

dist-clean:
	@rm -rf $(DIST_DIR)
	@rm -f $(DIST_TGZ)

build:
	@mkdir -p $(BUILD_DIR)

build-clean:
	@rm -rf $(BUILD_DIR)

pkg:
	@mkdir -p $(PKG_DIR)

pkg-clean:
	@rm -rf $(PKG_DIR)

ar:
	@mkdir -p $(AR_DIR)

ar-clean:
	@rm -rf $(AR_DIR)

rpm: build-clean build pkg dist-tgz
	@(cd $(PKG)/fedora && sh set_version.sh) > $(DIST_DIR)/kadeploy.spec
	@rpmbuild --define "_topdir $(BUILD_DIR)" -ta $(DIST_TGZ)
	@cp -r $(BUILD_DIR)/RPMS/* $(PKG_DIR)
	@$(MAKE) dist-clean

deb: build-clean build pkg
	@(cd $(PKG)/debian; PKG_DIR="$(PKG_DIR)" BUILD_DIR="$(BUILD_DIR)" make package_all; cd $(CURRENT_DIR))

tgz: ar dist
	@tar czf $(AR_DIR)/$(DIST_DIR_NAME).tar.gz $(DIST_DIR_NAME)
	@$(MAKE) dist-clean

mrproper: cleanapi dist-clean uninstall
	@find . -name '*~' | xargs rm -f	

.PHONY : pkg ar build build-clean
