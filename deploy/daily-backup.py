#!/usr/bin/env python3
"""Keep seven checked daily backups of only this service's database."""
import datetime
import os
import re
import shutil
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, "/opt/hero-oos")
from backup import backup

os.umask(0o077)
source = Path("/var/lib/hero-oos/state.sqlite3")
directory = Path("/var/lib/hero-oos/backups")
directory.mkdir(mode=0o700, exist_ok=True)
target = directory / ("hero-oos-" + datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d") + ".sqlite3")
if not target.exists():
    with sqlite3.connect(source.resolve().as_uri() + "?mode=ro", uri=True) as connection:
        snapshot_size = connection.execute("PRAGMA page_count").fetchone()[0] * connection.execute("PRAGMA page_size").fetchone()[0]
    required = snapshot_size + 512 * 1024 * 1024
    if shutil.disk_usage(directory).free < required:
        raise SystemExit("Not enough reserved disk space for a consistent backup; no backups were removed")
    backup(source, target)
with sqlite3.connect(target.resolve().as_uri() + "?mode=ro", uri=True) as connection:
    if connection.execute("PRAGMA quick_check").fetchone()[0] != "ok":
        raise SystemExit("Existing backup failed integrity check; no backups were removed")
managed = sorted(path for path in directory.iterdir()
                 if re.fullmatch(r"hero-oos-\d{4}-\d{2}-\d{2}\.sqlite3", path.name)
                 and path.is_file() and not path.is_symlink())
for old in managed[:-7]:
    old.unlink()
print("Verified backup:", target.name, "; retention: seven daily snapshots")
