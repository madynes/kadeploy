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
JOBNAME := Kadeploy-$(MAJOR_VERSION).$(MINOR_VERSION)$(RELEASE_VERSION)
TEXFILE := Kadeploy.tex
PDFFILE := $(JOBNAME).pdf
LATEX = pdflatex
BASEDIR := ..
BINFILES := $(wildcard $(BASEDIR)/bin/*) $(wildcard $(BASEDIR)/sbin/*)
HELPFILES := $(BINFILES:=.help)
COMPLETETEXFILE := $(TEXFILE:=.complete)

dia-files := $(wildcard fig/*.dia)
tex-files := $(wildcard *.tex)

pdf: $(PDFFILE)

$(PDFFILE): $(COMPLETETEXFILE) $(HELPFILES)
	$(LATEX) -jobname="$(JOBNAME)" "$(COMPLETETEXFILE)"; $(LATEX) -jobname="$(JOBNAME)" "$(COMPLETETEXFILE)"

dia: $(dia-files:%.dia=%.pdf)

$(HELPFILES): $(COMPLETETEXFILE)
	KADEPLOY3_LIBS=$(BASEDIR)/src/lib $(@:.help=) --help > $(notdir $@) || true
	sed -i -e "/__HELP_$(notdir $(@:.help=))_HELP__/r $(notdir $@)" -e "//d" $(COMPLETETEXFILE)

$(COMPLETETEXFILE):
	cp $(TEXFILE) $(COMPLETETEXFILE)

%.eps: %.dia
	dia -t eps-pango "$<"

%.pdf: %.eps
	epstopdf "$<"

clean:
	-rm -f *.aux *.dvi *~ *.bbl *.blg *.log *.toc *.ps *.pdf *.out *.help *.complete

.PHONY: clean pdf
