BASEDIR := ../..
MAJOR_VERSION:=$(shell cat $(BASEDIR)/major_version)
MINOR_VERSION:=$(shell cat $(BASEDIR)/minor_version)
RELEASE_VERSION:=$(shell cat $(BASEDIR)/release_version)
ifeq ($(strip $(RELEASE_VERSION)),stable)
	RELEASE_VERSION:=
else
	ifeq ($(strip $(RELEASE_VERSION)),git)
		RELEASE_VERSION:=.git$(shell git log --pretty=format:'%H' -n 1)
	else
		RELEASE_VERSION:=$(addprefix .,$(RELEASE_VERSION))
	endif
endif
OUTPREFIX := specs-
OUTDIR := $(OUTPREFIX)$(MAJOR_VERSION).$(MINOR_VERSION)$(RELEASE_VERSION)
DOCFILES := $(wildcard *.yard)


api:
	yard doc --plugin rest --title 'Kadeploy $(MAJOR_VERSION).$(MINOR_VERSION) Network API specification' --output-dir $(OUTDIR) --no-stats $(DOCFILES)

clean:
	-rm -Rf ./$(OUTPREFIX)*

.PHONY: clean api
