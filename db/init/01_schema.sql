/*******************************************************************************
   music-db - Schema
   Creates the tables, keys, constraints, indexes, triggers and views, plus the
   reference data (lookup tables and countries) that the constraints rely on.

   Sections: helper functions, reference data, catalog, people, users and
   social, foreign keys, indexes, triggers, views, search.

   Runs automatically on first container start via /docker-entrypoint-initdb.d,
   inside the database named by POSTGRES_DB.
********************************************************************************/

CREATE EXTENSION IF NOT EXISTS pg_trgm;    -- fast LIKE '%term%' search, similarity()
CREATE EXTENSION IF NOT EXISTS unaccent;   -- accent-insensitive search and slugs
CREATE EXTENSION IF NOT EXISTS btree_gist; -- non-overlapping band membership periods

/*******************************************************************************
   Helper functions
********************************************************************************/

-- unaccent() is only STABLE; this wrapper is IMMUTABLE so it can be used in
-- indexes and generated columns. 'José José' -> 'Jose Jose'.
CREATE FUNCTION f_unaccent(text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT AS $$
    SELECT public.unaccent('public.unaccent'::regdictionary, $1)
$$;

-- Normalized form used by the substring-search indexes: lower case, no accents.
-- Query with the same function so the trigram indexes are used:
--   WHERE f_search_key(name) LIKE '%' || f_search_key('jose') || '%'
CREATE FUNCTION f_search_key(text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT AS $$
    SELECT lower(public.f_unaccent($1))
$$;

-- URL-friendly identifier: 'Sgt. Pepper''s Lonely Hearts Club Band' -> 'sgt-pepper-s-lonely-hearts-club-band'
CREATE FUNCTION slugify(text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT AS $$
    SELECT trim(BOTH '-' FROM regexp_replace(lower(f_unaccent($1)), '[^a-z0-9]+', '-', 'g'))
$$;

-- Sets updated_at on a real change. Columns named in the trigger arguments
-- (cached counters such as follower_count) don't count as a change, so a new
-- follower doesn't make a playlist look edited.
CREATE FUNCTION set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    ignored TEXT[] := TG_ARGV || ARRAY['updated_at', 'search_vector'];
BEGIN
    IF (to_jsonb(NEW) - ignored) IS DISTINCT FROM (to_jsonb(OLD) - ignored) THEN
        NEW.updated_at := now();
    END IF;
    RETURN NEW;
END;
$$;

/*******************************************************************************
   Reference data
   Lookup tables instead of hard-coded CHECK lists: adding a value is an INSERT,
   and the API can list the allowed values. Codes cascade on rename.
********************************************************************************/
CREATE TABLE country
(
    country_code CHAR(2) NOT NULL,          -- ISO 3166-1 alpha-2
    name         VARCHAR(80) NOT NULL,
    CONSTRAINT country_pkey PRIMARY KEY (country_code),
    CONSTRAINT country_code_check CHECK (country_code ~ '^[A-Z]{2}$')
);
CREATE UNIQUE INDEX country_name_key ON country (lower(name));

CREATE TABLE artist_type
(
    code        VARCHAR(20) NOT NULL,
    description TEXT NOT NULL,
    CONSTRAINT artist_type_pkey PRIMARY KEY (code)
);

CREATE TABLE album_type
(
    code        VARCHAR(20) NOT NULL,
    description TEXT NOT NULL,
    CONSTRAINT album_type_pkey PRIMARY KEY (code)
);

-- Role of an artist on an album (album_artist) or a track (track_artist)
CREATE TABLE artist_role
(
    code        VARCHAR(20) NOT NULL,
    description TEXT NOT NULL,
    CONSTRAINT artist_role_pkey PRIMARY KEY (code)
);

-- Role of a person in a credit
CREATE TABLE credit_role
(
    code        VARCHAR(20) NOT NULL,
    description TEXT NOT NULL,
    is_songwriting BOOLEAN NOT NULL DEFAULT false, -- shown in track.composer
    CONSTRAINT credit_role_pkey PRIMARY KEY (code)
);

CREATE TABLE playlist_visibility
(
    code        VARCHAR(20) NOT NULL,
    description TEXT NOT NULL,
    CONSTRAINT playlist_visibility_pkey PRIMARY KEY (code)
);

-- Role of a collaborator on someone else's playlist (the owner is playlist.owner_id)
CREATE TABLE playlist_role
(
    code        VARCHAR(20) NOT NULL,
    description TEXT NOT NULL,
    can_edit    BOOLEAN NOT NULL,
    CONSTRAINT playlist_role_pkey PRIMARY KEY (code)
);

-- A playlist's visibility isn't chosen: it is public while at least one user has
-- it as a favorite (playlist_follow) and private otherwise (see the triggers).
-- 'unlisted' stays for future share links of private playlists.
INSERT INTO playlist_visibility (code, description) VALUES
    ('public',   'At least one user has it as a favorite: anyone can open it; listed in search and Discover'),
    ('unlisted', 'Not listed; anyone with the share link can open it (not used yet)'),
    ('private',  'Nobody has it as a favorite: only the owner and collaborators');

INSERT INTO playlist_role (code, description, can_edit) VALUES
    ('editor', 'Can add, remove and reorder tracks', true),
    ('viewer', 'Can open the playlist even when it is private', false);

INSERT INTO artist_type (code, description) VALUES
    ('solo',          'A single performer'),
    ('group',         'A band or other group with members'),
    ('orchestra',     'An orchestra or instrumental ensemble'),
    ('choir',         'A choir or vocal ensemble'),
    ('collaboration', 'A combined credit such as "Page & Plant"; its parts are listed in album_artist'),
    ('various',       'Placeholder for compilations by several artists');

INSERT INTO album_type (code, description) VALUES
    ('studio',      'Studio album'),
    ('live',        'Live recording'),
    ('compilation', 'Compilation of previously released material'),
    ('soundtrack',  'Film, TV or game soundtrack'),
    ('ep',          'Extended play'),
    ('single',      'Single');

INSERT INTO artist_role (code, description) VALUES
    ('main',      'Main artist'),
    ('featured',  'Featured or guest artist'),
    ('conductor', 'Conductor'),
    ('orchestra', 'Orchestra or ensemble'),
    ('soloist',   'Soloist'),
    ('choir',     'Choir'),
    ('composer',  'Composer credited as an artist (classical)'),
    ('remixer',   'Remixer');

INSERT INTO credit_role (code, description, is_songwriting) VALUES
    ('writer',    'Songwriter (music and lyrics)', true),
    ('composer',  'Composer of the music',         true),
    ('lyricist',  'Author of the lyrics',          true),
    ('arranger',  'Arranger',                      true),
    ('producer',  'Producer',                      false),
    ('engineer',  'Recording or mixing engineer',  false),
    ('performer', 'Session musician or singer',    false);

-- ISO 3166-1 (all officially assigned codes)
INSERT INTO country (country_code, name) VALUES
    ('AD', 'Andorra'), ('AE', 'United Arab Emirates'), ('AF', 'Afghanistan'), ('AG', 'Antigua and Barbuda'),
    ('AI', 'Anguilla'), ('AL', 'Albania'), ('AM', 'Armenia'), ('AO', 'Angola'), ('AQ', 'Antarctica'),
    ('AR', 'Argentina'), ('AS', 'American Samoa'), ('AT', 'Austria'), ('AU', 'Australia'), ('AW', 'Aruba'),
    ('AX', 'Åland Islands'), ('AZ', 'Azerbaijan'),
    ('BA', 'Bosnia and Herzegovina'), ('BB', 'Barbados'), ('BD', 'Bangladesh'), ('BE', 'Belgium'),
    ('BF', 'Burkina Faso'), ('BG', 'Bulgaria'), ('BH', 'Bahrain'), ('BI', 'Burundi'), ('BJ', 'Benin'),
    ('BL', 'Saint Barthélemy'), ('BM', 'Bermuda'), ('BN', 'Brunei'), ('BO', 'Bolivia'),
    ('BQ', 'Caribbean Netherlands'), ('BR', 'Brazil'), ('BS', 'Bahamas'), ('BT', 'Bhutan'),
    ('BV', 'Bouvet Island'), ('BW', 'Botswana'), ('BY', 'Belarus'), ('BZ', 'Belize'),
    ('CA', 'Canada'), ('CC', 'Cocos (Keeling) Islands'), ('CD', 'Democratic Republic of the Congo'),
    ('CF', 'Central African Republic'), ('CG', 'Republic of the Congo'), ('CH', 'Switzerland'),
    ('CI', 'Côte d''Ivoire'), ('CK', 'Cook Islands'), ('CL', 'Chile'), ('CM', 'Cameroon'), ('CN', 'China'),
    ('CO', 'Colombia'), ('CR', 'Costa Rica'), ('CU', 'Cuba'), ('CV', 'Cabo Verde'), ('CW', 'Curaçao'),
    ('CX', 'Christmas Island'), ('CY', 'Cyprus'), ('CZ', 'Czechia'),
    ('DE', 'Germany'), ('DJ', 'Djibouti'), ('DK', 'Denmark'), ('DM', 'Dominica'), ('DO', 'Dominican Republic'),
    ('DZ', 'Algeria'),
    ('EC', 'Ecuador'), ('EE', 'Estonia'), ('EG', 'Egypt'), ('EH', 'Western Sahara'), ('ER', 'Eritrea'),
    ('ES', 'Spain'), ('ET', 'Ethiopia'),
    ('FI', 'Finland'), ('FJ', 'Fiji'), ('FK', 'Falkland Islands'), ('FM', 'Micronesia'), ('FO', 'Faroe Islands'),
    ('FR', 'France'),
    ('GA', 'Gabon'), ('GB', 'United Kingdom'), ('GD', 'Grenada'), ('GE', 'Georgia'), ('GF', 'French Guiana'),
    ('GG', 'Guernsey'), ('GH', 'Ghana'), ('GI', 'Gibraltar'), ('GL', 'Greenland'), ('GM', 'Gambia'),
    ('GN', 'Guinea'), ('GP', 'Guadeloupe'), ('GQ', 'Equatorial Guinea'), ('GR', 'Greece'),
    ('GS', 'South Georgia and the South Sandwich Islands'), ('GT', 'Guatemala'), ('GU', 'Guam'),
    ('GW', 'Guinea-Bissau'), ('GY', 'Guyana'),
    ('HK', 'Hong Kong'), ('HM', 'Heard Island and McDonald Islands'), ('HN', 'Honduras'), ('HR', 'Croatia'),
    ('HT', 'Haiti'), ('HU', 'Hungary'),
    ('ID', 'Indonesia'), ('IE', 'Ireland'), ('IL', 'Israel'), ('IM', 'Isle of Man'), ('IN', 'India'),
    ('IO', 'British Indian Ocean Territory'), ('IQ', 'Iraq'), ('IR', 'Iran'), ('IS', 'Iceland'), ('IT', 'Italy'),
    ('JE', 'Jersey'), ('JM', 'Jamaica'), ('JO', 'Jordan'), ('JP', 'Japan'),
    ('KE', 'Kenya'), ('KG', 'Kyrgyzstan'), ('KH', 'Cambodia'), ('KI', 'Kiribati'), ('KM', 'Comoros'),
    ('KN', 'Saint Kitts and Nevis'), ('KP', 'North Korea'), ('KR', 'South Korea'), ('KW', 'Kuwait'),
    ('KY', 'Cayman Islands'), ('KZ', 'Kazakhstan'),
    ('LA', 'Laos'), ('LB', 'Lebanon'), ('LC', 'Saint Lucia'), ('LI', 'Liechtenstein'), ('LK', 'Sri Lanka'),
    ('LR', 'Liberia'), ('LS', 'Lesotho'), ('LT', 'Lithuania'), ('LU', 'Luxembourg'), ('LV', 'Latvia'),
    ('LY', 'Libya'),
    ('MA', 'Morocco'), ('MC', 'Monaco'), ('MD', 'Moldova'), ('ME', 'Montenegro'), ('MF', 'Saint Martin'),
    ('MG', 'Madagascar'), ('MH', 'Marshall Islands'), ('MK', 'North Macedonia'), ('ML', 'Mali'),
    ('MM', 'Myanmar'), ('MN', 'Mongolia'), ('MO', 'Macao'), ('MP', 'Northern Mariana Islands'),
    ('MQ', 'Martinique'), ('MR', 'Mauritania'), ('MS', 'Montserrat'), ('MT', 'Malta'), ('MU', 'Mauritius'),
    ('MV', 'Maldives'), ('MW', 'Malawi'), ('MX', 'Mexico'), ('MY', 'Malaysia'), ('MZ', 'Mozambique'),
    ('NA', 'Namibia'), ('NC', 'New Caledonia'), ('NE', 'Niger'), ('NF', 'Norfolk Island'), ('NG', 'Nigeria'),
    ('NI', 'Nicaragua'), ('NL', 'Netherlands'), ('NO', 'Norway'), ('NP', 'Nepal'), ('NR', 'Nauru'),
    ('NU', 'Niue'), ('NZ', 'New Zealand'),
    ('OM', 'Oman'),
    ('PA', 'Panama'), ('PE', 'Peru'), ('PF', 'French Polynesia'), ('PG', 'Papua New Guinea'),
    ('PH', 'Philippines'), ('PK', 'Pakistan'), ('PL', 'Poland'), ('PM', 'Saint Pierre and Miquelon'),
    ('PN', 'Pitcairn Islands'), ('PR', 'Puerto Rico'), ('PS', 'Palestine'), ('PT', 'Portugal'), ('PW', 'Palau'),
    ('PY', 'Paraguay'),
    ('QA', 'Qatar'),
    ('RE', 'Réunion'), ('RO', 'Romania'), ('RS', 'Serbia'), ('RU', 'Russia'), ('RW', 'Rwanda'),
    ('SA', 'Saudi Arabia'), ('SB', 'Solomon Islands'), ('SC', 'Seychelles'), ('SD', 'Sudan'), ('SE', 'Sweden'),
    ('SG', 'Singapore'), ('SH', 'Saint Helena, Ascension and Tristan da Cunha'), ('SI', 'Slovenia'),
    ('SJ', 'Svalbard and Jan Mayen'), ('SK', 'Slovakia'), ('SL', 'Sierra Leone'), ('SM', 'San Marino'),
    ('SN', 'Senegal'), ('SO', 'Somalia'), ('SR', 'Suriname'), ('SS', 'South Sudan'),
    ('ST', 'São Tomé and Príncipe'), ('SV', 'El Salvador'), ('SX', 'Sint Maarten'), ('SY', 'Syria'),
    ('SZ', 'Eswatini'),
    ('TC', 'Turks and Caicos Islands'), ('TD', 'Chad'), ('TF', 'French Southern Territories'), ('TG', 'Togo'),
    ('TH', 'Thailand'), ('TJ', 'Tajikistan'), ('TK', 'Tokelau'), ('TL', 'Timor-Leste'), ('TM', 'Turkmenistan'),
    ('TN', 'Tunisia'), ('TO', 'Tonga'), ('TR', 'Türkiye'), ('TT', 'Trinidad and Tobago'), ('TV', 'Tuvalu'),
    ('TW', 'Taiwan'), ('TZ', 'Tanzania'),
    ('UA', 'Ukraine'), ('UG', 'Uganda'), ('UM', 'United States Minor Outlying Islands'), ('US', 'United States'),
    ('UY', 'Uruguay'), ('UZ', 'Uzbekistan'),
    ('VA', 'Vatican City'), ('VC', 'Saint Vincent and the Grenadines'), ('VE', 'Venezuela'),
    ('VG', 'British Virgin Islands'), ('VI', 'U.S. Virgin Islands'), ('VN', 'Vietnam'), ('VU', 'Vanuatu'),
    ('WF', 'Wallis and Futuna'), ('WS', 'Samoa'),
    ('YE', 'Yemen'), ('YT', 'Mayotte'),
    ('ZA', 'South Africa'), ('ZM', 'Zambia'), ('ZW', 'Zimbabwe');

/*******************************************************************************
   Catalog
********************************************************************************/
CREATE TABLE artist
(
    artist_id      INT NOT NULL GENERATED ALWAYS AS IDENTITY,
    name           VARCHAR(120) NOT NULL,   -- not unique: different acts can share a name
    slug           VARCHAR(140) NOT NULL,   -- set by trigger when omitted
    artist_type    VARCHAR(20),             -- -> artist_type
    person_id      INT,                     -- solo artists: the person behind the name
    country_code   CHAR(2),                 -- -> country
    city           VARCHAR(60),
    formed_year    SMALLINT,
    disbanded_year SMALLINT,
    biography      TEXT,
    image_url      VARCHAR(500),
    musicbrainz_id UUID,
    follower_count INT NOT NULL DEFAULT 0,  -- kept by trigger from artist_follow
    search_vector  TSVECTOR GENERATED ALWAYS AS (to_tsvector('simple', f_unaccent(name))) STORED,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT artist_pkey PRIMARY KEY (artist_id),
    CONSTRAINT artist_years_check
        CHECK (disbanded_year IS NULL OR formed_year IS NULL OR disbanded_year >= formed_year),
    CONSTRAINT artist_person_check CHECK (person_id IS NULL OR artist_type = 'solo')
);

CREATE TABLE label
(
    label_id       INT NOT NULL GENERATED ALWAYS AS IDENTITY,
    name           VARCHAR(120) NOT NULL,
    slug           VARCHAR(140) NOT NULL,   -- set by trigger when omitted
    country_code   CHAR(2),                 -- -> country
    musicbrainz_id UUID,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT label_pkey PRIMARY KEY (label_id)
);

CREATE TABLE album
(
    album_id       INT NOT NULL GENERATED ALWAYS AS IDENTITY,
    title          VARCHAR(160) NOT NULL,
    edition        VARCHAR(80),             -- e.g. '2009 Remaster', 'Deluxe'; tells same-title releases apart
    artist_id      INT NOT NULL,            -- artist as credited on the cover; see album_artist
    slug           VARCHAR(180) NOT NULL,   -- set by trigger when omitted; unique per artist
    release_date   DATE,                    -- exact date, when known
    release_year   SMALLINT,                -- always set when release_date is
    album_type     VARCHAR(20),             -- -> album_type
    label_id       INT,                     -- -> label
    upc            VARCHAR(14),             -- barcode (UPC-A / EAN-13 / GTIN-14)
    musicbrainz_id UUID,                    -- MusicBrainz release
    cover_url      VARCHAR(500),
    search_vector  TSVECTOR GENERATED ALWAYS AS (to_tsvector('simple', f_unaccent(title))) STORED,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT album_pkey PRIMARY KEY (album_id),
    CONSTRAINT album_release_year_check
        CHECK (release_date IS NULL OR release_year = extract(year FROM release_date)),
    CONSTRAINT album_upc_check CHECK (upc ~ '^[0-9]{12,14}$')
);

-- The individual artists on an album, with their role. Every album lists its
-- credited artist (album.artist_id) here, except a collaboration ("Page & Plant"),
-- which lists its parts instead (Jimmy Page, Robert Plant). Enforced at commit.
CREATE TABLE album_artist
(
    album_id  INT NOT NULL,
    artist_id INT NOT NULL,
    role      VARCHAR(20) NOT NULL DEFAULT 'main',  -- -> artist_role
    position  SMALLINT NOT NULL DEFAULT 1,
    CONSTRAINT album_artist_pkey PRIMARY KEY (album_id, artist_id)
);

CREATE TABLE genre
(
    genre_id        INT NOT NULL GENERATED ALWAYS AS IDENTITY,
    name            VARCHAR(120) NOT NULL,
    parent_genre_id INT,                           -- e.g. Progressive Rock -> Rock
    CONSTRAINT genre_pkey PRIMARY KEY (genre_id),
    CONSTRAINT genre_parent_check CHECK (parent_genre_id <> genre_id)
);

-- All genres of an album. An album with genres has exactly one primary
-- (enforced at commit). Genres used by its tracks are added automatically.
CREATE TABLE album_genre
(
    album_id   INT NOT NULL,
    genre_id   INT NOT NULL,
    is_primary BOOLEAN NOT NULL DEFAULT false,
    CONSTRAINT album_genre_pkey PRIMARY KEY (album_id, genre_id)
);

-- A song is the composition; tracks are its recordings on different albums
-- (studio, live, demo, remaster, compilation...).
CREATE TABLE song
(
    song_id            INT NOT NULL GENERATED ALWAYS AS IDENTITY,
    title              VARCHAR(200) NOT NULL,
    artist_id          INT,                  -- artist who recorded it first
    first_release_year SMALLINT,
    language           VARCHAR(3),           -- ISO 639 code of the lyrics ('en', 'es'); 'zxx' = instrumental
    is_traditional     BOOLEAN NOT NULL DEFAULT false, -- traditional tune; credits are arrangers
    iswc               CHAR(11),             -- e.g. 'T0101974597', without punctuation
    musicbrainz_id     UUID,                 -- MusicBrainz work
    search_vector      TSVECTOR GENERATED ALWAYS AS (to_tsvector('simple', f_unaccent(title))) STORED,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT song_pkey PRIMARY KEY (song_id),
    CONSTRAINT song_language_check CHECK (language ~ '^[a-z]{2,3}$'),
    CONSTRAINT song_iswc_check     CHECK (iswc ~ '^T[0-9]{10}$')
);

CREATE TABLE track
(
    track_id      INT NOT NULL GENERATED ALWAYS AS IDENTITY,
    name          VARCHAR(200) NOT NULL,
    album_id      INT NOT NULL,
    song_id       INT,
    disc_number   SMALLINT NOT NULL DEFAULT 1,
    track_number  SMALLINT,
    genre_id      INT,                      -- only when it differs from the album's primary genre
    composer      TEXT,                     -- songwriters as display text; generated from credit when the song has credits
    milliseconds  INT NOT NULL,
    bytes         INT,
    isrc          CHAR(12),                 -- e.g. 'GBAYE0601498'
    search_vector TSVECTOR GENERATED ALWAYS AS (
        to_tsvector('simple', f_unaccent(name || ' ' || coalesce(composer, '')))
    ) STORED,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT track_pkey PRIMARY KEY (track_id),
    CONSTRAINT track_album_position_key UNIQUE (album_id, disc_number, track_number),
    CONSTRAINT track_milliseconds_check CHECK (milliseconds > 0),
    CONSTRAINT track_disc_number_check  CHECK (disc_number > 0),
    CONSTRAINT track_track_number_check CHECK (track_number > 0),
    CONSTRAINT track_isrc_check CHECK (isrc ~ '^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$')
);

-- Performers of a single track, when they differ from the album's artists:
-- compilations, soundtracks, featured guests, remixers.
CREATE TABLE track_artist
(
    track_id  INT NOT NULL,
    artist_id INT NOT NULL,
    role      VARCHAR(20) NOT NULL DEFAULT 'main',  -- -> artist_role
    position  SMALLINT NOT NULL DEFAULT 1,
    CONSTRAINT track_artist_pkey PRIMARY KEY (track_id, artist_id)
);

CREATE TABLE playlist
(
    playlist_id    INT NOT NULL GENERATED ALWAYS AS IDENTITY,
    name           VARCHAR(120) NOT NULL,
    description    TEXT,
    owner_id       INT NOT NULL,                -- -> app_user
    visibility     VARCHAR(20) NOT NULL DEFAULT 'private', -- -> playlist_visibility; follows favorites (trigger)
    share_token    UUID NOT NULL DEFAULT gen_random_uuid(), -- secret for share links (unused while visibility follows favorites)
    cover_url      VARCHAR(500),
    version        INT NOT NULL DEFAULT 1,      -- goes up whenever the track list changes
    follower_count INT NOT NULL DEFAULT 0,      -- kept by trigger from playlist_follow
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT playlist_pkey PRIMARY KEY (playlist_id)
);

-- Ordered entries; a track can appear more than once. position is assigned
-- (end of the list) and added_by defaults to the owner when omitted; only the
-- owner and editors can add. The key is checked at the end of each statement,
-- so "UPDATE ... SET position = position + 1" can shift entries.
CREATE TABLE playlist_track
(
    playlist_id INT NOT NULL,
    position    INT NOT NULL,
    track_id    INT NOT NULL,
    added_by    INT,                            -- -> app_user (NULL once that user is deleted)
    added_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT playlist_track_pkey PRIMARY KEY (playlist_id, position) DEFERRABLE INITIALLY IMMEDIATE,
    CONSTRAINT playlist_track_position_check CHECK (position > 0)
);

/*******************************************************************************
   People
********************************************************************************/
CREATE TABLE person
(
    person_id      INT NOT NULL GENERATED ALWAYS AS IDENTITY,
    name           VARCHAR(120) NOT NULL,   -- name the person is known by
    birth_name     VARCHAR(120),
    birth_date     DATE,
    death_date     DATE,
    birth_place    VARCHAR(120),
    image_url      VARCHAR(500),
    musicbrainz_id UUID,
    search_vector  TSVECTOR GENERATED ALWAYS AS (
        to_tsvector('simple', f_unaccent(name || ' ' || coalesce(birth_name, '')))
    ) STORED,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT person_pkey PRIMARY KEY (person_id),
    CONSTRAINT person_dates_check
        CHECK (death_date IS NULL OR birth_date IS NULL OR death_date >= birth_date)
);

-- Who played in which band, and when. One row per stint: someone who left
-- and rejoined has two rows; stints of the same person can't overlap.
CREATE TABLE artist_member
(
    artist_member_id INT NOT NULL GENERATED ALWAYS AS IDENTITY,
    artist_id        INT NOT NULL,
    person_id        INT NOT NULL,
    roles            TEXT[] NOT NULL DEFAULT '{}',  -- e.g. {vocals,"bass guitar"}
    joined_year      SMALLINT,
    left_year        SMALLINT,
    CONSTRAINT artist_member_pkey PRIMARY KEY (artist_member_id),
    CONSTRAINT artist_member_years_check
        CHECK (left_year IS NULL OR joined_year IS NULL OR left_year >= joined_year),
    CONSTRAINT artist_member_no_overlap EXCLUDE USING gist (
        artist_id WITH =,
        person_id WITH =,
        int4range(joined_year, left_year, '[]') WITH &&
    )
);

-- Who wrote a song, or did what on a specific track.
-- Exactly one of song_id / track_id is set.
CREATE TABLE credit
(
    credit_id   INT NOT NULL GENERATED ALWAYS AS IDENTITY,
    song_id     INT,
    track_id    INT,
    person_id   INT NOT NULL,
    role        VARCHAR(20) NOT NULL,       -- -> credit_role
    position    SMALLINT NOT NULL DEFAULT 1, -- order as credited
    credited_as VARCHAR(120),               -- name as printed, when not person.name ('Richard Starkey')
    CONSTRAINT credit_pkey PRIMARY KEY (credit_id),
    CONSTRAINT credit_target_check CHECK (num_nonnulls(song_id, track_id) = 1)
);

/*******************************************************************************
   Users and social
********************************************************************************/
-- A listener account. Authentication lives in an external provider; this
-- table only keeps its subject id. ("user" is a reserved word, hence app_user.)
CREATE TABLE app_user
(
    user_id         INT NOT NULL GENERATED ALWAYS AS IDENTITY,
    username        VARCHAR(30) NOT NULL,   -- handle in URLs: /users/ana.garcia
    display_name    VARCHAR(80) NOT NULL,
    email           TEXT NOT NULL,          -- unique, case-insensitive
    auth_subject    TEXT,                   -- id at the auth provider (OIDC "sub")
    avatar_url      VARCHAR(500),
    bio             TEXT,
    country_code    CHAR(2),                -- -> country
    is_verified     BOOLEAN NOT NULL DEFAULT false, -- editorial and artist accounts
    follower_count  INT NOT NULL DEFAULT 0, -- kept by trigger from user_follow
    following_count INT NOT NULL DEFAULT 0, -- kept by trigger from user_follow
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT app_user_pkey PRIMARY KEY (user_id),
    CONSTRAINT app_user_username_check CHECK (username ~ '^[a-z0-9_.]{3,30}$'),
    CONSTRAINT app_user_email_check    CHECK (email ~ '^[^@\s]+@[^@\s]+$')
);

-- People who can edit or see someone else's playlist. The owner is not listed.
CREATE TABLE playlist_collaborator
(
    playlist_id INT NOT NULL,
    user_id     INT NOT NULL,
    role        VARCHAR(20) NOT NULL DEFAULT 'editor',  -- -> playlist_role
    added_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT playlist_collaborator_pkey PRIMARY KEY (playlist_id, user_id)
);

-- A user's library: liked tracks and saved albums
CREATE TABLE user_saved_track
(
    user_id  INT NOT NULL,
    track_id INT NOT NULL,
    saved_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT user_saved_track_pkey PRIMARY KEY (user_id, track_id)
);

CREATE TABLE user_saved_album
(
    user_id  INT NOT NULL,
    album_id INT NOT NULL,
    saved_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT user_saved_album_pkey PRIMARY KEY (user_id, album_id)
);

-- Follows. Each one keeps a follower_count up to date on what is followed.
CREATE TABLE playlist_follow
(
    user_id     INT NOT NULL,
    playlist_id INT NOT NULL,
    followed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT playlist_follow_pkey PRIMARY KEY (user_id, playlist_id)
);

CREATE TABLE artist_follow
(
    user_id     INT NOT NULL,
    artist_id   INT NOT NULL,
    followed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT artist_follow_pkey PRIMARY KEY (user_id, artist_id)
);

CREATE TABLE user_follow
(
    follower_id INT NOT NULL,   -- who follows
    followed_id INT NOT NULL,   -- whom
    followed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT user_follow_pkey PRIMARY KEY (follower_id, followed_id),
    CONSTRAINT user_follow_self_check CHECK (follower_id <> followed_id)
);

/*******************************************************************************
   Foreign keys
   Every foreign key has a matching index, except those to the small lookup
   tables (country, *_type, *_role), which are never deleted from in practice.

   Delete rules:
   - CASCADE for rows that only describe their parent (link tables, credits,
     playlist entries, an album's tracks).
   - SET NULL for optional pointers (song, parent genre, label, person).
   - NO ACTION where deleting would orphan the catalog: an artist with albums.
   - Deleting a user deletes their playlists, library and follows.
********************************************************************************/

-- Lookups
ALTER TABLE artist        ADD CONSTRAINT artist_artist_type_fkey
    FOREIGN KEY (artist_type) REFERENCES artist_type (code) ON UPDATE CASCADE;
ALTER TABLE album         ADD CONSTRAINT album_album_type_fkey
    FOREIGN KEY (album_type) REFERENCES album_type (code) ON UPDATE CASCADE;
ALTER TABLE album_artist  ADD CONSTRAINT album_artist_role_fkey
    FOREIGN KEY (role) REFERENCES artist_role (code) ON UPDATE CASCADE;
ALTER TABLE track_artist  ADD CONSTRAINT track_artist_role_fkey
    FOREIGN KEY (role) REFERENCES artist_role (code) ON UPDATE CASCADE;
ALTER TABLE credit        ADD CONSTRAINT credit_role_fkey
    FOREIGN KEY (role) REFERENCES credit_role (code) ON UPDATE CASCADE;
ALTER TABLE playlist      ADD CONSTRAINT playlist_visibility_fkey
    FOREIGN KEY (visibility) REFERENCES playlist_visibility (code) ON UPDATE CASCADE;
ALTER TABLE playlist_collaborator ADD CONSTRAINT playlist_collaborator_role_fkey
    FOREIGN KEY (role) REFERENCES playlist_role (code) ON UPDATE CASCADE;
ALTER TABLE app_user      ADD CONSTRAINT app_user_country_code_fkey
    FOREIGN KEY (country_code) REFERENCES country (country_code) ON UPDATE CASCADE;
ALTER TABLE artist        ADD CONSTRAINT artist_country_code_fkey
    FOREIGN KEY (country_code) REFERENCES country (country_code) ON UPDATE CASCADE;
ALTER TABLE label         ADD CONSTRAINT label_country_code_fkey
    FOREIGN KEY (country_code) REFERENCES country (country_code) ON UPDATE CASCADE;

-- Catalog
ALTER TABLE artist ADD CONSTRAINT artist_person_id_fkey
    FOREIGN KEY (person_id) REFERENCES person (person_id) ON DELETE SET NULL;
CREATE UNIQUE INDEX artist_person_id_key ON artist (person_id);

ALTER TABLE album ADD CONSTRAINT album_artist_id_fkey
    FOREIGN KEY (artist_id) REFERENCES artist (artist_id) ON DELETE NO ACTION;
CREATE INDEX album_artist_id_idx ON album (artist_id);

ALTER TABLE album ADD CONSTRAINT album_label_id_fkey
    FOREIGN KEY (label_id) REFERENCES label (label_id) ON DELETE SET NULL;
CREATE INDEX album_label_id_idx ON album (label_id);

ALTER TABLE album_artist ADD CONSTRAINT album_artist_album_id_fkey
    FOREIGN KEY (album_id) REFERENCES album (album_id) ON DELETE CASCADE;
ALTER TABLE album_artist ADD CONSTRAINT album_artist_artist_id_fkey
    FOREIGN KEY (artist_id) REFERENCES artist (artist_id) ON DELETE CASCADE;
CREATE INDEX album_artist_artist_id_idx ON album_artist (artist_id);

ALTER TABLE album_genre ADD CONSTRAINT album_genre_album_id_fkey
    FOREIGN KEY (album_id) REFERENCES album (album_id) ON DELETE CASCADE;
ALTER TABLE album_genre ADD CONSTRAINT album_genre_genre_id_fkey
    FOREIGN KEY (genre_id) REFERENCES genre (genre_id) ON DELETE CASCADE;
CREATE INDEX album_genre_genre_id_idx ON album_genre (genre_id);

ALTER TABLE genre ADD CONSTRAINT genre_parent_genre_id_fkey
    FOREIGN KEY (parent_genre_id) REFERENCES genre (genre_id) ON DELETE SET NULL;
CREATE INDEX genre_parent_genre_id_idx ON genre (parent_genre_id);

ALTER TABLE song ADD CONSTRAINT song_artist_id_fkey
    FOREIGN KEY (artist_id) REFERENCES artist (artist_id) ON DELETE SET NULL;
CREATE INDEX song_artist_id_idx ON song (artist_id);

ALTER TABLE track ADD CONSTRAINT track_album_id_fkey
    FOREIGN KEY (album_id) REFERENCES album (album_id) ON DELETE CASCADE;
CREATE INDEX track_album_id_idx ON track (album_id);

ALTER TABLE track ADD CONSTRAINT track_song_id_fkey
    FOREIGN KEY (song_id) REFERENCES song (song_id) ON DELETE SET NULL;
CREATE INDEX track_song_id_idx ON track (song_id);

-- A track's own genre must be one of its album's genres (the track trigger
-- adds it to album_genre when needed). NULL genre_id skips the check.
ALTER TABLE track ADD CONSTRAINT track_album_genre_fkey
    FOREIGN KEY (album_id, genre_id) REFERENCES album_genre (album_id, genre_id) ON DELETE NO ACTION;
CREATE INDEX track_genre_id_idx ON track (genre_id);

ALTER TABLE track_artist ADD CONSTRAINT track_artist_track_id_fkey
    FOREIGN KEY (track_id) REFERENCES track (track_id) ON DELETE CASCADE;
ALTER TABLE track_artist ADD CONSTRAINT track_artist_artist_id_fkey
    FOREIGN KEY (artist_id) REFERENCES artist (artist_id) ON DELETE CASCADE;
CREATE INDEX track_artist_artist_id_idx ON track_artist (artist_id);

-- (playlist_id is the leading PK column, so the PK index already covers it.)
ALTER TABLE playlist_track ADD CONSTRAINT playlist_track_playlist_id_fkey
    FOREIGN KEY (playlist_id) REFERENCES playlist (playlist_id) ON DELETE CASCADE;
ALTER TABLE playlist_track ADD CONSTRAINT playlist_track_track_id_fkey
    FOREIGN KEY (track_id) REFERENCES track (track_id) ON DELETE CASCADE;
-- (track_id, playlist_id) also answers "is this track in that playlist?" (/me/playlists?contains_track=)
CREATE INDEX playlist_track_track_id_idx ON playlist_track (track_id, playlist_id);
ALTER TABLE playlist_track ADD CONSTRAINT playlist_track_added_by_fkey
    FOREIGN KEY (added_by) REFERENCES app_user (user_id) ON DELETE SET NULL;
-- (added_by, playlist_id, added_at) also finds when a user last added to a playlist ("last used")
CREATE INDEX playlist_track_added_by_idx ON playlist_track (added_by, playlist_id, added_at DESC);

ALTER TABLE playlist ADD CONSTRAINT playlist_owner_id_fkey
    FOREIGN KEY (owner_id) REFERENCES app_user (user_id) ON DELETE CASCADE;
CREATE INDEX playlist_owner_id_idx ON playlist (owner_id);
-- Public playlists, for random picks (random_playlists)
CREATE INDEX playlist_public_idx ON playlist (playlist_id) WHERE visibility = 'public';

-- People
ALTER TABLE artist_member ADD CONSTRAINT artist_member_artist_id_fkey
    FOREIGN KEY (artist_id) REFERENCES artist (artist_id) ON DELETE CASCADE;
ALTER TABLE artist_member ADD CONSTRAINT artist_member_person_id_fkey
    FOREIGN KEY (person_id) REFERENCES person (person_id) ON DELETE CASCADE;
CREATE INDEX artist_member_artist_id_idx ON artist_member (artist_id);
CREATE INDEX artist_member_person_id_idx ON artist_member (person_id);

ALTER TABLE credit ADD CONSTRAINT credit_song_id_fkey
    FOREIGN KEY (song_id) REFERENCES song (song_id) ON DELETE CASCADE;
CREATE INDEX credit_song_id_idx ON credit (song_id);
ALTER TABLE credit ADD CONSTRAINT credit_track_id_fkey
    FOREIGN KEY (track_id) REFERENCES track (track_id) ON DELETE CASCADE;
CREATE INDEX credit_track_id_idx ON credit (track_id);
ALTER TABLE credit ADD CONSTRAINT credit_person_id_fkey
    FOREIGN KEY (person_id) REFERENCES person (person_id) ON DELETE CASCADE;
CREATE INDEX credit_person_id_idx ON credit (person_id);

-- Users and social (the user_id side is the leading PK column)
ALTER TABLE playlist_collaborator ADD CONSTRAINT playlist_collaborator_playlist_id_fkey
    FOREIGN KEY (playlist_id) REFERENCES playlist (playlist_id) ON DELETE CASCADE;
ALTER TABLE playlist_collaborator ADD CONSTRAINT playlist_collaborator_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES app_user (user_id) ON DELETE CASCADE;
CREATE INDEX playlist_collaborator_user_id_idx ON playlist_collaborator (user_id);

ALTER TABLE user_saved_track ADD CONSTRAINT user_saved_track_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES app_user (user_id) ON DELETE CASCADE;
ALTER TABLE user_saved_track ADD CONSTRAINT user_saved_track_track_id_fkey
    FOREIGN KEY (track_id) REFERENCES track (track_id) ON DELETE CASCADE;
CREATE INDEX user_saved_track_track_id_idx ON user_saved_track (track_id);

ALTER TABLE user_saved_album ADD CONSTRAINT user_saved_album_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES app_user (user_id) ON DELETE CASCADE;
ALTER TABLE user_saved_album ADD CONSTRAINT user_saved_album_album_id_fkey
    FOREIGN KEY (album_id) REFERENCES album (album_id) ON DELETE CASCADE;
CREATE INDEX user_saved_album_album_id_idx ON user_saved_album (album_id);

ALTER TABLE playlist_follow ADD CONSTRAINT playlist_follow_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES app_user (user_id) ON DELETE CASCADE;
ALTER TABLE playlist_follow ADD CONSTRAINT playlist_follow_playlist_id_fkey
    FOREIGN KEY (playlist_id) REFERENCES playlist (playlist_id) ON DELETE CASCADE;
CREATE INDEX playlist_follow_playlist_id_idx ON playlist_follow (playlist_id);

ALTER TABLE artist_follow ADD CONSTRAINT artist_follow_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES app_user (user_id) ON DELETE CASCADE;
ALTER TABLE artist_follow ADD CONSTRAINT artist_follow_artist_id_fkey
    FOREIGN KEY (artist_id) REFERENCES artist (artist_id) ON DELETE CASCADE;
CREATE INDEX artist_follow_artist_id_idx ON artist_follow (artist_id);

ALTER TABLE user_follow ADD CONSTRAINT user_follow_follower_id_fkey
    FOREIGN KEY (follower_id) REFERENCES app_user (user_id) ON DELETE CASCADE;
ALTER TABLE user_follow ADD CONSTRAINT user_follow_followed_id_fkey
    FOREIGN KEY (followed_id) REFERENCES app_user (user_id) ON DELETE CASCADE;
CREATE INDEX user_follow_followed_id_idx ON user_follow (followed_id);

/*******************************************************************************
   Other indexes
********************************************************************************/
-- Uniqueness (case-insensitive where it matters)
CREATE UNIQUE INDEX artist_slug_key         ON artist (slug);
CREATE UNIQUE INDEX label_name_key          ON label (lower(name));
CREATE UNIQUE INDEX label_slug_key          ON label (slug);
CREATE UNIQUE INDEX album_artist_title_key  ON album (artist_id, lower(title), lower(edition)) NULLS NOT DISTINCT;
CREATE UNIQUE INDEX album_artist_slug_key   ON album (artist_id, slug);
CREATE UNIQUE INDEX genre_name_key          ON genre (lower(name));
CREATE UNIQUE INDEX app_user_username_key   ON app_user (username);
CREATE UNIQUE INDEX app_user_email_key      ON app_user (lower(email));
CREATE UNIQUE INDEX app_user_auth_subject_key ON app_user (auth_subject);
CREATE UNIQUE INDEX playlist_share_token_key ON playlist (share_token);
CREATE UNIQUE INDEX album_genre_primary_key ON album_genre (album_id) WHERE is_primary;
CREATE UNIQUE INDEX credit_song_person_role_key  ON credit (song_id, person_id, role)  WHERE song_id  IS NOT NULL;
CREATE UNIQUE INDEX credit_track_person_role_key ON credit (track_id, person_id, role) WHERE track_id IS NOT NULL;
CREATE UNIQUE INDEX track_isrc_key          ON track (isrc);
CREATE UNIQUE INDEX album_upc_key           ON album (upc);
CREATE UNIQUE INDEX song_iswc_key           ON song (iswc);
CREATE UNIQUE INDEX artist_musicbrainz_id_key ON artist (musicbrainz_id);
CREATE UNIQUE INDEX album_musicbrainz_id_key  ON album (musicbrainz_id);
CREATE UNIQUE INDEX song_musicbrainz_id_key   ON song (musicbrainz_id);
CREATE UNIQUE INDEX person_musicbrainz_id_key ON person (musicbrainz_id);
CREATE UNIQUE INDEX label_musicbrainz_id_key  ON label (musicbrainz_id);

-- Lookup by name (not unique: see artist.name)
CREATE INDEX artist_name_idx ON artist (lower(name));

-- Sorting / filtering
CREATE INDEX album_release_year_idx ON album (release_year);
CREATE INDEX album_release_date_idx ON album (release_date);

-- Accent-insensitive substring search:
--   WHERE f_search_key(name) LIKE '%' || f_search_key('jose') || '%'
CREATE INDEX artist_name_trgm_idx ON artist USING gin (f_search_key(name)  gin_trgm_ops);
CREATE INDEX album_title_trgm_idx ON album  USING gin (f_search_key(title) gin_trgm_ops);
CREATE INDEX track_name_trgm_idx  ON track  USING gin (f_search_key(name)  gin_trgm_ops);
CREATE INDEX song_title_trgm_idx  ON song   USING gin (f_search_key(title) gin_trgm_ops);
CREATE INDEX person_name_trgm_idx ON person USING gin (f_search_key(name)  gin_trgm_ops);
CREATE INDEX playlist_name_trgm_idx ON playlist USING gin (f_search_key(name) gin_trgm_ops);
CREATE INDEX app_user_name_trgm_idx ON app_user USING gin (f_search_key(display_name) gin_trgm_ops);
CREATE INDEX app_user_username_trgm_idx ON app_user USING gin (username gin_trgm_ops);

-- Full-text search:
--   WHERE search_vector @@ plainto_tsquery('simple', f_unaccent('dark side moon'))
CREATE INDEX artist_search_idx ON artist USING gin (search_vector);
CREATE INDEX album_search_idx  ON album  USING gin (search_vector);
CREATE INDEX track_search_idx  ON track  USING gin (search_vector);
CREATE INDEX song_search_idx   ON song   USING gin (search_vector);
CREATE INDEX person_search_idx ON person USING gin (search_vector);

/*******************************************************************************
   Triggers
********************************************************************************/

-- Slugs: generated when not supplied, with -2, -3... on clashes. They are not
-- changed when the name changes, so URLs stay stable.
--   TG_ARGV[0]  column the slug is built from
--   TG_ARGV[1]  column that scopes uniqueness ('' = unique in the whole table)
--   TG_ARGV[2]  extra column appended to the source when set ('' = none)
-- An advisory lock per (table, scope, base slug) serializes concurrent inserts
-- that would otherwise pick the same suffix.
CREATE FUNCTION set_slug() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    rec       JSONB := to_jsonb(NEW);
    pk        TEXT  := TG_TABLE_NAME || '_id';
    scope_col TEXT  := nullif(TG_ARGV[1], '');
    extra_col TEXT  := nullif(TG_ARGV[2], '');
    base      TEXT;
    candidate TEXT;
    n         INT := 1;
    taken     BOOLEAN;
BEGIN
    IF NEW.slug IS NOT NULL AND NEW.slug <> '' THEN
        RETURN NEW;
    END IF;

    base := coalesce(nullif(slugify(concat_ws(' ', rec ->> TG_ARGV[0],
                                              CASE WHEN extra_col IS NOT NULL THEN rec ->> extra_col END)), ''),
                     TG_TABLE_NAME);
    PERFORM pg_advisory_xact_lock(hashtextextended(
        concat_ws(':', TG_TABLE_NAME, CASE WHEN scope_col IS NOT NULL THEN rec ->> scope_col END, base), 0));

    candidate := base;
    LOOP
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.%I WHERE slug = $1 AND %I IS DISTINCT FROM $2%s)',
                       TG_TABLE_SCHEMA, TG_TABLE_NAME, pk,
                       CASE WHEN scope_col IS NULL THEN '' ELSE format(' AND %I = $3', scope_col) END)
        INTO taken
        USING candidate, (rec ->> pk)::INT, CASE WHEN scope_col IS NOT NULL THEN (rec ->> scope_col)::INT END;
        EXIT WHEN NOT taken;
        n := n + 1;
        candidate := base || '-' || n;
    END LOOP;

    NEW.slug := candidate;
    RETURN NEW;
END;
$$;

CREATE TRIGGER artist_set_slug BEFORE INSERT OR UPDATE OF slug ON artist
    FOR EACH ROW EXECUTE FUNCTION set_slug('name', '', '');
CREATE TRIGGER label_set_slug BEFORE INSERT OR UPDATE OF slug ON label
    FOR EACH ROW EXECUTE FUNCTION set_slug('name', '', '');
CREATE TRIGGER album_set_slug BEFORE INSERT OR UPDATE OF slug ON album
    FOR EACH ROW EXECUTE FUNCTION set_slug('title', 'artist_id', 'edition');

CREATE FUNCTION album_set_release_year() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.release_date IS NOT NULL THEN
        NEW.release_year := extract(year FROM NEW.release_date);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER album_set_release_year BEFORE INSERT OR UPDATE OF release_date ON album
    FOR EACH ROW EXECUTE FUNCTION album_set_release_year();

-- updated_at
CREATE TRIGGER artist_set_updated_at   BEFORE UPDATE ON artist   FOR EACH ROW EXECUTE FUNCTION set_updated_at('follower_count');
CREATE TRIGGER label_set_updated_at    BEFORE UPDATE ON label    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER album_set_updated_at    BEFORE UPDATE ON album    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER song_set_updated_at     BEFORE UPDATE ON song     FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER track_set_updated_at    BEFORE UPDATE ON track    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER playlist_set_updated_at BEFORE UPDATE ON playlist FOR EACH ROW EXECUTE FUNCTION set_updated_at('follower_count');
CREATE TRIGGER person_set_updated_at   BEFORE UPDATE ON person   FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER app_user_set_updated_at BEFORE UPDATE ON app_user FOR EACH ROW EXECUTE FUNCTION set_updated_at('follower_count', 'following_count');

/*
   Album artists (checked at commit, so rows can be added in any order):
   an album must list its credited artist in album_artist, or, for a
   collaboration, at least one of its parts.
*/
CREATE FUNCTION assert_album_artists(p_album_id INT) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    a RECORD;
BEGIN
    SELECT al.album_id, al.title, al.artist_id, ar.name, ar.artist_type
    INTO a
    FROM album al
    JOIN artist ar ON ar.artist_id = al.artist_id
    WHERE al.album_id = p_album_id;

    IF NOT FOUND THEN
        RETURN;  -- album was deleted
    END IF;

    IF a.artist_type IS DISTINCT FROM 'collaboration' THEN
        IF NOT EXISTS (SELECT 1 FROM album_artist
                       WHERE album_id = a.album_id AND artist_id = a.artist_id) THEN
            RAISE EXCEPTION 'album % "%": its credited artist "%" (%) must be listed in album_artist',
                a.album_id, a.title, a.name, a.artist_id
                USING ERRCODE = 'integrity_constraint_violation';
        END IF;
    ELSIF NOT EXISTS (SELECT 1 FROM album_artist WHERE album_id = a.album_id) THEN
        RAISE EXCEPTION 'album % "%" is credited to the collaboration "%": list its artists in album_artist',
            a.album_id, a.title, a.name
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;
END;
$$;

CREATE FUNCTION check_album_artists() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    al_id INT;
BEGIN
    IF TG_TABLE_NAME = 'artist' THEN
        FOR al_id IN SELECT album_id FROM album WHERE artist_id = NEW.artist_id LOOP
            PERFORM assert_album_artists(al_id);
        END LOOP;
        RETURN NULL;
    END IF;
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        PERFORM assert_album_artists(OLD.album_id);
    END IF;
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        PERFORM assert_album_artists(NEW.album_id);
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER album_check_artists
    AFTER INSERT OR UPDATE OF artist_id ON album
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION check_album_artists();
CREATE CONSTRAINT TRIGGER album_artist_check_artists
    AFTER INSERT OR UPDATE OR DELETE ON album_artist
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION check_album_artists();
CREATE CONSTRAINT TRIGGER artist_check_album_artists
    AFTER UPDATE OF artist_type ON artist
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION check_album_artists();

/*
   Album genres: an album that has genres has exactly one primary (checked at
   commit, so the primary can be moved in two steps).
*/
CREATE FUNCTION check_album_primary_genre() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    al_id INT;
    n_genres INT;
    n_primary INT;
BEGIN
    FOREACH al_id IN ARRAY ARRAY[CASE WHEN TG_OP <> 'INSERT' THEN OLD.album_id END,
                                 CASE WHEN TG_OP <> 'DELETE' THEN NEW.album_id END] LOOP
        CONTINUE WHEN al_id IS NULL;
        SELECT count(*), count(*) FILTER (WHERE is_primary)
        INTO n_genres, n_primary
        FROM album_genre WHERE album_id = al_id;
        IF n_genres > 0 AND n_primary <> 1 THEN
            RAISE EXCEPTION 'album % has % primary genres; it must have exactly one', al_id, n_primary
                USING ERRCODE = 'integrity_constraint_violation';
        END IF;
    END LOOP;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER album_genre_check_primary
    AFTER INSERT OR UPDATE OR DELETE ON album_genre
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION check_album_primary_genre();

-- A track's own genre is added to its album's genres (as primary if the album
-- has none yet), so track_album_genre_fkey always holds.
CREATE FUNCTION track_add_album_genre() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.genre_id IS NOT NULL THEN
        INSERT INTO album_genre (album_id, genre_id, is_primary)
        VALUES (NEW.album_id, NEW.genre_id,
                NOT EXISTS (SELECT 1 FROM album_genre WHERE album_id = NEW.album_id))
        ON CONFLICT (album_id, genre_id) DO NOTHING;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER track_add_album_genre BEFORE INSERT OR UPDATE OF album_id, genre_id ON track
    FOR EACH ROW EXECUTE FUNCTION track_add_album_genre();

/*
   Composer text: for songs with songwriting credits (or marked traditional),
   track.composer is generated from credit, in credit order, using the name as
   credited. Songs without credits keep the composer text they were given.
*/
CREATE FUNCTION song_composer_text(p_song_id INT) RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT nullif(concat_ws(', ',
               CASE WHEN s.is_traditional THEN 'Traditional' END,
               (SELECT string_agg(CASE WHEN c.role = 'arranger' THEN 'arr. ' ELSE '' END
                                  || coalesce(c.credited_as, p.name), ', ' ORDER BY c.position, c.credit_id)
                FROM credit c
                JOIN credit_role cr ON cr.code = c.role AND cr.is_songwriting
                JOIN person p       ON p.person_id = c.person_id
                WHERE c.song_id = s.song_id)), '')
    FROM song s
    WHERE s.song_id = p_song_id
$$;

CREATE FUNCTION track_set_composer() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    generated TEXT;
BEGIN
    IF NEW.song_id IS NOT NULL THEN
        generated := song_composer_text(NEW.song_id);
        IF generated IS NOT NULL THEN
            NEW.composer := generated;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER track_set_composer BEFORE INSERT OR UPDATE OF composer, song_id ON track
    FOR EACH ROW EXECUTE FUNCTION track_set_composer();

-- When credits (or the traditional flag) change, regenerate the text of every
-- recording of the song. With no credits left the text is cleared.
CREATE FUNCTION refresh_song_composer() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    s_id INT;
BEGIN
    FOREACH s_id IN ARRAY ARRAY[CASE WHEN TG_OP <> 'INSERT' THEN OLD.song_id END,
                                CASE WHEN TG_OP <> 'DELETE' THEN NEW.song_id END] LOOP
        CONTINUE WHEN s_id IS NULL;
        UPDATE track
        SET composer = song_composer_text(s_id)
        WHERE song_id = s_id
          AND composer IS DISTINCT FROM song_composer_text(s_id);
    END LOOP;
    RETURN NULL;
END;
$$;

CREATE TRIGGER credit_refresh_composer AFTER INSERT OR UPDATE OR DELETE ON credit
    FOR EACH ROW EXECUTE FUNCTION refresh_song_composer();
CREATE TRIGGER song_refresh_composer AFTER UPDATE OF is_traditional ON song
    FOR EACH ROW EXECUTE FUNCTION refresh_song_composer();

/*
   Playlist access. The API asks these before reading or changing a playlist.
   Unlisted playlists are opened by share_token, which the API checks itself.
*/
CREATE FUNCTION playlist_can_edit(p_playlist_id INT, p_user_id INT) RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT EXISTS (SELECT 1 FROM playlist WHERE playlist_id = p_playlist_id AND owner_id = p_user_id)
        OR EXISTS (SELECT 1 FROM playlist_collaborator c
                   JOIN playlist_role r ON r.code = c.role AND r.can_edit
                   WHERE c.playlist_id = p_playlist_id AND c.user_id = p_user_id)
$$;

CREATE FUNCTION playlist_can_view(p_playlist_id INT, p_user_id INT) RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT EXISTS (SELECT 1 FROM playlist WHERE playlist_id = p_playlist_id
                   AND (visibility = 'public' OR owner_id = p_user_id))
        OR EXISTS (SELECT 1 FROM playlist_collaborator
                   WHERE playlist_id = p_playlist_id AND user_id = p_user_id)
$$;

-- The owner is never listed as a collaborator
CREATE FUNCTION playlist_collaborator_check() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM playlist WHERE playlist_id = NEW.playlist_id AND owner_id = NEW.user_id) THEN
        RAISE EXCEPTION 'user % owns playlist % and can''t also be a collaborator', NEW.user_id, NEW.playlist_id
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER playlist_collaborator_check BEFORE INSERT OR UPDATE ON playlist_collaborator
    FOR EACH ROW EXECUTE FUNCTION playlist_collaborator_check();

-- Playlist entries: append to the end when no position is given, and record
-- the owner as added_by when nobody is given. Locks the playlist row so
-- concurrent appends don't pick the same position. Only the owner and
-- editors can add tracks.
CREATE FUNCTION playlist_track_prepare() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    owner INT;
BEGIN
    SELECT owner_id INTO owner FROM playlist WHERE playlist_id = NEW.playlist_id FOR UPDATE;
    IF TG_OP = 'INSERT' THEN
        IF NEW.position IS NULL THEN
            SELECT coalesce(max(position), 0) + 1 INTO NEW.position
            FROM playlist_track WHERE playlist_id = NEW.playlist_id;
        END IF;
        NEW.added_by := coalesce(NEW.added_by, owner);
    END IF;
    IF NEW.added_by IS NOT NULL AND NOT playlist_can_edit(NEW.playlist_id, NEW.added_by) THEN
        RAISE EXCEPTION 'user % can''t add tracks to playlist %: only its owner and editors can',
            NEW.added_by, NEW.playlist_id
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER playlist_track_prepare BEFORE INSERT OR UPDATE OF playlist_id, added_by ON playlist_track
    FOR EACH ROW EXECUTE FUNCTION playlist_track_prepare();

-- playlist.version goes up by one for each INSERT, UPDATE or DELETE statement
-- that changes a playlist's track list (a statement combining two, like a
-- DELETE plus renumbering, counts twice). Clients send the version they
-- loaded; a different current version means someone else edited it in between.
CREATE FUNCTION playlist_bump_version() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE playlist SET version = version + 1
        WHERE playlist_id IN (SELECT playlist_id FROM new_rows);
    ELSIF TG_OP = 'DELETE' THEN
        UPDATE playlist SET version = version + 1
        WHERE playlist_id IN (SELECT playlist_id FROM old_rows);
    ELSE
        UPDATE playlist SET version = version + 1
        WHERE playlist_id IN (SELECT playlist_id FROM old_rows UNION SELECT playlist_id FROM new_rows);
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER playlist_track_version_insert AFTER INSERT ON playlist_track
    REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION playlist_bump_version();
CREATE TRIGGER playlist_track_version_update AFTER UPDATE ON playlist_track
    REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION playlist_bump_version();
CREATE TRIGGER playlist_track_version_delete AFTER DELETE ON playlist_track
    REFERENCING OLD TABLE AS old_rows FOR EACH STATEMENT EXECUTE FUNCTION playlist_bump_version();

/*
   Follower counts: a follow row adds 1 to the followed row's counter and
   removing it subtracts 1.
     TG_ARGV[0]  table that holds the counter    TG_ARGV[1]  its key column
     TG_ARGV[2]  column here that points to it   TG_ARGV[3]  counter column
*/
CREATE FUNCTION adjust_count() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    sql TEXT := format('UPDATE %I SET %I = %I + $1 WHERE %I = $2',
                       TG_ARGV[0], TG_ARGV[3], TG_ARGV[3], TG_ARGV[1]);
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        EXECUTE sql USING -1, (to_jsonb(OLD) ->> TG_ARGV[2])::INT;
    END IF;
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        EXECUTE sql USING 1, (to_jsonb(NEW) ->> TG_ARGV[2])::INT;
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER playlist_follow_count AFTER INSERT OR UPDATE OR DELETE ON playlist_follow
    FOR EACH ROW EXECUTE FUNCTION adjust_count('playlist', 'playlist_id', 'playlist_id', 'follower_count');
CREATE TRIGGER artist_follow_count AFTER INSERT OR UPDATE OR DELETE ON artist_follow
    FOR EACH ROW EXECUTE FUNCTION adjust_count('artist', 'artist_id', 'artist_id', 'follower_count');
CREATE TRIGGER user_follow_follower_count AFTER INSERT OR UPDATE OR DELETE ON user_follow
    FOR EACH ROW EXECUTE FUNCTION adjust_count('app_user', 'user_id', 'followed_id', 'follower_count');
CREATE TRIGGER user_follow_following_count AFTER INSERT OR UPDATE OR DELETE ON user_follow
    FOR EACH ROW EXECUTE FUNCTION adjust_count('app_user', 'user_id', 'follower_id', 'following_count');

/*
   Limits of the web UI (design: DB-Design.md DB-01, DB-04, DB-05):
     at most 5 favorites (playlist_follow rows) per user, own playlists included;
     at most 20 entries per playlist;
     at most 20 playlists owned per user (collaborations don't count).
   Each check locks the parent row first, so two simultaneous inserts are counted
   one after the other and can't pass the limit together. The errors are
   check_violations named after the trigger, which the API maps to HTTP by name:
   playlist_follow_limit, playlist_track_limit, playlist_owner_limit.
   (FOR NO KEY UPDATE on app_user doesn't block other transactions' foreign key
   checks against that user.)
*/
CREATE FUNCTION playlist_follow_limit() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM app_user WHERE user_id = NEW.user_id FOR NO KEY UPDATE;
    IF (SELECT count(*) FROM playlist_follow WHERE user_id = NEW.user_id) >= 5 THEN
        RAISE EXCEPTION 'user % already has 5 favorite playlists', NEW.user_id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'playlist_follow_limit';
    END IF;
    RETURN NEW;
END;
$$;

-- Runs before ON CONFLICT is resolved: re-favoriting one of your 5 is refused
-- too, so check for the row first.
CREATE TRIGGER playlist_follow_limit BEFORE INSERT ON playlist_follow
    FOR EACH ROW EXECUTE FUNCTION playlist_follow_limit();

CREATE FUNCTION playlist_track_limit() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM playlist WHERE playlist_id = NEW.playlist_id FOR UPDATE;
    IF (SELECT count(*) FROM playlist_track WHERE playlist_id = NEW.playlist_id) >= 20 THEN
        RAISE EXCEPTION 'playlist % already has 20 tracks', NEW.playlist_id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'playlist_track_limit';
    END IF;
    RETURN NEW;
END;
$$;

-- Inserts only: moving and removing entries never add rows. Nine sample
-- playlists are older than the limit and have more (see 02_data.sql): nothing
-- more can be added to them, but entries can still be moved and removed.
CREATE TRIGGER playlist_track_limit BEFORE INSERT ON playlist_track
    FOR EACH ROW EXECUTE FUNCTION playlist_track_limit();

CREATE FUNCTION playlist_owner_limit() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM app_user WHERE user_id = NEW.owner_id FOR NO KEY UPDATE;
    IF (SELECT count(*) FROM playlist WHERE owner_id = NEW.owner_id) >= 20 THEN
        RAISE EXCEPTION 'user % already owns 20 playlists', NEW.owner_id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'playlist_owner_limit';
    END IF;
    RETURN NEW;
END;
$$;

-- Playlists don't change owner, so only inserts are checked.
CREATE TRIGGER playlist_owner_limit BEFORE INSERT ON playlist
    FOR EACH ROW EXECUTE FUNCTION playlist_owner_limit();

/*
   Visibility follows favorites (DB-Design.md DB-03): a playlist is public while
   at least one user (its owner or anyone else) has it as a favorite, and private
   when nobody does. Nobody sets it directly:
     - new playlists are always private (they have no favorites yet);
     - after every favorite or unfavorite, the playlist's visibility is set again;
     - any other change of visibility fails with check_violation
       playlist_visibility_derived.
   pg_trigger_depth() is 1 in a trigger fired by a client's statement and 2 or
   more for the UPDATE issued by playlist_visibility_from_favorites, which is
   how the guard tells the two apart. A visibility change sets updated_at but
   not version (which counts track-list changes only).
*/
CREATE FUNCTION playlist_visibility_from_favorites() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    pid    INT := coalesce(NEW.playlist_id, OLD.playlist_id);
    wanted TEXT;
BEGIN
    -- Lock the playlist so two favorites removed at the same moment see each
    -- other's change (each statement below takes a new snapshot after the lock).
    PERFORM 1 FROM playlist WHERE playlist_id = pid FOR UPDATE;
    IF NOT FOUND THEN
        RETURN NULL;                -- the playlist itself is being deleted (cascade)
    END IF;
    wanted := CASE WHEN EXISTS (SELECT 1 FROM playlist_follow WHERE playlist_id = pid)
                   THEN 'public' ELSE 'private' END;
    UPDATE playlist SET visibility = wanted
    WHERE playlist_id = pid AND visibility IS DISTINCT FROM wanted;
    RETURN NULL;
END;
$$;

CREATE TRIGGER playlist_visibility_from_favorites AFTER INSERT OR DELETE ON playlist_follow
    FOR EACH ROW EXECUTE FUNCTION playlist_visibility_from_favorites();

CREATE FUNCTION playlist_visibility_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.visibility := 'private';
    ELSIF NEW.visibility IS DISTINCT FROM OLD.visibility AND pg_trigger_depth() < 2 THEN
        RAISE EXCEPTION 'playlist %: visibility follows favorites and can''t be set directly', NEW.playlist_id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'playlist_visibility_derived';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER playlist_visibility_guard BEFORE INSERT OR UPDATE OF visibility ON playlist
    FOR EACH ROW EXECUTE FUNCTION playlist_visibility_guard();

/*******************************************************************************
   Views for read endpoints
********************************************************************************/

-- One row per track with its song, album, artists and genre resolved.
--   artist_*       the album's credited artist (as on the cover)
--   track_artists  who performs this track: track_artist when set, else the album's artists
--   genre_*        the track's own genre, else the album's primary genre
CREATE VIEW track_detail AS
SELECT t.track_id,
       t.name                    AS track_name,
       t.disc_number,
       t.track_number,
       t.milliseconds,
       to_char(make_interval(secs => t.milliseconds / 1000.0), 'FMMI:SS') AS duration,
       t.composer,
       t.isrc,
       s.song_id,
       s.title                   AS song_title,
       al.album_id,
       al.title                  AS album_title,
       al.slug                   AS album_slug,
       al.edition                AS album_edition,
       al.release_date,
       al.release_year,
       al.album_type,
       ar.artist_id,
       ar.name                   AS artist_name,
       ar.slug                   AS artist_slug,
       perf.track_artists,
       g.genre_id,
       g.name                    AS genre_name,
       (t.genre_id IS NOT NULL)  AS has_own_genre
FROM track t
JOIN album       al ON al.album_id      = t.album_id
JOIN artist      ar ON ar.artist_id     = al.artist_id
LEFT JOIN song   s  ON s.song_id        = t.song_id
LEFT JOIN album_genre pg ON pg.album_id = t.album_id AND pg.is_primary
LEFT JOIN genre  g  ON g.genre_id       = coalesce(t.genre_id, pg.genre_id)
LEFT JOIN LATERAL (
    SELECT array_agg(a.name ORDER BY x.position, a.name) AS track_artists
    FROM (SELECT ta.artist_id, ta.position FROM track_artist ta WHERE ta.track_id = t.track_id
          UNION ALL
          SELECT aa.artist_id, aa.position FROM album_artist aa
          WHERE aa.album_id = t.album_id
            AND NOT EXISTS (SELECT 1 FROM track_artist ta WHERE ta.track_id = t.track_id)) x
    JOIN artist a ON a.artist_id = x.artist_id
) perf ON true;

-- One row per album with label, track count, running time and genres.
CREATE VIEW album_summary AS
SELECT al.album_id,
       al.title,
       al.edition,
       al.slug,
       al.release_date,
       al.release_year,
       al.album_type,
       l.label_id,
       l.name                                  AS label,
       al.upc,
       al.cover_url,
       ar.artist_id,
       ar.name                                 AS artist_name,
       ar.slug                                 AS artist_slug,
       gen.primary_genre,
       gen.genres,
       coalesce(trk.track_count, 0)            AS track_count,
       coalesce(trk.disc_count, 0)             AS disc_count,
       coalesce(trk.total_milliseconds, 0)     AS total_milliseconds
FROM album al
JOIN artist ar     ON ar.artist_id = al.artist_id
LEFT JOIN label l  ON l.label_id   = al.label_id
LEFT JOIN LATERAL (
    SELECT max(g.name) FILTER (WHERE ag.is_primary)                AS primary_genre,
           array_agg(g.name ORDER BY ag.is_primary DESC, g.name)   AS genres
    FROM album_genre ag
    JOIN genre g ON g.genre_id = ag.genre_id
    WHERE ag.album_id = al.album_id
) gen ON true
LEFT JOIN LATERAL (
    SELECT count(*)            AS track_count,
           max(t.disc_number)  AS disc_count,
           sum(t.milliseconds) AS total_milliseconds
    FROM track t
    WHERE t.album_id = al.album_id
) trk ON true;

-- One row per artist with album and track counts. Albums count when the
-- artist is credited on the cover or listed in album_artist (so both
-- "Page & Plant" and Jimmy Page get the album); tracks also include
-- track_artist appearances.
CREATE VIEW artist_summary AS
SELECT ar.artist_id,
       ar.name,
       ar.slug,
       ar.artist_type,
       ar.person_id,
       ar.country_code,
       ar.formed_year,
       ar.disbanded_year,
       ar.image_url,
       ar.follower_count,
       alb.album_count,
       trk.track_count
FROM artist ar
CROSS JOIN LATERAL (
    SELECT count(*) AS album_count
    FROM (SELECT album_id FROM album WHERE artist_id = ar.artist_id
          UNION
          SELECT album_id FROM album_artist WHERE artist_id = ar.artist_id) a
) alb
CROSS JOIN LATERAL (
    SELECT count(*) AS track_count
    FROM (SELECT t.track_id
          FROM track t
          WHERE t.album_id IN (SELECT album_id FROM album WHERE artist_id = ar.artist_id
                               UNION
                               SELECT album_id FROM album_artist WHERE artist_id = ar.artist_id)
          UNION
          SELECT track_id FROM track_artist WHERE artist_id = ar.artist_id) t
) trk;

-- One row per playlist with owner, collaborators, length and followers.
-- share_token is left out on purpose: only the owner should see it.
CREATE VIEW playlist_summary AS
SELECT p.playlist_id,
       p.name,
       p.description,
       p.visibility,
       p.cover_url,
       p.version,
       p.follower_count,
       u.user_id                                AS owner_id,
       u.username                               AS owner_username,
       u.display_name                           AS owner_name,
       coalesce(col.editor_count, 0) > 0        AS is_collaborative,
       coalesce(col.collaborator_count, 0)      AS collaborator_count,
       coalesce(trk.track_count, 0)             AS track_count,
       coalesce(trk.total_milliseconds, 0)      AS total_milliseconds,
       p.created_at,
       p.updated_at
FROM playlist p
JOIN app_user u ON u.user_id = p.owner_id
LEFT JOIN LATERAL (
    SELECT count(*)                                AS collaborator_count,
           count(*) FILTER (WHERE r.can_edit)      AS editor_count
    FROM playlist_collaborator c
    JOIN playlist_role r ON r.code = c.role
    WHERE c.playlist_id = p.playlist_id
) col ON true
LEFT JOIN LATERAL (
    SELECT count(*)            AS track_count,
           sum(t.milliseconds) AS total_milliseconds
    FROM playlist_track pt
    JOIN track t ON t.track_id = pt.track_id
    WHERE pt.playlist_id = p.playlist_id
) trk ON true;

/*******************************************************************************
   Search
   One call for a search box: substring (accent-insensitive, via the trigram
   indexes) or full-text matches across artists, albums, songs, tracks,
   people, public playlists and users, best first.
     SELECT * FROM search_catalog('jose');
     SELECT * FROM search_catalog('dark side moon', 5);
********************************************************************************/
CREATE FUNCTION search_catalog(query TEXT, max_results INT DEFAULT 20)
RETURNS TABLE (kind TEXT, id INT, name TEXT, slug TEXT, context TEXT, score REAL)
LANGUAGE sql STABLE AS $$
    WITH s AS (
        SELECT f_search_key(query) AS key,
               '%' || replace(replace(replace(f_search_key(query), '\', '\\'), '%', '\%'), '_', '\_') || '%' AS pattern,
               plainto_tsquery('simple', f_unaccent(query)) AS tsq
    )
    SELECT r.kind, r.id, r.name, r.slug, r.context, r.score
    FROM (
        SELECT 'artist' AS kind, a.artist_id AS id, a.name::text AS name, a.slug::text AS slug,
               NULL::text AS context,
               greatest(similarity(f_search_key(a.name), s.key), ts_rank(a.search_vector, s.tsq)) AS score
        FROM artist a, s
        WHERE f_search_key(a.name) LIKE s.pattern OR a.search_vector @@ s.tsq
        UNION ALL
        SELECT 'album', al.album_id, al.title, al.slug, ar.name,
               greatest(similarity(f_search_key(al.title), s.key), ts_rank(al.search_vector, s.tsq))
        FROM album al JOIN artist ar ON ar.artist_id = al.artist_id, s
        WHERE f_search_key(al.title) LIKE s.pattern OR al.search_vector @@ s.tsq
        UNION ALL
        SELECT 'song', so.song_id, so.title, NULL, ar.name,
               greatest(similarity(f_search_key(so.title), s.key), ts_rank(so.search_vector, s.tsq))
        FROM song so LEFT JOIN artist ar ON ar.artist_id = so.artist_id, s
        WHERE f_search_key(so.title) LIKE s.pattern OR so.search_vector @@ s.tsq
        UNION ALL
        SELECT 'track', t.track_id, t.name, NULL, al.title || ' — ' || ar.name,
               greatest(similarity(f_search_key(t.name), s.key), ts_rank(t.search_vector, s.tsq))
        FROM track t JOIN album al ON al.album_id = t.album_id JOIN artist ar ON ar.artist_id = al.artist_id, s
        WHERE f_search_key(t.name) LIKE s.pattern OR t.search_vector @@ s.tsq
        UNION ALL
        SELECT 'person', p.person_id, p.name, NULL, p.birth_name,
               greatest(similarity(f_search_key(p.name), s.key), ts_rank(p.search_vector, s.tsq))
        FROM person p, s
        WHERE f_search_key(p.name) LIKE s.pattern OR p.search_vector @@ s.tsq
        UNION ALL
        SELECT 'playlist', pl.playlist_id, pl.name, NULL, u.display_name,
               similarity(f_search_key(pl.name), s.key)
        FROM playlist pl JOIN app_user u ON u.user_id = pl.owner_id, s
        WHERE pl.visibility = 'public' AND f_search_key(pl.name) LIKE s.pattern
        UNION ALL
        SELECT 'user', u.user_id, u.display_name, u.username, NULL,
               greatest(similarity(f_search_key(u.display_name), s.key), similarity(u.username, s.key))
        FROM app_user u, s
        WHERE f_search_key(u.display_name) LIKE s.pattern OR u.username LIKE s.pattern
    ) r
    ORDER BY r.score DESC, r.kind, r.name
    LIMIT max_results
$$;

/*
   Song search (DB-Design.md DB-08): tracks by their name, their artists' names
   or their album's title, accent- and case-insensitive. search_catalog matches
   track names only, so tracks get a materialized view of normalized text.
   Refresh it after catalog changes (02_data.sql does at the end of the load, and
   api-spring-music after /admin writes):
     REFRESH MATERIALIZED VIEW CONCURRENTLY track_search;
     SELECT * FROM search_tracks('jose', 5);
     SELECT td.track_name, s.score, s.total FROM search_tracks('daft punk') s JOIN track_detail td USING (track_id);
*/
CREATE MATERIALIZED VIEW track_search AS
SELECT td.track_id,
       f_search_key(td.track_name) AS name_key,
       f_search_key(concat_ws(' ', td.track_name, array_to_string(td.track_artists, ' '), td.album_title)) AS search_key
FROM track_detail td;

CREATE UNIQUE INDEX track_search_pkey ON track_search (track_id);   -- needed by REFRESH ... CONCURRENTLY
CREATE INDEX track_search_trgm_idx ON track_search USING gin (search_key gin_trgm_ops);
CREATE INDEX track_search_fts_idx  ON track_search USING gin (to_tsvector('simple', search_key));

-- Matches rank: the whole name (1.0), the start of the name (0.9), anywhere in the
-- name (0.8), then matches in the artist or album only (0.5 to 0.75, by word
-- similarity). total is the same on every row (for paging). Fewer than 2
-- characters match nothing.
CREATE FUNCTION search_tracks(query TEXT, max_results INT DEFAULT 20, skip INT DEFAULT 0)
RETURNS TABLE (track_id INT, score REAL, total BIGINT)
LANGUAGE sql STABLE AS $$
    WITH s AS (
        SELECT f_search_key(btrim(query)) AS key,
               replace(replace(replace(f_search_key(btrim(query)), '\', '\\'), '%', '\%'), '_', '\_') AS escaped
    ), hits AS (
        SELECT ts.track_id, ts.name_key,
               (CASE WHEN ts.name_key = s.key                       THEN 1.0
                     WHEN ts.name_key LIKE s.escaped || '%'         THEN 0.9
                     WHEN ts.name_key LIKE '%' || s.escaped || '%'  THEN 0.8
                     ELSE 0.5 + 0.25 * word_similarity(s.key, ts.search_key)
                END)::real AS score
        FROM track_search ts, s
        WHERE length(s.key) >= 2
          AND (ts.search_key LIKE '%' || s.escaped || '%'
               OR to_tsvector('simple', ts.search_key) @@ plainto_tsquery('simple', s.key))
    )
    SELECT h.track_id, h.score, count(*) OVER () AS total
    FROM hits h
    ORDER BY h.score DESC, h.name_key, h.track_id
    LIMIT max_results OFFSET skip
$$;

/*
   Random picks (DB-Design.md DB-06, DB-07).
   random_tracks picks random IDs through the primary key instead of reading
   the whole catalog with ORDER BY random(). It draws 3 times as many IDs as
   asked for, to make up for gaps in the IDs and for exclusions, so it can come
   back a little short; callers ask again for the rest.
     SELECT td.* FROM random_tracks(20, '{3674,3668}') r(track_id) JOIN track_detail td USING (track_id);
   random_playlists returns public playlists that the user neither owns nor has
   as a favorite (any public playlist when the user is NULL). Every public
   playlist is someone's favorite and each user has at most 5, so ORDER BY
   random() stays cheap.
*/
CREATE FUNCTION random_tracks(max_results INT DEFAULT 20, exclude INT[] DEFAULT '{}')
RETURNS SETOF INT
LANGUAGE sql VOLATILE AS $$
    WITH bounds AS (SELECT min(track_id) AS lo, max(track_id) AS hi FROM track),
    picks AS (
        SELECT DISTINCT (b.lo + floor(random() * (b.hi - b.lo + 1)))::int AS track_id
        FROM bounds b, generate_series(1, greatest(max_results, 1) * 3)
    )
    SELECT t.track_id
    FROM picks
    JOIN track t ON t.track_id = picks.track_id
    WHERE t.track_id <> ALL (coalesce(exclude, '{}'))
    LIMIT max_results
$$;

CREATE FUNCTION random_playlists(p_user_id INT, max_results INT DEFAULT 12, exclude INT[] DEFAULT '{}')
RETURNS SETOF INT
LANGUAGE sql VOLATILE AS $$
    SELECT p.playlist_id
    FROM playlist p
    WHERE p.visibility = 'public'
      AND p.owner_id IS DISTINCT FROM p_user_id
      AND p.playlist_id <> ALL (coalesce(exclude, '{}'))
      AND NOT EXISTS (SELECT 1 FROM playlist_follow f
                      WHERE f.playlist_id = p.playlist_id AND f.user_id = p_user_id)
    ORDER BY random()
    LIMIT max_results
$$;

/*******************************************************************************
   Authentication (schema "auth")
   Passwords and roles of the accounts that log in through api-spring-music,
   which issues the tokens. Kept apart from the music schema; the API's Flyway
   migration V1__auth_schema.sql creates the same tables on databases loaded
   before this section existed, so keep the two in sync.

   - role:          lookup table of account roles (listener < curator < admin)
   - user_account:  password hash and role of an app_user
   - refresh_token: rotating refresh tokens, stored only as SHA-256 hashes

   Rows reference public.app_user with ON DELETE CASCADE, so deleting an account
   also removes its credentials and sessions.
********************************************************************************/
CREATE SCHEMA auth;

CREATE TABLE auth.role
(
    code        VARCHAR(20) NOT NULL,
    description TEXT        NOT NULL,
    CONSTRAINT role_pkey PRIMARY KEY (code)
);

INSERT INTO auth.role (code, description) VALUES
    ('listener', 'Regular account: playlists, library and follows'),
    ('curator',  'Can also edit the catalog: artists, albums, tracks, credits and genres'),
    ('admin',    'Can also manage accounts: roles and passwords');

CREATE TABLE auth.user_account
(
    user_id             INT         NOT NULL,
    role                VARCHAR(20) NOT NULL DEFAULT 'listener',
    password_hash       TEXT,                   -- NULL: no password login (for example the seed users)
    password_changed_at TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT user_account_pkey PRIMARY KEY (user_id),
    CONSTRAINT user_account_user_id_fkey
        FOREIGN KEY (user_id) REFERENCES public.app_user (user_id) ON DELETE CASCADE,
    CONSTRAINT user_account_role_fkey
        FOREIGN KEY (role) REFERENCES auth.role (code) ON UPDATE CASCADE
);

-- One row per issued refresh token. Every token from one login shares a family;
-- presenting a token that was already used revokes the whole family (reuse detection).
CREATE TABLE auth.refresh_token
(
    token_id   UUID        NOT NULL DEFAULT gen_random_uuid(),
    family_id  UUID        NOT NULL,
    user_id    INT         NOT NULL,
    token_hash BYTEA       NOT NULL,            -- SHA-256 of the token; the token itself is never stored
    issued_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL,
    used_at    TIMESTAMPTZ,                     -- exchanged for a new token (rotation)
    revoked_at TIMESTAMPTZ,                     -- logout, password change or detected reuse
    CONSTRAINT refresh_token_pkey PRIMARY KEY (token_id),
    CONSTRAINT refresh_token_user_id_fkey
        FOREIGN KEY (user_id) REFERENCES public.app_user (user_id) ON DELETE CASCADE,
    CONSTRAINT refresh_token_expiry_check CHECK (expires_at > issued_at)
);

CREATE UNIQUE INDEX refresh_token_token_hash_key ON auth.refresh_token (token_hash);
CREATE INDEX refresh_token_user_id_idx   ON auth.refresh_token (user_id);
CREATE INDEX refresh_token_family_id_idx ON auth.refresh_token (family_id);
CREATE INDEX refresh_token_expires_at_idx ON auth.refresh_token (expires_at);
