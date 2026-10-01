"""
Ingest raw ERP text extracts into DuckDB (raw schema).

What this does, per source:
  1. Reads each tab-delimited .txt file line by line.
  2. Fixes encoding: the extracts mix UTF-8 and latin-1 (sometimes within one file),
     so each line is decoded as UTF-8 first and falls back to latin-1.
  3. Checks every row has the same number of fields as the header (fail loudly if not).
  4. Writes a clean UTF-8 copy to data/interim/, prefixed with lineage columns
     (_source_file, _source_line). _source_line matters because the sales extract has
     no line-number column, and identical duplicate lines are legitimate.
  5. Loads the clean copies into raw.<table> with every column as text (types are cast in dbt staging).
     Yearly files (sales_2023..2026 etc.) are stacked into one table, matched by column name.

Raw = faithful copy of the source. No business logic here. Blank fields load as NULL.

Run:  python ingest/ingest.py
"""

from datetime import datetime, timezone
from pathlib import Path

import duckdb

PROJECT_DIR = Path(__file__).resolve().parents[1]
RAW_DIR = PROJECT_DIR / "data" / "raw" / "Sample ERP Data"
INTERIM_DIR = PROJECT_DIR / "data" / "interim"
DB_PATH = PROJECT_DIR / "data" / "adh.duckdb"

# raw table name -> file pattern. Only *.txt files are loaded (ignores the .zip copies).
SOURCES = {
    "sales": "sales_*.txt",
    "orders": "orders_*.txt",
    "purchases": "purch_*.txt",
    "products": "proddata*.txt",
    "customers": "custdata.txt",
    "inventory": "invendata.txt",
    "branches": "branchdata.txt",
    "buylines": "blinedata.txt",
    "gltypes": "gltypedata.txt",
    "salespeople": "slspdata.txt",
}


def decode_line(raw_bytes: bytes) -> tuple[str, str]:
    """Decode one line: UTF-8 if valid, otherwise latin-1 (which never fails)."""
    try:
        return raw_bytes.decode("utf-8"), "utf-8"
    except UnicodeDecodeError:
        return raw_bytes.decode("latin-1"), "latin-1"


def convert_file(src: Path, dest: Path) -> dict:
    """Write a UTF-8 copy of src with lineage columns added. Returns stats for the summary."""
    stats = {"rows": 0, "latin1_lines": 0}
    with open(src, "rb") as fin, open(dest, "w", encoding="utf-8", newline="\n") as fout:
        header, _ = decode_line(fin.readline().rstrip(b"\r\n"))
        n_cols = len(header.split("\t"))
        fout.write(f"_source_file\t_source_line\t{header}\n")

        for line_no, raw in enumerate(fin, start=2):  # line 1 is the header
            raw = raw.rstrip(b"\r\n")
            if not raw:
                continue  # skip blank lines (e.g. trailing newline)
            text, enc = decode_line(raw)
            if enc == "latin-1":
                stats["latin1_lines"] += 1
            n_fields = len(text.split("\t"))
            if n_fields != n_cols:
                raise ValueError(f"{src.name} line {line_no}: {n_fields} fields, header has {n_cols}")
            fout.write(f"{src.name}\t{line_no}\t{text}\n")
            stats["rows"] += 1
    return stats


def main() -> None:
    INTERIM_DIR.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect(str(DB_PATH))
    con.execute("create schema if not exists raw")
    loaded_at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")

    print(f"{'table':<12} {'files':>5} {'rows':>10} {'latin-1 lines':>14}")
    for table, pattern in SOURCES.items():
        files = sorted(RAW_DIR.glob(pattern))
        if not files:
            raise FileNotFoundError(f"No files match {pattern} in {RAW_DIR}")

        expected_rows, latin1_lines, clean_paths = 0, 0, []
        for src in files:
            dest = INTERIM_DIR / f"{src.stem.replace(' ', '').rstrip('-')}.tsv"
            stats = convert_file(src, dest)
            expected_rows += stats["rows"]
            latin1_lines += stats["latin1_lines"]
            clean_paths.append(str(dest))

        # quote='' / escape='': text fields contain stray " characters, so treat quotes as plain text.
        # union_by_name: purch_2026 has an extra column (Order_Status) that purch_2025 lacks.
        con.execute(
            f"""
            create or replace table raw.{table} as
            select *, timestamp '{loaded_at}' as _loaded_at
            from read_csv(?, delim='\t', header=true, quote='', escape='',
                          all_varchar=true, union_by_name=true)
            """,
            [clean_paths],
        )

        loaded = con.execute(f"select count(*) from raw.{table}").fetchone()[0]
        if loaded != expected_rows:
            raise RuntimeError(f"raw.{table}: loaded {loaded} rows, files contain {expected_rows}")
        print(f"{table:<12} {len(files):>5} {loaded:>10,} {latin1_lines:>14,}")

    con.close()
    print(f"\nLoaded into {DB_PATH.relative_to(PROJECT_DIR)}")


if __name__ == "__main__":
    main()
