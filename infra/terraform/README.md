# Infrastructure

Terraform for the ECS deployment — around 100 resources across 15 files: a VPC,
an Application Load Balancer, an ECS Fargate cluster with two services, RDS
PostgreSQL, two ECR repositories, the IAM roles that tie them together, and the
CloudWatch logs and alarms around all of it.

## Layout

| File | Contents |
|---|---|
| [`versions.tf`](versions.tf) | Provider pins, naming locals, state backend |
| [`variables.tf`](variables.tf) | All 47 inputs, with the trade-off in each description |
| [`network.tf`](network.tf) | VPC, public/private subnets, NAT, routes, flow logs |
| [`security-groups.tf`](security-groups.tf) | The `internet → alb → app → rds` chain |
| [`ecr.tf`](ecr.tf) | Two private repositories with lifecycle policies |
| [`rds.tf`](rds.tf) | PostgreSQL, parameter group, generated credentials |
| [`alb.tf`](alb.tf) | Load balancer, target groups, listener rules |
| [`ecs.tf`](ecs.tf) | Cluster, task definitions, services |
| [`autoscaling.tf`](autoscaling.tf) | Target-tracking policies |
| [`waf.tf`](waf.tf) | Rate limiting |
| [`iam.tf`](iam.tf) | Execution role, task roles, service roles |
| [`iam-github.tf`](iam-github.tf) | The OIDC role CI assumes |
| [`logs.tf`](logs.tf) | Log groups and saved Logs Insights queries |
| [`alarms.tf`](alarms.tf) | CloudWatch alarms |
| [`outputs.tf`](outputs.tf) | 22 outputs — everything CI and the runbook need |

## Configuration

Every input has a working default in [`variables.tf`](variables.tf);
[`terraform.tfvars.example`](terraform.tfvars.example) shows the ones worth
changing, with the reason. The Fargate cpu/memory pairing and the database
connection ceiling are both checked by preconditions, so an invalid value fails
at plan time with the valid ones listed.

State is local by default, so `terraform init` needs no prerequisites. For
anything shared, uncomment the S3 backend in [`versions.tf`](versions.tf) — the
state file holds the generated database password in cleartext.

## Installing

Prerequisites: Terraform ≥ 1.9, the AWS CLI, Docker, and credentials with
enough access to create the above.

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — at minimum set github_repository to your repo.
```

**1. Create the registries first.** The ECS services reference an image tag;
until an image exists, tasks start and immediately fail. Creating ECR on its
own avoids a first apply that looks broken.

```bash
terraform init
terraform apply -target='aws_ecr_repository.this'
```

**2. Push the first images, by hand.**

Not with CI, and this is the ordering that has to be right: the workflow
authenticates to ECR by assuming the OIDC role, whose policy references the ECS
services — so it does not exist until step 3. Pushing to `main` first fails at
`configure-aws-credentials` with `Could not load credentials from any providers`.

`deploy_env` is not available yet either, for the same reason. These two
outputs are:

```bash
BACKEND_REPOSITORY="$(terraform output -raw backend_repository_url)"
FRONTEND_REPOSITORY="$(terraform output -raw frontend_repository_url)"
REGISTRY="${BACKEND_REPOSITORY%%/*}"          # <account>.dkr.ecr.<region>.amazonaws.com
REGION="$(cut -d. -f4 <<<"$REGISTRY")"

aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

docker build -t "$BACKEND_REPOSITORY:latest" --target runtime ../../backend
docker push "$BACKEND_REPOSITORY:latest"

docker build -t "$FRONTEND_REPOSITORY:latest" --target runner \
  --build-arg NEXT_PUBLIC_API_BASE_URL=/api ../../frontend
docker push "$FRONTEND_REPOSITORY:latest"
```

**3. Apply the rest.** RDS takes about ten minutes; the whole apply is
typically fifteen. This is the step that creates the OIDC deploy role, so
nothing in CI can work before it.

```bash
terraform apply
```

If you skipped step 2 the services come up with tasks that cannot start
(`CannotPullContainerError`) and retry indefinitely. That is self-healing: they
pick up the first image that lands.

**4. Verify.**

```bash
terraform output app_url
../../scripts/smoke-test.sh "$(terraform output -raw app_url)"
```

**5. Wire up CI.**

```bash
make tf-ci-vars     # prints the six values, ready to paste
```

Set them under Settings → Secrets and variables → Actions → the **Variables**
tab, at **repository** scope. None is a secret — that is the point of the OIDC
role. Not the `production` environment: `build` and `scan` need
`AWS_DEPLOY_ROLE_ARN` and declare no environment, so an environment-scoped
variable is invisible to them.

Then create a `production` environment there and attach whatever reviewers you
want; the role's trust policy names it, so its protection rules run before AWS
is contacted.

## Tearing down

```bash
terraform destroy
```

Two things block this on purpose. **The database**, while
`db_deletion_protection = true` — set it to `false`, apply, then destroy; a
final snapshot is taken either way. And **ECR repositories holding images**,
because `force_delete = false` — empty them first, or flip the flag.
