-- Portfolio upload quotas: 200 MiB total per editor, max 2 videos, 50 MiB per video.
-- Run this in Supabase SQL Editor. Existing public-read policy is intentionally unchanged.

CREATE OR REPLACE FUNCTION public.can_upload_portfolio_file(
  object_name text,
  object_metadata jsonb
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  current_uid uuid := auth.uid();
  new_size bigint;
  new_mime text;
  used_bytes bigint;
  used_videos bigint;
  is_video boolean;
BEGIN
  IF current_uid IS NULL
     OR (storage.foldername(object_name))[1] IS DISTINCT FROM current_uid::text THEN
    RETURN false;
  END IF;

  new_mime := lower(coalesce(object_metadata->>'mimetype', ''));
  IF new_mime NOT IN (
    'image/jpeg','image/png','image/webp','image/gif',
    'video/mp4','video/webm','video/quicktime'
  ) THEN
    RETURN false;
  END IF;

  IF coalesce(object_metadata->>'size', '') !~ '^[0-9]+$' THEN
    RETURN false;
  END IF;
  new_size := (object_metadata->>'size')::bigint;
  is_video := new_mime LIKE 'video/%';

  IF new_size <= 0 OR (is_video AND new_size > 52428800) THEN
    RETURN false;
  END IF;

  -- Serialize quota checks for this editor to prevent parallel uploads bypassing limits.
  PERFORM pg_advisory_xact_lock(hashtextextended(current_uid::text, 0));

  SELECT
    coalesce(sum(
      CASE WHEN coalesce(metadata->>'size', '') ~ '^[0-9]+$'
        THEN (metadata->>'size')::bigint ELSE 0 END
    ), 0),
    count(*) FILTER (
      WHERE lower(coalesce(metadata->>'mimetype', '')) LIKE 'video/%'
         OR lower(name) ~ '\\.(mp4|webm|mov|m4v)$'
    )
  INTO used_bytes, used_videos
  FROM storage.objects
  WHERE bucket_id = 'portfolio-files'
    AND (storage.foldername(name))[1] = current_uid::text;

  IF used_bytes + new_size > 209715200 THEN
    RETURN false;
  END IF;

  IF is_video AND used_videos >= 2 THEN
    RETURN false;
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.can_upload_portfolio_file(text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.can_upload_portfolio_file(text, jsonb) TO authenticated;

DROP POLICY IF EXISTS "Editors upload to own portfolio folder" ON storage.objects;
CREATE POLICY "Editors upload to own portfolio folder"
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'portfolio-files'
  AND public.can_upload_portfolio_file(name, metadata)
);
