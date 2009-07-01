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
DIST_DIR=$(KADEPLOY_ROOT)/kadeploy-3.0

api: cleanapi
	@echo "Generating API"
	@rdoc --exclude src/contrib --exclude test --include src --all --diagram --line-numbers --inline-source -A cattr_accessor=object --op doc/api

cleanapi:
	@rm -rf doc/api


install_src:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 644 $(SRC)/*.rb $(DESTDIR)/usr/local/kadeploy3/src
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 644 $(SRC)/lib/*.rb $(DESTDIR)/usr/local/kadeploy3/src/lib
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 644 $(SRC)/contrib/*.rb $(DESTDIR)/usr/local/kadeploy3/src/contrib

install_conf_client:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 644 $(CONF)/client_conf $(DESTDIR)/etc/kadeploy3

install_conf_server:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 600 $(CONF)/conf $(DESTDIR)/etc/kadeploy3
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 600 $(CONF)/specific_conf* $(DESTDIR)/etc/kadeploy3
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 600 $(CONF)/nodes $(DESTDIR)/etc/kadeploy3
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 600 $(CONF)/cmd $(DESTDIR)/etc/kadeploy3
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 600 $(CONF)/fdisk* $(DESTDIR)/etc/kadeploy3

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

install_rc_script:
ifeq ($(DISTRIB),debian)
	@install -m 644 $(ADDONS)/rc/debian/kadeploy3d $(DESTDIR)/etc/init.d
endif
ifeq ($(DISTRIB),fedora)
	@install -m 644 $(ADDONS)/rc/fedora/kadeploy3d $(DESTDIR)/etc/init.d
endif

install_ssh_key:
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 400 $(ADDONS)/ssh/id_deploy $(DESTDIR)/.keys
	@install -o $(DEPLOY_USER) -g $(DEPLOY_USER) -m 400 $(ADDONS)/ssh/id_deploy.pub $(DESTDIR)/.keys

tree_client:
	@mkdir -p $(DESTDIR)/usr/bin

tree_server:
	@mkdir -p $(DESTDIR)/usr/sbin
	@mkdir -p $(DESTDIR)/etc/init.d
	@mkdir -p $(DESTDIR)/.keys

tree_common:
	@mkdir -p $(DESTDIR)/usr/local/kadeploy3
	@mkdir -p $(DESTDIR)/usr/local/kadeploy3/src
	@mkdir -p $(DESTDIR)/usr/local/kadeploy3/src/lib
	@mkdir -p $(DESTDIR)/usr/local/kadeploy3/db
	@mkdir -p $(DESTDIR)/usr/local/kadeploy3/test
	@mkdir -p $(DESTDIR)/usr/local/kadeploy3/src/contrib
	@if [ -d $(DESTDIR)/etc/kadeploy3 ]; then  mv $(DESTDIR)/etc/kadeploy3 $(DESTDIR)/etc/kadeploy3-save-`date +"%s"`; fi
	@mkdir -p $(DESTDIR)/etc/kadeploy3

install_common: tree_common install_conf_common install_src install_test

install_client: tree_client install_conf_client install_bin

install_server: tree_server install_conf_server install_rc_script install_ssh_key install_sbin install_kastafior

install_all: install_common install_client install_server


uninstall:
	@rm -rf $(DESTDIR)/usr/local/kadeploy3
	@rm -f $(DESTDIR)/.keys/id_deploy
	@rm -f $(DESTDIR)/usr/sbin/kadeploy3_server $(DESTDIR)/usr/sbin/karights3
	@rm -f $(DESTDIR)/usr/bin/kaconsole3 $(DESTDIR)/usr/bin/kadeploy3 $(DESTDIR)/usr/bin/kaenv3 $(DESTDIR)/usr/bin/kanodes3 $(DESTDIR)/usr/bin/kareboot3 $(DESTDIR)/usr/bin/kastat3

dist: dist-clean
	@./make_dist_dir.sh $(DIST_DIR)

dist-tgz: dist
	@tar czf $(DIST_DIR).tar.gz $(shell basename $(DIST_DIR))
	@rm -rf $(DIST_DIR)

dist-clean:
	@rm -rf $(DIST_DIR)

rpm: dist
	cp $(PKG)/fedora/kadeploy.spec $(DIST_DIR)
	tar czf $(DIST_DIR).tar.gz $(shell basename $(DIST_DIR))
	rpmbuild -ta $(DIST_DIR).tar.gz

deb:
	@(cd $(PKG)/debian; make package_all; mv kadeploy-*.deb $(CURRENT_DIR); make clean; cd $(CURRENT_DIR))

mrproper: cleanapi dist-clean uninstall
	@find . -name '*~' | xargs rm -f	
