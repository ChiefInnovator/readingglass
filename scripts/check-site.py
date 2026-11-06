#!/usr/bin/env python3
"""Validate static publication assets, metadata, internal links and JSON-LD."""
import json
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlparse
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1] / "site"
CANONICAL = "https://chiefinnovator.github.io/readingglass/"

class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids, self.links, self.meta, self.schemas = set(), [], {}, []
        self.canonical = None
        self.h1 = self.main = 0
        self.in_schema = False
        self.schema = ""

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if "id" in a:
            assert a["id"] not in self.ids, f"Duplicate id: {a['id']}"
            self.ids.add(a["id"])
        if tag in ("a", "link") and a.get("href"):
            self.links.append(a["href"])
        if tag in ("img", "script") and a.get("src"):
            self.links.append(a["src"])
        if tag == "img":
            assert "alt" in a, "Image lacks alt attribute"
            assert "width" in a and "height" in a, "Image lacks explicit dimensions"
        if tag == "meta":
            self.meta[a.get("name", a.get("property"))] = a.get("content", "")
        if tag == "link" and a.get("rel") == "canonical":
            self.canonical = a["href"]
        if tag == "h1": self.h1 += 1
        if tag == "main": self.main += 1
        if tag == "script" and a.get("type") == "application/ld+json":
            self.in_schema, self.schema = True, ""

    def handle_data(self, data):
        if self.in_schema: self.schema += data

    def handle_endtag(self, tag):
        if tag == "script" and self.in_schema:
            self.schemas.append(json.loads(self.schema))
            self.in_schema = False

page = Page()
page.feed((ROOT / "index.html").read_text())
assert page.h1 == 1 and page.main == 1, "Expected one main and one h1"
assert page.canonical == CANONICAL
for key in ["description", "viewport", "robots", "og:title", "og:image", "og:description", "twitter:card"]:
    assert page.meta.get(key), f"Missing {key}"
assert page.meta["robots"].startswith("index,follow")
for href in page.links:
    parsed = urlparse(href)
    if parsed.scheme or parsed.netloc: continue
    if parsed.path:
        assert (ROOT / parsed.path).exists(), f"Missing local asset: {href}"
    if parsed.fragment:
        assert parsed.fragment in page.ids, f"Missing section: {href}"
graph = page.schemas[0]["@graph"]
assert {item["@type"] for item in graph} >= {"SoftwareApplication", "WebSite", "FAQPage"}
faq = next(item for item in graph if item["@type"] == "FAQPage")
assert len(faq["mainEntity"]) >= 5
assert CANONICAL in (ROOT / "robots.txt").read_text()
urls = ET.parse(ROOT / "sitemap.xml").findall("{*}url/{*}loc")
assert [url.text for url in urls] == [CANONICAL]
for name in ["app-icon.png", "social-card.png", "mark.svg"]:
    assert (ROOT / "assets" / name).is_file(), name
print("Site checks passed: metadata, JSON-LD, sitemap, assets and internal links.")
