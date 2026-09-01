SHELL := /bin/bash

.DEFAULT_GOAL := help

IMAGE_PREFIX ?= local/ovn-builder
PLATFORM ?= linux/amd64

.PHONY: help validate debs provenance images builder all clean

help:
	@printf '%s\n' \
	  'make validate                         Validate locks, scripts, Bake and workflows' \
	  'make debs TARGET=debs-ovs-u2204      Export a DEB bundle into dist/' \
	  'make provenance TARGET=provenance-ovn-u2204  Export raw per-run dpkg provenance' \
	  'make images TARGET=images-ovn-u2204  Load carrier and runtime images' \
	  'make builder TARGET=builder-u2204    Load the complete build environment' \
	  'make all                             Export all four DEB bundles'

validate:
	./scripts/ci/validate.sh

debs:
	@test -n "$(TARGET)" || { echo 'TARGET is required' >&2; exit 2; }
	IMAGE_PREFIX="$(IMAGE_PREFIX)" PLATFORM="$(PLATFORM)" docker buildx bake "$(TARGET)"

provenance:
	@test -n "$(TARGET)" || { echo 'TARGET is required' >&2; exit 2; }
	IMAGE_PREFIX="$(IMAGE_PREFIX)" PLATFORM="$(PLATFORM)" docker buildx bake "$(TARGET)"

images:
	@test -n "$(TARGET)" || { echo 'TARGET is required' >&2; exit 2; }
	IMAGE_PREFIX="$(IMAGE_PREFIX)" PLATFORM="$(PLATFORM)" docker buildx bake --load "$(TARGET)"

builder:
	@test -n "$(TARGET)" || { echo 'TARGET is required' >&2; exit 2; }
	IMAGE_PREFIX="$(IMAGE_PREFIX)" PLATFORM="$(PLATFORM)" docker buildx bake --load "$(TARGET)"

all:
	IMAGE_PREFIX="$(IMAGE_PREFIX)" PLATFORM="$(PLATFORM)" docker buildx bake

clean:
	@echo 'Remove dist/ manually when its contents are no longer needed.'
