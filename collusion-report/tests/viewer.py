"""Integration checks: python3 tests/viewer.py /absolute/path/to/site"""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1]).resolve())
project = Path(__file__).resolve().parents[1]


def fragment(pack, identifier, group, timestamp, body, title="Untitled"):
    metadata = dict(id=identifier, group=group, timestamp=timestamp,
                    title=title, author=None, source_url=None)
    (pack / "texts" / (identifier + ".md")).write_text(
        "---\n" + "".join(f"{k}: {json.dumps(v)}\n" for k, v in metadata.items())
        + "---\n" + body, encoding="utf-8")


with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    shutil.copytree(project / "templates", root / "templates")
    shutil.copy(project / "index.html", root / "index.html")
    packs = [root / "first pack", root / "second pack"]
    for pack in packs:
        (pack / "texts").mkdir(parents=True)
    fragment(packs[0], "late", "a/b", "2026-01-01T01:00:00Z", "late")
    fragment(packs[0], "early", "a/b", "2026-01-01T02:00:00+02:00", "early")
    fragment(packs[0], "unknown", "a/b", None,
             '<script>alert(1)</script>\n<img src="https://example.invalid/image">\n$body$ & text',
             '<b>Title</b>')
    fragment(packs[0], "separate", "a_2f_b", None, "separate group")
    fragment(packs[0], "parent", "a", None, "parent group")
    fragment(packs[0], "traversal", "../escape", None, "safe path")
    fragment(packs[1], "new", "New group", None, "second pack")
    result = subprocess.run([binary, str(packs[0]), "+RTS", "-N2", "-RTS"],
                            cwd=root, capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    index = (root / "_site/index.html").read_text()
    assert "FAQ" in index and "What is this?" in index
    assert 'rel="stylesheet"' not in index
    assert 'groups/a/index.html' in index and 'groups/a/b/' not in index
    directory = (root / "_site/groups/a/index.html").read_text()
    assert 'b/fragments.html' in directory and '<article' not in directory
    group = (root / "_site/groups/a/b/fragments.html").read_text()
    assert group.index('fragments/early.html') < group.index('fragments/late.html')
    assert group.index('fragments/late.html') < group.index('fragments/unknown.html')
    assert '<article' not in group and '<pre' not in group
    page = (root / "_site/fragments/unknown.html").read_text()
    assert "&lt;script&gt;" in page and "<script>" not in page
    assert "&lt;img" in page and "<img" not in page
    assert "&lt;b&gt;Title&lt;/b&gt;" in page and "$body$ &amp; text" in page
    assert "Undated" in page and "Unknown" in page
    assert 'groups/a/b/fragments.html' in page
    assert (root / "_site/groups/a_5f_2f_5f_b/fragments.html").exists()
    assert (root / "_site/groups/a/fragments.html").exists()
    assert 'Fragments in this group' in directory
    assert (root / "_site/groups/_2e__2e_/escape/fragments.html").exists()
    result = subprocess.run([binary, str(packs[1]), "+RTS", "-N2", "-RTS"],
                            cwd=root, capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    assert not (root / "_site/groups/a/b/fragments.html").exists()
    assert "New group" in (root / "_site/index.html").read_text()
    result = subprocess.run([binary, str(root / "missing")], cwd=root,
                            capture_output=True, text=True)
    assert result.returncode != 0 and "No texts directory" in result.stderr
print("Viewer integration checks passed.")
