.DEFAULT_GOAL := help

.PHONY: help build run test verify-assets smoke-test benchmark

help:
	@printf '%s\n' \
	  'make build          Build release/Blacksite.app' \
	  'make run            Build and open the macOS app' \
	  'make test           Run the complete Swift test suite' \
	  'make verify-assets  Verify the pinned photographic assets offline' \
	  'make smoke-test     Build and render a Metal smoke-test image' \
	  'make benchmark      Run the native CPU simulation benchmark'

build:
	./native/scripts/build-app.sh

run:
	./native/scripts/run.sh

test:
	./native/scripts/test.sh

verify-assets:
	python3 native/scripts/fetch-assets.py --verify

smoke-test:
	./native/scripts/build-app.sh --smoke-test

benchmark:
	./native/scripts/benchmark-core.sh
