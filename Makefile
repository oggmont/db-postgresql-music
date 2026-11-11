# Convenience commands. Run `make help` to list them.
-include .env
POSTGRES_USER ?= music
POSTGRES_DB   ?= music_db
PSQL = docker compose exec postgres psql -U $(POSTGRES_USER) -d $(POSTGRES_DB)

.PHONY: help up down reset psql logs verify

help:   ## List commands
	@grep -E '^[a-z]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-8s %s\n", $$1, $$2}'

up:     ## Start Postgres (loads schema + data on first run)
	docker compose up -d --wait

down:   ## Stop Postgres (keeps data)
	docker compose down

reset:  ## Delete the data volume and reload everything from db/init
	docker compose down -v
	docker compose up -d --wait

psql:   ## Open a psql shell
	$(PSQL)

logs:   ## Follow container logs
	docker compose logs -f postgres

verify: ## Check row counts against the expected totals
	$(PSQL) -f /queries/verify.sql
