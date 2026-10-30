#!/usr/bin/env python3
"""Release notes for the Sparkle appcast, from CHANGELOG.md.

Sparkle shows an item's <description> as HTML, so the raw markdown of a CHANGELOG
section reads as one run-on paragraph. This turns a section into styled HTML. It covers
the markdown CHANGELOG.md uses: ### headings, paragraphs, "-" lists nested by two
spaces with wrapped continuation lines, **bold**, _italic_, `code` and [links](url).

  release_notes.py html CHANGELOG VERSION
      Print VERSION's section as HTML (nothing if there is no section).
  release_notes.py appcast CHANGELOG APPCAST [--add VERSION DMG_URL LENGTH ED_SIGNATURE]
      Rewrite every item's description from CHANGELOG.md (an item with no section keeps
      its own). With --add, first insert VERSION's item at the top, replacing an item
      for the same version, so a re-run never adds a second one.

Standard library only: it runs on the release runner as is.
"""
import html
import os
import re
import sys
from email.utils import formatdate
from xml.etree import ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
MIN_SYSTEM = "14.0"

# Sparkle renders the notes in a web view: follow the system font and light/dark mode.
STYLE = """<style>
:root { color-scheme: light dark; }
body { font: 13px -apple-system, BlinkMacSystemFont, sans-serif; line-height: 1.45; margin: 0 2px; }
h3 { font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: .05em;
     opacity: .65; margin: 16px 0 4px; }
h3:first-child { margin-top: 2px; }
p { margin: 6px 0; }
ul { margin: 4px 0; padding-left: 18px; }
li { margin: 4px 0; }
li > ul { margin: 2px 0; }
code { font: 12px ui-monospace, Menlo, monospace; padding: 0 3px; border-radius: 3px;
       background: rgba(127, 127, 127, .16); }
</style>"""


def section(changelog, version):
    """VERSION's section, without its "## [VERSION]" heading and link references."""
    out, grab = [], False
    for line in changelog.splitlines():
        if re.match(r"## \[", line):
            if grab:
                break
            grab = line.startswith(f"## [{version}]")
            continue
        if grab and not re.match(r"\[[^\]]*\]: ", line):
            out.append(line)
    return "\n".join(out).strip()


def inline(text):
    """Escape, then **bold**, _italic_, `code` and [links](url); code spans stay literal."""
    codes = []

    def keep(m):
        codes.append(m.group(1))
        return f"\x00{len(codes) - 1}\x00"

    text = re.sub(r"`([^`]+)`", keep, text)
    text = html.escape(text, quote=False)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<![\w])_(.+?)_(?![\w])", r"<em>\1</em>", text)
    text = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)",
                  lambda m: f'<a href="{html.escape(html.unescape(m.group(2)))}">{m.group(1)}</a>', text)
    return re.sub(r"\x00(\d+)\x00", lambda m: f"<code>{html.escape(codes[int(m.group(1))], quote=False)}</code>", text)


def to_html(markdown):
    """The CHANGELOG subset as HTML: blocks first (headings, lists, paragraphs), then inline."""
    out = []
    para = []            # lines of the open paragraph
    stack = []           # indent (in spaces) of each open <ul>
    item = None          # [lines] of the open <li>, closed when the next block starts

    def flush_item():
        nonlocal item
        if item is not None:
            out.append(inline(" ".join(item)))
            item = None

    def flush_para():
        if para:
            out.append(f"<p>{inline(' '.join(para))}</p>")
            para.clear()

    def close_lists(to_depth=0):
        flush_item()
        while len(stack) > to_depth:
            out.append("</li></ul>")
            stack.pop()

    for raw in markdown.splitlines():
        line = raw.rstrip()
        m = re.match(r"^( *)[-*] (.*)$", line)
        if not line.strip():
            flush_para()
            continue
        if line.startswith("#"):
            flush_para()
            close_lists()
            level = min(max(len(line) - len(line.lstrip("#")), 3), 4)
            out.append(f"<h{level}>{inline(line.lstrip('#').strip())}</h{level}>")
        elif m:
            flush_para()
            indent, text = len(m.group(1)), m.group(2)
            if stack and indent > stack[-1]:
                flush_item()
                out.append("<ul><li>")
                stack.append(indent)
            else:
                while stack and indent < stack[-1]:
                    flush_item()
                    out.append("</li></ul>")
                    stack.pop()
                if stack:
                    flush_item()
                    out.append("</li><li>")
                else:
                    out.append("<ul><li>")
                    stack.append(indent)
            item = [text]
        elif item is not None and raw.startswith(" "):
            item.append(line.strip())   # a wrapped line of the open list item
        else:
            close_lists()
            para.append(line.strip())
    flush_para()
    close_lists()
    body = "\n".join(out)
    return f"{STYLE}\n{body}" if body else ""


def cdata(text):
    return "<![CDATA[" + text.replace("]]>", "]]]]><![CDATA[>") + "]]>"


def write_appcast(changelog, path, add=None):
    ET.register_namespace("sparkle", SPARKLE_NS)
    if os.path.exists(path):
        tree = ET.parse(path)
        rss = tree.getroot()
    else:
        rss = ET.Element("rss", {"version": "2.0"})
        ET.SubElement(rss, "channel")
        tree = ET.ElementTree(rss)
    channel = rss.find("channel")
    if channel is None:
        raise SystemExit("appcast.xml missing <channel>")

    if add:
        version, url, length, signature = add
        item = ET.Element("item")
        ET.SubElement(item, "title").text = f"QuestBits {version}"
        ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = version
        ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = version
        ET.SubElement(item, "pubDate").text = formatdate(localtime=False, usegmt=True)
        ET.SubElement(item, "description").text = f"QuestBits {version}"
        ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = MIN_SYSTEM
        ET.SubElement(item, "enclosure", {
            "url": url,
            "length": length,
            "type": "application/octet-stream",
            f"{{{SPARKLE_NS}}}edSignature": signature,
            f"{{{SPARKLE_NS}}}version": version,
            f"{{{SPARKLE_NS}}}shortVersionString": version,
        })
        for old in channel.findall("item"):
            if old.findtext(f"{{{SPARKLE_NS}}}version") == version:
                channel.remove(old)
        channel.insert(0, item)   # newest first: Sparkle reads top-down

    # Every description from CHANGELOG.md, as CDATA. ElementTree has no CDATA, so each
    # gets a placeholder that is swapped for the CDATA block after serializing.
    descriptions = {}
    for n, item in enumerate(channel.findall("item")):
        desc = item.find("description")
        if desc is None:
            desc = ET.SubElement(item, "description")
        notes = to_html(section(changelog, item.findtext(f"{{{SPARKLE_NS}}}version") or ""))
        descriptions[f"__DESCRIPTION_{n}__"] = notes or (desc.text or "")
        desc.text = f"__DESCRIPTION_{n}__"

    ET.indent(tree, space="    ")
    xml = ET.tostring(rss, encoding="unicode", xml_declaration=True)
    for token, text in descriptions.items():
        xml = xml.replace(token, cdata(text))
    with open(path, "w") as f:
        f.write(xml + "\n")


def main(argv):
    if len(argv) == 4 and argv[1] == "html":
        print(to_html(section(open(argv[2]).read(), argv[3])))
    elif len(argv) in (4, 9) and argv[1] == "appcast" and (len(argv) == 4 or argv[4] == "--add"):
        write_appcast(open(argv[2]).read(), argv[3], add=argv[5:9] if len(argv) == 9 else None)
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
