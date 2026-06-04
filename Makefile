# =============================================================================
# LedgerLite -- Developer Makefile
# =============================================================================
#
# Provides short, memorable commands for the most common development tasks.
# All targets are grouped into three sections:
#
#   1. Local development  -- build, run, stop, log, and clean the Docker stack
#   2. Smoke test         -- end-to-end integration test against the local stack
#   3. Terraform          -- infrastructure plan, apply, and destroy
#
# Usage:
#   make <target>
#
# Run 'make' or 'make help' with no arguments to see all available targets.
# =============================================================================

# .PHONY declares targets that are not files on disk.
# Without this, Make would skip a target if a file with the same name existed
# (e.g. a file called 'clean' would prevent 'make clean' from running).
.PHONY: build run stop restart logs clean smoke-test tf-plan tf-apply tf-destroy fmt help

# -- Local development --------------------------------------------------------
#
# These targets wrap 'docker compose' (v2) commands. Docker Compose v2 is
# bundled with Docker Desktop and replaces the older standalone docker-compose
# (v1) binary. Run 'docker compose version' to confirm v2 is available.
#
# The stack is defined in docker-compose.yml. It runs four containers:
# dynamodb-local, dynamodb-init (one-shot table setup), account-service,
# and transaction-service.

build:          ## Build both service images
	# Reads the 'build' stanzas in docker-compose.yml and builds the images.
	# Both services use multi-stage Dockerfiles -- the builder stage installs
	# dependencies; the runtime stage copies only what is needed.
	# Re-run after changing a Dockerfile or requirements.txt.
	docker compose build

run:            ## Start all services (detached). Waits for health checks.
	# '-d' starts containers in detached (background) mode.
	# Startup order is enforced by depends_on conditions in docker-compose.yml:
	#   dynamodb-local -> dynamodb-init -> account-service -> transaction-service
	# The sleep gives health checks time to settle before URLs are printed.
	docker compose up -d
	@echo ""
	@echo "Services starting -- waiting for health checks..."
	@sleep 5
	@echo ""
	@echo "  Transaction Service -> http://localhost:8001/docs"
	@echo "  Account Service     -> http://localhost:8002/docs"
	@echo "  DynamoDB Local      -> http://localhost:8000/shell"
	@echo ""
	@echo "Run 'make logs' to follow output, 'make smoke-test' to verify."

stop:           ## Stop all services
	# Stops and removes containers but preserves named volumes -- DynamoDB Local
	# data survives a stop/start cycle. Use 'make clean' for a full wipe.
	docker compose down

restart:        ## Rebuild and restart all services
	# Full rebuild-and-relaunch. Use after changing a Dockerfile,
	# requirements.txt, or any file COPYed during the Docker build.
	docker compose down
	docker compose build
	docker compose up -d

logs:           ## Follow logs for both services (Ctrl+C to exit)
	# Streams real-time output from the two application containers.
	# DynamoDB Local and the init container are excluded -- they produce no
	# useful output after initial startup.
	# Tip: pipe through jq for readable JSON: docker compose logs -f ... | jq .
	docker compose logs -f transaction-service account-service

clean:          ## Stop services, remove volumes, clear Python cache
	# '-v' removes named volumes -- wipes all DynamoDB Local data. The next
	# 'make run' recreates tables via the dynamodb-init container.
	# '--remove-orphans' removes containers from previous Compose configs
	# that are no longer defined in the current file.
	# The find commands remove Python bytecode cache that accumulates on the host.
	docker compose down -v --remove-orphans
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	find . -type f -name "*.pyc" -delete 2>/dev/null || true

# -- Smoke test ---------------------------------------------------------------
#
# Exercises the full request path end-to-end against the running local stack.
# Creates a fresh account each run so it is safe to run multiple times.
# See scripts/smoke-test.sh for full test logic and inline documentation.
#
# Prerequisite: the stack must be running ('make run') before calling this.

smoke-test:     ## End-to-end test: create account, post transactions, check balance
	# '@' suppresses Make from echoing the command, keeping terminal output clean.
	@bash scripts/smoke-test.sh

# -- Terraform ----------------------------------------------------------------
#
# Provisions and manages all AWS infrastructure in infrastructure/terraform/.
# The '-chdir' flag makes Terraform use that directory as its working directory
# without needing a 'cd'.
#
# Before running for the first time, bootstrap the remote state backend:
#   cd infrastructure/terraform/bootstrap
#   terraform init && terraform apply
#
# Workflow: always run 'tf-plan' and review the output before 'tf-apply'.
# AWS credentials must be configured in the environment before running these.

tf-plan:        ## Preview infrastructure changes
	# Computes the diff between current Terraform state and the desired state
	# in the .tf files. Shows what would be created, changed, or destroyed.
	# No AWS changes are made at this stage.
	terraform -chdir=infrastructure/terraform plan

tf-apply:       ## Apply infrastructure changes
	# Executes the changeset from the most recent plan. Terraform prompts for
	# confirmation before making any changes to AWS.
	terraform -chdir=infrastructure/terraform apply

tf-destroy:     ## DANGER: destroy all infrastructure
	# Destroys every AWS resource managed by this configuration, including
	# DynamoDB tables and all data stored in them. This is irreversible.
	# The confirmation prompt is a safety gate against accidental teardown.
	@echo "WARNING: This will destroy all AWS resources including data."
	@read -p "Type 'yes' to confirm: " confirm && [ "$$confirm" = "yes" ] \
		|| (echo "Aborted." && exit 1)
	terraform -chdir=infrastructure/terraform destroy

fmt:            ## Format Terraform files
	# Rewrites all .tf files to canonical Terraform style. Run before committing
	# Terraform changes to keep diffs free of style-only noise.
	terraform -chdir=infrastructure/terraform fmt -recursive

# -- Help ---------------------------------------------------------------------
#
# Prints a table of all targets that have a '## ' inline comment.
# grep matches lines of the form: target-name: ... ## description
# awk splits on the separator and prints a two-column aligned table.
# Targets without '## ' are intentionally excluded from the output.

help:           ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

# Make runs 'help' when no target is specified on the command line.
.DEFAULT_GOAL := help