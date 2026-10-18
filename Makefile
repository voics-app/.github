# Workflow validation. Both targets run in containers, so only Docker is needed.
ACTIONLINT_IMAGE ?= rhysd/actionlint:1.7.12
PYTHON_IMAGE     ?= python:3.13-slim

.PHONY: lint test

## lint: validate every workflow with actionlint (includes shellcheck and pyflakes)
lint:
	docker run --rm -v "$(CURDIR):/repo" -w /repo $(ACTIONLINT_IMAGE) -color

## test: run the behavioural tests of the scripts embedded in the workflows
test:
	docker run --rm -v "$(CURDIR):/repo" -w /repo $(PYTHON_IMAGE) sh -c '\
	  apt-get update -qq && apt-get install -y -qq --no-install-recommends jq >/dev/null && \
	  pip install --quiet --root-user-action=ignore "pyyaml>=6,<7" && \
	  python -m unittest discover -s tests -v'
