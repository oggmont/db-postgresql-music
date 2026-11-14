#!/bin/bash
# One-time setup of the Runlist infrastructure on Google Cloud (UI + API + this database),
# sized to stay inside the free tier. See README.md in this directory for the design and costs.
#
#   gcloud auth login && bash deploy/gcp/setup.sh
#
# Safe to re-run: steps that already exist are skipped. After it, the GitHub Actions workflows
# of the three repos build and deploy everything (keyless, through Workload Identity Federation).
set -euo pipefail

PROJECT_ID=${PROJECT_ID:-runlist-514701}
REGION=${REGION:-us-central1}  # free tier: us-central1, us-east1 or us-west1
ZONE=${ZONE:-us-central1-a}
GITHUB_OWNER=${GITHUB_OWNER:-oggmont}
REPOS=(ui-react-runlist restapi-spring-runlist db-postgresql-runlist)
DB_IP=10.128.0.10 # inside the default subnet of us-central1 (10.128.0.0/20)
VM=runlist-db
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)

g() { gcloud --project "$PROJECT_ID" "$@"; }
exists() { "$@" > /dev/null 2>&1; }
step() { printf '\n== %s\n' "$*"; }

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format 'value(projectNumber)')
API_SA=runlist-api@$PROJECT_ID.iam.gserviceaccount.com
UI_SA=runlist-ui@$PROJECT_ID.iam.gserviceaccount.com
DEPLOYER=github-deployer@$PROJECT_ID.iam.gserviceaccount.com

step "APIs (no Cloud Build, Cloud SQL, Container Scanning or other billed APIs)"
g services enable compute.googleapis.com run.googleapis.com artifactregistry.googleapis.com \
  secretmanager.googleapis.com iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com \
  cloudresourcemanager.googleapis.com iap.googleapis.com oslogin.googleapis.com billingbudgets.googleapis.com

step "Network: SSH only through IAP, no RDP, Private Google Access, fixed DB address"
for rule in default-allow-rdp default-allow-ssh; do
  if exists g compute firewall-rules describe "$rule"; then g compute firewall-rules delete "$rule" --quiet; fi
done
exists g compute firewall-rules describe allow-ssh-from-iap ||
  g compute firewall-rules create allow-ssh-from-iap --network default --direction INGRESS \
    --allow tcp:22 --source-ranges 35.235.240.0/20 \
    --description "SSH only through Identity-Aware Proxy (gcloud compute ssh --tunnel-through-iap)"
# PostgreSQL is reachable through default-allow-internal (10.128.0.0/9), which covers the
# Cloud Run instances' Direct VPC egress addresses. Nothing is open to the internet.
g compute networks subnets update default --region "$REGION" --enable-private-ip-google-access
exists g compute addresses describe runlist-db-internal --region "$REGION" ||
  g compute addresses create runlist-db-internal --region "$REGION" --subnet default --addresses "$DB_IP" \
    --description "Fixed internal IP of the Postgres VM (Cloud Run connects here)"

step "Secrets (generated here, never printed)"
create_secret() {
  exists g secrets describe "$1" || printf '%s' "$2" | g secrets create "$1" --replication-policy automatic --data-file=-
}
create_secret runlist-db-password "$(openssl rand -hex 24)"
create_secret runlist-jwt-secret "$(openssl rand -base64 48 | tr -d '\n')"
create_secret runlist-admin-password "$(openssl rand -base64 18 | tr -d '\n/+=' | cut -c1-20)"

step "Database VM: free e2-micro, Container-Optimized OS, 30 GB standard disk"
if ! exists g compute instances describe "$VM" --zone "$ZONE"; then
  # Created with a temporary external IP so it can pull postgres:17-alpine from Docker Hub once.
  g compute instances create "$VM" --zone "$ZONE" \
    --machine-type e2-micro --image-family cos-stable --image-project cos-cloud \
    --boot-disk-size 30GB --boot-disk-type pd-standard --boot-disk-auto-delete \
    --subnet default --private-network-ip "$DB_IP" \
    --no-service-account --no-scopes \
    --metadata enable-oslogin=TRUE,startup-script='#! /bin/bash
[ -f /var/lib/runlist/runlist-db.sh ] && bash /var/lib/runlist/runlist-db.sh start || true' \
    --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring \
    --labels app=runlist,role=db \
    --description "Runlist PostgreSQL 17 (Docker). Free tier e2-micro; managed by db-postgresql-runlist/deploy/gcp"
  sleep 30

  tmp=$(mktemp -d)
  mkdir -p "$tmp/seed"
  cp -R "$ROOT/db/init" "$ROOT/db/queries" "$tmp/seed/"
  cp "$HERE/runlist-db.sh" "$tmp/seed/"
  COPYFILE_DISABLE=1 tar -C "$tmp" -czf "$tmp/seed.tgz" seed
  g compute scp "$tmp/seed.tgz" "$VM:/tmp/seed.tgz" --zone "$ZONE" --tunnel-through-iap --quiet
  g secrets versions access latest --secret runlist-db-password |
    g compute ssh "$VM" --zone "$ZONE" --tunnel-through-iap --quiet --command '
      set -e
      sudo mkdir -p /var/lib/runlist
      sudo tar --no-same-owner -xzf /tmp/seed.tgz -C /var/lib/runlist
      sudo install -m 755 /var/lib/runlist/seed/runlist-db.sh /var/lib/runlist/runlist-db.sh
      rm /tmp/seed.tgz
      sudo bash /var/lib/runlist/runlist-db.sh install
      sudo bash /var/lib/runlist/runlist-db.sh reset /var/lib/runlist/seed/init
      sudo bash /var/lib/runlist/runlist-db.sh verify'
  rm -rf "$tmp"

  # The image is cached now: drop the external IP (no IPv4 charge, no exposure).
  g compute instances delete-access-config "$VM" --zone "$ZONE" --access-config-name external-nat
fi

step "Artifact Registry (cleanup keeps the 2 newest images of each, under the 0.5 GB free storage)"
if ! exists g artifacts repositories describe runlist --location "$REGION"; then
  g artifacts repositories create runlist --location "$REGION" --repository-format docker \
    --description "Runlist images (UI and API). Cleanup keeps the 2 newest versions to stay under the 0.5 GB free storage."
fi
policy=$(mktemp)
cat > "$policy" << 'EOF'
[
  {"name": "keep-latest-2", "action": {"type": "Keep"}, "mostRecentVersions": {"keepCount": 2}},
  {"name": "delete-older", "action": {"type": "Delete"}, "condition": {"tagState": "ANY", "olderThan": "1h"}}
]
EOF
g artifacts repositories set-cleanup-policies runlist --location "$REGION" --policy "$policy" --no-dry-run > /dev/null
rm -f "$policy"

step "Service accounts and roles"
for sa in "runlist-api:Runlist API (Cloud Run runtime)" "runlist-ui:Runlist UI (Cloud Run runtime)" \
  "github-deployer:GitHub Actions deployer (Workload Identity Federation)"; do
  exists g iam service-accounts describe "${sa%%:*}@$PROJECT_ID.iam.gserviceaccount.com" ||
    g iam service-accounts create "${sa%%:*}" --display-name "${sa#*:}"
done
for s in runlist-db-password runlist-jwt-secret runlist-admin-password; do
  g secrets add-iam-policy-binding "$s" --member "serviceAccount:$API_SA" \
    --role roles/secretmanager.secretAccessor --quiet > /dev/null
done
g artifacts repositories add-iam-policy-binding runlist --location "$REGION" \
  --member "serviceAccount:$DEPLOYER" --role roles/artifactregistry.writer --quiet > /dev/null
# run.developer: deploy Cloud Run (it can only run as runlist-api / runlist-ui, see below).
# compute.viewer: read-only, gcloud compute ssh looks the VM up. SSH itself is limited to the DB
# VM: OS Login admin on that instance only, and the IAP tunnel only to its IP and port 22.
for role in roles/run.developer roles/compute.viewer; do
  g projects add-iam-policy-binding "$PROJECT_ID" --member "serviceAccount:$DEPLOYER" --role "$role" \
    --condition None --quiet > /dev/null
done
g compute instances add-iam-policy-binding "$VM" --zone "$ZONE" --member "serviceAccount:$DEPLOYER" \
  --role roles/compute.osAdminLogin --quiet > /dev/null
g projects add-iam-policy-binding "$PROJECT_ID" --member "serviceAccount:$DEPLOYER" \
  --role roles/iap.tunnelResourceAccessor --quiet \
  --condition "expression=destination.ip == \"$DB_IP\" && destination.port == 22,title=ssh-runlist-db-only,description=IAP SSH tunnel to the runlist-db VM only" > /dev/null
for sa in "$API_SA" "$UI_SA"; do
  g iam service-accounts add-iam-policy-binding "$sa" --member "serviceAccount:$DEPLOYER" \
    --role roles/iam.serviceAccountUser --quiet > /dev/null
done

step "Workload Identity Federation for GitHub Actions (no keys)"
# Only pushes to / manual runs on main of the three repos get a token. The owner is matched by
# its numeric ID, which survives renames and can't be re-registered by someone else.
OWNER_ID=$(curl -fsS "https://api.github.com/users/$GITHUB_OWNER" | sed -n 's/^  "id": \([0-9]*\),$/\1/p')
REPO_LIST=$(printf "'$GITHUB_OWNER/%s', " "${REPOS[@]}")
CONDITION="assertion.repository_owner_id == '$OWNER_ID' && assertion.repository in [${REPO_LIST%, }] && assertion.ref == 'refs/heads/main' && assertion.event_name in ['push', 'workflow_dispatch']"
MAPPING="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner,attribute.repository_owner_id=assertion.repository_owner_id,attribute.ref=assertion.ref"
exists g iam workload-identity-pools describe github --location global ||
  g iam workload-identity-pools create github --location global --display-name "GitHub Actions"
if exists g iam workload-identity-pools providers describe github-oidc --location global --workload-identity-pool github; then
  g iam workload-identity-pools providers update-oidc github-oidc --location global --workload-identity-pool github \
    --attribute-mapping "$MAPPING" --attribute-condition "$CONDITION" > /dev/null
else
  g iam workload-identity-pools providers create-oidc github-oidc --location global --workload-identity-pool github \
    --display-name "GitHub OIDC" --issuer-uri https://token.actions.githubusercontent.com \
    --attribute-mapping "$MAPPING" --attribute-condition "$CONDITION"
fi
for repo in "${REPOS[@]}"; do
  g iam service-accounts add-iam-policy-binding "$DEPLOYER" --role roles/iam.workloadIdentityUser \
    --member "principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github/attribute.repository/$GITHUB_OWNER/$repo" \
    --quiet > /dev/null
done

cat << EOF

Done. Next:
  1. Push restapi-spring-runlist and ui-react-runlist to main (or run their CI/CD workflow):
     they create the Cloud Run services runlist-api and runlist-ui.
  2. Allow unauthenticated calls (once; deploys keep it). The API's ingress is internal, so
     only the UI (through the VPC) can reach it; the UI is the public entry point:
       gcloud run services add-iam-policy-binding runlist-api --region $REGION --member allUsers --role roles/run.invoker
       gcloud run services add-iam-policy-binding runlist-ui  --region $REGION --member allUsers --role roles/run.invoker
  3. Budget alert (alerts only, it doesn't stop anything):
       bash $HERE/budget.sh
EOF
