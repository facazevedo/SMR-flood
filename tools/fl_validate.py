"""Validate the complete Flood payload before deployment. Python stdlib only."""
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def validate():
    compiler = shutil.which("luac")
    interpreter = shutil.which("lua")
    if not compiler or not interpreter:
        raise RuntimeError("Lua 5.4 lua and luac are required for validation")
    metadata = (ROOT / "metadata.lua").read_text(encoding="utf-8")
    items = (ROOT / "items.lua").read_text(encoding="utf-8")
    code = re.findall(r'"(Code/[^\"]+\.lua)"', metadata)
    item_code = re.findall(r'"(Code/[^\"]+\.lua)"', items)
    actual = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "Code").glob("*.lua"))
    assert code == item_code, "metadata/items load order differs"
    assert sorted(code) == actual and len(set(code)) == len(code), "payload manifest incomplete or duplicated"
    assert code[0] == "Code/fl_config.lua" and code[-1] == "Code/Flood.lua", "invalid initialization order"
    assert all(Path(p).name == "Flood.lua" or Path(p).name.startswith("fl_") for p in code)
    files = [ROOT / "metadata.lua", ROOT / "items.lua"] + [ROOT / p for p in code]
    files += sorted((ROOT / "tests").glob("*.lua"))
    for file in files:
        subprocess.run([compiler, "-p", str(file)], check=True, cwd=ROOT)
    for test in sorted((ROOT / "tests").glob("*_test.lua")):
        subprocess.run([interpreter, str(test)], check=True, cwd=ROOT)
    print(f"PASS: syntax for {len(files)} Lua files; complete explicit load order")
    return files[: len(code) + 2]


if __name__ == "__main__":
    validate()

