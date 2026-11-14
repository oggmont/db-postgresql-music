# Runlist on Google Cloud (free tier)

How the three projects run on GCP project `runlist-514701`, region `us-central1`:
[ui-react-runlist](https://github.com/oggmont/ui-react-runlist) (web UI), [restapi-spring-runlist](https://github.com/oggmont/restapi-spring-runlist) (API) and this database. Everything is sized to stay inside the [free tier](https://cloud.google.com/free/docs/free-cloud-features) for light use, such as a few sessions a week.

- **Web UI:** https://runlist-ui-894040023319.us-central1.run.app
- **API:** https://runlist-api-894040023319.us-central1.run.app (Swagger UI at `/swagger-ui.html`)

## Architecture

```
iPhone / browser ──HTTPS──▶ Cloud Run "runlist-ui" (nginx: static bundle, proxies /api)
                                   │ HTTPS, same region
                                   ▼
                            Cloud Run "runlist-api" (Spring Boot, Java 25)
                                   │ Direct VPC egress, private IP only
                                   ▼
                            VM "runlist-db" 10.128.0.10 (e2-micro, Container-Optimized OS)
                              └─ Docker: postgres:17-alpine, data in /var/lib/runlist/pgdata
```

- Both Cloud Run services **scale to zero** and bill per request, so idle weeks cost nothing. The first request after a pause takes a few seconds while the API starts.
- The database VM has **no external IP**. Only the VPC reaches PostgreSQL (`default-allow-internal`). SSH goes through Identity-Aware Proxy with OS Login (`allow-ssh-from-iap`); the default RDP and public-SSH rules were deleted.
- The browser only talks to the UI's origin: nginx forwards `/api` to the API, so no CORS is involved.

## Resources

| Resource | Name | Notes |
|---|---|---|
| Cloud Run service | `runlist-ui` | 1 vCPU, 256 MiB, 0–2 instances, service account `runlist-ui` (no roles) |
| Cloud Run service | `runlist-api` | 1 vCPU, 1 GiB, 0–2 instances, startup CPU boost, Direct VPC egress to `default`, service account `runlist-api` |
| Compute Engine VM | `runlist-db` (`us-central1-a`) | e2-micro, 30 GB standard disk, Shielded VM, no service account, no external IP |
| Internal IP | `runlist-db-internal` | `10.128.0.10`, the API's `DB_HOST` |
| Artifact Registry | `runlist` (Docker) | images `ui` and `api`; a cleanup policy keeps the 2 newest of each |
| Secret Manager | `runlist-db-password`, `runlist-jwt-secret`, `runlist-admin-password` | read by `runlist-api` only |
| Workload Identity | pool `github`, provider `github-oidc` | only repositories of `oggmont`; the three repos impersonate `github-deployer` |
| Budget | `runlist-free-tier` | 4 PLN (about $1) a month; emails at 1%, 50%, 100% and forecast 100% |

[setup.sh](setup.sh) creates all of this (re-runnable), [budget.sh](budget.sh) the budget, and [runlist-db.sh](runlist-db.sh) runs on the VM to install, back up and reset the database.

## Cost

| Service | Free tier (per billing account, per month) | Runlist at a few sessions a week | Cost |
|---|---|---|---|
| Cloud Run (UI + API) | 2M requests, 180,000 vCPU-seconds, 360,000 GiB-seconds | a few thousand requests, ~2% of the CPU allowance | $0 |
| Compute Engine | 1 e2-micro in us-west1/us-central1/us-east1, 30 GB standard disk | the VM, always on | $0 |
| Artifact Registry | 0.5 GB storage | about 0.3–0.4 GB (2 versions of each image) | $0 (a few cents if it ever goes over) |
| Secret Manager | 6 active versions, 10,000 accesses | 3 versions, a few accesses per cold start | $0 |
| Networking | 1 GB egress from North America | a few MB | $0 |
| GitHub Actions | free on public repositories | builds and tests | $0 |

**Keep it free:** don't enable Cloud SQL, a Serverless VPC Access connector, Cloud NAT, a static external IP, minimum instances on Cloud Run, Container Scanning (Artifact Analysis) or a second VM. Each of these is billed. The free e2-micro covers one VM for the whole billing account, so don't run another one in another project on the same account. The budget alert only sends emails; it doesn't stop anything.

## CI/CD (GitHub Actions)

Each repository has `.github/workflows/deploy.yml`. They authenticate to GCP without keys, through Workload Identity Federation.

| Repository | On every push and PR | On push to `main` |
|---|---|---|
| ui-react-runlist | `npm run check` | build the nginx image, push to Artifact Registry, deploy `runlist-ui` |
| restapi-spring-runlist | `./mvnw verify` (integration tests use this repo's `db/init`) | build the image, push, deploy `runlist-api` |
| db-postgresql-runlist | load `db/init` into PostgreSQL 17, check `verify.sql`, run `examples.sql` | nothing automatic (see below) |

The database is **never reset automatically**, because the live data holds what people did in the app. Run the database workflow by hand (Actions > CI/CD > Run workflow, on `main`), with one of these actions:

- `scripts`: copy `db/init`, `db/queries` and `runlist-db.sh` to the VM. Data stays as it is.
- `backup`: run `pg_dump` on the VM. The 10 newest dumps are kept in `/var/lib/runlist/backups`.
- `reset`: type `RESET` in `confirm`. The workflow backs up, drops `music_db`, loads `db/init`, checks the row counts, then starts a new API revision so the super user's password is set again. Accounts, playlists and favorites made in the app are lost.

Run `reset` after you change the schema or the seed. For a change that must keep live data, apply it by hand over SSH instead.

## Operations

```bash
gcloud config set project runlist-514701

# Super user password (username oscargm)
gcloud secrets versions access latest --secret runlist-admin-password

# SQL shell on the database (IAP SSH, no external IP needed)
gcloud compute ssh runlist-db --zone us-central1-a --tunnel-through-iap \
  --command 'sudo docker exec -it runlist-postgres psql -U music -d music_db' -- -t

# Back up / check row counts on the VM
gcloud compute ssh runlist-db --zone us-central1-a --tunnel-through-iap \
  --command 'sudo bash /var/lib/runlist/runlist-db.sh backup'
gcloud compute ssh runlist-db --zone us-central1-a --tunnel-through-iap \
  --command 'sudo bash /var/lib/runlist/runlist-db.sh verify'

# Copy the newest backup to this machine
gcloud compute ssh runlist-db --zone us-central1-a --tunnel-through-iap \
  --command 'sudo sh -c "cat \$(ls -1t /var/lib/runlist/backups/*.dump | head -1)"' > music_db.dump

# Logs
gcloud run services logs read runlist-api --region us-central1 --limit 100
gcloud run services logs read runlist-ui --region us-central1 --limit 50
```

- **Changing a secret:** `printf '%s' 'new value' | gcloud secrets versions add runlist-admin-password --data-file=-`, then destroy the old version so there stay 3 active versions: `gcloud secrets versions destroy 1 --secret runlist-admin-password`. Changing the admin secret only affects an account without a password; change an existing one with `PUT /api/v1/me/password`. Rotating `runlist-jwt-secret` signs everyone out. The database password is set when the container is created; changing it needs `ALTER ROLE music PASSWORD ...` on the VM too.
- **Pausing:** `gcloud compute instances stop runlist-db --zone us-central1-a` stops the VM. It's free while running, so there's little point. The data stays on the disk, and the API fails until you start it again.
- **Tearing it all down:** delete the project (`gcloud projects delete runlist-514701`), or delete the Cloud Run services, the VM, the internal address, the Artifact Registry repository and the secrets.
