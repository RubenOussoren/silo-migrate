"""Pure fake Docker tests: python3 -I -B test/review_runtime_test.py."""
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("review_runtime", ROOT / "bin/review_runtime.py")
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


def image(letter):
    return {"Id": "sha256:" + letter * 64, "Architecture": "amd64", "Os": "linux",
            "RootFS": {"Layers": ["sha256:" + letter * 64]},
            "Config": {"User": "", "WorkingDir": "/var/www/discourse", "Env": ["PUBLIC=1"]},
            "RepoDigests": [runtime.PUBLIC + "@sha256:" + letter * 64]}


def metadata(version="2026.11.0-latest"):
    return {"version": version, "revision": "c" * 40, "ruby": "4.0.9", "bundler": "4.0.23",
            "gemfile_lock_sha256": "d" * 64, "core_migrations": ["20261101000000"], "postgres_major": "18"}


class Docker:
    def __init__(self):
        self.calls = []
        self.stock = image("a")
        self.meta = metadata()
        self.overlays = {}
        self.fail_tags = set()
        self.fail_build = False
        self.tags = ["latest", "2026.7.5", "2026.11.0-latest.1", "3.5.0", "3.4.2", "--help", "private/repo"]
        self.more_pages = False
        self.candidates = {}
        self.source_metadata = {}

    def __call__(self, args, **kwargs):
        self.calls.append((args, kwargs))
        if args[0] == "curl":
            return json.dumps({"results": [{"name": tag} for tag in self.tags],
                               "next": "https://untrusted.example/never-follow" if self.more_pages else None})
        if args[:2] == ["docker", "pull"]:
            if args[2].split(":")[-1] in self.fail_tags:
                runtime.refuse("PREPARATION_FAILED")
            return ""
        if args[:3] == ["docker", "image", "inspect"]:
            ref = args[3]
            if ref.startswith(runtime.PUBLIC + ":"):
                stock, meta = self.candidates.get(ref.split(":")[-1], (self.stock, self.meta))
                self.source_metadata[stock["Id"]] = copy.deepcopy(meta)
                return json.dumps([stock])
            if ref in self.overlays:
                return json.dumps([self.overlays[ref]])
            runtime.refuse("PREPARATION_FAILED")
        if args[:2] == ["docker", "build"]:
            if self.fail_build:
                runtime.refuse("PREPARATION_FAILED")
            source_id = next(a.split("@", 1)[1] for a in args if a.startswith("STOCK_IMAGE="))
            overlay = image("b" if source_id == image("a")["Id"] else "e")
            self.source_metadata[overlay["Id"]] = copy.deepcopy(self.source_metadata[source_id])
            self.overlays[args[args.index("--tag") + 1]] = overlay
            return ""
        if args[:2] == ["docker", "rm"] or args[:3] == ["docker", "container", "ls"]:
            return ""
        if args[:2] == ["docker", "run"]:
            return json.dumps(self.source_metadata.get(args[-3], self.meta)) if args[-2] == "-e" else ""
        raise AssertionError(args)


class RuntimeTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.cache = Path(self.temp.name) / "cache"
        self.baseline = json.loads(next((ROOT / "runtime/profiles").glob("*.json")).read_text())
        self.original = copy.deepcopy(self.baseline)
        self.docker = Docker()
        self.mock = patch.object(runtime, "run", self.docker)
        self.mock.start()
        self.addCleanup(self.mock.stop)
        self.space = patch.object(runtime.shutil, 'disk_usage', return_value=type('Space', (), {'free': 100 * 1024**3})())
        self.space.start()
        self.addCleanup(self.space.stop)

    def prepare(self, version=None, schema=None, required_migrations=None):
        return runtime.prepare(ROOT, self.cache, self.baseline, version, schema, required_migrations)

    def refused(self, suffix, action):
        with self.assertRaises(runtime.Refusal) as caught:
            action()
        self.assertEqual("STANDARD_REVIEW_RUNTIME_" + suffix, caught.exception.code)
        self.assertEqual(caught.exception.code, str(caught.exception))

    def calls(self, verb):
        return [args for args, _ in self.docker.calls if args[:2] == ["docker", verb]]

    def test_shared_profile_has_only_the_declared_image_fact_schema(self):
        plugin = '20991231235959'
        result = self.prepare('2026.11.0-latest', plugin, ['20261101000000', plugin])
        profile = result['profile']
        self.assertEqual({'core_migrations','schema_version','track','postgres_requirement_known','postgres_minimum_major','source','preparation_method','recipe_sha256'}, set(profile['review_runtime']))
        self.assertEqual({'method','recipe_sha256','key','source','track','core_migrations','schema_commit_exact'}, set(profile['preparation']))
        self.assertEqual({'ref','digest','local_id','content_id'}, set(profile['preparation']['source']))
        self.assertEqual(set(self.baseline['app']) | {'track','core_migrations','schema'}, set(profile['app']))
        raw = (self.cache/'profiles'/(result['name']+'.json')).read_text()
        self.assertNotIn(plugin, raw)
        for key in ('requested_schema','requested_version','required_migrations','unknown_required_migrations_count','core_comparison_complete'):
            self.assertNotIn('"'+key+'"', raw)
        self.assertEqual(1, result['comparison']['unknown_required_migrations_count'])

    def test_low_disk_refuses_before_any_pull_or_build(self):
        with patch.object(runtime.shutil, 'disk_usage', return_value=type('Space', (), {'free': 1024})()):
            self.refused('CAPACITY', self.prepare)
        self.assertFalse(self.calls('pull'))
        self.assertFalse(self.calls('build'))

    def test_latest_and_preserved_roles(self):
        result = self.prepare()
        self.assertEqual([["docker", "pull", runtime.PUBLIC + ":latest"]], self.calls("pull"))
        profile = result["profile"]
        self.assertEqual(self.original, self.baseline)
        for key in self.baseline:
            if key not in ("images", "app", "qualification", "selector"):
                self.assertEqual(self.baseline[key], profile[key])
        for role in self.baseline["images"]:
            if role != "web":
                self.assertEqual(self.baseline["images"][role], profile["images"][role])
        self.assertEqual("review_ready", profile["qualification"]["status"])
        self.assertFalse(profile["qualification"]["full_stack_qualified"])
        self.assertFalse(profile["preparation"]["schema_commit_exact"])
        self.assertEqual(max(profile["review_runtime"]["core_migrations"]),
                         profile["review_runtime"]["schema_version"])
        self.assertEqual(image("a")["Id"], profile["preparation"]["source"]["local_id"])
        raw = (self.cache / "profiles" / (result["name"] + ".json")).read_bytes()
        self.assertEqual(result["sha256"], hashlib.sha256(raw).hexdigest())
        self.assertEqual(result["name"], "review-" + result["sha256"])

    def test_exact_version_preferred(self):
        self.docker.meta = metadata("3.4.2")
        self.prepare("3.4.2", "20261101000000")
        self.assertEqual(runtime.PUBLIC + ":3.4.2", self.calls("pull")[0][2])
        self.assertEqual(2, len(self.calls("pull")))

    def test_stable_fallback_newer_only(self):
        self.docker.fail_tags.add("3.4.2")
        self.docker.meta = metadata("2026.7.5")
        result = self.prepare("3.4.2")
        self.assertEqual("stable", result["profile"]["app"]["track"])
        self.assertEqual(runtime.PUBLIC + ":2026.7.5", self.calls("pull")[-1][2])
        self.assertFalse(any(a[-1].endswith(":stable") for a in self.calls("pull")))

    def test_numbered_latest_tag_and_filename_normalization(self):
        self.docker.meta = metadata("2026.11.0-latest.1")
        for version in ("2026.11.0-latest.1", "2026.11.0-latest-1"):
            result = self.prepare(version)
            self.assertEqual("2026.11.0-latest.1", result["profile"]["app"]["version"])
            self.assertEqual(runtime.PUBLIC + ":2026.11.0-latest.1", self.calls("pull")[-2][2])
            self.assertEqual(runtime.PUBLIC + ":latest", self.calls("pull")[-1][2])

    def test_discovery_bounded_no_arbitrary_next_url(self):
        self.docker.fail_tags.add("3.4.2")
        self.docker.more_pages = True
        self.refused("VERSION_UNAVAILABLE", lambda: self.prepare("3.4.2"))
        calls = [a for a, _ in self.docker.calls if a[0] == "curl"]
        self.assertEqual(5, len(calls))
        for index, args in enumerate(calls, 1):
            self.assertEqual("https://hub.docker.com/v2/repositories/discourse/discourse/tags?page_size=100&page=" + str(index), args[-1])
            self.assertNotIn("--location", args)
        self.assertFalse(self.calls("build"))

    def test_discovery_no_stable_compatible_tag_refuses(self):
        self.docker.fail_tags.add("2027.1.0")
        self.refused("VERSION_UNAVAILABLE", lambda: self.prepare("2027.1.0"))
        self.assertEqual(1, len(self.calls("pull")))

    def test_docker_canonical_repo_digest_and_implicit_volumes(self):
        self.docker.stock["RepoDigests"] = ["discourse/discourse@sha256:" + "a" * 64]
        result = self.prepare()
        self.assertTrue(result["profile"]["images"]["web"]["derived_from"].startswith(runtime.PUBLIC + "@"))
        self.docker.stock["Config"]["Volumes"] = {"/data": {}}
        self.refused("METADATA_INVALID", self.prepare)

    def test_latest_fallback(self):
        version = "2026.10.0-latest"
        self.docker.fail_tags.add(version)
        self.prepare(version)
        self.assertEqual(runtime.PUBLIC + ":latest", self.calls("pull")[-1][2])

    def test_historical_beta_rc_never_silently_switch_track(self):
        for index, version in enumerate(("3.4.0.beta3", "3.4.0-rc1")):
            self.docker.stock = image("a" if index == 0 else "f")
            self.docker.meta = metadata(version)
            result = self.prepare(version)
            self.assertEqual("tests-passed", result["profile"]["selector"]["channel"])
            self.docker.fail_tags.add(version)
            self.docker.meta = metadata()
            self.refused("VERSION_UNAVAILABLE", lambda: self.prepare(version))

    def test_no_downgrade_or_track_switch(self):
        for requested, actual in (("2027.1.0-latest", "2026.11.0-latest"),
                                  ("3.5.0", "3.4.9"), ("3.4.0", "2026.11.0-latest"),
                                  ("3.4.0.beta4", "3.4.0.beta3")):
            with self.subTest(requested=requested):
                self.docker.meta = metadata(actual)
                self.refused("VERSION_UNAVAILABLE", lambda: self.prepare(requested))
        self.assertFalse(self.calls("build"))

    def test_invalid_backup_metadata_never_reaches_docker(self):
        for value in ("--help", "foo/bar:latest", "3.4.0;env", "latest", "3.4", "../3.4.0",
                      "3.4.0\n", "3.4.0@sha256:" + "a" * 64, "3.4.0-dev", "03.4.0", {}, 2):
            with self.subTest(value=value):
                self.refused("VERSION_INVALID", lambda: self.prepare(value))
        for value in ("--env=SECRET", "../../file", "123\n", {}, 1):
            self.refused("SCHEMA_INVALID", lambda: self.prepare(schema=value))
        self.assertEqual([], self.docker.calls)

    def test_probe_is_read_only_no_network_no_mounts_or_customer_values(self):
        self.prepare("2026.11.0-latest", "20261101000000")
        for args in self.calls("run"):
            self.assertIn("--network=none", args)
            self.assertIn("--read-only", args)
            self.assertIn("--pull=never", args)
            self.assertIn("--cap-drop=ALL", args)
            self.assertFalse(any(v in args for v in ("-v", "--volume", "--mount", "--env-file")))
            self.assertNotIn("20261101000000", args)
        probe = self.calls("run")[0][-1]
        self.assertIn('config/git-utils-overrides.json', probe)
        self.assertIn('require_relative "lib/version"', probe)
        self.assertIn('Discourse::VERSION::STRING', probe)

    def test_build_has_only_fixed_recipe_and_digest_lock_args(self):
        self.prepare()
        args, options = next((a, k) for a, k in self.docker.calls if a[:2] == ["docker", "build"])
        self.assertEqual("-", args[-1])
        self.assertIn("STOCK_IMAGE=" + runtime.PUBLIC + "@sha256:" + "a" * 64, args)
        self.assertIn("EXPECTED_LOCK_SHA256=" + "d" * 64, args)
        with tarfile.open(fileobj=io.BytesIO(options["input_bytes"])) as archive:
            self.assertEqual(["Dockerfile"], archive.getnames())
            self.assertEqual((ROOT / runtime.RECIPE).read_bytes(), archive.extractfile("Dockerfile").read())
        recipe = (ROOT / runtime.RECIPE).read_text()
        self.assertIn("BUNDLE_FROZEN=true", recipe)
        self.assertIn("bundle check", recipe)
        self.assertNotIn("redcarpet-3", recipe)
        self.assertNotIn("sqlite3-2", recipe)

    def test_cache_reuse_still_pulls_and_checks_bundle(self):
        first = self.prepare(schema="20261101000000")
        path = self.cache / "profiles" / (first["name"] + ".json")
        old = (path.stat().st_ino, path.read_bytes())
        again = self.prepare(schema="20261101000000")
        self.assertEqual(first, again)
        self.assertEqual(old, (path.stat().st_ino, path.read_bytes()))
        self.assertEqual(2, len(self.calls("pull")))
        self.assertEqual(1, len(self.calls("build")))
        self.assertEqual(2, len([a for a in self.calls("run") if a[-1] == "check"]))

    def test_same_version_refresh_digest_creates_immutable_profile(self):
        first = self.prepare("2026.11.0-latest", "20261101000000")
        old_path = self.cache / "profiles" / (first["name"] + ".json")
        old_raw = old_path.read_bytes()
        self.docker.stock = image("f")
        self.docker.meta["revision"] = "e" * 40
        second = self.prepare("2026.11.0-latest", "20261101000000")
        self.assertNotEqual(first["name"], second["name"])
        self.assertEqual(old_raw, old_path.read_bytes())
        self.assertEqual(2, len(self.calls("build")))

    def test_private_comparisons_share_only_the_same_public_profile(self):
        first = self.prepare(schema="20261101000000")
        second = self.prepare(schema="20261102000000")
        self.assertEqual(first["name"], second["name"])
        self.assertNotEqual(first["comparison"], second["comparison"])
        self.assertEqual(1, len(self.calls("build")))

    def test_unattested_local_tag_is_rebuilt(self):
        self.prepare()
        for path in (self.cache / "profiles").glob("*.json"):
            path.unlink()
        self.prepare()
        self.assertEqual(2, len(self.calls("build")))

    def test_corrupt_or_symlink_cache_is_not_overwritten(self):
        first = self.prepare()
        path = self.cache / "profiles" / (first["name"] + ".json")
        path.write_text("corrupt")
        self.refused("CACHE_INVALID", self.prepare)
        self.assertEqual("corrupt", path.read_text())
        path.unlink()
        target = Path(self.temp.name) / "untouched"
        target.write_text("private")
        path.symlink_to(target)
        self.refused("PREPARATION_FAILED", self.prepare)
        self.assertEqual("private", target.read_text())

    def test_symlink_cache_root_and_lock_refused(self):
        target = Path(self.temp.name) / "outside"
        target.mkdir()
        self.cache.symlink_to(target, target_is_directory=True)
        self.refused("CACHE_INVALID", self.prepare)
        self.cache.unlink()
        self.cache.mkdir(mode=0o700)
        (self.cache / ".prepare.lock").symlink_to(target / "not-created")
        self.refused("PREPARATION_FAILED", self.prepare)
        self.assertFalse((target / "not-created").exists())

    def test_postgres_requirement_no_silent_upgrade(self):
        self.docker.meta["postgres_major"] = "19"
        self.refused("POSTGRES_INCOMPATIBLE", self.prepare)
        self.assertFalse(self.calls("build"))
        self.assertEqual(self.original, self.baseline)

    def test_lower_pg_minimum_preserves_actual_baseline_db_major(self):
        self.baseline["app"]["postgres_major"] = "18"
        self.docker.meta["postgres_major"] = "13"
        result = self.prepare()
        profile = result["profile"]
        self.assertEqual("18", profile["app"]["postgres_major"])
        self.assertEqual("13", profile["review_runtime"]["postgres_minimum_major"])
        self.assertTrue(profile["review_runtime"]["postgres_requirement_known"])
        self.assertEqual(self.baseline["images"]["db"], profile["images"]["db"])
        self.assertEqual(self.original, self.baseline)

    def test_missing_pg_requirement_is_explicitly_unknown(self):
        self.docker.meta["postgres_major"] = None
        result = self.prepare()
        self.assertEqual(self.baseline["app"]["postgres_major"], result["profile"]["app"]["postgres_major"])
        self.assertIsNone(result["profile"]["review_runtime"]["postgres_minimum_major"])
        self.assertFalse(result["profile"]["review_runtime"]["postgres_requirement_known"])

    def test_bad_stock_metadata_refused(self):
        for key, value in (("version", "unparseable"), ("revision", "abcd123"),
                           ("ruby", "ruby 4.0"), ("core_migrations", ["../bad"]),
                           ("bundler", None), ("postgres_major", "host/path")):
            with self.subTest(key=key):
                self.docker.meta = metadata()
                self.docker.meta[key] = value
                with self.assertRaises(runtime.Refusal):
                    self.prepare()
        self.assertFalse(self.calls("build"))

    def test_wrong_registry_digest_is_refused(self):
        self.docker.stock["RepoDigests"] = ["private.example/discourse@sha256:" + "a" * 64]
        self.refused("METADATA_INVALID", self.prepare)

    def two_core_candidates(self):
        exact = metadata()
        current = metadata()
        additions = ["20261102000000", "20261103000000", "20261104000000", "20261105000000"]
        current["revision"] = "f" * 40
        current["core_migrations"] += additions
        current["postgres_major"] = "13"
        self.docker.candidates = {"2026.11.0-latest": (image("a"), exact),
                                  "latest": (image("f"), current)}
        return exact, current, additions

    def test_same_version_current_core_covers_four_missing_backup_ids(self):
        exact, current, additions = self.two_core_candidates()
        required = exact["core_migrations"] + additions
        result = self.prepare("2026.11.0-latest", max(required), required)
        profile = result["profile"]
        self.assertEqual(current["revision"], profile["app"]["revision"])
        self.assertEqual(runtime.PUBLIC + ":latest", profile["preparation"]["source"]["ref"])
        comparison = result["comparison"]
        self.assertTrue(comparison["core_comparison_complete"])
        self.assertEqual(len(required), comparison["known_required_core_migrations"])
        self.assertEqual(0, comparison["missing_known_core_migrations"])
        self.assertEqual("18", profile["app"]["postgres_major"])
        self.assertEqual("13", profile["review_runtime"]["postgres_minimum_major"])
        self.assertEqual(self.baseline["images"]["db"], profile["images"]["db"])
        self.assertEqual(2, len(self.calls("pull")))

    def test_unknown_plugin_max_never_forces_upgrade_or_enters_public_inventory(self):
        exact, _, _ = self.two_core_candidates()
        plugin = "20990101000000"
        result = self.prepare("2026.11.0-latest", plugin, exact["core_migrations"] + [plugin])
        profile = result["profile"]
        self.assertEqual(exact["revision"], profile["app"]["revision"])
        comparison = result["comparison"]
        self.assertTrue(comparison["core_comparison_complete"])
        self.assertEqual(1, comparison["unknown_required_migrations_count"])
        self.assertNotIn(plugin, json.dumps(profile))
        self.assertEqual(max(exact["core_migrations"]), profile["review_runtime"]["schema_version"])

    def test_unrelated_current_migrations_preserve_exact(self):
        exact, _, _ = self.two_core_candidates()
        result = self.prepare("2026.11.0-latest", required_migrations=exact["core_migrations"])
        self.assertEqual(exact["revision"], result["profile"]["app"]["revision"])
        self.assertTrue(result["comparison"]["core_comparison_complete"])

    def test_alternate_pull_failure_returns_exact_but_incomplete(self):
        exact, _, additions = self.two_core_candidates()
        self.docker.fail_tags.add("latest")
        result = self.prepare("2026.11.0-latest", required_migrations=exact["core_migrations"] + additions)
        profile = result["profile"]
        self.assertEqual(exact["revision"], profile["app"]["revision"])
        self.assertFalse(result["comparison"]["core_comparison_complete"])
        self.assertEqual(4, result["comparison"]["unknown_required_migrations_count"])

    def test_failed_stable_discovery_returns_exact_but_incomplete(self):
        self.docker.meta = metadata("3.4.2")
        self.docker.more_pages = True
        result = self.prepare("3.4.2", required_migrations=self.docker.meta["core_migrations"])
        self.assertEqual("3.4.2", result["profile"]["app"]["version"])
        self.assertFalse(result["comparison"]["core_comparison_complete"])

    def test_tests_passed_discovers_actual_same_track_prerelease(self):
        exact = metadata("3.4.0.beta3")
        current = metadata("3.4.0.rc1")
        current["core_migrations"].append("20261102000000")
        self.docker.tags += ["3.4.0.beta3", "3.4.0.rc1"]
        self.docker.candidates = {"3.4.0.beta3": (image("a"), exact),
                                  "3.4.0.rc1": (image("f"), current)}
        result = self.prepare("3.4.0.beta3", required_migrations=current["core_migrations"])
        self.assertEqual("3.4.0.rc1", result["profile"]["app"]["version"])
        self.assertTrue(result["comparison"]["core_comparison_complete"])
        self.assertFalse(any(a[-1].endswith(":latest") for a in self.calls("pull")))

    def test_most_known_core_ids_wins_when_neither_covers_all(self):
        exact, current, additions = self.two_core_candidates()
        current["core_migrations"] = additions
        required = exact["core_migrations"] + additions
        result = self.prepare("2026.11.0-latest", required_migrations=required)
        comparison = result["comparison"]
        self.assertEqual(additions, result["profile"]["review_runtime"]["core_migrations"])
        self.assertEqual(len(exact["core_migrations"]), comparison["missing_known_core_migrations"])

    def test_required_migrations_strictly_validated_before_subprocess(self):
        for value in ("20261101000000", {}, ["../path"], [123], ["20261101000000\n"],
                      ["20261101000000"] * 20001):
            self.refused("SCHEMA_INVALID", lambda: self.prepare("2026.11.0-latest", required_migrations=value))
        self.assertEqual([], self.docker.calls)

    def test_exact_provenance_failure_is_not_silently_replaced(self):
        exact, current, _ = self.two_core_candidates()
        exact['revision'] = 'invalid'
        self.refused('METADATA_INVALID', lambda: self.prepare('2026.11.0-latest'))
        self.assertEqual(1, len(self.calls('pull')))
        self.assertFalse(self.calls('build'))

    def test_current_provenance_failure_is_not_an_availability_warning(self):
        _, current, _ = self.two_core_candidates()
        current['revision'] = 'invalid'
        self.refused('METADATA_INVALID', lambda: self.prepare('2026.11.0-latest'))
        self.assertFalse(self.calls('build'))

    def test_unknown_pull_outcome_stops_before_any_fallback_or_build(self):
        version = '2026.11.0-latest'
        for tag, expected_pulls in ((version, 1), ('latest', 2)):
            with self.subTest(tag=tag), tempfile.TemporaryDirectory() as directory:
                self.docker.calls.clear()
                target = ['docker', 'pull', runtime.PUBLIC + ':' + tag]
                def interrupted(args, **kwargs):
                    if args == target:
                        self.docker.calls.append((args, kwargs))
                        runtime._BUDGET.get().uncertain = True
                        runtime.refuse('PREPARATION_FAILED')
                    return self.docker(args, **kwargs)
                with patch.object(runtime, 'run', interrupted):
                    self.refused('RECOVERY_REQUIRED', lambda: runtime.prepare(
                        ROOT, Path(directory), self.baseline, version, None))
                self.assertEqual(expected_pulls, len(self.calls('pull')))
                self.assertEqual(target, self.docker.calls[-1][0])
                self.assertFalse(self.calls('build'))

    def test_unknown_outcome_stays_recovery_required_when_lease_update_fails(self):
        def interrupted(args, **kwargs):
            if args[:2] == ['docker', 'pull']:
                runtime._BUDGET.get().uncertain = True
                runtime.refuse('PREPARATION_FAILED')
            return self.docker(args, **kwargs)
        with patch.object(runtime, 'run', interrupted), \
                patch.object(runtime.os, 'replace', side_effect=OSError('no space')):
            self.refused('RECOVERY_REQUIRED', self.prepare)
        self.assertEqual('in_progress', json.loads((self.cache / '.inflight.json').read_text())['status'])
        self.refused('RECOVERY_REQUIRED', self.prepare)

    def test_probe_cleanup_failure_fences_further_preparation(self):
        original = self.docker
        def failed_cleanup(args, **kwargs):
            if args[:3] == ['docker', 'container', 'ls']:
                return 'owned-container-still-present\n'
            return original(args, **kwargs)
        with patch.object(runtime, 'run', failed_cleanup):
            self.refused('RECOVERY_REQUIRED', self.prepare)
        marker = self.cache / '.inflight.json'
        self.assertEqual('outcome_unknown', json.loads(marker.read_text())['status'])
        pulls = len(self.calls('pull'))
        self.refused('RECOVERY_REQUIRED', self.prepare)
        self.assertEqual(pulls, len(self.calls('pull')))
        self.assertFalse(list((self.cache / 'profiles').glob('*.json')))

    def test_named_probe_is_removed_and_absence_checked_on_error(self):
        calls = []
        def failed_probe(args, **kwargs):
            calls.append(args)
            if args[:2] == ['docker', 'run']:
                runtime.refuse('TIMEOUT')
            return ''
        with patch.object(runtime, 'run', failed_probe):
            self.refused('TIMEOUT', lambda: runtime.probe('sha256:'+'a'*64))
        name = calls[0][calls[0].index('--name')+1]
        self.assertRegex(name, r'^silo-rr-[0-9a-f]{32}$')
        self.assertEqual(['docker','rm','--force',name], calls[1])
        self.assertIn('name=^/'+name+'$', calls[2])

    def test_lock_acquisition_respects_the_shared_deadline(self):
        with tempfile.TemporaryFile() as lock, patch.object(runtime.fcntl, 'flock', side_effect=BlockingIOError()), \
                patch.object(runtime.time, 'sleep'), patch.object(runtime.time, 'monotonic', side_effect=[0,31]):
            self.refused('TIMEOUT', lambda: runtime.acquire_lock(lock, runtime.Budget(60)))

    def test_build_failure_fixed_code_no_profile(self):
        self.docker.fail_build = True
        self.refused("PREPARATION_FAILED", self.prepare)
        self.assertEqual([], list((self.cache / "profiles").glob("*.json")))

    def test_atomic_publish_no_overwrite(self):
        self.cache.mkdir()
        runtime.publish(self.cache, "test", b"old")
        self.refused("CACHE_INVALID", lambda: runtime.publish(self.cache, "test", b"new"))
        self.assertEqual(b"old", (self.cache / "test.json").read_bytes())


class RunnerTest(unittest.TestCase):
    """Exercise bounded subprocess plumbing without launching any process."""
    def fake_run(self, *, stdout=b"ok", stderr=b"", code=0, timeout=False, argv=None, **kwargs):
        from types import SimpleNamespace
        class Pipe(io.BytesIO):
            def __init__(self, data, number):
                super().__init__(data)
                self.number = number
            def fileno(self):
                return self.number
        class Process:
            def __init__(self):
                self.pid = 424242
                self.stdout = Pipe(stdout, 10)
                self.stderr = Pipe(stderr, 11)
                self.killed = False
                self.done = False
                self.waits = []
            def __enter__(self):
                return self
            def __exit__(self, *unused):
                pass
            def poll(self):
                return code if self.done else None
            def wait(self, **options):
                self.waits.append(options)
                self.done = True
                return code
            def kill(self):
                self.killed = True
        class Selector:
            def __init__(self):
                self.items = {}
            def __enter__(self):
                return self
            def __exit__(self, *unused):
                pass
            def register(self, pipe, unused):
                self.items[pipe.fileno()] = SimpleNamespace(fileobj=pipe)
            def unregister(self, pipe):
                del self.items[pipe.fileno()]
            def get_map(self):
                return self.items
            def select(self, unused):
                return [(key, 1) for key in list(self.items.values())]
        proc = Process()
        options = {}
        def popen(args, **opts):
            options.update(opts)
            if hasattr(opts["stdin"], "read"):
                options["input_bytes"] = opts["stdin"].read()
            return proc
        self.proc, self.options = proc, options
        streams = {10: proc.stdout, 11: proc.stderr}
        clock = iter((0, 0, 10000) if runtime._BUDGET.get() else (0, 10000)) if timeout else None
        with patch.object(runtime.subprocess, "Popen", popen), \
             patch.object(runtime.selectors, "DefaultSelector", Selector), \
             patch.object(runtime.os, "read", lambda fd, size: streams[fd].read(size)), \
             patch.object(runtime.os, "killpg", lambda pid, sig: proc.kill()), \
             patch.object(runtime.time, "monotonic", lambda: next(clock, 10000) if clock else 0):
            return runtime.run(argv or ["docker", "fake"], **kwargs)

    def test_sanitized_environment_and_bounded_stdin(self):
        self.assertEqual("ok", self.fake_run(input_bytes=b"fixed-context"))
        env = self.options["env"]
        self.assertEqual({"PATH", "LANG", "DOCKER_CONFIG"}, set(env))
        self.assertFalse(Path(env["DOCKER_CONFIG"]).exists())
        self.assertEqual(b"fixed-context", self.options["input_bytes"])

    def test_stream_output_limit_kills_process_without_disk_logs(self):
        with self.assertRaisesRegex(runtime.Refusal, "STANDARD_REVIEW_RUNTIME_OUTPUT_LIMIT"):
            self.fake_run(stderr=b"private" * runtime.MAX_OUTPUT)
        self.assertTrue(self.proc.killed)

    def test_timeout_kills_process(self):
        with self.assertRaisesRegex(runtime.Refusal, "STANDARD_REVIEW_RUNTIME_TIMEOUT"):
            self.fake_run(timeout=True)
        self.assertTrue(self.proc.killed)

    def test_total_deadline_reserves_time_for_cleanup(self):
        token = runtime._BUDGET.set(runtime.Budget(90))
        try:
            self.assertEqual('ok', self.fake_run())
            self.assertEqual(60, self.proc.waits[0]['timeout'])
        finally:
            runtime._BUDGET.reset(token)
        with patch.object(runtime.time, 'monotonic', return_value=80):
            self.assertEqual(10, runtime.Budget(90).limit(600, cleanup=True))
            with self.assertRaisesRegex(runtime.Refusal, 'TIMEOUT'):
                runtime.Budget(90).limit(600)

    def test_interrupted_mutator_leaves_a_replay_fence(self):
        with tempfile.TemporaryDirectory() as temp:
            cache = Path(temp)
            budget = runtime.Budget(1_000_000)
            token = runtime._BUDGET.set(budget)
            try:
                with runtime.preparation_lease(cache, budget):
                    with self.assertRaisesRegex(runtime.Refusal, 'TIMEOUT'):
                        self.fake_run(timeout=True, argv=['docker','build','--tag','silo-migrate/review-runtime:test'])
            finally:
                runtime._BUDGET.reset(token)
            self.assertTrue(budget.uncertain)
            self.assertEqual('outcome_unknown', json.loads((cache/'.inflight.json').read_text())['status'])
            with self.assertRaisesRegex(runtime.Refusal, 'RECOVERY_REQUIRED'):
                with runtime.preparation_lease(cache, runtime.Budget(1_000_000)):
                    self.fail('replayed an uncertain daemon operation')

    def test_interrupted_probe_records_its_exact_container_for_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory)
            budget = runtime.Budget(1_000_000)
            token = runtime._BUDGET.set(budget)
            name = 'silo-rr-' + 'a' * 32
            try:
                with runtime.preparation_lease(cache, budget):
                    with self.assertRaisesRegex(runtime.Refusal, 'PREPARATION_FAILED'):
                        self.fake_run(code=-9, argv=['docker', 'run', '--name', name])
            finally:
                runtime._BUDGET.reset(token)
            marker = json.loads((cache / '.inflight.json').read_text())
            self.assertEqual('outcome_unknown', marker['status'])
            self.assertEqual({'operation': 'run', 'container': name}, marker['phase'])

    def test_killed_mutator_client_is_not_treated_as_a_settled_failure(self):
        budget = runtime.Budget(1_000_000)
        token = runtime._BUDGET.set(budget)
        try:
            with self.assertRaisesRegex(runtime.Refusal, 'PREPARATION_FAILED'):
                self.fake_run(code=-9, argv=['docker','pull',runtime.PUBLIC+':latest'])
            self.assertTrue(budget.uncertain)
            self.assertTrue(self.proc.killed)
        finally:
            runtime._BUDGET.reset(token)

    def test_raw_daemon_errors_never_reach_caller(self):
        with self.assertRaises(runtime.Refusal) as caught:
            self.fake_run(stderr=b"secret/config/error", code=1)
        self.assertEqual("STANDARD_REVIEW_RUNTIME_PREPARATION_FAILED", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
