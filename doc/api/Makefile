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
API_SCRIPT := './apidoc'
CSSFILE := './api.css'
DOCFILES := $(wildcard *.api)
OUTPREFIX := api_specs-
OUTFILE := $(OUTPREFIX)$(MAJOR_VERSION).$(MINOR_VERSION)$(RELEASE_VERSION).html


api:
	$(API_SCRIPT) 'Kadeploy $(MAJOR_VERSION).$(MINOR_VERSION) Network API specification' $(CSSFILE) $(DOCFILES) > $(OUTFILE)

build-clean:

clean:
	-rm -f ./$(OUTPREFIX)*

.PHONY: clean api
