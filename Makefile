# Day-to-day commands for the Hermes Agent rootless Podman deployment.
# Run from the repo directory as your normal user (never with sudo).
SHELL := /bin/bash
COMPOSE ?= podman-compose
C := hermes

.PHONY: help setup up down restart logs shell chat status verify upgrade backup restore uninstall

help:
	@echo "make setup      one-time: create data/ and run the Hermes setup wizard"
	@echo "make up         start the gateway (detached)"
	@echo "make down       stop and remove the container (data/ is kept)"
	@echo "make restart    restart the container"
	@echo "make logs       follow container logs"
	@echo "make shell      bash inside the container as the hermes user"
	@echo "make chat       interactive 'hermes chat' inside the running container"
	@echo "make status     container state, version, ports, gateway status"
	@echo "make verify     run all deployment checks (used by CI)"
	@echo "make upgrade    list releases; make upgrade VERSION=vX.Y.Z to switch"
	@echo "make backup     stop, tar data/ into backups/, start again"
	@echo "make restore    ARCHIVE=backups/<file>.tar.gz restore into data/"
	@echo "make uninstall  remove container/images (PURGE=1 also deletes data/)"

setup:
	./scripts/first-setup.sh

.env:
	cp .env.example .env && chmod 600 .env

up: .env
	@test -f data/config.yaml || { echo "data/ is not initialised; run 'make setup' first."; exit 1; }
	$(COMPOSE) up -d

down:
	$(COMPOSE) down

restart:
	podman restart $(C)

logs:
	podman logs -f --tail 200 $(C)

shell:
	podman exec -it --user hermes -e HOME=/opt/data -w /opt/data $(C) bash

chat:
	podman exec -it --user hermes -e HOME=/opt/data $(C) hermes chat

status:
	@podman ps -a --filter name=^$(C)$$ --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}'
	@podman exec $(C) hermes --version 2>/dev/null | head -n1 || true
	@echo "published ports: $$(podman port $(C) 2>/dev/null || true)(none if empty)"
	@podman exec --user hermes -e HOME=/opt/data $(C) hermes gateway status 2>/dev/null | tail -n 20 || true

verify:
	./scripts/verify.sh

upgrade:
	./scripts/upgrade.sh $(VERSION)

backup:
	./scripts/backup.sh

restore:
	@test -n "$(ARCHIVE)" || { echo "usage: make restore ARCHIVE=backups/<file>.tar.gz"; ls -1t backups/ 2>/dev/null | head; exit 1; }
	./scripts/restore.sh "$(ARCHIVE)"

uninstall:
	./scripts/uninstall.sh
