# AI-Gated CI/CD Pipeline to AWS ECS Fargate

This project is a production-style demo of a **FastAPI** service deployed on **AWS ECS Fargate**, with a **GitHub Actions CI/CD pipeline** that is protected by an **AI gate** running on **AWS Lambda + Amazon Bedrock**.

On every push to `main`, the pipeline:

1. Runs tests for the FastAPI API.
2. Builds and pushes a Docker image to Amazon ECR.
3. Computes real git diff stats (files changed, lines added/removed).
4. Sends commit + test + diff context to a Lambda “AI gate”.
5. The Lambda makes a **structured decision** (`approve`, `warn`, or `block`) and generates a **natural-language explanation** using Bedrock.
6. Only if the decision is not `block` does the pipeline deploy a new task definition to the ECS Fargate service via a rolling deployment through an Application Load Balancer (ALB).

---

## Architecture Overview

**Components**

- **FastAPI app** under `api/`
  - Basic REST API (health and tasks endpoints).
  - Tested with `pytest`.

- **Containerization**
  - Dockerfile in `api/`.
  - Image built in CI and pushed to **Amazon ECR**.

- **Infrastructure (Terraform)** under `infra/`:
  - ECR repository for the API image.
  - ECS Fargate cluster and service.
  - Task definition pointing to the ECR image.
  - Application Load Balancer (ALB) + security groups.
  - CloudWatch Logs for ECS tasks.
  - IAM user (`task-tracker-ci-user`) with a scoped policy allowing:
    - Pushing images to ECR.
    - Forcing ECS service deployments.
    - Invoking the AI gate Lambda.
  - Lambda function `task-tracker-ai-gate`:
    - Deployed from `lambda-ai-gate/` via `data "archive_file"` + `aws_lambda_function`.
    - Execution role with:
      - `AWSLambdaBasicExecutionRole` for logging.
      - Custom policy allowing `bedrock:InvokeModel` for on-demand Bedrock models.

- **AI gate (Lambda + Bedrock)**
  - Lambda receives a JSON payload from GitHub Actions:
    - `commit_sha`, `branch`
    - `tests.status`, `tests.total`, `tests.failed`
    - `diff.files_changed`, `diff.insertions`, `diff.deletions`
    - `service.name`, `service.environment`
  - Lambda:
    - Applies simple **rule-based logic**:
      - If tests did not pass → `decision = "block"`.
      - Else if diff is large (e.g., many files or many changed lines) → `decision = "warn"`.
      - Else → `decision = "approve"`.
    - Computes a basic `risk_score` from diff size.
    - For non-`block` decisions, calls **Amazon Bedrock** with a short prompt to generate a natural-language explanation of the risk.
    - Returns a structured JSON result with:
      - `decision`, `risk_score`, `reasons[]`, `explanation`, and `context`.

- **GitHub Actions workflow**
  - `.github/workflows/deploy-ecs.yml`.
  - Triggered on pushes to `main`.

---

## CI/CD Workflow Details

The GitHub Actions workflow:

1. **Checkout & Test**

   - Uses `actions/checkout` to fetch the repo.
   - Sets `fetch-depth: 2` so `HEAD~1` is available for `git diff`.
   - Sets up Python 3.12 and runs:
     - `python -m venv .venv`
     - `pip install -r requirements.txt`
     - `pytest`

2. **Compute Diff Stats for AI**

   - Calls:

     ```bash
     git diff --name-only HEAD~1..HEAD
     git diff --shortstat HEAD~1..HEAD
     ```

   - Extracts:
     - `FILES_CHANGED`
     - `INSERTIONS`
     - `DELETIONS`
   - Builds `ai_payload.json` with commit, tests, diff, and service metadata.

3. **Invoke AI Gate Lambda**

   - Configures AWS credentials using `aws-actions/configure-aws-credentials`.
   - Calls:

     ```bash
     aws lambda invoke \
       --function-name task-tracker-ai-gate \
       --payload file://ai_payload.json \
       --cli-binary-format raw-in-base64-out \
       ai_response.json
     ```

   - Takes the last line of `ai_response.json` as the Lambda’s JSON response.
   - Uses `jq` to parse `.decision`.

4. **Enforce AI Decision**

   - If `decision == "block"` → the job fails and deployment stops.
   - If `decision == "warn"` → logs a warning but continues.
   - Otherwise → continues to deploy.

5. **Build & Deploy**

   - Logs in to ECR.
   - Builds the Docker image tagged with the short commit SHA.
   - Pushes the image to ECR.
   - Calls `aws ecs update-service --force-new-deployment` to trigger a rolling deploy on ECS Fargate.

---

## Lambda AI Gate Logic

The `lambda-ai-gate/lambda_function.py` implements:

- **Input parsing**:
  - Pulls test status and diff stats from the `event` JSON.

- **Decision policy**:
  - `block` if tests are not `"passed"`.
  - `warn` if the change set is large (many files or many total changed lines).
  - `approve` otherwise.
  - Computes a simple `risk_score` based on `total_lines_changed` and whether the deploy is blocked.

- **Cost-aware Bedrock usage**:
  - If `decision == "block"`, returns a static explanation and **does not call Bedrock**.
  - Otherwise:
    - Builds a compact, structured prompt with the event JSON and the current decision.
    - Calls `bedrock:InvokeModel` on a small, cost-efficient model.
    - Extracts and returns the model’s textual explanation.
  - All Bedrock errors are caught and returned as a fallback string in `explanation`, without breaking the CI gate.

---

## IAM and Security

- **Lambda execution role**:
  - Trusts `lambda.amazonaws.com`.
  - Has `AWSLambdaBasicExecutionRole` for CloudWatch Logs.
  - Custom `lambda-ai-gate-policy` grants:
    - `bedrock:InvokeModel` on either all models or a specific foundation model ARN.

- **CI user** (`task-tracker-ci-user`):
  - Custom `ci_ecr_ecs` policy allows:
    - ECR auth and push actions.
    - ECS `Describe*` and `UpdateService`.
    - `lambda:InvokeFunction` on the AI gate Lambda only.

- **Network**:
  - Default VPC and public subnets (to keep infrastructure simple and cheap).
  - ALB security group allows inbound HTTP on port 80 from the internet.
  - ECS task security group only allows inbound traffic from the ALB SG on port 8000.

---

## Deployment & Usage

1. **Provision infrastructure**

   From `infra/`:

   ```bash
   terraform init
   terraform apply
   ```

   This creates the ECR repo, ECS cluster, Fargate service, ALB, IAM roles, CI IAM user + access key, and the AI gate Lambda.

2. **Configure GitHub secrets**

   In the GitHub repo’s **Settings → Secrets and variables → Actions**, add:

   - `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` for `task-tracker-ci-user`.
   - `AWS_REGION`
   - `AWS_ACCOUNT_ID`
   - `ECR_REPOSITORY` (e.g., `task-tracker-api`)
   - `ECS_CLUSTER` (e.g., `task-tracker-cluster`)
   - `ECS_SERVICE` (e.g., `task-tracker-service`)

3. **Run the pipeline**

   - Push to `main`.
   - Watch the workflow in GitHub Actions:
     - Tests → AI gate (Lambda + Bedrock) → Deploy to ECS.
   - Check the logs for:
     - `AI result: { ... }`
     - `Decision from AI gate: approve|warn|block`
     - The Bedrock-generated `explanation`.

4. **Access the app**

   - In `infra/`, run:

     ```bash
     terraform output alb_dns_name
     ```

   - Hit:

     ```bash
     curl http://<ALB_DNS>/health
     curl http://<ALB_DNS>/tasks
     ```

---

## Cost Considerations

- **ECS Fargate + ALB**:
  - You pay per vCPU/memory second and per ALB-LCU hour.
  - Using a small Fargate task and default VPC keeps costs low.

- **Bedrock**:
  - The AI gate uses a small model and a short prompt/response, so each invocation costs a tiny fraction of a cent.
  - The Lambda only calls Bedrock for non-block decisions, further reducing usage.

- **Terraform resources**:
  - You can tear down everything with:

    ```bash
    cd infra
    terraform destroy
    ```

---

## What This Project Demonstrates

- How to build a **CI/CD pipeline to ECS Fargate with GitHub Actions**.
- How to **compute real git diff stats** inside GitHub Actions and pass them to a Lambda.
- How to build a **safe AI gate**:
  - Rule-based logic for predictable decisions.
  - LLM-based explanations for human-friendly risk summaries.
  - Graceful error handling so AI failures never break the pipeline.

---

If you share your intended audience (recruiters, blog readers, teammates), this README can be tuned further to emphasize the most relevant parts (e.g., DevOps skills, cloud architecture, or AI integration).
