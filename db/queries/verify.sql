-- Row counts for every table, compared with the expected totals.
-- Update the numbers here when you add seed data. auth.refresh_token holds live
-- sessions, not seed data, so it isn't counted.
-- Run with: make verify
SELECT t.table_name, t.expected, t.actual,
       CASE WHEN t.expected = t.actual THEN 'ok' ELSE 'MISMATCH' END AS status
FROM (
    VALUES
        ('album',                 1301, (SELECT count(*) FROM album)),
        ('album_artist',          1301, (SELECT count(*) FROM album_artist)),
        ('album_genre',           1500, (SELECT count(*) FROM album_genre)),
        ('album_type',               6, (SELECT count(*) FROM album_type)),
        ('app_user',                 1, (SELECT count(*) FROM app_user)),
        ('artist',                 792, (SELECT count(*) FROM artist)),
        ('artist_follow',            4, (SELECT count(*) FROM artist_follow)),
        ('artist_member',           14, (SELECT count(*) FROM artist_member)),
        ('artist_role',              8, (SELECT count(*) FROM artist_role)),
        ('artist_type',              6, (SELECT count(*) FROM artist_type)),
        ('auth.role',                3, (SELECT count(*) FROM auth.role)),
        ('auth.user_account',        1, (SELECT count(*) FROM auth.user_account)),
        ('country',                249, (SELECT count(*) FROM country)),
        ('credit',                1018, (SELECT count(*) FROM credit)),
        ('credit_role',              7, (SELECT count(*) FROM credit_role)),
        ('genre',                   27, (SELECT count(*) FROM genre)),
        ('label',                  561, (SELECT count(*) FROM label)),
        ('person',                 136, (SELECT count(*) FROM person)),
        ('playlist',                20, (SELECT count(*) FROM playlist)),
        ('playlist_collaborator',    0, (SELECT count(*) FROM playlist_collaborator)),
        ('playlist_follow',          0, (SELECT count(*) FROM playlist_follow)),
        ('playlist_role',            2, (SELECT count(*) FROM playlist_role)),
        ('playlist_track',        2312, (SELECT count(*) FROM playlist_track)),
        ('playlist_visibility',      3, (SELECT count(*) FROM playlist_visibility)),
        ('song',                  2382, (SELECT count(*) FROM song)),
        ('track',                 2730, (SELECT count(*) FROM track)),
        ('track_artist',           138, (SELECT count(*) FROM track_artist)),
        ('user_follow',              0, (SELECT count(*) FROM user_follow)),
        ('user_saved_album',        34, (SELECT count(*) FROM user_saved_album)),
        ('user_saved_track',      1561, (SELECT count(*) FROM user_saved_track))
) AS t(table_name, expected, actual)
ORDER BY t.table_name;

-- Rules kept by triggers. Every row should say 'ok'.
SELECT r.rule, r.violations,
       CASE WHEN r.violations = 0 THEN 'ok' ELSE 'MISMATCH' END AS status
FROM (
    VALUES
        ('visibility follows favorites',
         (SELECT count(*) FROM playlist p
          WHERE visibility <> CASE WHEN EXISTS (SELECT 1 FROM playlist_follow f WHERE f.playlist_id = p.playlist_id)
                                   THEN 'public' ELSE 'private' END)),
        ('at most 5 favorites per user',
         (SELECT count(*) FROM (SELECT user_id FROM playlist_follow GROUP BY user_id HAVING count(*) > 5) x)),
        ('at most 20 playlists per owner',
         (SELECT count(*) FROM (SELECT owner_id FROM playlist GROUP BY owner_id HAVING count(*) > 20) x)),
        -- The 20 Spotify playlists are older than the limit (see 02_data.sql)
        ('at most 20 tracks per playlist (20 Spotify playlists excepted)',
         (SELECT count(*) - 20 FROM (SELECT playlist_id FROM playlist_track GROUP BY playlist_id HAVING count(*) > 20) x)),
        ('track_search is current',
         (SELECT count(*) FROM track t FULL JOIN track_search s USING (track_id) WHERE t.track_id IS NULL OR s.track_id IS NULL))
) AS r(rule, violations);
