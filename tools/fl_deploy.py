"""Validated, non-destructive deployment to the local Flood mod directory."""
from pathlib import Path
import hashlib
import os
import re
import shutil
from fl_validate import ROOT, validate


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    payload = validate()
    appdata = Path(os.environ["APPDATA"])
    base = appdata / "Surviving Mars Relaunched" / "Mods"
    if not base.is_dir():
        raise RuntimeError(f"Game mod directory missing: {base}")
    destination = base / "flood"
    if destination.is_symlink() or destination.is_junction():
        raise RuntimeError("Refusing redirected deployment directory")
    if destination.exists():
        meta = destination / "metadata.lua"
        if not meta.is_file() or not re.search(r"'id',\s*\"Flood\"", meta.read_text(encoding="utf-8")):
            raise RuntimeError("Existing destination is not an identified Flood payload")
        expected = {p.relative_to(ROOT) for p in payload}
        extras = [str(p) for p in destination.rglob("*") if p.is_file() and p.relative_to(destination) not in expected]
        if extras:
            raise RuntimeError(f"Unrecognized destination files; nothing copied: {extras}")
    for source in payload:
        target = destination / source.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.is_symlink() or target.parent.is_symlink() or target.parent.is_junction():
            raise RuntimeError(f"Refusing redirected payload path: {target}")
        shutil.copy2(source, target)
        assert sha(source) == sha(target), f"Deployment verification failed: {target}"
    print(f"DEPLOYED: {len(payload)} hash-verified files to {destination}; no files deleted")


if __name__ == "__main__":
    main()

