SHELL := /bin/bash

.PHONY: lint test verify

lint:
	shellcheck backup.sh restore.sh verify.sh install.sh internal/*.sh platforms/*.sh services/*.sh

test:
	@echo "No tests configured yet."

verify:
	./verify.sh
