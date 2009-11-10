LATEX = pdflatex

dia-files := $(wildcard fig/*.dia)
tex-files := $(wildcard *.tex)

pdf: $(tex-files:%.tex=%.pdf)

%.pdf: %.tex dia
	$(LATEX) "$<" ; $(LATEX) "$<"

dia: $(dia-files:%.dia=%.pdf)

%.eps: %.dia
	dia -t eps-pango "$<"

%.pdf: %.eps
	epstopdf "$<"

clean:
	-rm -f *.aux *.dvi *~ *.bbl *.blg *.log *.toc *.ps *.pdf *.out

.PHONY: clean pdf
