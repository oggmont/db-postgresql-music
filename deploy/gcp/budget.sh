#!/bin/bash
# A ~$1 monthly budget on the Runlist project that emails the billing account's admins at the
# first cent (1%), 50% and 100%, both for actual and forecast spend. Budgets only alert; they
# never stop services. Expected spend is $0 (see README.md).
set -euo pipefail

PROJECT_ID=${PROJECT_ID:-runlist-514701}
BILLING_ACCOUNT=$(gcloud billing projects describe "$PROJECT_ID" --format 'value(billingAccountName)' | sed 's|billingAccounts/||')
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format 'value(projectNumber)')
# A budget must use the billing account's currency (PLN for this account): about $1 by default.
CURRENCY=$(gcloud billing accounts describe "$BILLING_ACCOUNT" --format 'value(currencyCode)')
AMOUNT=${AMOUNT:-$([ "$CURRENCY" = USD ] && echo 1 || echo 4)}

if gcloud billing budgets list --billing-account "$BILLING_ACCOUNT" --format 'value(displayName)' | grep -qx runlist-free-tier; then
  echo "Budget runlist-free-tier already exists"
  exit 0
fi

gcloud billing budgets create --billing-account "$BILLING_ACCOUNT" \
  --display-name runlist-free-tier \
  --budget-amount "$AMOUNT$CURRENCY" \
  --filter-projects "projects/$PROJECT_NUMBER" \
  --calendar-period month \
  --threshold-rule percent=0.01 \
  --threshold-rule percent=0.5 \
  --threshold-rule percent=1.0 \
  --threshold-rule percent=1.0,basis=forecasted-spend
