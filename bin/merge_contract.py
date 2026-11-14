"""One fixed, customer-free merge-layer capability contract for data and coding agents."""

MERGE_LAYER_MAX_FILES = 32
MERGE_LAYER_MAX_BYTES = 512 * 1024
MERGE_SETTINGS_MAX_BYTES = 256 * 1024  # as StandardMergeRun::MERGE_SETTINGS_BYTES; its only size rule, spelled out in the guide
MERGE_GUIDE = """A merge run restores the site to merge into (the Base site), loads the source site's backup beside it and runs
Discourse's own merger, script/bulk_import/discourse_merger.rb, unedited. A project that needs rules of its own (source
categories into chosen destination categories, topics re-homed, groups mapped, ...) adds a merge layer. You write the layer;
the run applies it; the engineer approves every run.

The contract
- Entry file: {path}. Sibling .rb files in the same folder may be loaded with require_relative. The layer must not load or read anything else.
- The folder may hold only regular .rb files: at most {files} files, {kib} KiB together. Anything else refuses the plan.
- The entry file defines exactly ONE subclass of BulkImport::DiscourseMerger, anywhere in the folder's files. Change behaviour
  by overriding its methods and calling super. Never copy or edit the stock script, and never reopen BulkImport::DiscourseMerger
  or BulkImport::Base themselves.
- The layer is loaded inside the Discourse app (Rails models such as Category, Topic, Group are available) after the stock
  merger, with no network. Do not require the stock file yourself.
- Customer values never go in the repository: no real category, group or user names, IDs, URLs or emails in code, tests,
  comments or commit messages. The layer reads them at run time from the YAML mapping named by ENV["SILO_MERGE_SETTINGS"]
  (YAML.safe_load_file). You decide the key names; migration-data fills in the values and registers the file (type
  merge-settings). Describe the keys and value shapes to the engineer, with invented values, so migration-data can write it.
  If the layer needs no values, don't read the variable (it is unset when the run has no settings).
- The settings file's only limits: at most 256 KiB, and it must load safely as YAML with a mapping at its root. Loading safely
  means mappings, lists, strings, numbers, true/false and null only, with aliases disabled: an alias (*name), a symbol
  (:name), an unquoted date or time (quote them) or a tagged object refuses the plan with STANDARD_MERGE_SETTINGS_INVALID,
  as does a list or nothing at the root. There is no limit on the number of lines or entries within that size.
- Report what the layer did as totals: print lines `SILO_MERGE_TOTAL: name=integer` to standard output (name: lowercase
  letters, digits, _, spelled out in the layer's code; at most 20 names). A name built from a row (a slug, a user name) is
  dropped. The engineer and migration-data see those totals on the run; you don't. What you see back from a run, under
  recent_runs here, is which commit ran, where it stopped, fixed site counts and how many of your totals were reported.
  A total's value reaches you only if the engineer passes it on (a released finding). Everything else the layer prints or
  raises stays in the run's private log. Never try to return data through messages, names, totals or the site's counts.
- Do not write files, open sockets, start processes or read paths other than SILO_MERGE_SETTINGS.

Useful extension points of the stock class (read the source at the URLs below before overriding; they are pinned to the
Discourse revision runs use, and the file is public, so reading it on the web is fine):
- category_exists(cat_row): called for every source category; return an existing destination category's id to merge the
  source category into it, or nil to create it.
- process_topic(topic), process_post(post) and the other process_<table>(row) methods: called per copied row with a hash of
  column values; change the hash and return it, or return nil to skip the row.
- execute: the ordered list of copy steps; override to add a step before or after super.
- initialize: call super first, then load your settings.
- Prepared custom merges MUST also define class methods self.silo_merge_preflight! and self.silo_merge_postflight!.
  Each returns exactly true only after validating the intended policy (raise or return anything else to refuse).
  The preflight runs BEFORE the stock constructor; postflight runs after copying and BEFORE finalize/backup/release.
  Silo captures destination site settings before loading the layer. Only the stock constructor's temporary
  authorized_extensions assignment is allowed: Silo restores its exact prior stored override (or absence) and
  effective value BEFORE postflight. Finalize/rebake and backup run with the original destination policy.
  The layer must import no source site settings and introduce no site-setting changes (including in hooks).
  Do not skip super, patch stock core, write settings to work around the constructor, or suppress verification.
  Unexpected changes to any other setting fail the run; Silo never silently repairs them. Failure restoration
  is best-effort and cannot make a failed/dirty run successful. If guest termination is unknown, restoration
  refuses unsafe concurrent writes and reports unproven; engineer diagnosis/reset is required.
  Setting values stay private, not in totals/errors. Silo rebakes through the supported Post API without
  the stock rake wrapper's second setting write; synchronous cooking completes, follow-up jobs stay queued.
  Use Rails target models and SILO_MERGE_SETTINGS to verify exact destination identities and resulting permissions;
  a grant count, read_restricted flag or parent placement alone does not prove the intended audience.
  These reviewed checks do not run for an explicitly stock merge. Legacy one-shot layers retain their prior contract.

Testing without a Discourse app
- Put tests in {tests}/..._test.rb. They run with dev_test in the converter sandbox, which has no Discourse: define a small
  stub BulkImport::DiscourseMerger (and any model you call, e.g. Category) in the test before requiring the layer, write a
  temporary settings file with invented values, and assert on what your overrides return.
- The stub proves your logic, not the fit with the real merger. That is proven by a merge run: migration-data proposes it,
  the engineer starts it, and you read the outcome under recent_runs here (call this tool again) and in any released finding.
  failure_code STANDARD_MERGE_LAYER_INVALID at stage merge means the layer didn't load or didn't define exactly one subclass;
  STANDARD_MERGE_SCHEMA means the merger met a column it doesn't know; STANDARD_MERGE_FAILED means it raised while merging.
  STANDARD_MERGE_SITE_SETTINGS_FAILED means exact destination settings preservation could not be proven.
  What it raised is in the private log: ask the engineer to have migration-data look and release a finding.
- Format, lint and commit as for converter code. A run uses the checkout's committed head: commit before asking for a run.
"""


def _swap(text, old, new):
    # The standalone guide is the one contract above with only its repository-specific
    # passages replaced; a passage that no longer matches must fail loudly, not be skipped.
    if text.count(old) != 1:
        raise ValueError("STANDARD_OPERATION_FAILED")
    return text.replace(old, new)


# The same contract for the project's standalone local merger repository (bin/merger_dev.py).
# Placeholders: {path} (the repository's actual path), {files}, {kib}.
STANDALONE_MERGE_GUIDE = MERGE_GUIDE
for _old, _new in (
    ("""- Entry file: {path}. Sibling .rb files in the same folder may be loaded with require_relative. The layer must not load or read anything else.
- The folder may hold only regular .rb files: at most {files} files, {kib} KiB together. Anything else refuses the plan.
""", """- The layer lives in this project's own local Git repository: {path}. It has no remote: nothing is pushed or fetched, and
  the engineer reviews it right there. Entry file: merger.rb at its root. Ruby files under helpers/ may be loaded with
  require_relative. The layer must not load or read anything else.
- A merge runs merger.rb and helpers/**/*.rb only: regular .rb files, at most {files} files, {kib} KiB together. Tests and
  invented fixtures go under test/ and notes in README.md: committed and reviewed, never run by a merge. Any other top-level
  entry, a link or a submodule refuses the plan.
"""),
    ("anywhere in the folder's files.", "in merger.rb or helpers/."),
    ("""- Put tests in {tests}/..._test.rb. They run with dev_test in the converter sandbox, which has no Discourse: define a small
""", """- Put tests in test/..._test.rb. They run with dev_merger_test in a sealed container: the pinned converter image's Ruby and
  minitest only, with no network, no Bundler, no gems of your own and no Discourse. Define a small
"""),
    ("""- Format, lint and commit as for converter code. A run uses the checkout's committed head: commit before asking for a run.
""", """- Format (dev_merger_format) and commit (dev_merger_commit) here; the converter repository plays no part. A merge plan binds
  the committed HEAD and the SHA-256 manifest of its executable files when migration-data proposes it, and is refused while
  anything is uncommitted: commit, check that dev_merger_status shows dirty false and a layer, then ask for the plan. A later
  commit never changes a proposed plan; it needs a new one.
"""),
):
    STANDALONE_MERGE_GUIDE = _swap(STANDALONE_MERGE_GUIDE, _old, _new)
