---
name: mybb
description: Source facts about MyBB forums (1.6/1.8) - tables, versions, encodings and MyCode (BBCode) quirks - for profiling a MyBB database or planning its migration. Use when the source platform is MyBB.
---

# MyBB source facts

Verify every fact against the actual dump: versions, plugins and admins change schemas.
Reference implementations to compare with: discourse-converters `converters/phpbb` (the
closest converter), and Discourse main's legacy `script/import_scripts/mybb.rb` (older
importer; useful for table usage and MyCode handling, not as code to copy).

**Identity.** Default table prefix `mybb_`. Version: the `datacache` row with
`title = 'version'` (PHP-serialized, e.g. version `1.8.x` and a numeric version code);
also the `settings` table (`bbname`, `bburl`, `uploadspath`, `avataruploadpath`).
MyBB 1.8 needs MySQL 5.x+; 1.6 is very old (expect latin1 tables).

**Core tables** (prefix omitted):
- `users` (`uid`, `username`, `email`, `usergroup`, `additionalgroups` comma list,
  `displaygroup`, `regdate`/`lastvisit` Unix time, `avatar`, `signature`, `postnum`,
  `regip`/`lastip` packed binary in 1.8); `userfields` (`ufid` = uid, `fidN` columns
  defined in `profilefields`); `usergroups` (built-in gids 1-7: guests, registered,
  super mods, admins, awaiting activation, mods, banned).
- `forums` (`fid`, `pid` parent, `type` `c` category / `f` forum, `parentlist`,
  `disporder`, `linkto` = link forum, `active`, `open`).
- `threads` (`tid`, `fid`, `subject`, `uid`, `dateline`, `firstpost`, `views`,
  `replies`, `sticky`, `closed` (may hold `moved|<tid>` for redirects), `visible`: 1
  visible, 0 unapproved, -1 soft-deleted, -2 a user's saved **draft** (1.8; a draft
  thread has the thread and its first post at -2; never published, normally not migrated);
  `prefix` → `threadprefixes`).
- `posts` (`pid`, `tid`, `replyto`, `uid`, `username` for guests, `dateline`,
  `message` MyCode, `visible` as threads, `ipaddress` binary, `edituid`/`edittime`).
- `attachments` (`aid`, `pid`, `uid`, `filename` original name, `attachname` stored path
  under the uploads folder, `filetype`, `filesize`, `downloads`, `visible`); avatars under
  the avatar upload path, often `avatar_<uid>.<ext>`.
- `privatemessages` (one row **per copy**: `uid` owner, `fromid`, `toid`, `recipients`
  PHP-serialized, `folder` 1 inbox / 2 sent / 3 drafts / 4 trash, `dateline`).
- `polls` (options and votes as strings joined by `||~|~||`), `pollvotes`.
- Also: `reputation`, `threadsubscriptions`, `forumsubscriptions`, `banned`,
  `moderators`, `smilies` (code → image), `threadratings`, `warnings`.

**MyCode quirks.** `[quote='Name' pid='123' dateline='1700000000']`, `[url=…]`, `[img]`
(optionally with dimensions), `[code]`, `[php]`, `[size=…]`, `[color=…]`, `[font=…]`,
`[align=…]`, `[list]`/`[list=1]` with `[*]`, `[s]`, `[hr]`, `[video=youtube]…`,
`[attachment=AID]` inline attachments, smilies from the `smilies` table, and raw HTML
only if the forum allowed it. Stored text is usually unescaped; check subjects for HTML
entities. Line breaks are literal newlines.

**Watch for:** latin1 tables with UTF-8 bytes (mojibake), guests posting by `username`
with `uid` 0, PMs duplicated per recipient, moved-thread redirects, link forums, users in
"awaiting activation", and plugin tables (count them; ask what matters).
