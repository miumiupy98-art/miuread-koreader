"""Verify the generated #135 fixture as a readable EPUB navigation document.

Checks both EPUB 3 nav.xhtml and EPUB 2 toc.ncx, with actual targets and
fragment IDs. This requires only Python stdlib; no Kindle/device is simulated.
"""
import argparse
import xml.etree.ElementTree as ET
from pathlib import PurePosixPath
from zipfile import ZipFile

NS = {
    "x": "http://www.w3.org/1999/xhtml",
    "n": "http://www.daisy.org/z3986/2005/ncx/",
    "o": "http://www.idpf.org/2007/opf",
}


def validate(path):
    with ZipFile(path) as z:
        assert z.testzip() is None, "corrupt ZIP entry"
        assert z.read("mimetype") == b"application/epub+zip"
        nav = ET.fromstring(z.read("OEBPS/nav.xhtml"))
        ncx = ET.fromstring(z.read("OEBPS/toc.ncx"))
        opf = ET.fromstring(z.read("OEBPS/package.opf"))
        nav_list = nav.find(".//x:nav/x:ol", NS)
        assert nav_list is not None, "EPUB 3 TOC is absent"
        links = nav_list.findall(".//x:a", NS)
        nodes = ncx.findall(".//n:navPoint", NS)
        assert len(links) == len(nodes) == 4, "expected heading/chapter/anchor nodes"
        assert [node.get("playOrder") for node in nodes] == ["1", "2", "3", "4"]
        assert len({node.get("id") for node in nodes}) == 4
        assert [link.text for link in links] == ["第一篇", "第一章", "第一节", "第二章"]
        ncx_hrefs = [node.find("n:content", NS).get("src") for node in nodes]
        assert ncx_hrefs == [link.get("href") for link in links], "nav.xhtml and NCX disagree"
        for link in links:
            href = link.get("href")
            relative, _, fragment = href.partition("#")
            assert relative.startswith("text/chapter-") and ".." not in PurePosixPath(relative).parts
            chapter_path = "OEBPS/" + relative
            assert chapter_path in z.namelist(), f"missing navigation target: {relative}"
            root = ET.fromstring(z.read(chapter_path))
            if fragment:
                assert any(el.get("id") == fragment or el.get("name") == fragment
                           for el in root.iter()), f"missing XHTML fragment: {fragment}"
        spine = opf.find("o:spine", NS)
        assert spine is not None and len(spine) == 2, "reading spine mutated"
        assert len(nav_list.findall("x:li", NS)) == 1, "volume hierarchy not nested"
        assert len(nav_list.findall("x:li/x:ol/x:li", NS)) == 2, "chapter hierarchy not nested"
        assert len(nav_list.findall("x:li/x:ol/x:li/x:ol/x:li", NS)) == 1, "section missing"
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("epub")
    args = parser.parse_args()
    validate(args.epub)
    print("Issue #135 EPUB nav/NCX/XML/spine/anchor verification passed")


if __name__ == "__main__":
    main()
