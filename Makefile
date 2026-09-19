EMACS ?= $(shell command -v emacs 2>/dev/null || \
           ls -d /Applications/Emacs.app/Contents/MacOS/Emacs \
                 /opt/homebrew/Cellar/emacs-plus*/*/Emacs.app/Contents/MacOS/Emacs \
                 2>/dev/null | tail -1)
JEV ?= ../jev.el
ELS = flymake-jev.el

.PHONY: all compile test clean

all: compile test

compile:
	$(EMACS) -Q -batch -L . -L $(JEV) --eval "(setq byte-compile-error-on-warn t)" \
	  -f batch-byte-compile $(ELS)

test:
	$(EMACS) -Q -batch --eval "(setq load-prefer-newer t)" -L . -L $(JEV) -L tests \
	  -l tests/flymake-jev-tests.el -f ert-run-tests-batch-and-exit

clean:
	rm -f *.elc
