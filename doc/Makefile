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
TEXFILE := Kadeploy-V3.tex
PDFFILE := $(JOBNAME).pdf
LATEX = pdflatex

dia-files := $(wildcard fig/*.dia)
tex-files := $(wildcard *.tex)

pdf: $(PDFFILE)

$(PDFFILE): $(TEXFILE) dia
	$(LATEX) -jobname="$(JOBNAME)" "$<"; $(LATEX) -jobname="$(JOBNAME)" "$<"

dia: $(dia-files:%.dia=%.pdf)

%.eps: %.dia
	dia -t eps-pango "$<"

%.pdf: %.eps
	epstopdf "$<"

clean:
	-rm -f *.aux *.dvi *~ *.bbl *.blg *.log *.toc *.ps *.pdf *.out

.PHONY: clean pdf
