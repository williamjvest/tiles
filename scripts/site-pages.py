#!/usr/bin/env python3
"""Write Tiles' public pages in site/ (GitHub Pages from the public repository, served at https://tiles.toldwell.com):
the Terms of Use from the app's own text, so the site and the app can't say different things.

    scripts/site-pages.py            # writes site/terms/index.html; the site is deployed when it reaches the public main

The support page (site/index.html), the privacy policy (site/privacy/index.html) and the downloads page are written by
hand. .github/workflows/pages.yml publishes site/ when the public repository's main changes.
"""
import html
import pathlib
import re
import sys

repo = pathlib.Path(__file__).resolve().parent.parent
core = repo / "Packages/CameraKit/Sources/CameraCore"
swift = (core / "TermsOfUse.swift").read_text()
version = re.search(r"static let version = (\d+)", swift).group(1)
dated = re.search(r'static let dated = "([^"]+)"', swift).group(1)
paragraphs = [p.strip() for p in (core / "Resources/TermsOfUse.md").read_text().split("\n\n") if p.strip()]


def render(paragraph: str) -> str:
    text = html.escape(paragraph, quote=False)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"\b([\w.+-]+@[\w-]+\.[\w.]+\w)", r'<a href="mailto:\1">\1</a>', text)
    text = re.sub(r"(?<![\w/@.])(tiles\.toldwell\.com)\b", r'<a href="https://\1">\1</a>', text)
    return f"<p>{text}</p>"


page = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Tiles: Camera Control Terms of Use</title>
<style>body{{font:17px/1.5 -apple-system,system-ui,sans-serif;max-width:40em;margin:3em auto;padding:0 1.2em;color:#222}}h1{{font-size:1.5em}}</style>
</head>
<body>
<h1>Tiles: Camera Control Terms of Use</h1>
<p><small>Version {version}, {dated}. The app shows these terms, and asks you to agree to them, before it connects to a camera.</small></p>
{chr(10).join(render(p) for p in paragraphs)}
<p><small><a href="../">Tiles</a> · <a href="../privacy/">Privacy policy</a></small></p>
</body>
</html>
"""
out = (pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else repo / "site") / "terms" / "index.html"
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(page)
print(f"wrote {out} (version {version}, {len(paragraphs)} sections)")
