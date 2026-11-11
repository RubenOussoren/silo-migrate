"""Opt-in Development-only cancellation check; cached public image, no network/data mounts.

SILO_REVIEW_RUNTIME_LIVE_IMAGE=silo-migrate/review-runtime-test:20261111 \
  python3 -I -B test/review_runtime_live_test.py
"""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('review_runtime_live', ROOT/'bin/review_runtime.py')
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)
IMAGE = os.environ.get('SILO_REVIEW_RUNTIME_LIVE_IMAGE')


@unittest.skipUnless(IMAGE, 'opt-in local cached public-image test')
class LivePreparationCleanupTest(unittest.TestCase):
    def test_timed_out_probe_is_removed_and_its_known_outcome_can_release_lease(self):
        self.assertTrue(IMAGE.startswith('silo-migrate/review-runtime-test:'))
        document = runtime.inspect(IMAGE)
        original = runtime.run
        calls = []
        def observed(args, **kwargs):
            calls.append(args)
            return original(args, **kwargs)
        with tempfile.TemporaryDirectory(prefix='review-runtime-cancel-') as directory:
            cache = Path(directory)
            budget = runtime.Budget(time.monotonic()+31)
            token = runtime._BUDGET.set(budget)
            runtime.run = observed
            try:
                with self.assertRaisesRegex(runtime.Refusal, 'STANDARD_REVIEW_RUNTIME_TIMEOUT'):
                    with runtime.preparation_lease(cache, budget):
                        runtime.sandbox(['--rm','--pull=never','--network=none','--read-only',
                                         '--cap-drop=ALL','--security-opt=no-new-privileges',
                                         '--memory=128m','--cpus=0.25','--pids-limit=32','--user=discourse',
                                         '--entrypoint=ruby',document['Id'],'-e','sleep 60'])
            finally:
                runtime.run = original
                runtime._BUDGET.reset(token)
            self.assertFalse(budget.uncertain, 'probe absence was not confirmed')
            self.assertFalse((cache/'.inflight.json').exists())
        started = next(args for args in calls if args[:2] == ['docker','run'])
        name = started[started.index('--name')+1]
        self.assertIn(['docker','rm','--force',name], calls)
        left = original(['docker','container','ls','--all','--quiet','--filter','name=^/'+name+'$'])
        self.assertEqual('', left.strip())
        print(json.dumps({'result':'timed-out named probe removed; lease settled','container':name}))


if __name__ == '__main__':
    unittest.main()
