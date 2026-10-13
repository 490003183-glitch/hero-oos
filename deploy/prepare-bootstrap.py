#!/usr/bin/env python3
"""Prepare one-time bootstrap files at explicit private paths; never print secrets."""
import argparse
import hashlib
import json
import os
import secrets
from pathlib import Path


def prepare(token_file: Path, config_file: Path):
    if token_file.resolve() == config_file.resolve():
        raise ValueError("Token and server config must use different paths")
    if token_file.is_symlink() or config_file.is_symlink():
        raise ValueError("Refusing symlink outputs")
    if config_file.exists():
        raise FileExistsError("Server config already exists; left untouched")
    for directory in (token_file.parent, config_file.parent):
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    if token_file.exists():
        token = token_file.read_text().strip()
        if len(token) < 48:
            raise ValueError("Existing credential is invalid; left untouched")
    else:
        token = secrets.token_urlsafe(48)
        fd = os.open(token_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as target:
            target.write(token)
            target.flush()
            os.fsync(target.fileno())
    os.chmod(token_file, 0o600)
    config = {"database": "/var/lib/hero-oos/state.sqlite3", "port": 4180,
              "bootstrapTokenHash": hashlib.sha256(token.encode()).hexdigest()}
    fd = os.open(config_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as target:
        json.dump(config, target)
    print("Bootstrap credential and server config prepared; secrets not displayed.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--token-file", required=True, type=Path,
                        help="Private local file read by the native owner setup flow")
    parser.add_argument("--config-output", required=True, type=Path,
                        help="New private server config file, outside the source checkout")
    args = parser.parse_args()
    os.umask(0o077)
    prepare(args.token_file.expanduser(), args.config_output.expanduser())
