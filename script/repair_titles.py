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


def read_documents(database):
    return database.execute(
        """
        SELECT d.document_id, d.title, MIN(l.path)
        FROM documents d
        JOIN locations l ON l.document_id = d.document_id
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
        for document_id, old_title, new_title, _ in changes:
            database.execute(
                "UPDATE documents SET title = ? WHERE document_id = ?",
                (new_title, document_id),
            )
            database.execute(
                """
                UPDATE search_text
                SET heading = ?
                WHERE document_id = ? AND heading = ?
                """,
                (new_title, document_id, old_title),
            )


def proposed_title(worker, document):
    document_id, old_title, path = document
    try:
        return document_id, old_title, worker.extract_title(path), path, None
    except Exception as error:
        return document_id, old_title, None, path, (
            f"{type(error).__name__}: {error}"
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
    documents = read_documents(database)
    changes = []
    errors = []

    for document in documents:
        document_id, old_title, new_title, path, error = proposed_title(
            worker,
            document,
        )
        if error is None:
            if worker.should_repair_title(old_title, new_title):
                changes.append(
                    (document_id, old_title, new_title, path)
                )
            continue
        errors.append(
            {
                "document_id": document_id,
                "path": path,
                "error": error,
            }
        )

    improved_noise = sum(
        worker.title_noise_score(old_title) >= 0.65
        and worker.title_noise_score(new_title) < 0.65
        for _, old_title, new_title, _ in changes
    )
    worsened_noise = sum(
        worker.title_noise_score(old_title) < 0.65
        and worker.title_noise_score(new_title) >= 0.65
        for _, old_title, new_title, _ in changes
    )
    report = {
        "documents": len(documents),
        "changed": len(changes),
        "unchanged": len(documents) - len(changes) - len(errors),
        "errors": len(errors),
        "improved_noise_gate": improved_noise,
        "worsened_noise_gate": worsened_noise,
        "applied": arguments.apply,
        "changes": [
            {
                "document_id": document_id,
                "old_title": old_title,
                "new_title": new_title,
                "path": path,
            }
            for document_id, old_title, new_title, path in changes
        ],
        "failures": errors,
    }

    if arguments.apply:
        timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        backup_path = arguments.database.with_name(
            f"{arguments.database.name}.before-title-repair-{timestamp}"
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
