PREFIX ?= $(HOME)/.local
BINDIR := $(PREFIX)/bin
BASH_COMPDIR := $(PREFIX)/share/bash-completion/completions
ZSH_COMPDIR := $(PREFIX)/share/zsh/site-functions

REPO := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

.PHONY: install uninstall test lint

install:
	mkdir -p $(BINDIR) $(BASH_COMPDIR) $(ZSH_COMPDIR)
	ln -sf $(REPO)/bin/wt $(BINDIR)/wt
	ln -sf $(REPO)/completions/wt.bash $(BASH_COMPDIR)/wt
	ln -sf $(REPO)/completions/_wt $(ZSH_COMPDIR)/_wt
	@echo installed: $(BINDIR)/wt

uninstall:
	rm -f $(BINDIR)/wt $(BASH_COMPDIR)/wt $(ZSH_COMPDIR)/_wt

test:
	bash tests/test-wt.sh

lint:
	shellcheck -x -P SCRIPTDIR bin/wt tests/test-wt.sh tests/test-framework.sh completions/wt.bash
