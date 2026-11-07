---
name: uploads-sorting
description: Make sense of a source's uploads (attachments, avatars, images) - a forum's upload folder, a Discourse backup's uploads tree or loose files - and match them to database records. Use when uploads arrive or attachment counts don't match.
---

# Uploads

1. **Inventory**: `data_list` the extracted tree (area `work` after `data_extract`).
   Count files per folder and extension with a sandbox script (`data_script`) that prints
   a summary: count, total bytes, extensions, largest files, zero-byte files, duplicate
   SHA-1/SHA-256 groups. No file contents in the output.
2. **Find the mapping** from records to files. Forums store the stored name and the
   original name separately (e.g. MyBB `attachments.attachname` vs `filename`; phpBB
   `physical_filename` vs `real_filename`). Avatars often live in their own folder and are
   named by user ID. Discourse backups keep `uploads/default/original/…` with the SHA-1 in
   the file name, matching the `uploads` table.
3. **Check both directions** with a script over the database export or dump and the tree:
   records whose file is missing, and files no record points to (orphans). Report counts
   and a few invented-looking examples of the *pattern* (`YYYYMM/post_<pid>_<time>_<hash>.attach`),
   not real names.
4. **Sort only into new folders** in `work/` when the converter needs a different layout
   (e.g. one folder per type); never rename originals. Register a manifest (CSV:
   record ID, relative path, size, checksum) with `data_register` rather than thousands
   of files.
5. **Report** totals that the count reconciliation will check later: attachments in the
   database, files present, missing, orphans, avatars.

Files can be big: stream checksums; stay within the job's time limit (raise
`timeout_minutes` for large trees).
