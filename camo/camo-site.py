#!/usr/bin/env python3
"""camo-site —— 为代理节点生成一个「单人小站」形态的伪装站点。

一个站只用一个源，题材与来源一致。产物为纯静态目录：
首页（列表）+ 8..12 篇详情 + about + archive + 404 + robots.txt（全站 noindex）。
无 JS、无外部字体、无图片、CSS 内联；页面之间只用相对链接，
因此既能挂在站点根目录，也能挂在子目录下预览。

用法：
    ./camo-site.py --source eso --node tw --output /var/www/camo
    ./camo-site.py --source eso --style 3 --output /tmp/x    # 指定版式调试
"""
import argparse
import hashlib
import html
import os
import re
import sys
import urllib.request
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime

# W3C 的 WAF 会对带 "KHTML, like Gecko" 的完整 Chrome UA 直接 403，
# 精简版 UA 四个源都放行，因此统一用它。
UA = "Mozilla/5.0 (Macintosh) AppleWebKit/537.36 Chrome/131 Safari/537.36"

# ---------------------------------------------------------------- 内容源

SOURCES = {
    "eso": {
        "feed": "https://www.eso.org/public/news/feed/",
        "who": "European Southern Observatory",
        "licence": "CC BY 4.0",
        "body_max": 900,
        "names": ["Southern Sky Notes", "The Observatory Log", "Deep Field Journal"],
        "blurb": "Notes on telescopes, instruments and what they find.",
        "tags": ["observing", "instruments", "imaging", "spectroscopy"],
        "styles": [0, 2, 4, 6],
    },
    "wikimedia": {
        "feed": "https://wikimediafoundation.org/news/feed/",
        "who": "Wikimedia Foundation",
        "licence": "CC BY-SA 4.0",
        "body_max": 1400,
        "names": ["Open Knowledge Notes", "The Commons Journal", "Free Culture Log"],
        "blurb": "Writing about open knowledge, archives and the commons.",
        "tags": ["open data", "archives", "community", "licensing"],
        "styles": [1, 3, 5, 7],
    },
    "w3c": {
        "feed": "https://www.w3.org/blog/feed/",
        "who": "W3C",
        "licence": "quotation, (c) the authors",
        "body_max": 450,
        "names": ["Standards Notebook", "The Web Spec Log", "Markup Notes"],
        "blurb": "Short notes on web standards, specs and implementation.",
        "tags": ["specs", "accessibility", "html", "browsers"],
        "styles": [0, 3, 4, 7],
    },
    "bhl": {
        "feed": "https://blog.biodiversitylibrary.org/feed/",
        "who": "Biodiversity Heritage Library",
        "licence": "quotation, (c) the authors",
        "body_max": 450,
        "names": ["Field & Archive", "Natural History Notes", "Herbarium Log"],
        "blurb": "Pictures and paragraphs from old natural history collections.",
        "tags": ["botany", "expeditions", "illustration", "archives"],
        "styles": [1, 2, 5, 6],
    },
}

# ---------------------------------------------------------------- 版式
#
# 8 套版式：4 套列表型 + 4 套卡片型。同类之间靠四样东西拉开差距：
# 字体族（衬线 / 无衬线 / 等宽）、基础字号（16–19px）、配色（含一套深色）、
# 栏宽（36–56rem）与分隔线/圆角。每套都是一个「成型的风格」而不是随机拼装。

STYLES = [
    # 0 杂志·暖纸 · 衬线大标题 · 细线 · 42rem
    dict(layout="mag", bg="#fbf8f3", fg="#241f1a", muted="#7a6f63", line="#e6ddd0",
         accent="#9c4a1a", serif="Charter,Georgia,serif", sans="system-ui,sans-serif",
         mono="ui-monospace,Menlo,monospace", size="18px", width="42rem", radius="0px",
         head="serif", rule="1px", caps=False, dark=False,
         extra=""),
    # 1 列表·冷白 · 无衬线 · 无分隔线 · 36rem · 小型大写品牌
    dict(layout="list", bg="#ffffff", fg="#14181c", muted="#68727c", line="#eef1f4",
         accent="#1f6feb", serif="Georgia,serif", sans="system-ui,-apple-system,sans-serif",
         mono="ui-monospace,Menlo,monospace", size="16px", width="40rem", radius="0px",
         head="sans", rule="0px", caps=True, dark=False),
    # 2 杂志·灰绿 · 衬线 · 3px 粗顶线 · 50rem
    dict(layout="mag", bg="#f4f6f4", fg="#1b2420", muted="#5f6b64", line="#d9e0da",
         accent="#0f6b4f", serif="Iowan Old Style,Palatino,Georgia,serif",
         sans="system-ui,sans-serif", mono="ui-monospace,Menlo,monospace",
         size="17px", width="50rem", radius="0px", head="serif", rule="3px", caps=True, dark=False),
    # 3 列表·米色 · 等宽元信息 · 44rem
    dict(layout="list", bg="#fdfbf6", fg="#232323", muted="#7b7264", line="#e8e0d2",
         accent="#8a5a00", serif="Georgia,serif", sans="system-ui,sans-serif",
         mono="ui-monospace,SFMono-Regular,Menlo,monospace",
         size="17px", width="44rem", radius="0px", head="sans", rule="1px", caps=False, dark=False),
    # 4 卡片·暖灰 · 白卡 · 大圆角 · 54rem
    dict(layout="cards", bg="#f3f1ee", fg="#1e1c1a", muted="#6b655e", line="#e0dbd4",
         accent="#b4432c", serif="Georgia,serif", sans="system-ui,sans-serif",
         mono="ui-monospace,Menlo,monospace", size="17px", width="54rem", radius="10px",
         head="sans", rule="0px", caps=False, dark=False),
    # 5 卡片·深色 · 等宽标题 · 描边卡 · 52rem
    dict(layout="cards", bg="#15171a", fg="#e8e6e3", muted="#949a9f", line="#2b2f34",
         accent="#6ea8fe", serif="Georgia,serif",
         sans="ui-monospace,SFMono-Regular,Menlo,monospace",
         mono="ui-monospace,SFMono-Regular,Menlo,monospace",
         size="16px", width="52rem", radius="2px", head="mono", rule="0px", caps=True, dark=True),
    # 6 卡片·浅蓝灰 · 衬线标题 · 方角 · 56rem
    dict(layout="cards", bg="#f7f9fb", fg="#182028", muted="#5d6a75", line="#dde5ec",
         accent="#2b6c8f", serif="Palatino,Georgia,serif", sans="system-ui,sans-serif",
         mono="ui-monospace,Menlo,monospace", size="17px", width="56rem", radius="0px",
         head="serif", rule="0px", caps=False, dark=False),
    # 7 列表·深色 · 衬线 · 19px 大字号 · 48rem
    dict(layout="list", bg="#101211", fg="#eae7e2", muted="#9aa19c", line="#272b29",
         accent="#c8a24a", serif="Iowan Old Style,Georgia,serif", sans="system-ui,sans-serif",
         mono="ui-monospace,Menlo,monospace", size="19px", width="48rem", radius="0px",
         head="serif", rule="1px", caps=False, dark=True),
]

BASE_CSS = """
*,*::before,*::after{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--fg);font:var(--size)/1.72 var(--serif)}
.wrap{max-width:var(--width);margin:0 auto;padding:3.2rem 2rem 5rem}
@media (max-width:48rem){.wrap{padding:2rem 1.4rem 3.5rem}}
@media (max-width:30rem){.wrap{padding:1.5rem 1.1rem 3rem}}
a{color:inherit;text-decoration:none}
a:hover{color:var(--accent)}
header{border-bottom:var(--rule) solid var(--line);padding-bottom:1.2rem;margin-bottom:2.6rem;
  display:flex;flex-wrap:wrap;gap:.55rem 1.6rem;align-items:baseline;justify-content:space-between}
.brand{font:600 1.15rem/1.3 var(--sans);letter-spacing:.01em}
.caps .brand{text-transform:uppercase;letter-spacing:.15em;font-size:.95rem}
nav{font:500 .86rem/1.4 var(--sans);color:var(--muted)}
nav a{margin-left:1.3rem}
nav a:first-child{margin-left:0}
nav a[aria-current]{color:var(--fg);box-shadow:inset 0 -2px 0 var(--accent)}
h1{font:700 clamp(1.65rem,3vw,2.4rem)/1.22 var(--headfont);margin:0 0 .7rem;letter-spacing:-.012em}
.mag h1{font-size:clamp(1.8rem,3.6vw,2.7rem)}
h2{font:600 1.12rem/1.4 var(--sans);margin:2.4rem 0 .45rem}
.meta{font:400 .78rem/1.45 var(--mono);color:var(--muted);letter-spacing:.02em}
.lede{font-size:1.08rem;color:var(--muted);margin:0 0 2.6rem;max-width:38rem}
ul.posts,ul.cards{list-style:none;margin:0;padding:0}
ul.posts li{border-top:1px solid var(--line);padding:1.2rem 0;min-width:0}
ul.posts li:first-child{border-top:0;padding-top:0}
ul.posts li>a{font:600 1.08rem/1.5 var(--sans);display:block;margin:.22rem 0 .4rem}
.mag ul.posts li>a{font:700 1.18rem/1.45 var(--headfont)}
ul.posts li>p{font-size:.92rem;line-height:1.62;color:var(--muted);margin:0;max-width:52rem}
p{margin:0 0 1.2rem;overflow-wrap:anywhere}
li,article{min-width:0}
article{max-width:42rem}
article p:first-of-type{font-size:1.05rem}
.tag{font:400 .72rem/1 var(--mono);color:var(--muted);border:1px solid var(--line);
  border-radius:var(--radius);padding:.2rem .42rem;margin-right:.35rem;display:inline-block}
footer{margin-top:4.2rem;padding-top:1.3rem;border-top:1px solid var(--line);
  font:400 .82rem/1.65 var(--sans);color:var(--muted)}
footer p{max-width:48rem}
/* 杂志式：日期右对齐 */
.mag ul.posts li{display:grid;grid-template-columns:1fr auto;column-gap:1.6rem}
.mag ul.posts li>.meta:first-child{grid-column:2;grid-row:1;text-align:right;white-space:nowrap}
.mag ul.posts li>a{grid-column:1;grid-row:1}
.mag ul.posts li>p{grid-column:1/-1;margin-top:.3rem}
/* 卡片式 */
ul.cards{display:grid;gap:1.2rem;grid-template-columns:repeat(auto-fill,minmax(18rem,1fr))}
@media (max-width:30rem){ul.cards{grid-template-columns:1fr}}
ul.cards li{border:1px solid var(--line);border-radius:var(--radius);padding:1.2rem 1.25rem;
  min-width:0;transition:border-color .15s}
ul.cards li:hover{border-color:var(--accent)}
ul.cards li>a{font:600 1.05rem/1.45 var(--headfont);display:block;margin:.32rem 0 .5rem}
ul.cards li>p{font-size:.9rem;line-height:1.6;color:var(--muted);margin:0}
.dark ul.cards li{background:#1c1f23}
/* 404 */
.nf h1{font-size:clamp(2rem,5vw,3.2rem);margin-bottom:1rem}
.nf h2{margin-top:2.8rem}
"""


# 每套版式额外的一条差异化规则（让同类之间也一眼能分开）
STYLE_EXTRA = {
    0: "",
    1: "h1{font-size:clamp(1.45rem,2.4vw,1.75rem);font-weight:600}"
       ".brand{color:var(--accent)}"
       "ul.posts li{border-top:0;border-bottom:1px solid var(--line);padding:1rem 0}",
    2: "h1{letter-spacing:-.02em}nav{text-transform:uppercase;letter-spacing:.12em;font-size:.76rem}",
    3: "h1{font-family:var(--serif);font-weight:700;letter-spacing:-.004em}"
       ".meta{text-transform:uppercase;letter-spacing:.09em;font-size:.72rem}",
    4: "ul.cards li{background:#fff}",
    5: "h1,h2{letter-spacing:.06em}ul.cards li{border-color:#333a41}",
    6: "ul.cards li{border:0;box-shadow:0 1px 2px rgba(20,40,60,.06),0 10px 26px rgba(20,40,60,.05)}"
       "ul.cards{grid-template-columns:repeat(auto-fill,minmax(23rem,1fr))}",
    7: "h1{font-size:clamp(1.85rem,3.4vw,2.6rem)}",
}


def h(s):
    return html.escape(s, quote=True)


def strip_html(s):
    s = re.sub(r"(?is)<(script|style).*?</\1>", " ", s or "")
    s = re.sub(r"(?i)<br\s*/?>|</p>", "\n\n", s)
    s = re.sub(r"(?s)<[^>]+>", " ", s)
    return html.unescape(s)


def paragraphs(raw, limit):
    text = strip_html(raw)
    parts = [re.sub(r"[ \t]+", " ", p).strip() for p in re.split(r"\n\s*\n", text)]
    parts = [re.sub(r"\s+", " ", p) for p in parts if len(p) > 40]
    out, used, seen = [], 0, set()
    for p in parts:
        if p in seen:
            continue
        seen.add(p)
        if used and used + len(p) > limit:
            break
        out.append(p)
        used += len(p)
    return out


def fetch(url):
    req = urllib.request.Request(url, headers={
        "User-Agent": UA,
        "Accept": "application/rss+xml,application/atom+xml,application/xml;q=0.9,*/*;q=0.8",
    })
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode("utf-8", "replace")


def parse_feed(body):
    items = re.findall(r"<item[ >].*?</item>", body, re.S) or re.findall(r"<entry[ >].*?</entry>", body, re.S)

    def field(it, *tags):
        for t in tags:
            m = re.search(rf"<{t}[^>]*>(.*?)</{t}>", it, re.S)
            if m:
                return m.group(1)
        return ""

    out = []
    for it in items:
        title = re.sub(r"\s+", " ", strip_html(field(it, "title"))).strip()
        link = strip_html(field(it, "link", "id")).strip()
        m = re.search(r'<link[^>]*href="([^"]+)"', it)
        if m:
            link = html.unescape(m.group(1))
        raw = field(it, "content:encoded", "content", "description", "summary")
        dt = None
        for key in ("pubDate", "published", "updated", "dc:date"):
            val = field(it, key).strip()
            if not val:
                continue
            try:
                dt = parsedate_to_datetime(val)
                break
            except Exception:
                try:
                    dt = datetime.fromisoformat(val.replace("Z", "+00:00"))
                    break
                except Exception:
                    continue
        if not title or not link or dt is None:
            continue
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        out.append({"title": title, "link": link, "date": dt, "raw": raw})
    return out


def slugify(title, i):
    s = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")[:60]
    return f"{i:02d}-{s or 'post'}"


def page(shell, title, body, nav_html, is_404=False):
    cls = "wrap"
    if shell["layout"] != "list":
        cls += " " + shell["layout"]
    if shell["caps"]:
        cls += " caps"
    if shell["dark"]:
        cls += " dark"
    if is_404:
        cls += " nf"
    return f"""<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>{h(title)}</title>
<style>{shell['css']}</style>
<div class="{cls}">
<header>
<a class="brand" href="index.html">{h(shell['name'])}</a>
<nav>{nav_html}</nav>
</header>
{body}
<footer>
<p>{h(shell['blurb'])}</p>
<p>© {datetime.now(timezone.utc).year} {h(shell['name'])}. Excerpts and quotations remain the property of
their authors; a source link is given on every page.
<a href="https://{h(shell['host'])}">{h(shell['who'])}</a> — {h(shell['licence'])}.</p>
</footer>
</div>
</html>"""


def build(source_key, node, outdir, style_override=None):
    cfg = SOURCES[source_key]
    seed = hashlib.sha1(f"{source_key}:{node}".encode()).hexdigest()
    rnd = int(seed[:8], 16)

    st_idx = style_override if style_override is not None else \
        cfg["styles"][(rnd >> 4) % len(cfg["styles"])]
    st = STYLES[st_idx]

    feed = parse_feed(fetch(cfg["feed"]))
    cutoff = datetime.now(timezone.utc) - timedelta(days=200)
    posts = []
    for it in feed:
        if it["date"] < cutoff:
            continue
        body = paragraphs(it["raw"], cfg["body_max"])
        if sum(len(p) for p in body) < 300:
            continue
        posts.append(dict(it, paras=body))
    posts.sort(key=lambda p: p["date"], reverse=True)
    if len(posts) < 6:
        sys.exit(f"源 {source_key} 合格的只有 {len(posts)} 篇（要求 ≥6）")
    posts = posts[:12]

    name = cfg["names"][rnd % len(cfg["names"])]
    headfont = {"serif": st["serif"], "sans": st["sans"], "mono": st["mono"]}[st["head"]]
    subs = {
        "--bg": st["bg"], "--fg": st["fg"], "--muted": st["muted"], "--line": st["line"],
        "--accent": st["accent"], "--serif": st["serif"], "--sans": st["sans"],
        "--mono": st["mono"], "--headfont": headfont, "--radius": st["radius"],
        "--width": st["width"], "--size": st["size"], "--rule": st["rule"],
    }
    extra = STYLE_EXTRA.get(st_idx, "")
    css = re.sub(r"var\((--[\w-]+)\)", lambda m: subs.get(m.group(1), m.group(0)),
                 BASE_CSS + "\n" + extra)

    shell = dict(name=name, blurb=cfg["blurb"], who=cfg["who"], licence=cfg["licence"],
                 css=css, layout=st["layout"], caps=st["caps"], dark=st["dark"],
                 host=re.sub(r"^https?://([^/]+).*", r"\1", cfg["feed"]))

    def nav(cur):
        return "".join(f'<a href="{href}"{" aria-current=page" if n == cur else ""}>{n}</a>'
                       for n, href in (("Home", "index.html"), ("Archive", "archive.html"),
                                       ("About", "about.html")))

    os.makedirs(outdir, exist_ok=True)
    written = 0

    for i, p in enumerate(posts, 1):
        p["slug"] = slugify(p["title"], i)
        tags = "".join(f'<span class="tag">{h(t)}</span>' for t in
                       (cfg["tags"][i % len(cfg["tags"])], cfg["tags"][(i + 1) % len(cfg["tags"])]))
        body_html = "".join(f"<p>{h(x)}</p>" for x in p["paras"])
        inner = f"""<article>
<p class="meta">{p['date'].strftime('%Y-%m-%d')} · {tags}</p>
<h1>{h(p['title'])}</h1>
{body_html}
<p class="meta">Source: <a href="{h(p['link'])}">{h(shell['host'])}</a> — excerpt kept short,
full text at the original publisher.</p>
</article>"""
        with open(os.path.join(outdir, p["slug"] + ".html"), "w") as f:
            f.write(page(shell, p["title"], inner, nav("")))
        written += 1

    def excerpt(p, n=190):
        t = p["paras"][0] if p["paras"] else ""
        cut = t[:n]
        if len(t) > n:
            cut = cut.rsplit(" ", 1)[0] + "…"
        return cut

    if st["layout"] == "cards":
        items = "".join(
            f'<li><span class="meta">{p["date"].strftime("%Y-%m-%d")}</span>'
            f'<a href="{p["slug"]}.html">{h(p["title"])}</a><p>{h(excerpt(p, 140))}</p></li>'
            for p in posts)
        list_html = f'<ul class="cards">{items}</ul>'
    else:
        items = "".join(
            f'<li><span class="meta">{p["date"].strftime("%Y-%m-%d")}</span>'
            f'<a href="{p["slug"]}.html">{h(p["title"])}</a>'
            f'<p>{h(excerpt(p))}</p></li>' for p in posts)
        list_html = f'<ul class="posts">{items}</ul>'

    index = f'<h1>{h(shell["name"])}</h1>\n<p class="lede">{h(cfg["blurb"])}</p>\n{list_html}'
    with open(os.path.join(outdir, "index.html"), "w") as f:
        f.write(page(shell, shell["name"], index, nav("Home")))
    written += 1

    arch = "".join(f'<li><span class="meta">{p["date"].strftime("%Y-%m-%d")}</span>'
                   f'<a href="{p["slug"]}.html">{h(p["title"])}</a></li>' for p in posts)
    with open(os.path.join(outdir, "archive.html"), "w") as f:
        f.write(page(shell, "Archive", f'<h1>Archive</h1><ul class="posts">{arch}</ul>', nav("Archive")))
    written += 1

    about = f"""<h1>About</h1>
<p>This is a small reading log. It collects short excerpts from {h(cfg['who'])} material published
between {posts[-1]['date'].year} and {posts[0]['date'].year}, with a link back to the original
release on every page.</p>
<p>Nothing here is original reporting: quotations are kept to a few paragraphs, credited, and linked.
Where something is out of date, the original publisher is the better source.</p>
<h2>Contact</h2>
<p>Corrections and takedown requests go to the address published on
<a href="https://{h(shell['host'])}">{h(shell['host'])}</a>.</p>"""
    with open(os.path.join(outdir, "about.html"), "w") as f:
        f.write(page(shell, "About", about, nav("About")))
    written += 1

    recent = "".join(f'<li><span class="meta">{p["date"].strftime("%Y-%m-%d")}</span>'
                     f'<a href="{p["slug"]}.html">{h(p["title"])}</a></li>' for p in posts[:3])
    nf = (f'<h1>Page not found</h1>\n<p class="lede">The address you asked for is not on this site — '
          f'it may have been moved, or the link may be wrong.</p>\n'
          f'<p><a href="index.html">Back to the index</a></p>\n'
          f'<h2>Recent posts</h2><ul class="posts">{recent}</ul>')
    with open(os.path.join(outdir, "404.html"), "w") as f:
        f.write(page(shell, "Page not found", nf, nav(""), is_404=True))

    with open(os.path.join(outdir, "robots.txt"), "w") as f:
        f.write("User-agent: *\nDisallow: /\n")

    return dict(source=source_key, node=node, site=name, style=st_idx, layout=st["layout"],
                pages=written, posts=len(posts), newest=posts[0]["date"].strftime("%Y-%m-%d"),
                oldest=posts[-1]["date"].strftime("%Y-%m-%d"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", required=True, choices=sorted(SOURCES))
    ap.add_argument("--node", default="local", help="随机种子（一般用主机简称）")
    ap.add_argument("--output", required=True)
    ap.add_argument("--style", type=int, default=None, choices=range(len(STYLES)),
                    help="强制指定版式（调试用，0-7）")
    a = ap.parse_args()
    info = build(a.source, a.node, a.output, a.style)
    for k, v in info.items():
        print(f"{k}: {v}")


if __name__ == "__main__":
    main()
