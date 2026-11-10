"""Passes and the findings track (widgets/project/board.py). Run: python3 -I -B test/project_board_test.py."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def load():
    spec = importlib.util.spec_from_file_location('project_board', ROOT / 'integrations/term-llm/widgets/project/board.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def plan(n, status='consumed', created='2026-01-0%dT00:00:00Z'):
    return {'plan_id': 'plan-%d' % n, 'status': status, 'created_at': created % n if '%' in created else created}


def run(n, plan_n, status='completed', checks=6, matched=6, started=None):
    return {'run_id': 'run-%d' % n, 'plan_id': 'plan-%d' % plan_n, 'status': status, 'stage': None, 'started_at': started or '2026-01-0%dT01:00:00Z' % n,
            'results': {'reconciliation_checks': checks, 'reconciliation_matched': matched}}


def convert_body(revision='a' * 40, version=1, dataset='dataset-1'):
    return {'operation': 'standard_convert', 'converter_revision': revision, 'converter': {'branch': 'migration/x'}, 'dataset_id': dataset,
            'delivery': {'dataset_id': dataset, 'kind': 'development', 'version': version}, 'roles': {'source': 'input-1', 'settings': 'input-2'}}


def review_body(from_run):
    return {'operation': 'standard_review', 'from_run': {'run_id': from_run}, 'roles': {}}


def push(digest, head, status='pushed', pushed='2026-01-05T00:00:00Z', findings=()):
    return {'digest': digest, 'status': status, 'pushed_at': pushed if status == 'pushed' else None, 'proposed_at': '2026-01-04T00:00:00Z',
            'proposal': {'head': head, 'title': 'Update ' + digest, 'findings': list(findings)}}


class PassesTest(unittest.TestCase):
    def setUp(self):
        self.b = load()

    def build(self, plans, runs, bodies, sites=None, pushes=(), deliveries=None):
        return self.b.build_passes(plans, runs, bodies, sites or {}, list(pushes), deliveries or {})

    def test_a_convert_run_and_its_imports_make_one_pass_newest_first(self):
        result = self.build([plan(1), plan(2), plan(3), plan(4)], [run(1, 1), run(2, 2), run(3, 3), run(4, 4)],
                            {'plan-1': convert_body('a' * 40), 'plan-2': review_body('run-1'), 'plan-3': convert_body('b' * 40), 'plan-4': review_body('run-3')},
                            sites={'run-4': True})
        self.assertEqual([2, 1], [group['number'] for group in result['passes']])
        latest = result['passes'][0]
        self.assertEqual(('run-3', ['run-4']), (latest['convert']['run_id'], [step['run_id'] for step in latest['imports']]))
        self.assertEqual('plan-3', latest['key'])  # the same before and after it runs
        self.assertEqual(('Ready to check', 'now'), latest['status'])
        self.assertEqual(('All checks matched', 'ok'), result['passes'][1]['status'])
        self.assertEqual('Development v1', latest['delivery'])

    def test_statuses_tell_what_is_next(self):
        cases = [
            ([plan(1, 'proposed')], [], 'Waiting for your approval'),
            ([plan(1)], [run(1, 1, status='running')], 'Running'),
            ([plan(1)], [run(1, 1, matched=5)], 'Convert needs a look'),
            ([plan(1)], [run(1, 1)], 'Converted: import next'),
            ([plan(1, 'stale')], [], 'Out of date: propose it again'),
        ]
        for plans, runs, expected in cases:
            with self.subTest(expected=expected):
                self.assertEqual(expected, self.build(plans, runs, {'plan-1': convert_body()})['passes'][0]['status'][0])

    def test_discarded_plans_that_never_ran_are_not_passes(self):
        self.assertEqual([], self.build([plan(1, 'discarded')], [], {'plan-1': convert_body()})['passes'])

    def test_updates_say_which_passes_used_them_and_a_new_one_shows_a_banner(self):
        result = self.build([plan(1)], [run(1, 1, started='2026-01-01T01:00:00Z')], {'plan-1': convert_body('a' * 40)},
                            pushes=[push('d1', 'a' * 40, pushed='2026-01-01T00:00:00Z'), push('d2', 'b' * 40, pushed='2026-01-03T00:00:00Z')])
        used = {update['digest']: update['used_by'] for update in result['updates']}
        self.assertEqual({'d1': [1], 'd2': []}, used)
        self.assertEqual(('converter', 'bbbbbbb', 2, 'run-1'), tuple(result['banner'][key] for key in ('kind', 'head', 'next', 'run_id')))

    def test_newer_data_shows_a_banner_without_a_button(self):
        deliveries = {'dataset-1': {'dataset_id': 'dataset-1', 'kind': 'development', 'version': 1, 'sequence': 1},
                      'dataset-2': {'dataset_id': 'dataset-2', 'kind': 'development', 'version': 2, 'sequence': 2}}
        banner = self.build([plan(1)], [run(1, 1)], {'plan-1': convert_body()}, deliveries=deliveries)['banner']
        self.assertEqual({'kind': 'data', 'label': 'Development v2', 'next': 2}, banner)

    def test_no_banner_while_a_pass_waits_or_runs(self):
        result = self.build([plan(1), plan(2, 'proposed')], [run(1, 1)], {'plan-1': convert_body('a' * 40), 'plan-2': convert_body('b' * 40)},
                            pushes=[push('d2', 'b' * 40, pushed='2026-01-09T00:00:00Z')])
        self.assertIsNone(result['banner'])


class FindingsTrackTest(unittest.TestCase):
    def setUp(self):
        self.b = load()

    def passes(self, pushes=()):
        built = self.b.build_passes([plan(1), plan(2), plan(3)], [run(1, 1, started='2026-01-01T01:00:00Z'), run(2, 2, matched=5, started='2026-01-02T01:00:00Z'), run(3, 3, started='2026-01-06T01:00:00Z')],
                                    {'plan-1': convert_body('a' * 40), 'plan-2': review_body('run-1'), 'plan-3': convert_body('c' * 40)}, {}, list(pushes), {})
        return built['passes'], built['updates']

    def record(self, n, status='released', **extra):
        return dict({'id': 'finding-%d' % n, 'title': 'F%d' % n, 'kind': 'finding', 'status': status, 'proposed_at': 'x', 'decided_at': 'y'}, **extra)

    def test_a_finding_moves_from_review_to_progress_to_done(self):
        passes, updates = self.passes([push('d1', 'c' * 40, pushed='2026-01-05T00:00:00Z', findings=['finding-2'])])
        groups = self.b.build_findings([self.record(1, 'proposed'), self.record(2, run_id='run-2'), self.record(3), self.record(4, 'rejected')], passes, updates, {'finding-3': {'by': 'R'}})
        self.assertEqual(['finding-1'], [item['id'] for item in groups['review']])
        self.assertEqual(['finding-2', 'finding-3'], sorted(item['id'] for item in groups['done']))
        two = next(item for item in groups['done'] if item['id'] == 'finding-2')
        self.assertEqual(({'pass': 1, 'step': 'import'}, 'ccccccc', 2), (two['origin'], two['fix']['head'], two['checked_in']))
        self.assertEqual(['finding-4'], [item['id'] for item in groups['other']])

    def test_a_fix_not_yet_run_or_not_yet_pushed_stays_in_progress(self):
        for pushes, expected in (([push('d1', 'd' * 40, pushed='2026-01-09T00:00:00Z', findings=['finding-2'])], {'head': 'ddddddd', 'title': 'Update d1'}),
                                 ([push('d1', 'd' * 40, status='proposed', findings=['finding-2'])], {'proposed': True}),
                                 ([], None)):
            with self.subTest(expected=expected):
                passes, updates = self.passes(pushes)
                groups = self.b.build_findings([self.record(2)], passes, updates, {})
                self.assertEqual(['finding-2'], [item['id'] for item in groups['progress']])
                self.assertEqual(expected, groups['progress'][0]['fix'])
                self.assertIsNone(groups['progress'][0]['checked_in'])

    def test_a_pass_on_another_branch_does_not_check_a_fix(self):
        fix = push('d1', 'f' * 40, pushed='2026-01-05T00:00:00+00:00', findings=['finding-2'])
        fix['proposal']['branch'] = 'migration/x/first-fix'
        passes, updates = self.passes([fix])  # pass 2 runs 'c'*40 on migration/x, after the push
        groups = self.b.build_findings([self.record(2)], passes, updates, {})
        self.assertEqual(['finding-2'], [item['id'] for item in groups['progress']])
        self.assertFalse(groups['progress'][0]['ran'])
        fix['proposal']['branch'] = 'migration/x'  # a later commit of the same branch carries it
        passes, updates = self.passes([fix])
        self.assertEqual(2, self.b.build_findings([self.record(2)], passes, updates, {})['done'][0]['checked_in'])

    def test_times_compare_as_instants_whatever_their_format(self):
        self.assertTrue(self.b._t('2026-01-05T00:00:01Z') > self.b._t('2026-01-05T00:00:00+00:00'))
        self.assertTrue(self.b._t('2026-01-05T01:00:00+02:00') < self.b._t('2026-01-05T00:00:00Z'))
        self.assertEqual(self.b._t(''), self.b._t(None))

    def test_a_mark_follows_the_finding_through_a_correction(self):
        passes, updates = self.passes()
        groups = self.b.build_findings([self.record(2, 'superseded'), self.record(5, supersedes='finding-2')], passes, updates, {'finding-2': {'by': 'R'}})
        self.assertEqual((['finding-5'], 'finding-2'), ([item['id'] for item in groups['done']], groups['done'][0]['marked_id']))

    def test_a_correction_keeps_the_fix_of_the_finding_it_replaced(self):
        passes, updates = self.passes([push('d1', 'c' * 40, pushed='2026-01-05T00:00:00Z', findings=['finding-2'])])
        groups = self.b.build_findings([self.record(2, 'superseded'), self.record(5, supersedes='finding-2')], passes, updates, {})
        self.assertEqual(['finding-5'], [item['id'] for item in groups['done']])


if __name__ == '__main__':
    unittest.main()
