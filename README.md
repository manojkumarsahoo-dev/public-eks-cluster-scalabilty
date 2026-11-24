# EKS 1.35 Autoscaling Lab using GitHub Actions
### Create infra, deploy, test pod scaling (HPA) and node scaling (Cluster Autoscaler), then destroy

**What you will build**
- An Amazon EKS 1.35 cluster named `manoj` in `us-east-1` (N. Virginia), with 2 public `t3.medium` worker nodes (can grow to 6)
- nginx app, metrics-server, Horizontal Pod Autoscaler (HPA, 3 to 20 pods at 50% CPU)
- Cluster Autoscaler that adds/removes EC2 nodes when pods cannot fit
- Everything created, deployed, tested and deleted from GitHub Actions buttons

**What you need on your laptop:** a browser, `git`, and a GitHub account. Nothing else (no eksctl or kubectl needed, GitHub does it).
**What you need on AWS:** an AWS account where you can create an IAM user, with enough EC2 vCPU quota for 6 x t3.medium (12 vCPU) in us-east-1.

---

## Folder layout

```
.github/workflows/
  01-create-cluster.yml    creates the EKS cluster
  02-deploy-apps.yml       installs metrics-server, nginx, HPA, Cluster Autoscaler
  03-scale-tests.yml       start/stop load tests and show status
  04-destroy-cluster.yml   deletes everything
infra/cluster.yaml         cluster definition (name, region, node group)
k8s/                       nginx, HPA, load-generator, node-scale-test manifests
scripts/setup-cluster-autoscaler.sh
```
The hidden folder must be named exactly `.github`. If it is spelled `.gihub`, GitHub never shows the workflows.

---

# PART A: One-time setup

## A1. Create an IAM user and access key in AWS
1. Sign in to the AWS Console and open **IAM** (search "IAM").
2. Left menu: **Users** > **Create user**.
3. User name: `github-eks-lab` > **Next**.
4. Choose **Attach policies directly**, search `AdministratorAccess`, tick it > **Next** > **Create user**.
   (The lab needs broad rights because eksctl creates a VPC, IAM roles, EC2 instances and CloudFormation stacks. Delete this user after the lab.)
5. Click the new user `github-eks-lab` > tab **Security credentials** > **Create access key**.
6. Use case: choose **Third-party service** (or **Other**), tick the confirmation box > **Next** > **Create access key**.
7. Copy the **Access key ID** and **Secret access key** now, or click **Download .csv file**. The secret is shown only once.
8. Never paste these keys into any file in the repo or into chat.

## A2. Create the GitHub repository
1. GitHub > **New repository**.
2. Name: `eks-scaling-lab`. Choose **Private** (recommended). Do NOT tick "Add a README". > **Create repository**.

## A3. Push the project files to GitHub
Unzip `eks-scaling-lab.zip`, open a terminal inside the unzipped `eks-scaling-lab` folder, and run (replace `YOUR-USERNAME`):

```bash
git init
git add .
git commit -m "EKS autoscaling lab"
git branch -M main
git remote add origin https://github.com/YOUR-USERNAME/eks-scaling-lab.git
git push -u origin main
```
`git add .` includes the hidden `.github` folder. Avoid drag-and-drop upload in the browser, because it often skips hidden folders.

Check: on the repo page you should see folders `.github`, `infra`, `k8s`, `scripts` and this README.

## A4. Add the AWS keys as GitHub Secrets
1. In your repo: **Settings** > **Secrets and variables** > **Actions**.
2. Click **New repository secret**.
   - Name: `AWS_ACCESS_KEY_ID`  Secret: the access key ID > **Add secret**
3. Click **New repository secret** again.
   - Name: `AWS_SECRET_ACCESS_KEY`  Secret: the secret access key > **Add secret**
4. Names must match exactly (capital letters, underscores). You should now see both listed under "Repository secrets".

## A5. Make sure Actions is enabled
Repo > **Actions** tab. If you see a button "I understand my workflows, go ahead and enable them", click it. You should see the four workflows in the left sidebar.

---

# PART B: Create the infrastructure

## How to run any workflow (same every time)
1. Repo > **Actions** tab.
2. In the left sidebar click the workflow name.
3. Click **Run workflow** (right side), keep branch `main`, fill the input if there is one, click the green **Run workflow** button.
4. Refresh the page; click the new run to watch the logs. A green tick means success.

## B1. Run workflow `01 - Create EKS cluster`
- Takes about **15-20 minutes**.
- The first step "Check AWS login works" must print your account ID. If it fails, fix the secrets (see Troubleshooting).
- Success: the last step "Verify nodes" shows **2 nodes with STATUS Ready** and an EXTERNAL-IP.

Optional AWS Console checks (region **US East (N. Virginia) us-east-1**): **EKS > Clusters** shows `manoj` Active; **EC2 > Instances** shows 2 running t3.medium; **CloudFormation** shows stacks starting with `eksctl-manoj-`.

---

# PART C: Deploy the applications

## C1. Run workflow `02 - Deploy metrics-server, nginx, HPA, Cluster Autoscaler`
- Takes about 3-5 minutes.
- Success: the last step "Show state" shows:
  - nodes `Ready`
  - pods `nginx-...` (3), `metrics-server-...`, `cluster-autoscaler-...` all `Running`
  - HPA `nginx` with TARGETS like `0%/50%` (not `<unknown>`), MINPODS 3, MAXPODS 20
- Also, in the "Install Cluster Autoscaler" step the output includes a line with `--node-group-auto-discovery=...manoj`. That confirms the cluster name is set.

If TARGETS shows `<unknown>`, wait 2 minutes and check again with workflow 03 > `status`.

---

# PART D: Testing

All tests use workflow **`03 - Scaling tests`**. Choose an action in the dropdown. Each run waits 45 seconds, then prints nodes, HPA, nginx pods and the autoscaler logs. Run `status` repeatedly to watch things change.

## Test 1: Pod scaling with HPA
1. Run 03 with **`status`**. Note the baseline: nginx pods = 3, HPA about `0%/50%`, nodes = 2. Screenshot it.
2. Run 03 with **`hpa-load-start`**. This starts 3 load-generator pods hammering nginx.
3. Wait 2-3 minutes, run **`status`** again, repeat a few times.
   - Expected: HPA TARGETS goes well above `50%` and REPLICAS increases above 3 (up to 20). Screenshot it.
   - Some nginx pods may show `Pending` if the nodes are full. That is normal and leads into Test 2.
4. Run 03 with **`hpa-load-stop`**.
5. Wait 3-5 minutes, run **`status`**. Expected: CPU drops and REPLICAS fall back toward 3.

## Test 2: Node scaling with Cluster Autoscaler
Do this after Test 1 has scaled back down (load stopped).
1. Run 03 with **`node-test-start`**. This creates 10 pods requesting 500m CPU each (5 vCPU total), more than 2 nodes can hold.
2. In the output you should see node-scale-test pods `Pending`, and autoscaler log lines mentioning scale-up. Screenshot it.
3. Wait 3-5 minutes and run **`status`** again. Expected: **nodes increase from 2 to 3 or more**, and Pending pods become Running.
   - AWS Console check: **EC2 > Auto Scaling groups** > the `eksctl-manoj-...` group: Desired capacity increased.
4. Run 03 with **`node-test-stop`**.
5. Wait about **10-15 minutes** (Cluster Autoscaler waits ~10 minutes before removing unneeded nodes), then run **`status`**. Expected: nodes back to **2**.

---

# PART E: Destroy everything (do not skip)

The nodes and the EKS control plane are billed hourly while they exist (roughly $0.10 per hour for the control plane plus the EC2 cost of the nodes; check current AWS pricing).

1. Run workflow **`04 - Destroy EKS cluster`**, and in the input box type exactly `manoj` > Run workflow.
2. Takes 10-15 minutes. Success: green tick.
3. Verify in AWS Console (us-east-1): EKS has no clusters, EC2 has no running instances, CloudFormation has no `eksctl-manoj-*` stacks.
4. Optional cleanup: IAM > Users > `github-eks-lab` > delete the access key, then delete the user. Delete the two GitHub secrets if you do not need them.

---

# Lab log checklist (screenshots)
- [ ] Workflow 01 run: green tick and "Verify nodes" output
- [ ] Workflow 02 run: "Show state" output
- [ ] Test 1: baseline `status`, `status` during load (HPA above 50%, more pods), `status` after scale-down
- [ ] Test 2: Pending pods plus scale-up log, nodes increased, nodes back to 2
- [ ] AWS EC2 Auto Scaling group desired capacity before/after
- [ ] Workflow 04 run: green tick

---

# Troubleshooting

| Problem | Fix |
|---|---|
| No workflows shown in Actions tab | Folder must be `.github/workflows` on the `main` branch; push again |
| "Credentials could not be loaded" | Secret names must be exactly `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`; re-create them |
| `InvalidClientTokenId` / `SignatureDoesNotMatch` | Wrong or mistyped key; create a new access key and update the secrets |
| Workflow 01 fails during creation | Open the failed step log; also check CloudFormation events in us-east-1. Common causes: vCPU quota, EKS 1.35 not yet available, missing permissions. If a half-created stack remains, run workflow 04 before retrying |
| "You must be logged in to the server" in 02/03 | A different IAM user's keys were used than in workflow 01. Use the same keys |
| Workflow 02 error `Duplicate value: "https"` / `field is immutable` for metrics-server | The cluster already has metrics-server preinstalled. Fixed in the current workflow 02 (it skips the install if present). Replace your `02-deploy-apps.yml` with the new one and re-run. Workflow 02 now also auto-repairs a broken metrics API |
| HPA TARGETS `<unknown>` | metrics-server not ready; wait 2 minutes and run `status` |
| Pods Pending but nodes do not increase | Already at 6 nodes, or the cluster-autoscaler pod is not Running; check `status` logs |
| Autoscaler log `an AWS region is required` or credentials errors | The pod cannot use the node's metadata service. Workflow 02 gives it permissions through EKS Pod Identity (IAM role `manoj-cluster-autoscaler-role`); re-run workflow 02 |
| Autoscaler logs show AccessDenied | `autoScaler: true` missing in `infra/cluster.yaml` or the node group was created without it |
| Nodes do not scale down | Wait the full 10-15 minutes after `node-test-stop` and `hpa-load-stop` |
| Workflow 04 skipped | The confirm input must be exactly `manoj` |
| Two workflows at once | They share a queue; wait for the running one to finish |

# Changing names or region
Edit `CLUSTER_NAME` and `AWS_REGION` at the top of all four workflow files, and `name`, `region` and the `k8s.io/cluster-autoscaler/<name>` tag in `infra/cluster.yaml`.
