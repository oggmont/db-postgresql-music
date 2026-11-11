-- Example queries against music-db.
-- Run inside psql with: \i /queries/examples.sql

-- 1. Number of tracks and total duration (minutes) per genre
--    (track_detail resolves the genre: the track's own, else the album's primary)
SELECT genre_name AS genre, COUNT(*) AS tracks, ROUND(SUM(milliseconds) / 60000.0) AS minutes
FROM track_detail
GROUP BY genre_name
ORDER BY tracks DESC;

-- 2. The Beatles discography with track count and running time
SELECT release_year, title, album_type, track_count,
       to_char(make_interval(secs => total_milliseconds / 1000), 'FMHH24:MI:SS') AS length
FROM album_summary
WHERE artist_name = 'The Beatles'
ORDER BY release_date, title;

-- 3. Full track listing of an album, in order
SELECT disc_number, track_number, track_name, duration, composer
FROM track_detail
WHERE artist_name = 'The Beatles' AND album_title = 'Abbey Road'
ORDER BY disc_number, track_number;

-- 4. Case- and accent-insensitive search across tracks (uses the trigram index)
SELECT d.track_name, d.album_title, d.artist_name, d.duration
FROM track t
JOIN track_detail d ON d.track_id = t.track_id
WHERE f_search_key(t.name) LIKE '%' || f_search_key('love') || '%'
ORDER BY d.artist_name, d.release_date NULLS LAST, d.track_name
LIMIT 20;

-- 5. Band line-up: members, roles and years
SELECT p.name, p.birth_name, array_to_string(m.roles, ', ') AS roles, m.joined_year, m.left_year, p.birth_date, p.death_date
FROM artist_member m
JOIN person p  ON p.person_id  = m.person_id
JOIN artist ar ON ar.artist_id = m.artist_id
WHERE ar.name = 'The Beatles'
ORDER BY m.joined_year, m.left_year DESC, p.name;

-- 6. Songs released on the most Beatles albums
SELECT track_name, count(*) AS albums, string_agg(album_title, ' | ' ORDER BY release_date) AS appears_on
FROM track_detail
WHERE artist_name = 'The Beatles'
GROUP BY track_name
HAVING count(*) > 2
ORDER BY albums DESC, track_name;

-- 7. Every recording of a song (studio, live, demo, compilation...)
SELECT track_name, album_title, release_year, duration
FROM track_detail
WHERE song_id = (SELECT song_id FROM song WHERE title = 'Strawberry Fields Forever')
ORDER BY release_year, track_id;

-- 8. Songwriting credits of a person (credited_as: the name as printed)
SELECT s.title AS song, c.role, c.credited_as, ar.name AS artist
FROM credit c
JOIN person p  ON p.person_id  = c.person_id
JOIN song s    ON s.song_id    = c.song_id
JOIN artist ar ON ar.artist_id = s.artist_id
WHERE p.name = 'Ringo Starr'
ORDER BY s.title;

-- 9. Every album an artist appears on: their own (album_artist) and other
--     artists' albums and compilations where they perform a track (track_artist)
SELECT al.title, credited.name AS credited_as, x.role, x.tracks
FROM (
    SELECT aa.album_id, aa.role, NULL::bigint AS tracks
    FROM album_artist aa JOIN artist a ON a.artist_id = aa.artist_id
    WHERE a.slug = 'bee-gees'
    UNION ALL
    SELECT t.album_id, ta.role, count(*)
    FROM track_artist ta JOIN artist a ON a.artist_id = ta.artist_id JOIN track t ON t.track_id = ta.track_id
    WHERE a.slug = 'bee-gees'
    GROUP BY t.album_id, ta.role
) x
JOIN album al        ON al.album_id = x.album_id
JOIN artist credited ON credited.artist_id = al.artist_id
ORDER BY al.release_date NULLS LAST, al.title;

-- 10. Albums in a genre or any of its subgenres (e.g. Rock -> Progressive Rock)
WITH RECURSIVE g AS (
    SELECT genre_id FROM genre WHERE name = 'Rock'
    UNION ALL
    SELECT c.genre_id FROM genre c JOIN g ON c.parent_genre_id = g.genre_id
)
SELECT DISTINCT a.title, a.artist_name, a.release_year
FROM album_summary a
JOIN album_genre ag ON ag.album_id = a.album_id
WHERE ag.genre_id IN (SELECT genre_id FROM g)
ORDER BY a.release_year NULLS LAST, a.title
LIMIT 20;

-- 11. Accent-insensitive search ("jose" finds "José José"), uses the trigram index
SELECT name, slug
FROM artist
WHERE f_search_key(name) LIKE '%' || f_search_key('jose') || '%';

-- 12. Full-text search over track names and songwriters, ranked
SELECT d.track_name, d.artist_name, d.composer,
       ts_rank(t.search_vector, q) AS rank
FROM track t
JOIN track_detail d ON d.track_id = t.track_id,
     plainto_tsquery('simple', f_unaccent('gilmour time')) AS q
WHERE t.search_vector @@ q
ORDER BY rank DESC
LIMIT 10;

-- 13. Look up by slug (for URLs like /artists/pink-floyd/albums/the-wall)
SELECT al.title, al.release_year, al.album_type
FROM album al
JOIN artist ar ON ar.artist_id = al.artist_id
WHERE ar.slug = 'pink-floyd' AND al.slug = 'the-wall';

-- 14. One search box across artists, albums, songs, tracks and people
SELECT * FROM search_catalog('jose');

-- 15. Who performs each track of a compilation
--     (track_artists falls back to the album's artists)
SELECT track_number, track_name, artist_name AS credited_as, track_artists
FROM track_detail
WHERE album_title = 'Tomorrowland 2012_02'
ORDER BY disc_number, track_number;

-- 16. A playlist in order
SELECT pt.position, d.track_name, d.album_title, d.duration
FROM playlist p
JOIN playlist_track pt ON pt.playlist_id = p.playlist_id
JOIN track_detail d    ON d.track_id     = pt.track_id
WHERE p.name = 'Run'
ORDER BY pt.position
LIMIT 20;

-- 17. Tracks whose genre differs from their album's primary genre
SELECT d.album_title, d.track_name, d.genre_name, a.primary_genre AS album_genre
FROM track_detail d
JOIN album_summary a ON a.album_id = d.album_id
WHERE d.has_own_genre
ORDER BY d.album_title, d.track_number;

-- 18. Albums by label
SELECT l.name AS label, count(*) AS albums, min(al.release_year) AS first, max(al.release_year) AS last
FROM album al
JOIN label l ON l.label_id = al.label_id
GROUP BY l.name
ORDER BY albums DESC, l.name
LIMIT 15;

-- 19. A user's playlists, with size and running time
SELECT ps.name, ps.visibility, ps.track_count,
       to_char(make_interval(secs => ps.total_milliseconds / 1000), 'FMHH24:MI:SS') AS length
FROM playlist_summary ps
WHERE ps.owner_username = 'oscargm'
ORDER BY ps.playlist_id;

-- 20. When tracks were added to a playlist, by month
SELECT date_trunc('month', pt.added_at)::date AS month, count(*) AS tracks
FROM playlist p
JOIN playlist_track pt ON pt.playlist_id = p.playlist_id
WHERE p.name = 'Run'
GROUP BY 1
ORDER BY 1;

-- 21. Liked songs that aren't in any of the user's playlists
SELECT d.track_name, d.artist_name, d.album_title
FROM user_saved_track s
JOIN app_user u     ON u.user_id  = s.user_id
JOIN track_detail d ON d.track_id = s.track_id
WHERE u.username = 'oscargm'
  AND NOT EXISTS (SELECT 1 FROM playlist_track pt JOIN playlist p ON p.playlist_id = pt.playlist_id
                  WHERE pt.track_id = s.track_id AND p.owner_id = u.user_id)
ORDER BY s.saved_at DESC
LIMIT 20;

-- 22. A user's library: liked tracks, newest first
SELECT d.track_name, d.artist_name, d.album_title, s.saved_at
FROM user_saved_track s
JOIN app_user u     ON u.user_id   = s.user_id
JOIN track_detail d ON d.track_id  = s.track_id
WHERE u.username = 'oscargm'
ORDER BY s.saved_at DESC, d.track_name
LIMIT 20;

-- 23. Recently added: the newest entries across a user's own playlists
SELECT p.name AS playlist, t.name AS track, pt.added_at
FROM app_user u
JOIN playlist p        ON p.owner_id     = u.user_id
JOIN playlist_track pt ON pt.playlist_id = p.playlist_id
JOIN track t           ON t.track_id     = pt.track_id
WHERE u.username = 'oscargm'
ORDER BY pt.added_at DESC, p.name, pt.position
LIMIT 10;

-- 24. The user's top artists: liked tracks per album artist
SELECT d.artist_name, count(*) AS liked_tracks
FROM user_saved_track s
JOIN track_detail d ON d.track_id = s.track_id
WHERE s.user_id = (SELECT user_id FROM app_user WHERE username = 'oscargm')
GROUP BY d.artist_name
ORDER BY liked_tracks DESC, d.artist_name
LIMIT 10;

-- 25. Safe edit with optimistic locking: only applies if nobody changed the
--     playlist since the client loaded version 1 (0 rows = reload and retry)
-- BEGIN;
-- DELETE FROM playlist_track
-- WHERE playlist_id = 20 AND position = 7
--   AND (SELECT version FROM playlist WHERE playlist_id = 20) = 1;
-- COMMIT;

-- 26. Song search: by track name, artist or album, ignoring accents ("jose" finds
--     José José); track-name matches first. total is the number of matches.
SELECT d.track_name, d.track_artists, d.album_title, s.score, s.total
FROM search_tracks('jose', 10) s
JOIN track_detail d ON d.track_id = s.track_id
ORDER BY s.score DESC, d.track_name;

-- 27. Random songs, leaving out two that are already on screen
SELECT d.track_name, d.artist_name, d.album_title
FROM random_tracks(5, '{1,2}') r(track_id)
JOIN track_detail d ON d.track_id = r.track_id;

-- 28. Playlists to discover: random public playlists (NULL = for anyone). Empty
--     in the seed: no playlist has a favorite yet, so none is public.
SELECT ps.name, ps.owner_username, ps.track_count, ps.follower_count
FROM random_playlists(NULL, 12) r(playlist_id)
JOIN playlist_summary ps ON ps.playlist_id = r.playlist_id;

-- 29. Followed artists, with how much of each is in the library
SELECT a.name, a.follower_count, s.album_count, s.track_count,
       (SELECT count(*) FROM user_saved_track ust JOIN track_detail d ON d.track_id = ust.track_id
        WHERE ust.user_id = f.user_id AND a.name = ANY (d.track_artists)) AS liked_tracks
FROM artist_follow f
JOIN artist a          ON a.artist_id = f.artist_id
JOIN artist_summary s  ON s.artist_id = a.artist_id
WHERE f.user_id = (SELECT user_id FROM app_user WHERE username = 'oscargm')
ORDER BY a.name;
