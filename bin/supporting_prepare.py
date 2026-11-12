#!/usr/bin/env -S python3 -I -B
"""Deterministic preparation of converter-native files from one supporting reference.

Runs inside the no-network data-job sandbox (stdlib only). It never interprets
workbook prose: it projects a bounded table region of an XLSX sheet or CSV into
a declared output format, using the same bounded parser as supporting_reader.

    supporting_prepare.py SPEC.json INPUT OUT_DIR

The spec (validated by validate_spec, also on the host before a job starts):

    {"version": 1, "format": "xlsx" | "csv", "sheet": name | null,
     "header_row": zero-based logical row holding column headers,
     "max_rows": 1..MAX_ROWS data rows after it (more refuses, never truncates),
     "columns": [{"from": header text, "to": output field,
                  "type": "string" | "integer" | "boolean", "required": bool}],
     "output": {"format": "csv" | "json" | "yaml", "shape": "rows" | "map",
                "name": output file name}}

Headers are matched within the first HEADER_SCAN (100) columns; a header row using
column 101 or beyond refuses (PREPARE_HEADER_TOO_WIDE). Rows whose selected cells
are all empty are skipped and counted. Formula and
error cells in a selected column refuse: neither formulas nor cached results are
data. Numbers and dates keep their raw stored text. "map" uses exactly two
columns, the first as a unique non-empty key. The same spec and input bytes
always produce the same output bytes.

Prints one JSON line: {status: ok, name, bytes, sha256, rows, skipped_blank}
or {status: error, error: STANDARD_SUPPORTING_*, row?, column?} with no
input-derived text. Exit 0 on success, 1 on refusal.
"""
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import supporting_reader as reader  # noqa: E402  (fixed sibling in the read-only /silo mount)

VERSION = 1
MAX_ROWS = 10000
MAX_COLUMNS = 50
HEADER_SCAN = 100
MAX_OUTPUT = 20 * 1024 * 1024
FIELD = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_ .-]{0,63}\Z")
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z")
INTEGER = re.compile(r"-?(?:0|[1-9][0-9]{0,17})\Z")
SPEC_KEYS = {"version", "format", "sheet", "header_row", "max_rows", "columns", "output"}
EXTENSIONS = {"csv": (".csv",), "json": (".json",), "yaml": (".yml", ".yaml")}


class Refusal(Exception):
    def __init__(self, code, row=None, column=None):
        super().__init__(code)
        self.code = "STANDARD_SUPPORTING_" + code
        self.row, self.column = row, column


def require(condition, code="PREPARE_SPEC_INVALID", row=None, column=None):
    if not condition:
        raise Refusal(code, row, column)


def label(value):
    return isinstance(value, str) and 0 < len(value) <= 128 and not any(ord(c) < 32 or ord(c) == 127 for c in value)


def validate_spec(spec):
    """Return a normalized copy or raise Refusal. Host and sandbox share this check."""
    require(isinstance(spec, dict) and set(spec) <= SPEC_KEYS and spec.get("version", VERSION) == VERSION)
    require(spec.get("format") in ("xlsx", "csv"))
    sheet = spec.get("sheet")
    require(sheet is None or label(sheet))
    header = spec.get("header_row", 0)
    require(type(header) is int and 0 <= header < reader.MAX_ROWS)
    limit = spec.get("max_rows", MAX_ROWS)
    require(type(limit) is int and 1 <= limit <= MAX_ROWS)
    columns = spec.get("columns")
    require(isinstance(columns, list) and 1 <= len(columns) <= MAX_COLUMNS)
    normalized, targets = [], set()
    for column in columns:
        require(isinstance(column, dict) and set(column) <= {"from", "to", "type", "required"})
        source, target = column.get("from"), column.get("to", column.get("from"))
        kind, required = column.get("type", "string"), column.get("required", False)
        require(label(source) and source.strip() == source and isinstance(target, str) and FIELD.fullmatch(target) is not None)
        require(kind in ("string", "integer", "boolean") and type(required) is bool and target not in targets)
        targets.add(target)
        normalized.append({"from": source, "to": target, "type": kind, "required": required})
    output = spec.get("output")
    require(isinstance(output, dict) and set(output) <= {"format", "shape", "name"})
    fmt, shape, name = output.get("format"), output.get("shape", "rows"), output.get("name")
    require(fmt in EXTENSIONS and shape in ("rows", "map"))
    require(isinstance(name, str) and NAME.fullmatch(name) is not None and name.lower().endswith(EXTENSIONS[fmt]))
    require(shape == "rows" or (len(normalized) == 2 and fmt != "csv"))
    return {"version": VERSION, "format": spec["format"], "sheet": sheet, "header_row": header, "max_rows": limit,
            "columns": normalized, "output": {"format": fmt, "shape": shape, "name": name}}


def canonical(spec):
    return json.dumps(spec, ensure_ascii=True, sort_keys=True, separators=(",", ":")).encode("utf-8")


def region(data, spec, offset, limit, columns):
    """Rows [offset, offset+limit) and whether more exist, via the bounded reader."""
    if spec["format"] == "csv":
        require(spec["sheet"] in (None, "CSV"), "SHEET_NOT_FOUND")
        found = reader.csv_document(data, "rows", None, offset, limit, columns)
        return found["rows"], found["has_more"]
    book = reader.Workbook(data)
    try:
        sheet = spec["sheet"] if spec["sheet"] is not None else next(iter(book.sheets), None)
        require(sheet in book.sheets, "SHEET_NOT_FOUND")
        return book.rows(sheet, offset, limit, columns)
    finally:
        book.archive.close()


def value_of(cell, column, row, index):
    kind, raw = cell.get("type"), cell.get("value")
    require(kind not in ("formula", "error"), "PREPARE_FORMULA_CELL" if kind == "formula" else "PREPARE_ERROR_CELL", row, index)
    if kind == "empty" or (kind == "string" and raw.strip() == ""):
        return None
    if column["type"] == "boolean":
        if kind == "boolean":
            return raw
        text = str(raw).strip().lower()
        require(text in ("true", "false", "1", "0"), "PREPARE_TYPE_MISMATCH", row, index)
        return text in ("true", "1")
    text = raw if isinstance(raw, str) else ("true" if raw else "false")
    if column["type"] == "integer":
        text = text.strip()
        require(INTEGER.fullmatch(text) is not None, "PREPARE_TYPE_MISMATCH", row, index)
        return int(text)
    return text


def table(data, spec):
    # One column past the scanned width: a header row with a used cell there is refused
    # explicitly rather than reported as a missing header. Rows shorter than the width are
    # padded with empty cells by the shared reader (XLSX and CSV alike).
    header_cells, _ = region(data, spec, spec["header_row"], 1, HEADER_SCAN + 1)
    require(len(header_cells) == 1, "PREPARE_HEADER_MISSING")
    require(header_cells[0][HEADER_SCAN].get("type") == "empty", "PREPARE_HEADER_TOO_WIDE")
    headers = [cell["value"].strip() if cell.get("type") == "string" else None for cell in header_cells[0][:HEADER_SCAN]]
    positions = []
    for index, column in enumerate(spec["columns"]):
        found = [i for i, text in enumerate(headers) if text == column["from"]]
        require(found, "PREPARE_HEADER_MISSING", column=index)
        require(len(found) == 1, "PREPARE_HEADER_AMBIGUOUS", column=index)
        positions.append(found[0])
    width = max(positions) + 1
    rows, more = region(data, spec, spec["header_row"] + 1, spec["max_rows"], width)
    require(not more, "PREPARE_ROWS_EXCEED_LIMIT")
    records, skipped = [], 0
    for number, row in enumerate(rows, spec["header_row"] + 1):
        values = [value_of(row[position], column, number, index)
                  for index, (column, position) in enumerate(zip(spec["columns"], positions))]
        if all(value is None for value in values):
            skipped += 1
            continue
        for index, (column, value) in enumerate(zip(spec["columns"], values)):
            require(value is not None or not column["required"], "PREPARE_REQUIRED_EMPTY", number, index)
        records.append((number, values))
    return records, skipped


def yaml_scalar(value):
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    out = []
    for char in value:
        code = ord(char)
        if char in '"\\':
            out.append("\\" + char)
        elif code < 0x20 or 0x7F <= code < 0xA0 or 0xD800 <= code < 0xE000 or code in (0x2028, 0x2029, 0xFEFF):
            out.append("\\u%04x" % code)
        else:
            out.append(char)
    return '"' + "".join(out) + '"'


def emit(records, spec):
    columns, output = spec["columns"], spec["output"]
    names = [column["to"] for column in columns]
    if output["shape"] == "map":
        keys = set()
        for number, (key, _value) in records:
            require(key is not None, "PREPARE_REQUIRED_EMPTY", number, 0)
            require(key not in keys, "PREPARE_DUPLICATE_KEY", number, 0)
            keys.add(key)
    fmt = output["format"]
    if fmt == "csv":
        stream = io.StringIO(newline="")
        writer = csv.writer(stream, lineterminator="\n")
        writer.writerow(names)
        for _number, values in records:
            writer.writerow(["" if v is None else ("true" if v is True else "false" if v is False else str(v)) for v in values])
        return stream.getvalue().encode("utf-8")
    if fmt == "json":
        document = ({values[0]: values[1] for _n, values in records} if output["shape"] == "map"
                    else [dict(zip(names, values)) for _n, values in records])
        if output["shape"] == "map":
            document = {str(key): value for key, value in document.items()}
        return (json.dumps(document, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    lines = []
    if output["shape"] == "map":
        lines = [yaml_scalar(values[0]) + ": " + yaml_scalar(values[1]) for _n, values in records] or ["{}"]
    else:
        for _number, values in records:
            for index, (name, value) in enumerate(zip(names, values)):
                lines.append(("- " if index == 0 else "  ") + yaml_scalar(name) + ": " + yaml_scalar(value))
        lines = lines or ["[]"]
    return ("\n".join(lines) + "\n").encode("utf-8")


def prepare(spec_path, input_path, out_dir):
    with open(spec_path, "rb") as stream:
        raw = stream.read(64 * 1024 + 1)
    require(len(raw) <= 64 * 1024)
    try:
        spec = validate_spec(json.loads(raw))
    except ValueError:
        raise Refusal("PREPARE_SPEC_INVALID")
    with open(input_path, "rb") as stream:
        data = stream.read(reader.MAX_INPUT + 1)
    require(len(data) <= reader.MAX_INPUT, "LIMIT")
    records, skipped = table(data, spec)
    body = emit(records, spec)
    require(len(body) <= MAX_OUTPUT, "LIMIT")
    name = spec["output"]["name"]
    fd = os.open(os.path.join(out_dir, name), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    with os.fdopen(fd, "wb") as stream:
        stream.write(body)
    return {"status": "ok", "name": name, "bytes": len(body), "sha256": hashlib.sha256(body).hexdigest(),
            "rows": len(records), "skipped_blank": skipped, "spec_sha256": hashlib.sha256(canonical(spec)).hexdigest()}


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    try:
        require(len(argv) == 3, "INVALID_ARGUMENT")
        result = prepare(*argv)
    except Refusal as error:
        result = {"status": "error", "error": error.code}
        if error.row is not None:
            result["row"] = error.row
        if error.column is not None:
            result["column"] = error.column
    except reader.Refusal as error:
        result = {"status": "error", "error": error.code}
    except FileExistsError:
        result = {"status": "error", "error": "STANDARD_SUPPORTING_PREPARE_OUTPUT_EXISTS"}
    except OSError:
        result = {"status": "error", "error": "STANDARD_SUPPORTING_IO"}
    except Exception:  # noqa: BLE001 - never print parser diagnostics containing cell text
        result = {"status": "error", "error": "STANDARD_SUPPORTING_INVALID_DOCUMENT"}
    sys.stdout.write(json.dumps(result, separators=(",", ":")) + "\n")
    return 0 if result["status"] == "ok" else 1


if __name__ == "__main__":
    sys.exit(main())
