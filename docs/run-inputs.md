# Optional run inputs, preparation review metadata and master-list preparation

Ruby backend contract (`lib/silo_migrate/services/standard_run_inputs.rb`). Both plan
documents are optional. A plan without them keeps exactly its previous body, digest and
run behaviour. Neither document is a DSL: nothing in it is executed or interpreted as
converter behaviour.

## Where each piece fits

| Need | Mechanism |
| --- | --- |
| Converter reads reviewed decision files from one directory (for example Khoros `mappings.directory`) | `run_inputs` manifest on a `convert` or `master-lists` plan |
| Explain what the run will and won't do, which references informed it, open questions | `preparation` on a `convert` or `merge` plan |
| Native Discourse merge settings and code | Existing `--settings` (merge-settings YAML) and the committed `mergers/<workspace>/` layer. There's no parallel mapping system. |
| Khoros master reference lists for the mapping spreadsheet | `master-lists` plan operation (the converter's own exporter) |

## Engineer CLI

```
plan propose WS --operation convert --source ID --settings ID [--reconciliation ID] [--charset N]
                [--run-inputs MANIFEST.json] [--preparation PREPARATION.json]
plan propose WS --operation merge --source ID --base-site ID [--settings ID] ... [--preparation PREPARATION.json]
plan propose WS --operation master-lists --source ID --settings ID [--list NAME] [--charset N] [--run-inputs MANIFEST.json]
plan show WS PLAN_ID [--detail]
run show WS RUN_ID [--detail]
```

Documents are regular JSON files (not symlinks), at most 64 KiB, UTF-8. They're validated,
normalised and embedded in the plan body, so the one plan digest and approval covers them.

Ruby: `propose_convert_plan(..., run_inputs:, preparation:)`,
`propose_merge_plan(..., preparation:)`,
`propose_master_lists_plan(source:, settings:, list: "all", charset:, allow_unqualified_runtime:, run_inputs:)`,
`show_plan(id, detail:)`, `show_run(id, detail:)`.

### What each audience sees

- **Proposal response, `plan show --detail`, `run show --detail`:** the full normalised
  documents and private evidence. These are for the engineer, and for the trusted private
  analyst session that wrote them.
- **Default `plan show` / `run show` and `agent plan-show` / `agent run-show`:** clean
  projection only.
  - Plans show the run-input contract and counts, the file digests (`sha256`, `bytes`), and
    preparation counts with `code_readiness`.
  - Run results show counts only.
  - No analyst text, logical file names, lineage or generated names.

## Run-input manifest v1

```json
{"version": 1,
 "consumer": {"platform": "khoros", "setting": "mappings.directory"},
 "source_sha256": "<sha256 of the plan's source input>",
 "files": [
   {"name": "category_organization.csv", "input_id": "input-…", "sha256": "…", "bytes": 123,
    "lineage": {"references": [{"file_id": "file-…", "sha256": "…"}],
                "preparation": {"job": "job-…", "tool": "…", "script_sha256": "…", "preparation_sha256": "…"}},
    "reuse": {"dataset_id": "dataset-…", "source_sha256": "…"}}],
 "absent_defaults": ["tag_mapping.csv"],
 "generated": ["trust_level_mapping.yml"]}
```

### Files

- `files` may be an explicit empty list (0–256 entries). For example, Khoros with no
  reviewed mapping files declares `"files": []`, `"generated": ["trust_level_mapping.yml"]`
  and its absent defaults. It gets a fresh, empty, writable directory, with no header-only
  placeholder that would change converter semantics. Generated-file checks and capture
  apply unchanged. A plan without any manifest keeps the old path.
- Each file is an already-registered named input of type `run-input` or `mapping`, not
  bound in another role, with the registered sha256 and bytes.
- **Dataset:** by default the file must be in the plan source's own dataset.
  - A file prepared for another delivery needs an explicit per-file `reuse`: its own dataset,
    plus the sha256 of the source snapshot it was prepared against. That digest must belong to
    an input of that dataset with the same type as this plan's source, and never to the
    reused file itself.
  - Reuse is never from Base-site data, and is counted in the plan's mutations.
  - Silo doesn't decide whether old decisions still apply to the new source. That stays the
    engineer's explicit, reviewed choice.

### Names

- Relative names of 1–4 segments matching `[A-Za-z0-9_][A-Za-z0-9_.-]*`, with no `.`/`..`.
- Unique ignoring case. A name can't be both a file and a directory.
- **Data formats only:** `csv tsv yml yaml json ndjson jsonl txt xml xlsx`. Code (`.rb`,
  `.sh`, …) and extensionless names are refused for files, absent defaults and generated
  names.

### Consumer

- `consumer.platform` must be the source's platform.
- `consumer.setting` must exist in the converter's own committed
  `converters/<platform>/settings.yml` at the bound revision.
- The settings template must contain that key with the exact value `"${SILO_RUN_INPUTS_DIR}"`
  (`/run-inputs` in the container). Without a manifest the placeholder is refused.

### Absent defaults and generated files

- `absent_defaults` declares deliberate absence: the converter's documented default applies.
  That is not the same thing as an empty or header-only file, which is a bound file.
- `generated` makes the directory writable for those names only.

### Lineage

- `lineage.references` and `preparation.references` are each `{file_id|input_id, sha256}`.
- **Checked against custody bytes:** a named input, or a Files reference whose file roles
  entry has `input_id`/`taken` (the custody input). These are re-hashed at proposal.
  - Result: `verified: "custody_bytes"`.
- **Checked against the registry digest only:** an untaken intake reference. Silo can only
  check the file roles registry's recorded sha256.
  - Result: `verified: "registry_digest"`.
- A reference that changes later makes the plan stale with reason `preparation`.

### At run time

1. **Preflight** copies every bound input (roles and manifest files) into the run, and the
   copies are checked against the plan's sha256 and size.
2. **Fresh working copy:** the convert step builds `work/run-inputs/` from those copies.
   - Every file is a new regular file: never a hardlink, never another run's directory.
     The directory must not exist yet.
   - Files are 0400, mounted read-only, unless `generated` is declared. Then files are 0600
     and the mount is writable.
3. **Check after the converter**, even if the converter failed. The tree must contain:
   - the bound files, byte-identical (a size change is detected without hashing);
   - declared generated names only, as regular non-executable files of at most 16 MiB;
   - directories that are parents of bound or generated names, at most 4 levels deep;
   - at most 1,024 entries in total.

   Anything else fails the run with `STANDARD_RUN_INPUTS_MUTATED`: modified, removed,
   undeclared or executable files, symlinks, extra or empty directories.
4. **Evidence:**
   - `evidence/run-inputs.json` records declared status, generated files, defaults in
     effect and violations.
   - Generated files are copied to `private/run-inputs-generated/`. They are never promoted
     into a later plan; reuse needs a new explicit selection.

If a selected file changes or disappears after approval, the plan becomes stale (`inputs`).

## Preparation metadata v1

```json
{"version": 1,
 "analyst": {"label": "Analyst summary (migration-data)", "text": "…"},
 "references": [{"input_id": "input-…", "sha256": "…"}],
 "outcomes": [{"id": "o1", "requirement": "…",
               "disposition": "stock|setting|prepared_input|code|manual|excluded",
               "input": "category_organization.csv", "exclusion": "x1"}],
 "questions": [{"id": "q1", "text": "…", "status": "resolved|excluded|scope_narrowed", "resolution": "…"}],
 "exclusions": [{"id": "x1", "text": "…", "reason": "…"}]}
```

### Validation

- A question with any other status, or none, is refused with
  `STANDARD_PREPARATION_UNRESOLVED`. Material questions can't silently become defaults.
- `prepared_input` must name a bound manifest file, or `settings` when settings are bound.
- `setting` needs bound settings.
- `excluded` (outcome or question) must name an exclusion.

### What Silo adds

- **`code_readiness`** comes from the plan itself:
  - convert: the converter platform path at the pinned revision;
  - merge: the committed layer's path, revision, sha256 and file count, or `present: false`.
- A `code` outcome is refused when no pinned code exists.
- `claim: "pinned_code_available"` and its `note` state that this is availability only: not
  proof that a requirement is implemented, tested or reviewed.
- Manual and excluded outcomes are added to the plan's `not_included` (covered by the
  digest), so a plan never reads as covering work the run won't perform.

## Khoros master-list preparation (`standard_master_lists`)

A separately proposed and approved plan with stages `preflight` → `export`.

- **What runs:** the converter's own committed `converters/<platform>/scripts/export_master_lists.rb`,
  on the run's disposable copy of the source (same isolation, limits, deps and image as
  convert).
  - The exporter checks its own `--list` name and settings. The platform must have the
    script at the bound revision.
- **What it mutates:** the exporter may rebuild source-side staging tables and indexes.
  Only the disposable copy is affected, and the plan says so in `mutations`. It is not a
  read-only status.
- **Mapping files:** an optional read-only `run_inputs` can provide, for example,
  `trust_level_mapping.yml`.
- **Output:** the CSVs in `output/master_lists`. Only regular `*.csv` files are accepted:
  ≤ 64 files, ≤ 8 GiB each, ≤ 16 GiB in total.
  - They're moved to `artifacts/master-lists/` (0400) and recorded in
    `evidence/master-lists.json`.
  - Public results: `{files, bytes}`.
- **Not included:** no conversion, no import, no automatic registration as run inputs, no
  external spreadsheet transfer.

## Error codes

| Code | Meaning |
| --- | --- |
| `STANDARD_RUN_INPUTS_INVALID` | Manifest doesn't match registered inputs, the source, dataset/reuse rules, the data-format allowlist or the converter's settings contract |
| `STANDARD_RUN_INPUTS_MUTATED` | Run failure: undeclared change to the run-input directory (private evidence has details) |
| `STANDARD_PREPARATION_INVALID` | Malformed metadata, a stale or unknown reference, or an outcome claiming code/input/setting the plan doesn't bind |
| `STANDARD_PREPARATION_UNRESOLVED` | A question has no resolution, exclusion or scope narrowing |

Stale reasons gain `preparation` (a bound reference changed).

## Limits (honest)

- **Content:** Silo validates structure, identity, formats and the post-run tree. It doesn't
  validate file content. The pinned converter's own parser does that at run time (no
  separate pre-run dry validation), so a semantically wrong but well-formed CSV still fails
  or behaves according to the converter.
- **Allowlist:** the data-format allowlist is Silo's. It isn't yet derived from a
  per-converter declared format list.
- **Untaken references:** an intake reference that was never taken into a dataset is bound
  by its registry digest, not re-hashed custody bytes.
- **Not yet covered:** launch, delta and multi-source plans don't use run inputs (launch
  runs remain `STANDARD_LAUNCH_NOT_READY`). Review and Base-site plans don't take
  preparation metadata.
- **No-manifest Khoros:** a Khoros convert without a manifest keeps the old behaviour. A
  blank `mappings.directory` points into the read-only code snapshot, where the converter
  can't write a generated `trust_level_mapping.yml`.
