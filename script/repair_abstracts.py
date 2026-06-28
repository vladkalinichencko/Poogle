#!/usr/bin/env python3

import argparse
import importlib.util
import json
import sqlite3
from datetime import datetime
from pathlib import Path


def load_worker(path):
    spec = importlib.util.spec_from_file_location("poogle_worker", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def read_empty_abstracts(database):
    return database.execute(
        """
        SELECT d.document_id, MIN(l.path)
        FROM documents d
        JOIN locations l ON l.document_id = d.document_id
        WHERE TRIM(d.abstract) = ''
        GROUP BY d.document_id
        ORDER BY d.document_id
        """
    ).fetchall()


def backup_database(database, path):
    backup = sqlite3.connect(path)
    try:
        database.backup(backup)
    finally:
        backup.close()


def apply_changes(database, changes):
    with database:
        for document_id, abstract in changes:
            database.execute(
                "UPDATE documents SET abstract = ? WHERE document_id = ?",
                (abstract, document_id),
            )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--worker", type=Path, required=True)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--report", type=Path)
    arguments = parser.parse_args()

    worker = load_worker(arguments.worker)
    database = sqlite3.connect(arguments.database)
    documents = read_empty_abstracts(database)
    changes = []
    errors = []

    for document_id, path in documents:
        try:
            abstract = worker.extract_abstract(path)
        except Exception as error:
            errors.append(
                {
                    "document_id": document_id,
                    "path": path,
                    "error": f"{type(error).__name__}: {error}",
                }
            )
            continue
        if abstract:
            changes.append((document_id, abstract))

    report = {
        "empty_documents": len(documents),
        "filled": len(changes),
        "still_empty": len(documents) - len(changes) - len(errors),
        "errors": len(errors),
        "applied": arguments.apply,
        "samples": [
            {"document_id": document_id, "abstract": abstract[:200]}
            for document_id, abstract in changes[:20]
        ],
        "failures": errors,
    }

    if arguments.apply:
        timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        backup_path = arguments.database.with_name(
            f"{arguments.database.name}.before-abstract-repair-{timestamp}"
        )
        backup_database(database, backup_path)
        apply_changes(database, changes)
        report["backup"] = str(backup_path)

    output = json.dumps(report, ensure_ascii=False, indent=2)
    if arguments.report:
        arguments.report.write_text(output + "\n")
    print(output)


if __name__ == "__main__":
    main()
