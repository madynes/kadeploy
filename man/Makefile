MAJOR_VERSION:=$(shell cat ../major_version)
MINOR_VERSION:=$(shell cat ../minor_version)
RELEASE_VERSION:=$(shell cat ../release_version)
ifeq ($(strip $(RELEASE_VERSION)),stable)
	RELEASE_VERSION:=
else
	ifeq ($(strip $(RELEASE_VERSION)),git)
		RELEASE_VERSION:=.git$(shell git log --pretty=format:'%H' -n 1)
	else
		RELEASE_VERSION:=$(addprefix .,$(RELEASE_VERSION))
	endif
endif
VERSION := v$(MAJOR_VERSION).$(MINOR_VERSION)$(RELEASE_VERSION)
BASEDIR=$(shell pwd)/..
BINDIR=$(BASEDIR)/bin
SBINDIR=$(BASEDIR)/sbin
TEMPLATE=TEMPLATE
BINFILES := $(wildcard $(BINDIR)/*)
SBINFILES := $(wildcard $(SBINDIR)/*)
MAN1FILES := $(addsuffix .1, $(notdir $(BINFILES)))
MAN8FILES := $(addsuffix .8, $(notdir $(SBINFILES)))
MANFILES := $(MAN1FILES) $(MAN8FILES)

DESC_karights3 := allows to set the deployment rights to users
DESC_kadeploy3d := the launcher of Kadeploy server
DESC_kaconsole3 :=  allows to get a console on the deploying nodes
DESC_kadeploy3 := allows to perform efficient deployments on cluster nodes
DESC_kaenv3 := allows to manage the Kadeploy environments
DESC_kanodes3 := allows to get information on the current deployments
DESC_kapower3 := allows to perform several operations to control the power status of nodes
DESC_kareboot3 := allows to perform several reboot operations on the nodes involved in a deployment
DESC_kastat3 := allows to get statistics on the deployments

KADEPLOY3_LIBS := $(BASEDIR)/lib/
export KADEPLOY3_LIBS
COLUMNS := 0
export COLUMNS

all: $(MANFILES)
	@echo Done

$(MAN1FILES): $(BINFILES)
	$(eval BINFILE := $(SBINDIR)/$(basename $@))
	help2man --version-string=$(VERSION) -N -n "$(DESC_$(notdir $(BINFILE)))" -i $(TEMPLATE) -s 1 -o $@ $(BINDIR)/$(basename $@)

$(MAN8FILES): $(SBINFILES)
	$(eval BINFILE := $(SBINDIR)/$(basename $@))
	help2man --version-string=$(VERSION) -N -n "$(DESC_$(notdir $(BINFILE)))" -i $(TEMPLATE) -s 8 -o $@ $(SBINDIR)/$(basename $@)

build-clean:

clean:
	-rm -f *.1 *.8
