# music-db

A PostgreSQL database for a music playlist platform (a music catalog plus users, playlists, libraries and follows), ready to run with Docker. Its design, and that of the REST API ([api-spring-music](https://github.com/oggmont/restapi-spring-music)) and web UI built on it, is in [design-music-system](https://github.com/oggmont/design-music-system); the schema changes for the UI follow its [DB-Design.md](https://github.com/oggmont/design-music-system/blob/main/DB-Design.md).

It includes:

- **A catalog built for an API:** songs linked to all their recordings, songwriter credits, multi-artist albums (collaborations, classical credits) and per-track performers, a genre tree with several genres per album, record labels, release years and album types, ordered playlists, URL slugs, external IDs (MusicBrainz, ISRC, UPC, ISWC), accent-insensitive and full-text search with a one-call `search_catalog()` and song search by name, artist or album (`search_tracks()`), random picks of songs and playlists, `created_at`/`updated_at` timestamps and read views.
- **A playlist platform:** users, playlists with an owner and a visibility that follows favorites (public while anyone has the playlist as a favorite, private otherwise), limits of 5 favorites, 20 tracks per playlist and 20 owned playlists, collaborators (editors and viewers) with `added_by` on every entry, a version number for safe concurrent edits, liked tracks and saved albums, follows of playlists, artists and users with cached follower counts, and access checks (`playlist_can_view`, `playlist_can_edit`).
- **Integrity enforced in the database:** lookup tables for every type and role, ISO country codes, composer text generated from credits, one primary genre per album, album artists checked at commit, and only owners and editors adding to a playlist.
- **Real data from one listener:** the seed is oscargm's Spotify library (20 playlists with 2312 entries, 1561 liked songs, 34 saved albums and 4 followed artists) and the catalog behind it, 2730 tracks on 1301 albums by 792 artists, with track details from Deezer. The Beatles, Pink Floyd, José José and Daft Punk are written by hand, with band members and songwriting credits. See [About the data](docs/data-model.md#about-the-data).

## Requirements

- [Docker](https://docs.docker.com/get-docker/) with Docker Compose v2
- `make` (optional; every command below also has a plain `docker compose` form)

## Quick start

```bash
cp .env.example .env     # optional: change user, password, DB name or port
make up                  # or: docker compose up -d --wait
make verify              # check that every table has the expected row count
make psql                # open a SQL shell
```

On the first start Postgres runs the scripts in [`db/init/`](db/init/) in order, which creates the tables and loads the data (about 10 seconds). Later starts reuse the stored data and skip this step.

## Connecting

| Setting  | Default     |
|----------|-------------|
| Host     | `localhost` |
| Port     | `5432`      |
| Database | `music_db`  |
| User     | `music`     |
| Password | `music`     |

Connection string: `postgresql://music:music@localhost:5432/music_db`

Change any of these in `.env`. If you change them after the first start, run `make reset`, because user and database are only created on first initialization.

If port 5432 is already taken on your machine, set `POSTGRES_PORT` in `.env` (for example `55432`).

### Web UI (Adminer)

`make up` also starts [Adminer](https://www.adminer.org/) at http://localhost:8080 (change it with `ADMINER_PORT` in `.env`). Log in with System **PostgreSQL**, Server **`postgres`** (the service name inside Docker), and the user, password and database above.

## Commands

| make | docker compose equivalent | What it does |
|---|---|---|
| `make up` | `docker compose up -d --wait` | Start the database and wait until it is ready |
| `make down` | `docker compose down` | Stop it; data is kept |
| `make reset` | `docker compose down -v && docker compose up -d --wait` | **Delete all data** and reload from `db/init/` |
| `make psql` | `docker compose exec postgres psql -U music -d music_db` | Open a SQL shell |
| `make verify` | `docker compose exec postgres psql -U music -d music_db -f /queries/verify.sql` | Compare row counts with expected totals |
| `make logs` | `docker compose logs -f postgres` | Follow server logs |

Inside `psql` you can run the example queries with `\i /queries/examples.sql`.

## Repository layout

```
.
├── docker-compose.yml      # PostgreSQL 17 service, data volume, healthcheck
├── .env.example            # connection settings (copy to .env)
├── Makefile                # shortcuts for the commands above
├── db/
│   ├── init/               # run once, in order, on first start
│   │   ├── 01_schema.sql   # reference data, tables, constraints, indexes, triggers, views, search
│   │   └── 02_data.sql     # seed data: the Spotify library and the featured artists (one transaction)
│   └── queries/
│       ├── verify.sql      # row-count check
│       └── examples.sql    # sample queries (catalog, playlists, users)
└── docs/
    ├── data-model.md       # table reference and relationships
    └── music-db-schema.jpg # full ER diagram: every table, column and foreign key
```

## Data model

![music-db schema](docs/music-db-schema.jpg)

Full-size diagram: [docs/music-db-schema.jpg](docs/music-db-schema.jpg).

31 tables (28 in `public`, 3 in `auth`), 4 views and a search function:

- **Catalog:** `artist`, `label`, `album`, `album_artist`, `song`, `track`, `track_artist`, `genre`, `album_genre`
- **People:** `person`, `artist_member` (who played in which band, and when), `credit` (who wrote which song)
- **Playlists, users and social:** `app_user`, `playlist`, `playlist_track`, `playlist_collaborator`, `user_saved_track`, `user_saved_album`, `playlist_follow`, `artist_follow`, `user_follow`
- **Reference data:** `country`, `artist_type`, `album_type`, `artist_role`, `credit_role`, `playlist_visibility`, `playlist_role`
- **Authentication (`auth` schema):** `auth.role`, `auth.user_account` (password hash and role), `auth.refresh_token`, used by [api-spring-music](https://github.com/oggmont/restapi-spring-music)
- **Views:** `track_detail`, `album_summary`, `artist_summary`, `playlist_summary` (joins already resolved, handy for read endpoints)
- **Search:** `search_catalog('jose')` across artists, albums, songs, tracks, people, public playlists and users; `search_tracks('daft punk')` for songs by name, artist or album
- **Random picks:** `random_tracks(20)`, `random_playlists(user_id, 12)`

See [docs/data-model.md](docs/data-model.md) for every column, the relationships and the rules the database enforces.

Primary keys are identity columns, so leave the ID out when inserting:

```sql
INSERT INTO artist (name, artist_type) VALUES ('New Artist', 'group') RETURNING artist_id, slug;  -- returns 793, 'new-artist'
```

Some rules are checked when the transaction commits rather than per statement. For example, a new album must have its artist in `album_artist`, so insert both in one transaction:

```sql
BEGIN;
INSERT INTO album (title, artist_id) VALUES ('New Album', 793);
INSERT INTO album_artist (album_id, artist_id) SELECT currval(pg_get_serial_sequence('album', 'album_id')), 793;
COMMIT;
```

See [Rules checked by triggers](docs/data-model.md#rules-checked-by-triggers) for the rest.

## Changing the schema or data

Edit the files in `db/init/` (or add a new one such as `03_more_data.sql`; they run in alphabetical order), then run `make reset` to rebuild the database from scratch. Init scripts only run when the data volume is empty.

