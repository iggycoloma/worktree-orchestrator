PREFIX ?= $(HOME)/.local
BINDIR := $(PREFIX)/bin
BASH_COMPDIR := $(PREFIX)/share/bash-completion/completions
ZSH_COMPDIR := $(PREFIX)/share/zsh/site-functions
FISH_COMPDIR := $(PREFIX)/share/fish/vendor_completions.d
FISH_FUNCDIR := $(PREFIX)/share/fish/vendor_functions.d

REPO := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

.PHONY: install uninstall test lint

install:
	PREFIX=$(PREFIX) bash $(REPO)/install.sh

uninstall:
	rm -f $(BINDIR)/wt $(BASH_COMPDIR)/wt $(ZSH_COMPDIR)/_wt \
		$(FISH_COMPDIR)/wt.fish $(FISH_FUNCDIR)/wt.fish

test:
	bash tests/test-wt.sh

lint:
	shellcheck -x -P SCRIPTDIR bin/wt install.sh tests/test-wt.sh tests/test-framework.sh completions/wt.bash
