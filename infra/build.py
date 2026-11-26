#!/usr/bin/env python3
"""Package the two Lambda functions into build/loan-read.zip and build/loan-write.zip.

Each zip holds the service's handler.py at the root plus the shared/ package.
Uses only the standard library, so it runs anywhere (CloudShell, Lab IDE, laptop).
"""
import pathlib
import shutil
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
OUT = ROOT / "build"

SERVICES = {"loan-read": "loan_read", "loan-write": "loan_write"}


def add_tree(zf, folder, arcroot):
    for path in sorted(folder.rglob("*")):
        if path.is_file() and "__pycache__" not in path.parts and path.suffix != ".pyc":
            zf.write(path, arcroot / path.relative_to(folder))


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir()
    for name, package in SERVICES.items():
        target = OUT / f"{name}.zip"
        with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as zf:
            zf.write(SRC / package / "handler.py", "handler.py")
            add_tree(zf, SRC / "shared", pathlib.Path("shared"))
        print(f"built {target.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
