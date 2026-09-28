#!/usr/bin/env python3
"""Search a site from the address field (SiteSearch.swift), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/site_search.py`. Uses the
split suite's harness: started hidden, no window made or shown, everything
removed afterwards. The OpenSearch checks reach duckduckgo.com and search.brave.com,
which say where their search is.
"""
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402


def field(text):
    return sv.cmd({"do": "field", "text": text})


def site(action="state", **fields):
    return sv.cmd({"do": "sitesearch", "action": action, **fields})


def main():
    t = sv.T()
    try:
        sv.setup(); sv.launch()
        field("red"); time.sleep(0.3)
        t.ok("off: nothing offered", site()["offer"] == "")
        site("esc"); sv.cmd({"do": "ui", "peeklink": "close"}) if False else None
        sv.quit()
        subprocess.run(["defaults", "write", sv.SUITE, "search.sites", "-bool", "true"])
        sv.launch()
        sv.page("start")
        for typed, want in [("red", "Reddit"), ("yout", "YouTube"), ("yt", "YouTube"), ("wiki", "Wikipedia"),
                            ("gh", "GitHub"), ("chat", "ChatGPT"), ("twi", "X"), ("stack", "Stack Overflow"),
                            ("x", ""), ("red panda", "")]:
            field(typed); time.sleep(0.2)
            got = site()["offer"]
            t.ok(f"typing {typed!r} offers {want or 'nothing'}", got == want, got)
        field("red"); time.sleep(0.2)
        s = site("tab")
        t.ok("Tab: Reddit in the field, the word let go", s["took"] and s["chip"] == "Reddit" and s["typed"] == "", s)
        field("coffee beans"); time.sleep(0.2)
        s = site()
        t.ok("words after the chip: Reddit's search", s["offers"] and s["offers"][0][1] == "https://www.reddit.com/search/?q=coffee%20beans", s["offers"])
        s = site("go")
        t.ok("Return searches Reddit, the chip goes", "reddit.com/search/?q=coffee%20beans" in (s["address"] + s["pending"]) and s["chip"] == "", s)
        field("yout"); time.sleep(0.2); site("tab")
        s = site("delete")
        t.ok("⌫ in the empty field takes the site out", s["chip"] == "" and s["editing"], s)
        field("gh"); time.sleep(0.2); site("tab")
        s = site("esc")
        t.ok("Esc takes the site out, the field stays", s["chip"] == "" and s["editing"], s)
        site("esc")
        # OpenSearch: a site's own description, fetched from that site
        site("forget")
        s = site("learn", page="https://duckduckgo.com/", description="https://example.com/opensearch.xml")
        t.ok("a description on another site is never read", s["learned"] == [], s["learned"])
        s = site("learn", page="https://duckduckgo.com/", description="https://duckduckgo.com/opensearch.xml")
        learned = s["learned"]
        t.ok("a site's own description: it joins the list", learned and learned[0][1] == "duckduckgo.com" and "%s" in learned[0][2], learned)
        field("duckd"); time.sleep(0.2)
        t.ok("…and is offered by its address", site()["offer"] == "duckduckgo.com", site()["offer"])
        site("esc"); site("forget")
        # A learned site is named and matched by its address only, never by
        # the name its description gives itself ("Google", a bank's).
        s = site("adopt", host="lookalike.example", template="https://lookalike.example/?q=%s")
        t.ok("a learned site is named by its address", s["learned"] and s["learned"][0][0] == "lookalike.example", s["learned"])
        for typed in ["goo", "kag", "chase"]:
            field(typed); time.sleep(0.2)
            t.ok(f"typing {typed!r} never offers the learned site", site()["offer"] != "lookalike.example", site()["offer"])
            site("esc")
        field("looka"); time.sleep(0.2)
        t.ok("typing its address offers it, by its address", site()["offer"] == "lookalike.example", site()["offer"])
        site("esc")
        s = site("adopt", host="foo.github.io", template="https://github.io/?q=%s")
        t.ok("a page can't name a public suffix above it (github.io)", not any(l[1] == "foo.github.io" for l in s["learned"]), s["learned"])
        site("forget")
        # visiting its home page in an ordinary tab is enough
        sv.sp("open", url="https://search.brave.com/"); time.sleep(6)
        learned = site()["learned"]
        t.ok("visiting a home page that says where its search is: learned", learned and learned[0][1] == "search.brave.com", learned)
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
