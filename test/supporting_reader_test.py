"""Invented fixtures only. Run: python3 -I -B test/supporting_reader_test.py."""
import ast
import importlib.util
import io
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import warnings
import zipfile
from xml.sax.saxutils import escape, quoteattr

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'bin/supporting_reader.py'
SPEC = importlib.util.spec_from_file_location('supporting_reader', SCRIPT)
reader = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(reader)
NS = reader.MAIN_NS
REL = reader.DOC_REL_NS
PKG = reader.PKG_REL_NS
CANARY = 'INVENTED-PRIVATE-PATH-AND-CONTENT-7431'


def worksheet(body):
    return '<worksheet xmlns="%s"><sheetData>%s</sheetData></worksheet>' % (NS, body)


def relationship(identity, target, kind='worksheet', extra=''):
    return '<Relationship Id=%s Target=%s Type=%s %s/>' % (
        quoteattr(identity), quoteattr(target), quoteattr(REL + '/' + kind), extra)


def relationships(body):
    return '<Relationships xmlns="%s">%s</Relationships>' % (PKG, body)


def members(sheets=None, shared=None):
    sheets = [('First', '<row><c><v>42</v></c></row>')] if sheets is None else sheets
    book_sheets, rels, result = [], [], {}
    for index, (name, body) in enumerate(sheets, 1):
        book_sheets.append('<sheet name=%s sheetId="%d" r:id="r%d"/>' % (quoteattr(name), index, index))
        rels.append(relationship('r%d' % index, 'worksheets/sheet%d.xml' % index))
        result['xl/worksheets/sheet%d.xml' % index] = worksheet(body)
    if shared is not None:
        result['xl/sharedStrings.xml'] = '<sst xmlns="%s">%s</sst>' % (NS, shared)
        rels.append(relationship('shared', 'sharedStrings.xml', 'sharedStrings'))
    result['xl/workbook.xml'] = '<workbook xmlns="%s" xmlns:r="%s"><sheets>%s</sheets></workbook>' % (
        NS, REL, ''.join(book_sheets))
    result['xl/_rels/workbook.xml.rels'] = relationships(''.join(rels))
    result['_rels/.rels'] = relationships(relationship('root', 'xl/workbook.xml', 'officeDocument'))
    result['[Content_Types].xml'] = '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>'
    return result


def zip_bytes(entries, compression=zipfile.ZIP_DEFLATED):
    out = io.BytesIO()
    pairs = entries.items() if isinstance(entries, dict) else entries
    with warnings.catch_warnings():
        warnings.simplefilter('ignore', UserWarning)
        with zipfile.ZipFile(out, 'w', compression=compression) as archive:
            for name, content in pairs:
                archive.writestr(name, content)
    return out.getvalue()


class SupportingReaderTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / (CANARY + '.input')

    def read(self, data=None, *, entries=None, **kwargs):
        if entries is not None:
            data = zip_bytes(entries)
        if data is not None:
            self.path.write_bytes(data if isinstance(data, bytes) else data.encode())
        return reader.read_document(self.path, format=kwargs.pop('format', 'xlsx'), **kwargs)

    def refused(self, result, code=None):
        self.assertEqual(result['status'], 'error', result)
        self.assertEqual(set(result), {'status', 'error'})
        self.assertTrue(result['error'].startswith('STANDARD_SUPPORTING_'))
        if code:
            self.assertEqual(result['error'], 'STANDARD_SUPPORTING_' + code)
        self.assertNotIn(CANARY, json.dumps(result))
        self.assertLessEqual(len(reader.encoded(result)), 32768)

    def test_sheet_discovery_and_selection(self):
        result = self.read(entries=members([('One & Two', ''), ('Second', '<row><c><v>7</v></c></row>')]))
        self.assertEqual(result, {'status': 'ok', 'format': 'xlsx', 'mode': 'sheets', 'sheets': ['One & Two', 'Second']})
        result = self.read(mode='rows', sheet='Second', columns=2)
        self.assertEqual(result['rows'], [[reader.cell('number', '7'), reader.cell()]])
        self.assertEqual(result['sheet'], 'Second')
        self.assertFalse(result['has_more'])
        self.refused(self.read(mode='rows', sheet=CANARY), 'SHEET_NOT_FOUND')

    def test_sparse_rows_columns_offsets_and_implicit_references(self):
        body = ('<row r="2"><c r="C2"><v>2.50</v></c><c><v>3</v></c></row>'
                '<row><c><v>4</v></c></row><row r="6"><c r="B6"><v>8</v></c></row>')
        result = self.read(entries=members([('Sparse', body)]), mode='rows', offset=1, limit=3, columns=4)
        self.assertEqual(result['status'], 'ok', result)
        self.assertEqual(result['rows'], [
            [reader.cell(), reader.cell(), reader.cell('number', '2.50'), reader.cell('number', '3')],
            [reader.cell('number', '4'), reader.cell(), reader.cell(), reader.cell()],
            [reader.cell()] * 4])
        self.assertTrue(result['has_more'])
        result = self.read(mode='rows', offset=5, limit=3, columns=2)
        self.assertEqual(result['rows'], [[reader.cell(), reader.cell('number', '8')]])
        self.assertFalse(result['has_more'])
        self.assertEqual(self.read(mode='rows', offset=10)['rows'], [])

    def test_mixed_types_shared_inline_rich_dates_errors_and_formula_caches(self):
        body = ('<row><c t="s"><v>0</v></c>'
                '<c t="inlineStr"><is><r><t>in</t></r><r><t>line</t></r></is></c>'
                '<c t="b"><v>1</v></c><c t="b"><v>0</v></c>'
                '<c t="d"><v>2026-11-11T00:00:00Z</v></c><c s="99"><v>46200</v></c>'
                '<c><f>WEBSERVICE(&quot;https://example.invalid&quot;)</f><v>12345</v></c>'
                '<c t="str"><f t="shared" si="0"/><v>' + CANARY + '</v></c>'
                '<c t="str"><v>literal</v></c><c t="e"><v>#DIV/0!</v></c><c/></row>')
        shared = '<si><r><t>sha</t></r><r><t>red &amp; safe</t></r><rPh><t>exclude</t></rPh></si>'
        result = self.read(entries=members([('Types', body)], shared), mode='rows', columns=11)
        self.assertEqual(result['status'], 'ok', result)
        self.assertEqual(result['rows'][0], [reader.cell('string', 'shared & safe'), reader.cell('string', 'inline'),
                         reader.cell('boolean', True), reader.cell('boolean', False),
                         reader.cell('date', '2026-11-11T00:00:00Z'), reader.cell('number', '46200'),
                         {'type': 'formula', 'formula': True, 'value': None},
                         {'type': 'formula', 'formula': True, 'value': None},
                         reader.cell('string', 'literal'), reader.cell('error', '#DIV/0!'), reader.cell()])
        self.assertNotIn(CANARY, json.dumps(result))
        self.assertNotIn('WEBSERVICE', json.dumps(result))
        self.assertNotIn('12345', json.dumps(result))

    def test_number_lexemes_never_float_or_format_conversion(self):
        values = ['0002', '-1.20', '+.5', '1e99999', '12345678901234567890']
        body = '<row>' + ''.join('<c><v>%s</v></c>' % value for value in values) + '</row>'
        result = self.read(entries=members([('Numbers', body)]), mode='rows', columns=5)
        self.assertEqual([item['value'] for item in result['rows'][0]], values)

    def test_csv_bom_quoting_multiline_empty_and_formula_like_strings(self):
        data = '\ufeffname,note,,formula\r\n"A, B","line1\nline2",,"=1+1"\r\n\r\nx,y,z,w\r\n'
        self.assertEqual(self.read(data, format='csv')['sheets'], ['CSV'])
        result = self.read(format='csv', mode='rows', offset=1, limit=2, columns=5)
        self.assertEqual(result['rows'], [
            [reader.cell('string', 'A, B'), reader.cell('string', 'line1\nline2'),
             reader.cell('string', ''), reader.cell('string', '=1+1'), reader.cell()],
            [reader.cell()] * 5])
        self.assertTrue(result['has_more'])
        self.refused(self.read(format='csv', mode='rows', sheet=CANARY), 'SHEET_NOT_FOUND')

    def test_csv_tab_dialect_and_single_column(self):
        result = self.read('a\tb\n"c\td"\te\n', format='csv', mode='rows', columns=3)
        self.assertEqual(result['rows'][1], [reader.cell('string', 'c\td'), reader.cell('string', 'e'), reader.cell()])
        result = self.read('one\ntwo\n', format='csv', mode='rows', offset=1, columns=1)
        self.assertEqual(result['rows'], [[reader.cell('string', 'two')]])
        self.assertEqual(self.read('', format='csv', mode='rows')['rows'], [])

    def test_maximum_parameters_and_empty_documents(self):
        result = self.read(entries=members([('Empty', '')]), mode='rows', offset=499999, limit=100, columns=50)
        self.assertEqual(result['rows'], [])
        self.assertEqual(result['offset'], 499999)
        self.assertEqual(result['columns'], 50)
        self.assertFalse(result['has_more'])

    def test_invalid_parameters_are_fixed_and_do_not_open_files(self):
        cases = [{'format': 'zip'}, {'format': []}, {'mode': 'other'}, {'sheet': ''}, {'sheet': []},
                 {'sheet': 'x' * 129}, {'offset': -1}, {'offset': 500000}, {'offset': True}, {'offset': '0'},
                 {'limit': 0}, {'limit': 101}, {'limit': 1.0}, {'limit': False},
                 {'columns': 0}, {'columns': 51}, {'columns': None}]
        for kwargs in cases:
            with self.subTest(kwargs=kwargs), mock.patch('builtins.open', side_effect=AssertionError('opened')):
                self.refused(reader.read_document(self.path, **{'format': 'xlsx', **kwargs}), 'INVALID_ARGUMENT')

    def test_input_file_size_real_boundary(self):
        with self.path.open('wb') as stream:
            stream.truncate(reader.MAX_INPUT + 1)
        self.refused(self.read(format='csv'), 'LIMIT')
        self.refused(reader.read_document(self.path.parent / CANARY, format='csv'), 'IO')

    def test_bad_zip_xml_and_encoding(self):
        self.refused(self.read(CANARY))
        entries = members()
        entries['xl/workbook.xml'] = '<broken>' + CANARY
        self.refused(self.read(entries=entries))
        self.refused(self.read(b'\xff' + CANARY.encode(), format='csv'))
        self.refused(self.read(b'hi\x00there', format='csv'))
        self.refused(self.read('"unclosed\n' + CANARY, format='csv', mode='rows'))

    def test_dtd_and_entities_rejected_in_full_xml_including_unused_members(self):
        payloads = [
            '<!DOCTYPE foo [<!ENTITY secret "%s">]><foo>&secret;</foo>' % CANARY,
            ('<!--' + 'x' * 100000 + '-->\n<!DOCTYPE foo SYSTEM "file:///' + CANARY + '"><foo/>'),
            '<!ENTITY secret SYSTEM "https://example.invalid/' + CANARY + '"><foo/>',
            '<!-- <!DOCTYPE hidden> --><foo/>',
            '<!DOCTYPE foo [<!ENTITY a "a"><!ENTITY b "&a;&a;&a;">]><foo>&b;</foo>',
        ]
        for payload in payloads:
            with self.subTest(prefix=payload[:40]):
                entries = members()
                entries['xl/unused.xml'] = payload
                self.refused(self.read(entries=entries), 'UNSAFE_XML')
        entries = members()
        entries['xl/unused.xml'] = payloads[0].encode('utf-16')
        self.refused(self.read(entries=entries))

    def test_deep_and_excessive_xml_node_budgets(self):
        entries = members()
        entries['unused.xml'] = '<a>' * 129 + '</a>' * 129
        self.refused(self.read(entries=entries), 'LIMIT')
        entries['unused.xml'] = '<a>' + '<b/>' * 100 + '</a>'
        with mock.patch.object(reader, 'MAX_XML_NODES', 50):
            self.refused(self.read(entries=entries), 'LIMIT')

    def test_external_relationships_never_fetch_even_unused_or_nested(self):
        for mode, target in [('External', 'https://example.invalid/' + CANARY),
                             ('External', 'file:///' + CANARY), ('external', 'worksheets/sheet1.xml')]:
            with self.subTest(mode=mode, target=target):
                entries = members()
                entries['xl/_rels/unused.xml.rels'] = relationships(
                    relationship('bad', target, extra='TargetMode="%s"' % mode))
                self.refused(self.read(entries=entries), 'UNSAFE_RELATIONSHIP')

    def test_relationship_target_path_attacks_and_missing_targets(self):
        targets = ['../outside.xml', 'worksheets/../worksheets/sheet1.xml', '//xl/worksheets/sheet1.xml',
                   'worksheets\\sheet1.xml', 'https://example.invalid/x', 'file:///etc/passwd',
                   'worksheets/%73heet1.xml', 'worksheets/sheet1.xml#part', './worksheets/sheet1.xml',
                   '', 'missing.xml']
        for target in targets:
            with self.subTest(target=target):
                entries = members()
                entries['xl/_rels/workbook.xml.rels'] = relationships(relationship('r1', target))
                self.refused(self.read(entries=entries))

    def test_package_absolute_relationship_and_nondefault_worksheet_filename(self):
        entries = members()
        entries['xl/worksheets/renamed.xml'] = entries.pop('xl/worksheets/sheet1.xml')
        entries['xl/_rels/workbook.xml.rels'] = relationships(relationship('r1', '/xl/worksheets/renamed.xml'))
        result = self.read(entries=entries, mode='rows', columns=1)
        self.assertEqual(result['rows'], [[reader.cell('number', '42')]])

    def test_duplicate_missing_wrong_relationships_and_sheet_names(self):
        originals = members()
        variants = [relationships(relationship('r1', 'worksheets/sheet1.xml') * 2),
                    relationships(relationship('other', 'worksheets/sheet1.xml')),
                    relationships(relationship('r1', 'worksheets/sheet1.xml', 'chartsheet')),
                    '<bad/>']
        for rels in variants:
            with self.subTest(rels=rels[:80]):
                entries = {**originals, 'xl/_rels/workbook.xml.rels': rels}
                self.refused(self.read(entries=entries))
        for sheets in [[], [('Duplicate', ''), ('Duplicate', '')], [('', '')]]:
            self.refused(self.read(entries=members(sheets)))

    def test_zip_entry_attacks_duplicates_and_aliases(self):
        for name in ['../outside', '/absolute', 'xl/../outside', 'xl\\workbook.xml', './xl/a',
                     'xl//a', 'xl//', 'C:/drive', 'xl/a%2fb', 'xl/a\x00suffix', 'xl/\x01bad']:
            with self.subTest(name=repr(name)):
                entries = list(members().items()) + [(name, 'bad')]
                # ZipFile itself strips NUL suffixes on writing; use a raw patch below.
                if '\x00' in name:
                    data = zip_bytes(list(members().items()) + [('xl/aZsuffix', 'bad')])
                    data = data.replace(b'xl/aZsuffix', b'xl/a\x00suffix')
                    self.refused(self.read(data))
                else:
                    self.refused(self.read(zip_bytes(entries)))
        entries = list(members().items())
        self.refused(self.read(zip_bytes(entries + [entries[0]])))
        self.refused(self.read(zip_bytes(entries + [('ambiguous', ''), ('ambiguous/', '')])))
        self.refused(self.read(zip_bytes(entries + [('parent', ''), ('parent/child', '')])))

    def test_zip_symlink_and_encryption_unsupported(self):
        out = io.BytesIO(zip_bytes(members()))
        with zipfile.ZipFile(out, 'a') as archive:
            info = zipfile.ZipInfo('xl/link')
            info.create_system = 3
            info.external_attr = 0o120777 << 16
            archive.writestr(info, CANARY)
        self.refused(self.read(out.getvalue()))
        data = bytearray(zip_bytes(members()))
        for signature, delta in [(b'PK\x03\x04', 6), (b'PK\x01\x02', 8)]:
            position = 0
            while True:
                position = data.find(signature, position)
                if position < 0:
                    break
                flags = struct.unpack_from('<H', data, position + delta)[0]
                struct.pack_into('<H', data, position + delta, flags | 1)
                position += 4
        self.refused(self.read(bytes(data)), 'UNSUPPORTED')

    def test_zip_crc_and_compression_refusals(self):
        data = zip_bytes(members(), zipfile.ZIP_STORED)
        data = data.replace(b'<v>42</v>', b'<v>43</v>', 1)
        self.refused(self.read(data))
        self.refused(self.read(zip_bytes(members(), zipfile.ZIP_BZIP2)), 'UNSUPPORTED')

    def test_zip_bomb_member_total_and_member_count_limits(self):
        entries = members()
        entries['padding.txt'] = b'x' * (reader.MAX_MEMBER + 1)
        data = zip_bytes(entries)
        self.assertLess(len(data), 100000)
        self.refused(self.read(data), 'LIMIT')
        entries = members()
        entries.update(('extra%d' % index, b'') for index in range(2000))
        self.refused(self.read(entries=entries), 'LIMIT')
        entries = members()
        entries['padding.txt'] = b'x' * 10000
        with mock.patch.object(reader, 'MAX_EXPANDED', 5000):
            self.refused(self.read(entries=entries), 'LIMIT')

    def test_macros_refused_and_never_interpreted(self):
        for name, value in [('xl/vbaProject.bin', CANARY),
                            ('[Content_Types].xml', '<Types Type="application/vnd.ms-excel.sheet.macroEnabled.main+xml"/>')]:
            entries = {**members(), name: value}
            self.refused(self.read(entries=entries), 'UNSUPPORTED')

    def test_sheet_limit_real_boundary(self):
        entries = members([('Sheet%d' % i, '') for i in range(100)])
        self.assertEqual(len(self.read(entries=entries)['sheets']), 100)
        self.refused(self.read(entries=members([('Sheet%d' % i, '') for i in range(101)])), 'LIMIT')

    def test_shared_string_count_and_char_budgets_even_in_sheets_mode(self):
        entries = members(shared='<si><t>x</t></si>' * 100001)
        self.refused(self.read(entries=entries), 'LIMIT')
        entries = members(shared='<si><t>abc</t></si><si><t>def</t></si>')
        with mock.patch.object(reader, 'MAX_SHARED_CHARS', 5):
            self.refused(self.read(entries=entries), 'LIMIT')
        entries = members(shared='<si><t>' + 'x' * 4097 + '</t></si>')
        self.refused(self.read(entries=entries), 'LIMIT')

    def test_cell_length_limits_in_unselected_columns_rows_and_formula_cache(self):
        for body in ['<row><c r="Z1" t="inlineStr"><is><t>%s</t></is></c></row>',
                     '<row r="100"><c><f>%s</f><v>0</v></c></row>',
                     '<row><c><f>1</f><v>%s</v></c></row>']:
            entries = members([('Long', body % ('x' * 4097))])
            self.refused(self.read(entries=entries, mode='rows', limit=1, columns=1), 'LIMIT')
        entries = members([('Exact', '<row><c t="inlineStr"><is><t>%s</t></is></c></row>' % ('x' * 4096))])
        self.assertEqual(self.read(entries=entries, mode='rows', columns=1)['status'], 'ok')
        # Runs cannot circumvent the aggregate inline string cap.
        body = '<row><c t="inlineStr"><is>' + '<r><t>%s</t></r>' % ('x' * 3000) * 2 + '</is></c></row>'
        self.refused(self.read(entries=members([('Long', body)]), mode='rows'), 'LIMIT')

    def test_shared_indices_and_invalid_cell_types_fail_closed(self):
        cells = ['<c t="s"><v>-1</v></c>', '<c t="s"><v>1</v></c>', '<c t="s"><v>0.0</v></c>',
                 '<c t="b"><v>true</v></c>', '<c><v>nan</v></c>', '<c><v>1_000</v></c>',
                 '<c t="unknown"><v>1</v></c>', '<c t="inlineStr"/>', '<c><v>1</v><v>2</v></c>']
        for item in cells:
            with self.subTest(item=item):
                entries = members([('Bad', '<row>%s</row>' % item)], '<si><t>only</t></si>')
                self.refused(self.read(entries=entries, mode='rows'))

    def test_malformed_row_and_cell_references(self):
        bodies = ['<row r="0"/>', '<row r="01"/>', '<row r="-1"/>', '<row r="1.0"/>',
                  '<row r="1"/><row r="1"/>', '<row r="2"/><row r="1"/>',
                  '<row><c r="A0"/></row>', '<row><c r="a1"/></row>', '<row><c r="$A$1"/></row>',
                  '<row><c r="A2"/></row>', '<row><c r="XFE1"/></row>',
                  '<row><c r="B1"/><c r="A1"/></row>', '<row><c r="A1"/><c r="A1"/></row>']
        for body in bodies:
            with self.subTest(body=body):
                self.refused(self.read(entries=members([('Bad', body)]), mode='rows'))

    def test_row_and_cell_scan_budgets_apply_beyond_requested_window(self):
        self.refused(self.read(entries=members([('Big', '<row r="500001"/>')]), mode='rows'), 'LIMIT')
        self.refused(self.read(entries=members([('Big', '<row r="500000"/><row/>')]), mode='rows'), 'LIMIT')
        entries = members([('Cells', '<row><c/><c/><c/></row>')])
        with mock.patch.object(reader, 'MAX_CELLS', 2):
            self.refused(self.read(entries=entries, mode='rows', columns=1, limit=1), 'LIMIT')
        entries = members([('Edge', '<row r="500000"><c r="XFD500000"><v>1</v></c></row>')])
        self.assertEqual(self.read(entries=entries, mode='rows', offset=499999, columns=1)['rows'], [[reader.cell()]])

    def test_csv_field_and_scan_budgets_restore_global_field_limit(self):
        original = reader.csv.field_size_limit()
        self.refused(self.read('x\n' + 'y' * 4097, format='csv', mode='rows', limit=1))
        self.assertEqual(reader.csv.field_size_limit(), original)
        with mock.patch.object(reader, 'MAX_ROWS', 3):
            self.refused(self.read('a\nb\nc\nd\n', format='csv', mode='rows', limit=1), 'LIMIT')
        with mock.patch.object(reader, 'MAX_CELLS', 3):
            self.refused(self.read('a,b,c,d\n', format='csv', mode='rows', columns=1), 'LIMIT')

    def test_oversized_json_refuses_without_truncation_or_private_payload(self):
        body = '<row>' + ('<c t="inlineStr"><is><t>%s</t></is></c>' % (CANARY * 100)) * 20 + '</row>'
        self.refused(self.read(entries=members([('Big', body)]), mode='rows'), 'OUTPUT_LIMIT')
        data = ','.join([CANARY * 100] * 20)
        self.refused(self.read(data, format='csv', mode='rows'), 'OUTPUT_LIMIT')
        # UTF-8 byte length, not character length, is the boundary.
        data = ','.join(['\U0001f600' * 1000] * 10)
        self.refused(self.read(data, format='csv', mode='rows'), 'OUTPUT_LIMIT')
        self.assertEqual(len(reader.encoded(reader.bounded({'x': 'a' * (32768 - 9)}))), 32768)
        with self.assertRaises(reader.Refusal):
            reader.bounded({'x': 'a' * (32768 - 8)})

    def test_real_total_expansion_csv_scan_and_shared_character_limits(self):
        entries = members()
        padding = b'x' * reader.MAX_MEMBER
        entries.update(('padding%d.txt' % index, padding) for index in range(4))
        # Workbook metadata plus four individually permitted members exceeds 64 MiB.
        self.refused(self.read(entries=entries), 'LIMIT')
        self.refused(self.read('\n' * 500001, format='csv', mode='rows', limit=1), 'LIMIT')
        self.refused(self.read(',' * 1000000, format='csv', mode='rows', columns=1), 'LIMIT')
        shared = '<si><t>' + 'x' * 4096 + '</t></si>'
        self.refused(self.read(entries=members(shared=shared * 1025)), 'LIMIT')

    def test_cli_output_overflow_is_fixed_json_without_content(self):
        self.path.write_text(','.join([CANARY * 100] * 20))
        result = subprocess.run([sys.executable, '-I', '-B', str(SCRIPT), '--format', 'csv',
                                 '--mode', 'rows', str(self.path)], capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr, b'')
        self.refused(json.loads(result.stdout), 'OUTPUT_LIMIT')
        self.assertEqual(result.stdout.count(b'\n'), 1)

    def test_cli_isolated_success_fixed_argument_parser_errors_and_no_stderr(self):
        self.path.write_text('a,b\nx,y\n')
        base = [sys.executable, '-I', '-B', str(SCRIPT)]
        result = subprocess.run(base + ['--format', 'csv', '--mode', 'rows', '--sheet', 'CSV',
                                      '--offset', '1', '--limit', '1', '--columns', '2', str(self.path)],
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, b'')
        self.assertEqual(json.loads(result.stdout)['rows'], [[reader.cell('string', 'x'), reader.cell('string', 'y')]])
        for args in [[], ['--help'], ['--format', CANARY, str(self.path)],
                     ['--format', 'csv', '--offset', CANARY, str(self.path)],
                     ['--format', 'csv', '--limit', '101', str(self.path)],
                     ['--format', 'csv', '--columns', '51', str(self.path)],
                     ['--form', 'csv', str(self.path)], ['--format', 'csv', str(self.path), CANARY]]:
            with self.subTest(args=args):
                result = subprocess.run(base + args, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stderr, b'')
                self.refused(json.loads(result.stdout), 'INVALID_ARGUMENT')
        self.path.write_bytes(b'not-a-zip-' + CANARY.encode())
        result = subprocess.run(base + ['--format', 'xlsx', str(self.path)], capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr, b'')
        self.refused(json.loads(result.stdout))

    def test_ast_and_stdlib_only_no_execution_or_network_imports(self):
        tree = ast.parse(SCRIPT.read_text(), filename=str(SCRIPT))
        imports = {node.name.split('.')[0] for item in ast.walk(tree) if isinstance(item, ast.Import) for node in item.names}
        self.assertTrue(imports <= {'argparse', 'csv', 'io', 'json', 'os', 'posixpath', 're', 'stat', 'sys', 'zipfile', 'xml'})
        self.assertFalse(any(isinstance(item, ast.ImportFrom) for item in ast.walk(tree)))
        calls = {item.func.id for item in ast.walk(tree) if isinstance(item, ast.Call) and isinstance(item.func, ast.Name)}
        self.assertFalse(calls & {'eval', 'exec', 'compile', '__import__'})


if __name__ == '__main__':
    unittest.main()
