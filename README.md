# TeamGram — Capstone Onboarding Exercise

> **Goal:** In ~30 minutes, you will make a one-line change to a Terraform file, open a Pull Request, watch GitHub Actions deploy it to your team's AWS sandbox, and see your self-introduction appear on your team's wall.
>
> **What you're really learning:** how to use the PR → CI → shared-state workflow on a real AWS account, with your real teammates. This is the workflow you will use with your client for the rest of the semester.

---

## 0. Background: Why This Workflow Exists

Read this once before you touch any code. It's the _whole reason_ the rest of this exercise looks the way it does.

### 0.1 What is "Infrastructure as Code" (IaC)?

> As developers, we don't want to click around the AWS Console a million times to provision a load balancer, a database, an IAM role, etc. We want a **file** that describes the desired infrastructure, and a tool that makes the cloud match that file.

That file is **Terraform**. You write `.tf` files describing what you want (an S3 bucket, an ECS service, a DynamoDB table…), run `terraform apply`, and Terraform creates/updates AWS to match.

To know what's currently deployed (so it can compute the diff on the next apply), Terraform keeps a **state file** — by default, `terraform.tfstate` on your laptop. Hold that thought.

### 0.2 What goes wrong when a team tries to use Terraform?

The state-file-on-your-laptop default breaks the moment a second person joins. Three escalating failure modes:

1. **Stage 1 — state on one laptop. (Worst)**
   > Alice writes Terraform → runs `apply`, deploys an ECS service → her laptop now holds the only copy of `terraform.tfstate`.\
   > \
   > ✘ **_Problem:_** Bob has no idea what's deployed → if he runs `apply` from his copy, Terraform thinks nothing exists yet and tries to create everything a second time.
2. **Stage 2 — push code + state to GitHub. (Better, but not working)**
   > Alice commits `terraform.tfstate` to the repo → Bob pulls.\
   > \
   > ✘ Better — until Alice forgets to commit after an apply, or someone resolves a merge conflict in the state file by hand. Now the state silently lies about reality.
3. **Stage 3 — race condition.**
   > Even if both have the latest state, Alice and Bob both hit `terraform apply` at the same time. They each compute a plan against the same starting point, both write to AWS, and one overwrites the other.\
   > \
   > ✘ Now nobody knows what's actually deployed. **This is a race condition.**

The takeaway: for a team to collaborate safely on the same AWS environment, you need

- (a) **one shared copy of the state file** and
- (b) **a lock that prevents two applies from running at once**.

### 0.3 The workflow: GitHub PR → GitHub Actions → S3 + DynamoDB

This is the standard answer in the AWS world, and it's what this repo is wired up for:

| Piece                   | Job                                                                                                                                                  |
| ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| **GitHub Pull Request** | The only way to propose an infrastructure change. Every change is reviewable.                                                                        |
| **GitHub Actions**      | The only thing that runs `terraform apply`. No one applies from their laptop. This guarantees there's exactly one path that touches AWS.             |
| **S3 bucket**           | Stores `terraform.tfstate` — one shared copy, durable, versioned.                                                                                    |
| **DynamoDB lock table** | Holds a lock row while an apply is running. If two applies start at once, the second one waits for the first to release the lock. **No more races.** |

You will use this exact pattern with your real client. TeamGram is the safe, low-stakes place to learn it.

---

## 1. The Exercise in One Paragraph

In your capstone you will build real systems for real clients on shared AWS infrastructure (each team has its own AWS Innovation Sandbox lease for the semester). Before you touch your client's project, every team member needs to be fluent in:

1. How to get a code change from your laptop into shared cloud infrastructure **without breaking your teammates' work**.
2. What "Infrastructure as Code" actually feels like.
3. Why we use **GitHub Actions** as the _only_ path that deploys to the team's sandbox.
4. The basic AWS building blocks (ALB, ECS, ECR, SQS, Lambda, DynamoDB, S3) and how they fit together.

TeamGram is a tiny throwaway app whose only purpose is to give you that muscle memory.

---

## 2. What You're Going to Build (or rather, _deploy_)

A "TeamGram" is your team's social wall. Each teammate posts a short self-intro:

- Name
- Nick Name
- Hobby
- Future career dream

Posts show up on a webpage hosted on a public AWS load balancer in your team's sandbox account. Every team gets their own wall.

### The architecture you are deploying

```
                                 Internet
                                    │
                                    ▼
                          ┌───────────────────┐
                          │   Application     │
                          │   Load Balancer   │   ← Security Group: only
                          │       (ALB)       │     allowlisted IPs get in
                          └─────────┬─────────┘
                                    │
                                    ▼
                          ┌───────────────────┐
                          │  ECS Fargate      │   ← Container pulled
                          │  (the API server) │     from ECR
                          └────┬─────────┬────┘
                               │         │
                       GET /   │         │  POST /intro
                  read wall    │         │  enqueue post
                               ▼         ▼
                          ┌─────────┐  ┌─────────┐
                          │DynamoDB │  │  SQS    │
                          │ (posts) │  │ (queue) │
                          └─────────┘  └────┬────┘
                                ▲           │
                                │           ▼
                                │      ┌─────────┐
                                └──────│ Lambda  │  consumes queue,
                                       │consumer │  validates,
                                       └─────────┘  writes to DynamoDB

       S3 ─── Terraform state file (shared by your team)
       DynamoDB lock table ─── prevents two teammates applying at once
```

### Why each service is here (read this carefully — this is the lesson)

| Service         | Why it's in the architecture                                                   | Where you'll see this in your capstone                       |
| --------------- | ------------------------------------------------------------------------------ | ------------------------------------------------------------ |
| **ALB**         | Public entry point, terminates HTTPS, routes traffic                           | Almost every web system you build                            |
| **ECS Fargate** | Runs your containerized app without you managing servers                       | The most common way to host backend services on AWS          |
| **ECR**         | Private Docker registry — ECS pulls images from here                           | Anywhere you ship a container                                |
| **SQS**         | Decouples request from work. POST returns instantly; processing happens later. | Anytime "this is slow, do it in the background"              |
| **Lambda**      | Serverless function — runs only when there's work                              | Background jobs, glue code, event handlers                   |
| **DynamoDB**    | Fast key-value store, no schema migrations to manage                           | When you need durable state but don't want to run a database |
| **S3**          | Object storage. Here it stores the Terraform state file.                       | Static assets, backups, data lakes, ML datasets              |

**You don't have to write any of this code.** It's already written. Your job is to _read_ it, understand it, and ship a one-line change through the team workflow.

### Repo layout

```
teamgram/
├── bootstrap.sh                 ONE-time setup script
├── bootstrap-destroy.sh         tears down what bootstrap.sh created
├── bootstrap/
│   └── iam-trust-policy.json.tmpl
├── app/                         Flask API (containerized, on ECS)
│   ├── app.py
│   ├── requirements.txt
│   └── Dockerfile
├── lambda/                      SQS consumer
│   ├── handler.py
│   └── requirements.txt
├── terraform/
│   ├── backend.tf               partial backend (filled by backend.hcl)
│   ├── providers.tf
│   ├── variables.tf
│   ├── terraform.tfvars         ← THE FILE STUDENTS EDIT
│   ├── network.tf               VPC + subnets
│   ├── alb.tf                   ALB + the IP allowlist SG
│   ├── ecs.tf                   Fargate service + IAM
│   ├── sqs_lambda.tf            queue + Lambda + event mapping
│   ├── dynamodb.tf
│   └── outputs.tf
└── .github/workflows/
    ├── plan.yml                 terraform plan on PR
    ├── apply.yml                build image + terraform apply on merge
    └── destroy.yml              manual teardown (see §10)
```

---

## 3. Your Task

You will edit **one line** in a Terraform variables file to add your home IP address to the ALB security group's allowlist. Until your PR is merged, the load balancer will refuse your traffic. After your PR is merged, you can submit your self-intro and see it appear on the wall.

> **The point:** your one-line PR is what _literally opens the door_ on shared infrastructure. That is collaboration on AWS in a nutshell.

### What you'll change

In `terraform/terraform.tfvars`, find the `allowed_ips` list:

```hcl
allowed_ips = [
  "203.0.113.10/32",   # instructor
  # add your /32 below, with a comment containing your name
]
```

Add your IP:

```hcl
allowed_ips = [
  "203.0.113.10/32",   # instructor
  "198.51.100.42/32",  # Hao Wu
]
```

That's it. One line.

---

## 4. The Full Workflow (Step by Step)

### Prerequisites

The prereqs differ depending on whether you're the **team lead doing the day-1 setup** or **a teammate joining after bootstrap is done**.

#### A. Team lead — day-1 setup (do this once per team)

You only need to do this **once**, on the first day, before anyone else can use the repo. Plan ~15 minutes.

##### A.1 Install the required tools

| Tool             | macOS                                 | Ubuntu / Debian                                                                                     | Notes                                                         |
| ---------------- | ------------------------------------- | --------------------------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| **GitHub CLI**   | `brew install gh`                     | [docs.github.com/gh](https://github.com/cli/cli/blob/trunk/docs/install_linux.md)                   | needed by `bootstrap.sh`                                      |
| **AWS CLI v2**   | `brew install awscli`                 | [aws.amazon.com/cli](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | needed by `bootstrap.sh` and CI parity                        |
| **Terraform**    | `brew install terraform`              | [developer.hashicorp.com/terraform/install](https://developer.hashicorp.com/terraform/install)      | for local plans (optional)                                    |
| **jq**           | `brew install jq`                     | `sudo apt install jq`                                                                               | needed by `bootstrap.sh`                                      |
| **Docker**       | already installed if you have Desktop | [docs.docker.com/engine/install](https://docs.docker.com/engine/install/)                           | only required if you build images locally; CI builds them too |
| **git, openssl** | preinstalled                          | preinstalled                                                                                        | —                                                             |

Verify everything is on your `$PATH`:

```bash
gh --version && aws --version && terraform --version && jq --version
```

##### A.2 Authenticate `gh` (HTTPS)

```bash
gh auth login
```

Answer the prompts:

1. **What account do you want to log into?** → `GitHub.com`
2. **What is your preferred protocol for Git operations on this host?** → `HTTPS`
3. **Authenticate Git with your GitHub credentials?** → `Yes`
4. **How would you like to authenticate GitHub CLI?** → `Login with a web browser`

`gh` prints an 8-character device code (e.g. `XXXX-XXXX`). Press Enter — your browser opens to `https://github.com/login/device`. Paste the code, sign in to the GitHub account that owns your team's repo, click "Authorize github". Back in the terminal you should see:

```
✓ Authentication complete.
✓ Logged in as <your-github-username>
```

Confirm with:

```bash
gh auth status
```

##### A.3 Get AWS credentials from your sandbox lease and export them

Each team's AWS Innovation Sandbox lease provides **temporary** AWS credentials (typically valid for a few hours). To get them:

1. Open the AWS Innovation Sandbox portal your instructor shared with your team.
2. Click into your team's lease.
3. Click **"Access Key"** (the button that shows command-line credentials).
4. The portal shows a block that looks like:

```bash
export AWS_ACCESS_KEY_ID="ASIA..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_SESSION_TOKEN="..."
```

5. **Copy the entire block and paste it directly into your terminal.** That sets the three env vars in your current shell session.

6. Verify the credentials are working and you're pointing at the right account:

```bash
aws sts get-caller-identity
```

You should see your team's sandbox account ID. If you instead see your personal AWS account, your credentials weren't exported (or were exported in a different shell).

> ⚠️ These credentials **expire** (often within 1–4 hours). If `bootstrap.sh` later complains "the security token included in the request is expired," return to the portal and re-export a fresh block.

##### A.4 Create your team's repo from the template and clone it

```bash
gh repo create <your-org>/<team-name>-teamgram \
  --template wuhao2809/aws-team-playbook \
  --private --clone

cd <team-name>-teamgram
```

##### A.5 Run `./bootstrap.sh`

```bash
./bootstrap.sh
```

The script prints what it's about to do and asks you to type `yes` to continue. It then creates (in your sandbox account):

- The S3 state bucket and DynamoDB lock table from §0.3
- An ECR repo for the app container
- A GitHub OIDC identity provider
- An IAM role (`teamgram-gha-deploy`) that GitHub Actions assumes — see §7 for why this is keyless
- Three GitHub Actions secrets pointing CI at all of the above

It's idempotent — re-running it is safe.

##### A.6 Seed the allowlist with your own IP and push

```bash
curl -s https://checkip.amazonaws.com/   # copy this IP

# edit terraform/terraform.tfvars, add a line like:
#   "<your-ip>/32",  # <your-name>

git add terraform/terraform.tfvars
git commit -m "Seed allowlist with team-lead IP"
git push origin main
```

Watch the **Actions → terraform-apply** run. When it succeeds, the last step prints the ALB URL. Open it — you should see an empty wall. Pin that URL in your team's chat.

#### B. Every other teammate (after bootstrap is done)

1. You have a GitHub account and have been added to your team's repo as a collaborator. (Your team lead created it from [`wuhao2809/aws-team-playbook`](https://github.com/wuhao2809/aws-team-playbook) and ran `./bootstrap.sh`.)
2. You have `git` installed.
3. You **do not** need the AWS CLI, Terraform, Docker, or `gh` locally. GitHub Actions runs everything.

### Step 1 — Find your public IP

Open https://checkip.amazonaws.com/ in your browser. Copy the IP it shows you. That is your **public** IP — the one AWS sees, not your laptop's `192.168.x.x`.

> ⚠️ Your home/coffee-shop IP can change. If your post stops working tomorrow, your IP changed — open another PR.

### Step 2 — Clone your team's repo and create a branch

```bash
git clone git@github.com:<your-org>/<your-team-repo>.git
cd <your-team-repo>
git checkout -b add-ip-<your-name>
```

Branch naming: `add-ip-<your-name>` so reviewers know what your PR does at a glance.

### Step 3 — Edit `terraform/terraform.tfvars`

Add a single line to the `allowed_ips` list with your IP in `/32` notation and a comment with your name. Example:

```hcl
"198.51.100.42/32",  # Hao Wu — Team 3
```

> **What is `/32`?** It means "exactly this one IP address." A `/24` would mean 256 addresses. We use `/32` so each student opens the door for exactly themselves.

### Step 4 — Commit and push

```bash
git add terraform/terraform.tfvars
git commit -m "Allow Hao Wu's IP for TeamGram"
git push -u origin add-ip-<your-name>
```

### Step 5 — Open a Pull Request

On GitHub, open a PR from your branch into `main`.

What happens automatically:

- **GitHub Actions runs `terraform plan`** and the run output shows the planned change. You should see one line added to a security group ingress rule.
- A teammate reviews and approves.

> **Why a teammate reviews:** in a shared sandbox, _every_ infra change can affect everyone on your team. Code review is the safety net.

### Step 6 — Merge

Once approved, merge the PR. **GitHub Actions runs `terraform apply` against your team's sandbox account.** Watch the Actions tab — the apply takes ~1–2 minutes.

> **Why only GitHub Actions deploys:** because the only way to know "what is currently deployed" is if there's exactly one path that deploys. If teammates run `terraform apply` from their laptops, the shared state turns into chaos within a day. **Never run `terraform apply` locally against the team sandbox.** (It's fine to run `terraform plan` locally for debugging.)

### Step 7 — Post your self-intro

After the apply finishes, visit your team's wall. The URL is the last line of the `terraform-apply` job log — look for the "Show wall URL" step. It looks like:

```
http://teamgram-alb-<...>.us-west-2.elb.amazonaws.com/
```

Your team lead probably also pinned it in your team Slack/Teams channel.

If your IP is allowlisted, you'll see the wall. Click "Post" and fill in your intro. Refresh — your card should appear.

If you get a connection timeout, it means either (a) your IP didn't make it into the allowlist (re-read your PR), or (b) your IP changed since you submitted (run `checkip.amazonaws.com` again).

---

## 5. What Happens Behind the Scenes (the part you should _read_, not write)

### When you POST your intro

1. Your browser sends `POST /intro` to the ALB.
2. ALB checks its security group → your IP is in the allowlist → traffic forwarded to ECS.
3. The ECS container receives the POST, validates the form, and **drops a message onto SQS**. It then immediately responds `200 OK` to your browser.
4. Lambda is configured as the SQS consumer. AWS invokes it with your message.
5. Lambda parses the message, does light sanitization (strip newlines, cap each field's length), and writes a row to DynamoDB.
6. Next time someone loads the wall, ECS reads from DynamoDB and renders all the cards — including yours.

### Why the SQS + Lambda hop?

You could have ECS write to DynamoDB directly. We added SQS + Lambda to demonstrate **asynchronous processing** — the most important pattern in distributed systems for those of you who haven't taken 7610/distributed systems yet.

The benefits become real when:

- DynamoDB is briefly slow → the user's POST still returns instantly because the work sits safely in SQS.
- A bug in the Lambda → SQS retries automatically. No data loss.
- Traffic spikes → SQS absorbs the spike; Lambda scales out to drain it.

This is the pattern you will reach for again and again in your capstone whenever someone says _"this should happen in the background."_

### Where Terraform state lives

In an S3 bucket, with a DynamoDB table acting as a lock. **If two teammates try to `terraform apply` at the same time, one of them will be blocked by the lock.** That is the exact mechanism that prevents shared-account chaos. Read `terraform/backend.tf` to see how it's wired up.

---

## 6. The Collaboration Rules (Read This Twice)

These rules apply to TeamGram and to your client project:

1. **Never run `terraform apply` from your laptop against the team sandbox.** Only GitHub Actions does that. Local `terraform plan` is fine for debugging.
2. **Every infra change goes through a PR.** No exceptions, even for one-line changes. Your teammates need a chance to spot mistakes.
3. **State is sacred.** Never edit `terraform.tfstate` by hand. Never delete the state bucket or the lock table. If something looks wrong, ask before fixing.
4. **Don't widen IAM blindly.** The deploy role currently has `AdministratorAccess` because the sandbox is a contained blast radius. For your client's real account, you will scope this down — start thinking now about _which_ permissions your stack actually needs.
5. **Don't commit secrets.** No AWS keys, no client API tokens, no `.env` files. The deploy role is OIDC-based, so CI doesn't need any keys to be stored as secrets.

---

## 7. Security Note (One Paragraph, Important)

Your PR will put your home IP address into the git history of your team's repo. **For this exercise, that is fine** — the repo is private to your team, the AWS account is an ephemeral sandbox lease, and the IP exposure is harmless. **In a real production repo, you would never do this.** Production allowlists live in a private parameter store (AWS Systems Manager Parameter Store, Secrets Manager, or a non-public Terraform variables file) — not in git. When you build for your client, ask your instructor where allowlist data should live.

Also worth knowing: **no AWS access keys are ever stored in GitHub.** The `AWS_DEPLOY_ROLE_ARN` secret is just an ARN — a public identifier. CI uses GitHub's OIDC token to assume the IAM role at runtime; AWS hands back temporary credentials that live for the duration of the job and then vanish. If a leaked ARN ever made it into a screenshot, nothing bad happens — assuming the role requires a verifiable token from your specific repo's CI.

---

## 8. Troubleshooting

> Embrace the new era, ask your AI!

---

## 9. After You're Done

Once your card is on the wall, you can(optional):

1. **Read the codebase.** Especially:
   - `terraform/alb.tf` — the security group your IP just got added to.
   - `terraform/ecs.tf` — how a containerized service is wired up (cluster, task definition, service, IAM).
   - `terraform/sqs_lambda.tf` — how SQS triggers Lambda via an event source mapping.
   - `terraform/backend.tf` and `bootstrap.sh` — how the S3 + DynamoDB state backend you read about in §0.3 actually gets created.
   - `app/app.py` — the Flask API. ~100 lines.
   - `lambda/handler.py` — the SQS consumer. ~30 lines.
   - `.github/workflows/` — the CI/CD pipeline that just deployed your change.
2. **Sketch the diagram from §2 from memory.** If you can, you understand it.
3. **Talk to your team** about which of these services map onto your client project — and which ones are overkill.

---

## 10. Tearing It Down

When you're done with TeamGram (or whenever you want to start fresh), use the **terraform-destroy** workflow. Anyone with write access to the repo can trigger it.

### How to run it

1. Go to the repo's **Actions** tab.
2. In the left sidebar, click **terraform-destroy**.
3. Click **Run workflow** (top right).
4. Fill in the inputs:
   - **`confirm`** — type `DESTROY` (uppercase, exactly). Anything else aborts.
   - **`include_bootstrap`** — leave unchecked for "just nuke the app stack"; check it for "also delete the S3 state bucket, DynamoDB lock, ECR repo, and IAM deploy role."
5. Click **Run workflow**.

The workflow runs in this order:

1. `terraform destroy` against the app stack — tears down ALB, ECS service + cluster + task def, SQS, Lambda, the posts DynamoDB table, VPC, security groups, app IAM roles, CloudWatch logs.
2. (Only if `include_bootstrap` is checked) `bootstrap-destroy.sh` — empties and deletes the S3 state bucket, deletes the DynamoDB lock table, deletes the ECR repo (and all images), and deletes the IAM deploy role.

### When to use which

| Scenario                           | `include_bootstrap`?                                                     |
| ---------------------------------- | ------------------------------------------------------------------------ |
| Resetting between experiments      | **No** — keeps CI working; just re-run a push to redeploy                |
| Free up sandbox quota mid-semester | **No**                                                                   |
| End-of-semester cleanup            | **Yes**                                                                  |
| Sandbox lease about to expire      | Either — AWS will tear everything down automatically when the lease ends |

### What survives even with `include_bootstrap: true`

- The **GitHub OIDC identity provider** in your AWS account — it's account-scoped, harmless, and reusable if you re-bootstrap.
- The three **GitHub repo secrets** (`AWS_DEPLOY_ROLE_ARN`, `TF_STATE_BUCKET`, `TF_LOCK_TABLE`). They now point at deleted resources, so any future workflow run will fail at the `configure-aws-credentials` step until someone re-runs `./bootstrap.sh` locally. Either delete the secrets manually or just re-run bootstrap to overwrite them.

> ⚠️ If you check `include_bootstrap`, the **next push to `main` will fail CI** until someone runs `./bootstrap.sh` again. That's by design — bootstrap teardown is meant for end-of-life cleanup, not day-to-day resets.

---

## 11. FAQ

**Q: Why doesn't each _student_ get their own AWS account?**
A: Your team has one shared sandbox lease, not six. The skill you need to develop is _collaborating safely on a shared account with your teammates_ — that's the actual situation you'll be in with your client.

**Q: My IP is IPv6. Can I use that?**
A: For this exercise, find your IPv4 from `checkip.amazonaws.com`. The allowlist is configured for IPv4.

**Q: Why does only the team lead run `bootstrap.sh`? Can I run it too?**
A: It's idempotent — re-running it is safe. But re-running it doesn't _do_ anything new, since the resources already exist. There's no reason to run it a second time unless something got deleted.

**Q: My sandbox credentials expired in the middle of `bootstrap.sh`. What now?**
A: Re-export a fresh block from the Innovation Sandbox portal (§4-A.3), then re-run `./bootstrap.sh`. It picks up where it left off.

**Q: Cost?**
A: Roughly $5–15/month idle, mostly ALB hours and one Fargate task. Sandbox credits cover it.

---

**You're done when:** your card is on your team's wall, you can explain to a teammate why we have SQS + Lambda in the architecture, and you can answer "what would happen if two teammates merged their PRs at the exact same second?"

(Answer: one apply gets the DynamoDB lock and runs; the other waits for the lock to release, then runs against the now-updated state. No race. That is the whole point of §0.3.)
