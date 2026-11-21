# Writes the install pages of ios-ota from the build.json of every published build, so the pages always match what is on
# disk: one page per app (/<app key>/, its newest build) and one listing every app. Run by `ios-ota publish` after a
# build is added, and by the menu bar app after one is deleted.
#
#     python3 pages.py <builds folder>
#
# build.json (written by `ios-ota publish`, read here and by the menu bar app):
#   id, bundle, title, version, build, time (ISO 8601), commit ("branch @ sha", may be empty), project (folder it was
#   built from, may be empty), size (bytes of App.ipa), manifest (absolute https URL of manifest.plist), icon (file name
#   of the app's icon in the build folder, "icon.png", or empty when the app has none)

import html
import json
import os
import sys
import urllib.parse
from datetime import datetime

STYLE = """<style>
  :root { color-scheme: light dark; --bg: #f2f2f7; --card: #fff; --text: #1c1c1e; --dim: #6e6e73; --accent: #0a84ff; }
  @media (prefers-color-scheme: dark) { :root { --bg: #000; --card: #1c1c1e; --text: #f2f2f7; --dim: #98989d; } }
  body { margin: 0; background: var(--bg); color: var(--text); font: 17px -apple-system, system-ui, sans-serif; }
  main { padding: 40px 16px; display: flex; flex-direction: column; gap: 14px; }
  .card { background: var(--card); border-radius: 18px; padding: 20px; }
  h1 { font-size: 24px; margin: 0 0 6px; }
  h2 { font-size: 19px; margin: 0 0 4px; }
  p { margin: 3px 0; color: var(--dim); font-size: 15px; }
  a.install { display: block; margin-top: 16px; padding: 14px; border-radius: 14px; background: var(--accent);
              color: #fff; font-weight: 600; text-decoration: none; font-size: 18px; text-align: center; }
  a.app { color: inherit; text-decoration: none; display: block; }
  .row { display: flex; gap: 14px; align-items: center; }
  .icon { width: 60px; height: 60px; border-radius: 13.5px; flex: none; }
  .big { width: 96px; height: 96px; border-radius: 21.5px; display: block; margin: 0 auto 12px; }
  .center { text-align: center; }
  a.back { color: var(--accent); text-decoration: none; font-size: 17px; align-self: flex-start; padding: 4px 0; }
</style>"""

HEAD = '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">'


def builds(root):
    """Every app's builds, newest first: {app key (its folder): [build, ...]}."""
    out = {}
    for bundle in sorted(os.listdir(root)):
        folder = os.path.join(root, bundle)
        if not os.path.isdir(folder):
            continue
        found = []
        for bid in os.listdir(folder):
            path = os.path.join(folder, bid, "build.json")
            try:
                with open(path) as f:
                    found.append(json.load(f))
            except (OSError, ValueError):
                continue
        if found:
            out[bundle] = sorted(found, key=lambda b: b.get("time", ""), reverse=True)
    return out


def line(b):
    when = b.get("time", "")
    try:
        when = datetime.fromisoformat(when.replace("Z", "+00:00")).astimezone().strftime("%b %-d, %H:%M")
    except ValueError:
        pass
    text = f"Version {html.escape(b.get('version', '?'))} ({html.escape(str(b.get('build', '?')))}) &middot; {html.escape(when)}"
    commit = f"<p>{html.escape(b['commit'])}</p>" if b.get("commit") else ""
    return f"<p>{text}</p>{commit}"


def icon(b, cls, prefix=""):
    """The <img> of a build's icon, or nothing. `prefix` is the path from the page to the app's folder."""
    if not b.get("icon"):
        return ""
    src = prefix + urllib.parse.quote(b["id"]) + "/" + urllib.parse.quote(b["icon"])
    return f'<img class="{cls}" src="{src}" alt="">'


def size(b):
    """The download size, as the iPhone counts it (decimal units: 6.6 MB)."""
    n = float(b.get("size") or 0)
    for unit in ("bytes", "KB", "MB", "GB"):
        if n < 1000 or unit == "GB":
            return f"{n:.0f} {unit}" if unit in ("bytes", "KB") else f"{n:.1f} {unit}"
        n /= 1000


def write(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, path)          # never a half-written page


def main(root):
    apps = builds(root)
    for bundle, list_ in apps.items():
        b = list_[0]
        title = html.escape(b.get("title", bundle))
        link = "itms-services://?action=download-manifest&amp;url=" + urllib.parse.quote(b["manifest"], safe="")
        write(os.path.join(root, bundle, "index.html"),
              f"{HEAD}<title>Install {title}</title>{STYLE}</head><body><main><a class=\"back\" href=\"../\">\u2039 All Apps</a><div class=\"card center\">{icon(b, 'big')}<h1>{title}</h1>{line(b)}"
              f"<p>Download size: {size(b)}</p>"
              f"<a class=\"install\" href=\"{link}\">Install</a></div>"
              f"<p>After tapping Install, go to the Home Screen to watch it install.</p></main></body></html>")
    # Apps whose builds are all gone lose their page.
    for bundle in os.listdir(root):
        page = os.path.join(root, bundle, "index.html")
        if bundle not in apps and os.path.exists(page):
            os.remove(page)
    newest_first = sorted(apps.items(), key=lambda kv: kv[1][0].get("time", ""), reverse=True)
    cards = "".join(f"<a class=\"app\" href=\"{urllib.parse.quote(bundle)}/\"><div class=\"card row\">"
                    f"{icon(l[0], 'icon', urllib.parse.quote(bundle) + '/')}"
                    f"<div><h2>{html.escape(l[0].get('title', bundle))}</h2>{line(l[0])}</div></div></a>" for bundle, l in newest_first)
    write(os.path.join(root, "index.html"),
          f"{HEAD}<title>Install apps</title>{STYLE}</head><body><main><h1>Apps</h1>{cards or '<p>Nothing published yet.</p>'}</main></body></html>")


if __name__ == "__main__":
    main(sys.argv[1])
