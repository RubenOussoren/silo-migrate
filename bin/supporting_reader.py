#!/usr/bin/env -S python3 -I -B
"""Bounded, inert CSV/XLSX inspection (stdlib only; never extracts archive files).

read_document returns {status: 'ok', format, mode, sheets: [names]} in sheets
mode, or {status: 'ok', format, mode, sheet, offset, limit, columns, rows,
has_more} in rows mode. Offsets are zero-based logical rows, including gaps;
rows are arrays of exactly `columns` typed cell dictionaries. Empty cells are
{type: 'empty', value: None}. Numbers and ISO dates retain their raw strings;
no formatting, date serial conversion, or formula evaluation is attempted.
Formula cells are {type: 'formula', formula: True, value: None}; neither formula
text nor cached results are returned. CSV fields are always strings. XLSX successes may add
ignored_external_hyperlinks (a count, only when > 0): ordinary
TargetMode="External" hyperlink relationships are validated and discarded,
never resolved, fetched or returned. Any other external relationship refuses.

All refusals return {status: 'error', error: 'STANDARD_SUPPORTING_*'} with no
input-derived diagnostics. The UTF-8 JSON representation, including newline,
is at most 32 KiB. CLI exits 0 on success, 1 on any refusal. Host code owns
registration, path authorization, sandboxing and process deadlines.
"""
import argparse
import csv
import io
import json
import os
import posixpath
import re
import stat
import sys
import zipfile
import xml.etree.ElementTree as ET

MAX_INPUT = 20 * 1024 * 1024
MAX_EXPANDED = 64 * 1024 * 1024
MAX_MEMBERS = 2000
MAX_MEMBER = 16 * 1024 * 1024
MAX_SHEETS = 100
MAX_SHARED_STRINGS = 100000
MAX_SHARED_CHARS = 4 * 1024 * 1024
MAX_CELL_CHARS = 4096
MAX_ROWS = 500000
MAX_CELLS = 1000000
MAX_XML_NODES = 1000000
MAX_XML_DEPTH = 128
MAX_OUTPUT = 32 * 1024
MAIN_NS = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
DOC_REL_NS = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
PKG_REL_NS = 'http://schemas.openxmlformats.org/package/2006/relationships'
CELL_REF = re.compile(r'([A-Z]{1,3})([1-9][0-9]{0,6})\Z')
NUMBER = re.compile(r'[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\Z')


class Refusal(Exception):
    def __init__(self, code='INVALID_DOCUMENT'):
        self.code = 'STANDARD_SUPPORTING_' + code


def require(condition, code='INVALID_DOCUMENT'):
    if not condition:
        raise Refusal(code)


def encoded(result):
    return json.dumps(result, ensure_ascii=False, separators=(',', ':'), allow_nan=False).encode('utf-8') + b'\n'


def bounded(result):
    require(len(encoded(result)) <= MAX_OUTPUT, 'OUTPUT_LIMIT')
    return result


def cell(kind='empty', value=None):
    return {'type': kind, 'value': value}


def text_value(value):
    require(len(value) <= MAX_CELL_CHARS, 'LIMIT')
    return value


def safe_name(name):
    require(isinstance(name, str) and name and len(name) <= 1024)
    require(not any(ord(c) < 32 for c in name) and not any(c in name for c in '\\:%?#'))
    parts = name[:-1].split('/') if name.endswith('/') else name.split('/')
    require(not name.startswith('/') and all(p not in ('', '.', '..') for p in parts))
    return name


def xml_root(data):
    # Inspect the ENTIRE bounded member, not a prefix. NUL-free UTF-8 XML only:
    # this deliberately refuses UTF-16/32 rather than allowing encoded DTD bypasses.
    require(b'\x00' not in data)
    value = data.decode('utf-8-sig')
    require(re.search(r'<!\s*(?:DOCTYPE|ENTITY)\b', value, re.I) is None, 'UNSAFE_XML')
    return value


def validate_xml(data, budget):
    value = xml_root(data)
    depth = 0
    for event, element in ET.iterparse(io.StringIO(value), events=('start', 'end')):
        if event == 'start':
            depth += 1
            budget[0] += 1
            require(depth <= MAX_XML_DEPTH and budget[0] <= MAX_XML_NODES, 'LIMIT')
        else:
            depth -= 1
            element.clear()


class Workbook:
    def __init__(self, data):
        self.archive = zipfile.ZipFile(io.BytesIO(data))
        self.members = {}
        self.relationships = {}
        self.ignored_external_hyperlinks = 0
        total = 0
        normalized = set()
        entries = self.archive.infolist()
        require(len(entries) <= MAX_MEMBERS, 'LIMIT')
        for info in entries:
            name = safe_name(info.filename)
            require(info.orig_filename == info.filename and name not in self.members)
            require(not info.flag_bits & 1, 'UNSUPPORTED')
            require(info.compress_type in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED), 'UNSUPPORTED')
            mode = stat.S_IFMT(info.external_attr >> 16)
            require(mode in (0, stat.S_IFREG, stat.S_IFDIR))
            require(mode != stat.S_IFDIR or info.is_dir())
            require(mode != stat.S_IFREG or not info.is_dir())
            require(not info.is_dir() or info.file_size == 0)
            require(0 <= info.file_size <= MAX_MEMBER, 'LIMIT')
            total += info.file_size
            require(total <= MAX_EXPANDED, 'LIMIT')
            require('vbaproject' not in name.lower() and not name.lower().endswith('.bin'), 'UNSUPPORTED')
            require(name.rstrip('/') not in normalized)
            normalized.add(name.rstrip('/'))
            self.members[name] = info
        for name in self.members:
            parts = name.rstrip('/').split('/')
            for end in range(1, len(parts)):
                require('/'.join(parts[:end]) not in self.members)
        budget = [0]
        # Read every member (CRC and actual expansion checked), including unused XML.
        for name, info in self.members.items():
            data = self.read(name)
            if name.lower().endswith(('.xml', '.rels')):
                validate_xml(data, budget)
                if name == '[Content_Types].xml':
                    types = ET.fromstring(xml_root(data))
                    require(not any('macroenabled' in value.lower() for item in types.iter()
                                    for value in item.attrib.values()), 'UNSUPPORTED')
                if name.endswith('.rels'):
                    self.relationships[name] = self.read_relationships(name, data)
        root = self.root('xl/workbook.xml')
        require(root.tag == '{' + MAIN_NS + '}workbook')
        sections = root.findall('{' + MAIN_NS + '}sheets')
        require(len(sections) == 1)
        sheets = sections[0]
        self.sheets = {}
        rels = self.relationships.get('xl/_rels/workbook.xml.rels', {})
        for entry in sheets:
            require(entry.tag == '{' + MAIN_NS + '}sheet')
            name = entry.get('name', '')
            require(name and len(name) <= 128 and name not in self.sheets)
            relationship = rels.get(entry.get('{' + DOC_REL_NS + '}id'))
            require(relationship is not None)
            target, kind = relationship
            require(kind == DOC_REL_NS + '/worksheet', 'UNSUPPORTED')
            require(target.startswith('xl/') and target.endswith('.xml'))
            require(target not in self.sheets.values())
            self.sheets[name] = target
            require(len(self.sheets) <= MAX_SHEETS, 'LIMIT')
        require(self.sheets)
        self.shared = self.shared_strings()

    def read(self, name):
        require(name in self.members)
        info = self.members[name]
        with self.archive.open(info) as stream:
            data = stream.read(MAX_MEMBER + 1)
        require(len(data) <= MAX_MEMBER and len(data) == info.file_size, 'LIMIT')
        return data

    def root(self, name):
        return ET.fromstring(xml_root(self.read(name)))

    def read_relationships(self, name, data):
        root = ET.fromstring(xml_root(data))
        require(root.tag == '{' + PKG_REL_NS + '}Relationships')
        if name == '_rels/.rels':
            base = ''
        else:
            directory, filename = posixpath.split(name)
            require(posixpath.basename(directory) == '_rels' and filename.endswith('.rels'))
            base = posixpath.dirname(directory)
        result, seen = {}, set()
        for entry in root:
            require(entry.tag == '{' + PKG_REL_NS + '}Relationship')
            identity, kind = entry.get('Id'), entry.get('Type')
            mode = entry.get('TargetMode', 'Internal')
            if mode != 'Internal':
                # Only ordinary external cell hyperlinks are tolerated. Their
                # metadata is validated, counted and DISCARDED: never resolved,
                # fetched, opened or returned. Every other external relationship
                # (worksheet, sharedStrings, externalLink, OLE, data, unknown
                # types) and every unknown TargetMode still refuses.
                require(mode == 'External' and kind == DOC_REL_NS + '/hyperlink', 'UNSAFE_RELATIONSHIP')
                target = entry.get('Target', '')
                require(0 < len(target) <= MAX_CELL_CHARS)
                require(identity and identity not in seen)
                seen.add(identity)
                self.ignored_external_hyperlinks += 1
                continue
            target = entry.get('Target', '')
            # OPC package-absolute targets are allowed, filesystem paths are not.
            safe_name(target[1:] if target.startswith('/') else target)
            target = target.lstrip('/') if target.startswith('/') else posixpath.join(base, target)
            require(target in self.members and not target.endswith('/'))
            require(identity and identity not in seen and kind)
            seen.add(identity)
            result[identity] = (target, kind)
        return result

    def shared_strings(self):
        # Only a fixed, in-archive relationship can locate the optional table.
        targets = [target for target, kind in self.relationships.get('xl/_rels/workbook.xml.rels', {}).values()
                   if kind == DOC_REL_NS + '/sharedStrings']
        require(len(targets) <= 1)
        if not targets:
            return []
        require(targets[0].startswith('xl/'))
        root = self.root(targets[0])
        require(root.tag == '{' + MAIN_NS + '}sst')
        result, chars = [], 0
        for entry in root:
            require(entry.tag == '{' + MAIN_NS + '}si')
            value = rich_text(entry)
            chars += len(value)
            require(len(result) < MAX_SHARED_STRINGS and chars <= MAX_SHARED_CHARS, 'LIMIT')
            result.append(value)
        return result

    def rows(self, sheet, offset, limit, columns):
        shared = self.shared
        root = self.root(self.sheets[sheet])
        require(root.tag == '{' + MAIN_NS + '}worksheet')
        sections = root.findall('{' + MAIN_NS + '}sheetData')
        require(len(sections) == 1)
        section = sections[0]
        result = [[cell() for _ in range(columns)] for _ in range(limit)]
        last_row, count = 0, 0
        for row in section:
            require(row.tag == '{' + MAIN_NS + '}row')
            index = positive_index(row.get('r'), last_row + 1, MAX_ROWS)
            require(index > last_row)
            last_row = index
            last_column = 0
            for entry in row:
                require(entry.tag == '{' + MAIN_NS + '}c')
                count += 1
                require(count <= MAX_CELLS, 'LIMIT')
                reference = entry.get('r')
                if reference is None:
                    column = last_column + 1
                else:
                    match = CELL_REF.fullmatch(reference)
                    require(match is not None)
                    column = 0
                    for char in match[1]:
                        column = column * 26 + ord(char) - 64
                    require(int(match[2]) == index)
                require(last_column < column <= 16384)
                last_column = column
                value = xlsx_cell(entry, shared)
                if offset < index <= offset + limit and column <= columns:
                    result[index - offset - 1][column - 1] = value
        return result[:max(0, min(limit, last_row - offset))], last_row > offset + limit


def positive_index(value, default, maximum):
    if value is None:
        result = default
    else:
        require(re.fullmatch(r'[1-9][0-9]{0,6}', value) is not None)
        result = int(value)
    require(result <= maximum, 'LIMIT')
    return result


def rich_text(element):
    # Do not include phonetic annotations, only actual plain/rich text runs.
    parts = []
    for child in element:
        if child.tag == '{' + MAIN_NS + '}t':
            parts.append(child.text or '')
        elif child.tag == '{' + MAIN_NS + '}r':
            parts.extend(item.text or '' for item in child if item.tag == '{' + MAIN_NS + '}t')
    return text_value(''.join(parts))


def xlsx_cell(entry, shared):
    # Validate even hidden/unselected cells and formula caches for field limits.
    for item in entry.iter():
        if item.text:
            text_value(item.text)
    formulas = entry.findall('{' + MAIN_NS + '}f')
    require(len(formulas) <= 1)
    if formulas:
        return {'type': 'formula', 'formula': True, 'value': None}
    values = entry.findall('{' + MAIN_NS + '}v')
    require(len(values) <= 1)
    value = values[0].text or '' if values else ''
    kind = entry.get('t', 'n')
    require(kind in ('n', 's', 'inlineStr', 'str', 'b', 'd', 'e'))
    if kind == 'inlineStr':
        inline = entry.findall('{' + MAIN_NS + '}is')
        require(len(inline) == 1 and not values)
        return cell('string', rich_text(inline[0]))
    if not values:
        return cell()
    if kind == 's':
        require(re.fullmatch(r'(?:0|[1-9][0-9]{0,5})', value) is not None)
        index = int(value)
        require(index < len(shared))
        return cell('string', shared[index])
    if kind == 'b':
        require(value in ('0', '1'))
        return cell('boolean', value == '1')
    if kind == 'n':
        if not value:
            return cell()
        require(NUMBER.fullmatch(value) is not None)
        return cell('number', value)
    return cell({'str': 'string', 'd': 'date', 'e': 'error'}[kind], value)


def csv_document(data, mode, sheet, offset, limit, columns):
    text = data.decode('utf-8-sig')
    require('\x00' not in text)
    if mode == 'sheets':
        return {'sheets': ['CSV']}
    require(sheet in (None, 'CSV'), 'SHEET_NOT_FOUND')
    sample = text[:8192]
    try:
        dialect = csv.Sniffer().sniff(sample, delimiters=',\t')
    except csv.Error:
        dialect = csv.excel
    previous = csv.field_size_limit(MAX_CELL_CHARS)
    rows, total, count = [], 0, 0
    try:
        for total, row in enumerate(csv.reader(io.StringIO(text, newline=''), dialect, strict=True), 1):
            require(total <= MAX_ROWS, 'LIMIT')
            count += len(row)
            require(count <= MAX_CELLS, 'LIMIT')
            if offset < total <= offset + limit:
                rows.append([cell('string', text_value(value)) for value in row[:columns]] +
                            [cell() for _ in range(max(0, columns - len(row)))])
    finally:
        csv.field_size_limit(previous)
    return {'sheet': 'CSV', 'rows': rows, 'has_more': total > offset + limit}


def read_document(path, *, format, mode='sheets', sheet=None, offset=0, limit=20, columns=20):
    """Return bounded JSON-compatible success or fixed refusal; never parser errors."""
    try:
        require(format in ('xlsx', 'csv') and mode in ('sheets', 'rows'), 'INVALID_ARGUMENT')
        require(sheet is None or isinstance(sheet, str) and 0 < len(sheet) <= 128, 'INVALID_ARGUMENT')
        require(type(offset) is int and 0 <= offset < MAX_ROWS, 'INVALID_ARGUMENT')
        require(type(limit) is int and 1 <= limit <= 100, 'INVALID_ARGUMENT')
        require(type(columns) is int and 1 <= columns <= 50, 'INVALID_ARGUMENT')
        with open(path, 'rb') as stream:
            info = os.fstat(stream.fileno())
            require(stat.S_ISREG(info.st_mode), 'UNSUPPORTED')
            require(info.st_size <= MAX_INPUT, 'LIMIT')
            data = stream.read(MAX_INPUT + 1)
        require(len(data) <= MAX_INPUT, 'LIMIT')
        result = {'status': 'ok', 'format': format, 'mode': mode}
        if format == 'csv':
            result.update(csv_document(data, mode, sheet, offset, limit, columns))
        else:
            book = Workbook(data)
            try:
                if mode == 'sheets':
                    result['sheets'] = list(book.sheets)
                else:
                    sheet = sheet if sheet is not None else next(iter(book.sheets))
                    require(sheet in book.sheets, 'SHEET_NOT_FOUND')
                    rows, more = book.rows(sheet, offset, limit, columns)
                    result.update(sheet=sheet, rows=rows, has_more=more)
                if book.ignored_external_hyperlinks:
                    result['ignored_external_hyperlinks'] = book.ignored_external_hyperlinks
            finally:
                book.archive.close()
        if mode == 'rows':
            result.update(offset=offset, limit=limit, columns=columns)
        return bounded(result)
    except Refusal as error:
        return {'status': 'error', 'error': error.code}
    except OSError:
        return {'status': 'error', 'error': 'STANDARD_SUPPORTING_IO'}
    except Exception:
        # Parser/library diagnostics can contain private paths and cell contents.
        return {'status': 'error', 'error': 'STANDARD_SUPPORTING_INVALID_DOCUMENT'}


class FixedParser(argparse.ArgumentParser):
    def error(self, message):
        raise Refusal('INVALID_ARGUMENT')


def main(argv=None):
    try:
        parser = FixedParser(add_help=False, allow_abbrev=False)
        parser.add_argument('--format', required=True, choices=('xlsx', 'csv'))
        parser.add_argument('--mode', default='sheets', choices=('sheets', 'rows'))
        parser.add_argument('--sheet')
        parser.add_argument('--offset', type=int, default=0)
        parser.add_argument('--limit', type=int, default=20)
        parser.add_argument('--columns', type=int, default=20)
        parser.add_argument('path')
        args = vars(parser.parse_args(argv))
        path = args.pop('path')
        result = read_document(path, **args)
    except Refusal as error:
        result = {'status': 'error', 'error': error.code}
    sys.stdout.buffer.write(encoded(result))
    return 0 if result['status'] == 'ok' else 1


if __name__ == '__main__':
    sys.exit(main())
