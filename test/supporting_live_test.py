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


def workbook():
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('[Content_Types].xml', '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>')
        archive.writestr('xl/workbook.xml', '''<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Mappings" sheetId="1" r:id="rId1"/></sheets></workbook>''')
        archive.writestr('xl/_rels/workbook.xml.rels', '''<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>''')
        archive.writestr('xl/worksheets/sheet1.xml', '''<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>invented-reference-marker</t></is></c><c r="B1"><f>1+1</f><v>2</v></c></row></sheetData></worksheet>''')
    return stream.getvalue()


@unittest.skipUnless(os.environ.get('SILO_SUPPORTING_LIVE') == '1', 'opt-in cached-image reference reader test')
class SupportingLiveTest(unittest.TestCase):
    def test_private_copy_and_real_sandboxed_xlsx_csv_reads(self):
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
            uploads = base / 'uploads'
            uploads.mkdir(mode=0o700)
            context = {'_private_session': True, '_session_id': 'invented-locked-chat', '_uploads': [], 'via': 'chat'}
            names = []
            original = helpers.docker
            def observed(argv, **kwargs):
                if argv[0] == 'run':
                    names.append(argv[argv.index('--name') + 1])
                    self.assertIn('none', argv)
                    self.assertIn('--read-only', argv)
                    self.assertNotIn(str(root / 'inputs'), ' '.join(argv))
                return original(argv, **kwargs)
            with patch.dict(os.environ, SILO_TESTING='1', SILO_SUPPORT_UPLOADS_ROOT=str(uploads)), patch.object(helpers, 'docker', observed):
                for number, (filename, data) in enumerate((('mapping.xlsx', workbook()), ('reference.tsv', b'key\tvalue\nfixture\t7\n')), 1):
                    ref = '%032x' % number
                    path = uploads / ref
                    path.write_bytes(data)
                    path.chmod(0o600)
                    context['_uploads'] = [{'id': ref, 'path': str(path), 'filename': filename,
                                             'media_type': 'application/octet-stream', 'size_bytes': len(data)}]
                    def request(op, **kwargs):
                        return helpers.op_supporting(ws, dict(context, op=op, **kwargs))
                    admitted = request('supporting_list')['available_refs']
                    self.assertEqual(ref, admitted[0]['id'])
                    taken = request('supporting_take', ref=ref)['file']
                    self.assertEqual(hashlib.sha256(data).hexdigest(), taken['sha256'])
                    if filename.endswith('.xlsx'):
                        sheets = request('supporting_read', id=taken['id'], mode='sheets')
                        self.assertEqual(['Mappings'], sheets['sheets'])
                        rows = request('supporting_read', id=taken['id'], mode='rows', columns=2, limit=1)['rows']
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
            print(json.dumps({'result': 'supporting custody, XLSX/TSV sandbox reads, formula non-evaluation and exact cleanup passed',
                              'read_containers': len(names), 'migration_state_unchanged': True}))


if __name__ == '__main__':
    unittest.main()
