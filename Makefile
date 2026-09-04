# Developer entry points. `make help` lists them.
.DEFAULT_GOAL := help
COMPOSE      := docker compose
COMPOSE_PROD := docker compose -f docker-compose.yml
TF           := terraform -chdir=infra/terraform
SHELL        := /bin/bash

# Compose binds "$${HTTP_PORT:-80}:80", so any target that hardcodes port 80
# points at nothing the moment .env overrides it. Read the real value back
# instead. Recursive (=) not immediate (:=) so it is evaluated after `make env`
# has had a chance to create .env.
HTTP_PORT     = $(or $(shell sed -n 's/^HTTP_PORT=//p' .env 2>/dev/null | tail -1),80)
BACKEND_PORT  = $(or $(shell sed -n 's/^BACKEND_PORT=//p' .env 2>/dev/null | tail -1),8000)
LOCAL_URL     = http://localhost$(if $(filter 80,$(HTTP_PORT)),,:$(HTTP_PORT))

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# --- Environment -------------------------------------------------------------
.PHONY: env
env: ## Create .env from .env.example if it does not exist
	@test -f .env || (cp .env.example .env && echo "Created .env - edit the secrets before deploying")

# --- Local development -------------------------------------------------------
.PHONY: up
up: env ## Start the full stack with hot reload
	$(COMPOSE) up -d --build
	@echo "UI          $(LOCAL_URL)"
	@echo "API         $(LOCAL_URL)/api/tasks"
	@echo "API docs    http://localhost:$(BACKEND_PORT)/docs"

.PHONY: down
down: ## Stop the stack (keeps the database volume)
	$(COMPOSE) down

.PHONY: clean
clean: ## Stop the stack and delete volumes (destroys data)
	$(COMPOSE) down --volumes --remove-orphans

.PHONY: logs
logs: ## Tail logs from every service
	$(COMPOSE) logs -f --tail=100

.PHONY: ps
ps: ## Show container status and health
	$(COMPOSE) ps

# --- Quality gates -----------------------------------------------------------
.PHONY: test
test: ## Run the backend suite, lint and type-check inside the image
	docker build --target test -t task-manager-backend:test ./backend

.PHONY: lint-frontend
lint-frontend: ## Lint and type-check the frontend inside a container
	docker run --rm -v "$(PWD)/frontend":/app -w /app node:22-alpine \
		sh -c "npm ci --silent && npm run lint && npm run typecheck"

.PHONY: check
check: test lint-frontend ## Run every quality gate CI runs

# --- Production-like ---------------------------------------------------------
# The compose stack is no longer what runs in production — see infra/terraform.
# It is still the fastest way to run the same images against a real Postgres
# with the same routing shape, which is what these targets are for.
.PHONY: prod-up
prod-up: ## Start the full stack locally, without the dev override
	$(COMPOSE_PROD) up -d --build

.PHONY: prod-down
prod-down: ## Stop the production-like stack
	$(COMPOSE_PROD) down

.PHONY: monitoring
monitoring: ## Start the stack with Prometheus (http://localhost:9090)
	$(COMPOSE_PROD) --profile monitoring up -d

.PHONY: smoke
smoke: ## Verify every endpoint answers on a running stack
	./scripts/smoke-test.sh "$(LOCAL_URL)"

# --- AWS infrastructure ------------------------------------------------------
# Terraform owns the shape of the infrastructure; CI owns which image tag is
# running. See infra/terraform/README.md for why those are separate.
.PHONY: tf-init
tf-init: ## terraform init
	$(TF) init

.PHONY: tf-plan
tf-plan: ## Show what an apply would change
	$(TF) plan

.PHONY: tf-apply
tf-apply: ## Apply the infrastructure (prompts before changing anything)
	$(TF) apply

.PHONY: tf-fmt
tf-fmt: ## Format the Terraform
	$(TF) fmt -recursive

.PHONY: tf-check
tf-check: ## Run the checks CI runs against infra/ and scripts/
	$(TF) fmt -check -recursive -diff
	$(TF) init -backend=false -input=false
	$(TF) validate
	shellcheck scripts/*.sh

.PHONY: tf-output
tf-output: ## Show the outputs (URL, cluster, repositories, role ARN)
	$(TF) output

.PHONY: tf-ci-vars
tf-ci-vars: ## Print the six GitHub Actions repository VARIABLES to set
	@set -e; \
	role="$$($(TF) output -raw github_deploy_role_arn 2>/dev/null || true)"; \
	if [ -z "$$role" ]; then \
	  echo "github_deploy_role_arn is empty."; \
	  echo "The role is created by the FULL 'terraform apply', not by the"; \
	  echo "'-target=aws_ecr_repository.this' first step. Run 'make tf-apply'."; \
	  exit 1; \
	fi; \
	echo "Settings -> Secrets and variables -> Actions -> Variables tab."; \
	echo "Repository scope, NOT the production environment: the build and scan"; \
	echo "jobs need AWS_DEPLOY_ROLE_ARN and declare no environment."; \
	echo; \
	echo "AWS_DEPLOY_ROLE_ARN  $$role"; \
	echo "AWS_REGION           $$($(TF) output -raw aws_region)"; \
	echo "ECS_CLUSTER          $$($(TF) output -raw ecs_cluster_name)"; \
	echo "BACKEND_SERVICE      $$($(TF) output -raw backend_service_name)"; \
	echo "FRONTEND_SERVICE     $$($(TF) output -raw frontend_service_name)"; \
	echo "APP_URL              $$($(TF) output -raw app_url)"

# --- Deployment --------------------------------------------------------------
# Normally CI does this. These targets are for an incident, when waiting for a
# pipeline is the wrong answer.
.PHONY: deploy
deploy: ## Deploy IMAGE_TAG=sha-1a2b3c4 to ECS by hand
	@test -n "$(IMAGE_TAG)" || { echo "IMAGE_TAG is required, e.g. make deploy IMAGE_TAG=sha-1a2b3c4"; exit 1; }
	eval "$$($(TF) output -raw deploy_env)" && IMAGE_TAG=$(IMAGE_TAG) ./scripts/ecs-deploy.sh

.PHONY: rollback
rollback: ## Roll ECS back to the previous task definition
	eval "$$($(TF) output -raw deploy_env)" && ./scripts/ecs-rollback.sh

.PHONY: smoke-remote
smoke-remote: ## Run the smoke test against the deployed load balancer
	./scripts/smoke-test.sh "$$($(TF) output -raw app_url)"

.PHONY: logs-backend
logs-backend: ## Tail the backend's CloudWatch logs
	aws logs tail "$$($(TF) output -raw backend_log_group)" --follow --format short

.PHONY: logs-frontend
logs-frontend: ## Tail the frontend's CloudWatch logs
	aws logs tail "$$($(TF) output -raw frontend_log_group)" --follow --format short

.PHONY: services
services: ## Show what each ECS service is running right now
	eval "$$($(TF) output -raw deploy_env)" && aws ecs describe-services \
		--cluster "$$ECS_CLUSTER" --services "$$BACKEND_SERVICE" "$$FRONTEND_SERVICE" \
		--query 'services[].{service:serviceName,taskDefinition:taskDefinition,desired:desiredCount,running:runningCount,pending:pendingCount}' \
		--output table
