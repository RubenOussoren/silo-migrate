"""Opt-in invented-data custody/reader check against the cached control image.

SILO_SUPPORTING_LIVE=1 python3 -I -B test/supporting_live_test.py
No image pulls, network, database or customer files are used.
"""
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def load(name, filename):
    loader = importlib.machinery.SourceFileLoader(name, str(ROOT / filename))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


helpers = load('live_data_tools', 'bin/data_tools.py')
control = load('live_control', 'bin/silo-migrate-control')


def workbook(unsafe_relationship=False):
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('[Content_Types].xml', '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>')
        archive.writestr('xl/workbook.xml', '''<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Mappings" sheetId="1" r:id="rId1"/></sheets></workbook>''')
        archive.writestr('xl/_rels/workbook.xml.rels', '''<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>''')
        archive.writestr('xl/worksheets/sheet1.xml', '''<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>invented-reference-marker</t></is></c><c r="B1"><f>1+1</f><v>2</v></c></row></sheetData><hyperlinks><hyperlink ref="A1" r:id="rLink"/></hyperlinks><drawing r:id="rDraw"/></worksheet>''')
        # Common export shape: clickable metadata, not an external data source.
        # Standard OPC parent-relative reference stays within the ZIP, not the filesystem.
        target = '../../../PRIVATE_PART_NEVER_RETURN' if unsafe_relationship else '../drawings/drawing1.xml'
        archive.writestr('xl/worksheets/_rels/sheet1.xml.rels', '''<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rLink" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://example.invalid/LINK_TARGET_NEVER_FETCH_OR_RETURN" TargetMode="External"/><Relationship Id="rDraw" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing" Target="%s"/></Relationships>''' % target)
        archive.writestr('xl/drawings/drawing1.xml', '<wsDr xmlns="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing"/>')
    return stream.getvalue()


@unittest.skipUnless(os.environ.get('SILO_SUPPORTING_LIVE') == '1', 'opt-in cached-image reference reader test')
class SupportingLiveTest(unittest.TestCase):
    def test_private_copy_and_real_sandboxed_xlsx_csv_reads(self):
        old_umask = os.umask(0o022)  # intake admission refuses group-writable ancestors
        self.addCleanup(os.umask, old_umask)
        with tempfile.TemporaryDirectory(prefix='supporting-live-') as directory:
            base = Path(directory)
            root = base / 'workspaces/invented'
            named = root / '.silo-migrate/named'
            (named / 'standard').mkdir(parents=True, mode=0o700)
            state = named / 'state.json'
            state.write_text(json.dumps({'inputs': {}, 'datasets': {}}))
            profile = ROOT / 'runtime/profiles/discourse-2026.11.0-latest-3158c750.json'
            standard = named / 'standard/state.json'
            standard.write_text(json.dumps({'config': {'discourse_profile': profile.stem,
                                                       'discourse_profile_sha256': hashlib.sha256(profile.read_bytes()).hexdigest()}}))
            before = state.read_bytes(), standard.read_bytes()
            ws = helpers.Workspace(base / 'workspaces', 'invented', ROOT, control, {}, None)
            intake = base / 'intake/invented'
            intake.mkdir(parents=True, mode=0o700)
            module, api = helpers.supporting_module(), helpers.supporting_api()
            # Stock term-llm: the chat request is the adapter's whitelisted JSON plus via: chat.
            context = {'via': 'chat'}
            names = []
            original = helpers.docker
            def observed(argv, **kwargs):
                if argv[0] == 'run':
                    names.append(argv[argv.index('--name') + 1])
                    self.assertIn('none', argv)
                    self.assertIn('--read-only', argv)
                    self.assertNotIn(str(root / 'inputs'), ' '.join(argv))
                    self.assertNotIn(str(intake), ' '.join(argv))
                return original(argv, **kwargs)
            with patch.object(helpers, 'docker', observed):
                for number, (filename, data) in enumerate((('mapping.xlsx', workbook()), ('reference.tsv', b'key\tvalue\nfixture\t7\n')), 1):
                    path = intake / filename
                    path.write_bytes(data)
                    path.chmod(0o600)
                    def request(op, **kwargs):
                        chat = helpers.Workspace(base / 'workspaces', 'invented', ROOT, control, {}, None)
                        chat.chat = True
                        return helpers.op_supporting(chat, dict(context, op=op, **kwargs))
                    # The engineer's intake admission (Files), not a chat upload.
                    with ws.lock():
                        taken = module.admit_reference(ws, {'area': 'intake', 'path': filename, 'origin_id': 'file-live-%d' % number,
                                                            'by': 'Invented Engineer',
                                                            'identity': module.source_identity(path.stat(), filename)}, api)['file']
                    self.assertEqual(hashlib.sha256(data).hexdigest(), taken['sha256'])
                    listed = request('supporting_list')
                    self.assertEqual([], listed['available_refs'])
                    self.assertIn(taken['id'], [item['id'] for item in listed['files']])
                    with self.assertRaisesRegex(helpers.Refusal, '^STANDARD_SUPPORTING_USE_INTAKE$'):
                        request('supporting_take', ref='%032x' % number, _private_session=True, _session_id='forged',
                                _uploads=[{'id': '%032x' % number, 'path': str(path)}])
                    if filename.endswith('.xlsx'):
                        sheets = request('supporting_read', id=taken['id'], mode='sheets')
                        self.assertEqual(['Mappings'], sheets['sheets'])
                        self.assertEqual(1, sheets['ignored_external_hyperlinks'])
                        values = request('supporting_read', id=taken['id'], mode='rows', columns=2, limit=1)
                        self.assertEqual(1, values['ignored_external_hyperlinks'])
                        self.assertNotIn('LINK_TARGET_NEVER_FETCH_OR_RETURN', json.dumps([sheets, values]))
                        rows = values['rows']
                        self.assertEqual('invented-reference-marker', rows[0][0]['value'])
                        self.assertEqual({'type': 'formula', 'formula': True, 'value': None}, rows[0][1])
                    else:
                        rows = request('supporting_read', id=taken['id'], mode='rows', columns=2, limit=2)['rows']
                        self.assertEqual('7', rows[1][1]['value'])
                    self.assertEqual(data, path.read_bytes())
                    self.assertEqual(before, (state.read_bytes(), standard.read_bytes()))
            self.assertEqual(3, len(names))
            for name in names:
                left = subprocess.check_output(['docker', 'ps', '-aq', '--filter', 'name=^/' + name + '$'], timeout=10)
                self.assertEqual(b'', left.strip())
            print(json.dumps({'result': 'intake reference custody, no-context chat XLSX/TSV sandbox reads with archive-contained parent-relative drawing and inert external hyperlink metadata, take refused USE_INTAKE, formula non-evaluation and exact cleanup passed',
                              'read_containers': len(names), 'migration_state_unchanged': True}))


if __name__ == '__main__':
    unittest.main()
