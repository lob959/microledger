.PHONY: build run stop restart logs clean smoke-test tf-plan tf-apply tf-destroy fmt help

# ── Local development ──────────────────────────────────────────────────────

build:          ## Build both service images
	docker compose build

run:            ## Start all services (detached). Waits for health checks.
	docker compose up -d
	@echo ""
	@echo "Services starting — waiting for health checks..."
	@sleep 5
	@echo ""
	@echo "  Transaction Service → http://localhost:8001/docs"
	@echo "  Account Service     → http://localhost:8002/docs"
	@echo "  DynamoDB Local      → http://localhost:8000/shell"
	@echo ""
	@echo "Run 'make logs' to follow output, 'make smoke-test' to verify."

stop:           ## Stop all services
	docker compose down

restart:        ## Rebuild and restart all services
	docker compose down
	docker compose build
	docker compose up -d

logs:           ## Follow logs for both services (Ctrl+C to exit)
	docker compose logs -f transaction-service account-service

clean:          ## Stop services, remove volumes, clear Python cache
	docker compose down -v --remove-orphans
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	find . -type f -name "*.pyc" -delete 2>/dev/null || true

# ── Smoke test ─────────────────────────────────────────────────────────────

smoke-test:     ## End-to-end test: create account, post transactions, check balance
	@bash scripts/smoke-test.sh

# ── Terraform ──────────────────────────────────────────────────────────────

tf-plan:        ## Preview infrastructure changes
	terraform -chdir=infrastructure/terraform plan

tf-apply:       ## Apply infrastructure changes
	terraform -chdir=infrastructure/terraform apply

tf-destroy:     ## DANGER: destroy all infrastructure
	@echo "WARNING: This will destroy all AWS resources including data."
	@read -p "Type 'yes' to confirm: " confirm && [ "$$confirm" = "yes" ] \
		|| (echo "Aborted." && exit 1)
	terraform -chdir=infrastructure/terraform destroy

fmt:            ## Format Terraform files
	terraform -chdir=infrastructure/terraform fmt -recursive

# ── Help ───────────────────────────────────────────────────────────────────

help:           ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help