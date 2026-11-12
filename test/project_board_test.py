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

    def build(self, plans, runs, bodies, sites=None, pushes=(), deliveries=None, reviews=()):
        return self.b.build_passes(plans, runs, bodies, sites or {}, list(pushes), deliveries or {}, list(reviews))

    def test_a_merge_run_is_a_pass_of_its_own(self):
        base = {'delivery': {'kind': 'base_site', 'version': 1}, 'discourse_version': '2026.11.0-latest'}
        layer = {'present': True, 'path': 'mergers/arc/merger.rb', 'revision': 'c' * 40, 'files': 2, 'bytes': 900, 'sha256': 'd' * 64}

        def body(layer):
            return {'operation': 'standard_merge', 'converter_revision': 'c' * 40, 'converter': {'branch': 'migration/arc/merge-layer'}, 'dataset_id': 'dataset-1',
                    'delivery': {'dataset_id': 'dataset-1', 'kind': 'development', 'version': 1}, 'roles': {'source': 'input-1', 'base_site': 'input-2'},
                    'base_site': base, 'merge': {'layer': layer, 'settings': False, 'options': {}}}
        waiting = self.build([plan(1, 'proposed')], [], {'plan-1': body({'present': False})})['passes'][0]
        self.assertEqual(('merge', 'merge', [], ('Waiting for your approval', 'now'), {'present': False}, 'Base site v1'),
                         (waiting['kind'], waiting['convert']['kind'], waiting['imports'], waiting['status'], waiting['layer'], waiting['base_site']))
        merged = run(1, 1, checks=0, matched=0)
        merged['artifacts'] = {'backup': {'filename': 'invented.tar.gz', 'sha256': 'a' * 64, 'bytes': 42}}
        args = ([plan(1)], [merged], {'plan-1': body(layer)})
        group = self.build(*args, sites={'run-1': True})['passes'][0]
        self.assertEqual((('Ready to check', 'now'), 'ready', True, 'Development v1', 1), (group['status'], group['backup_state'], group['convert']['site_up'], group['delivery'], group['number']))
        self.assertEqual({'present': True, 'path': 'mergers/arc/merger.rb', 'revision': 'c' * 40, 'files': 2, 'sha256': 'd' * 64}, group['layer'])
        self.assertEqual(('Merged', 'ok'), self.build(*args)['passes'][0]['status'])
        merged['release'] = {'released_by': 'Engineer', 'outbox': '/invented/outbox'}
        group = self.build(*args, sites={'run-1': True})['passes'][0]
        self.assertEqual((('Backup released', 'ok'), 'released'), (group['status'], group['backup_state']))
        for status, expected in (('failed', ('Merge needs a look', 'warn')), ('abandoned', ('Merge needs a look', 'warn')), ('running', ('Running', 'now'))):
            self.assertEqual(expected, self.build([plan(1)], [run(1, 1, status=status)], {'plan-1': body(layer)})['passes'][0]['status'])
        self.assertEqual(('Out of date: propose it again', 'warn'), self.build([plan(1, 'stale')], [], {'plan-1': body(layer)})['passes'][0]['status'])
        self.assertEqual([], self.build([plan(1, 'discarded')], [], {'plan-1': body(layer)})['passes'])
        # A layer pushed after the last merge: the banner offers the next pass, worded for a merge.
        result = self.build([plan(1)], [merged], {'plan-1': body(layer)}, pushes=[push('p1', 'e' * 40)])
        self.assertEqual(('converter', True, 'run-1', 2), tuple(result['banner'][key] for key in ('kind', 'merge', 'run_id', 'next')))
        # A finding is never marked checked by a merge alone: there are no count checks to pass.
        findings = self.b.build_findings([{'id': 'finding-1', 'status': 'released', 'run_id': 'run-1'}], result['passes'],
                                         self.build([plan(1)], [merged], {'plan-1': body(layer)}, pushes=[push('p1', 'c' * 40, pushed='2026-01-01T00:30:00Z', findings=['finding-1'])])['updates'], {})
        self.assertEqual(({'pass': 1, 'step': 'merge'}, None), (findings['progress'][0]['origin'], findings['progress'][0]['checked_in']))

    def test_base_backup_release_is_separate_from_passed_checks(self):
        body = dict(review_body('run-1'), base_site={'delivery': {'kind': 'base_site', 'version': 2}, 'discourse_version': '2026.10.0'})
        review = run(2, 2, checks=6, matched=5)
        review['artifacts'] = {'backup': {'filename': 'invented.sql.gz', 'sha256': 'a' * 64, 'bytes': 42}}
        args = ([plan(1), plan(2)], [run(1, 1), review], {'plan-1': convert_body(), 'plan-2': body})
        group = self.build(*args)['passes'][0]
        self.assertEqual(('Base site v2', 'ready', None), (group['base_site'], group['backup_state'], group['release']))
        self.assertEqual(('Import needs a look', 'warn'), group['status'])
        release = {'released_by': 'Engineer', 'outbox': '/invented/outbox', 'acknowledged_differences': True}
        review['release'] = release
        group = self.build(*args)['passes'][0]
        self.assertEqual(('released', release), (group['backup_state'], group['release']))
        self.assertEqual(('Import needs a look', 'warn'), group['status'])
        review['results']['reconciliation_matched'] = 6
        self.assertEqual(('All checks matched', 'ok'), self.build(*args)['passes'][0]['status'])

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

    def test_the_site_verdict_shows_on_its_import_and_the_pass(self):
        plans, runs = [plan(1), plan(2)], [run(1, 1), run(2, 2)]
        bodies = {'plan-1': convert_body(), 'plan-2': review_body('run-1')}
        accepted = {'id': 'review-1', 'verdict': 'accepted', 'basis': 'customer', 'run_id': 'run-2', 'by': 'A', 'at': '2026-01-03T00:00:00Z', 'process': {'big': 1}}
        cases = [((), None, ('Ready to check', 'now')),
                 ([accepted], 'accepted', ('Accepted', 'ok')),
                 ([dict(accepted, basis='engineer')], 'accepted', ('Checked by you', 'ok')),
                 ([accepted, {'id': 'review-2', 'verdict': 'needs_changes', 'run_id': 'run-2', 'note': 'n'}], 'needs_changes', ('Needs changes', 'warn')),
                 ([accepted, {'id': 'review-3', 'verdict': 'withdrawn', 'of': 'review-1', 'run_id': 'run-2'}], None, ('Ready to check', 'now'))]
        for reviews, verdict, status in cases:
            with self.subTest(reviews=[entry['verdict'] for entry in reviews]):
                group = self.build(plans, runs, bodies, sites={'run-2': True}, reviews=reviews)['passes'][0]
                step = group['imports'][0]
                self.assertEqual(verdict, (step['review'] or {}).get('verdict'))
                self.assertEqual(status, group['status'])
                self.assertNotIn('process', step['review'] or {})  # the page gets the verdict, not the stored process
        # A pass whose acceptance a later pass replaced says so.
        newer = {'id': 'review-9', 'verdict': 'accepted', 'basis': 'customer', 'run_id': 'run-4'}
        built = self.build(plans + [plan(3), plan(4)], runs + [run(3, 3), run(4, 4)], dict(bodies, **{'plan-3': convert_body('b' * 40), 'plan-4': review_body('run-3')}),
                           reviews=[accepted, newer])
        self.assertEqual([('Accepted', 'ok'), ('Accepted earlier', 'wait')], [group['status'] for group in built['passes']])
        # Another run's verdict doesn't count for this one.
        other = dict(accepted, run_id='run-9')
        self.assertIsNone(self.build(plans, runs, bodies, reviews=[other])['passes'][0]['imports'][0]['review'])

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

    def test_effective_active_source_controls_banner_without_rewriting_passes(self):
        deliveries = {'dataset-1': {'dataset_id': 'dataset-1', 'kind': 'development', 'version': 1, 'sequence': 1},
                      'dataset-2': {'dataset_id': 'dataset-2', 'kind': 'development', 'version': 2, 'sequence': 2}}
        args = ([plan(1)], [run(1, 1)], {'plan-1': convert_body()}, {}, [], deliveries)
        for active in ({'development': 'dataset-1'}, {'development': None}, {}):
            with self.subTest(active=active):
                result = self.b.build_passes(*args, active=active)
                self.assertIsNone(result['banner'])
                self.assertEqual('dataset-1', result['passes'][0]['dataset_id'])
                self.assertEqual('Development v1', result['passes'][0]['delivery'])
        result = self.b.build_passes(*args, active={'development': 'dataset-2'})
        self.assertEqual({'kind': 'data', 'label': 'Development v2', 'next': 2}, result['banner'])
        self.assertEqual('Development v1', result['passes'][0]['delivery'])

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
