#!/usr/bin/env python3
"""Consistent online SQLite backup; never copies a live .sqlite3 file directly."""
import argparse
import os
import sqlite3
from pathlib import Path


def backup(source: Path, destination: Path):
    if not source.is_file():
        raise ValueError("Source database does not exist")
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Exclusively create: never replace an existing backup or the source database.
    descriptor = os.open(destination, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(descriptor)
    read = sqlite3.connect(source.resolve().as_uri() + "?mode=ro", uri=True)
    write = sqlite3.connect(destination)
    try:
        read.backup(write, pages=128)
        if write.execute("PRAGMA quick_check").fetchone()[0] != "ok":
            raise RuntimeError("Backup integrity check failed")
    except BaseException:
        write.close()
        read.close()
        destination.unlink(missing_ok=True)  # Only our own exclusively-created incomplete backup.
        raise
    else:
        write.close()
        read.close()
    return destination


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    print(backup(args.source, args.destination))
