#!/usr/bin/env python3
"""Inject the OSC 52 clipboard shim into ttyd's own index page.

Usage: inject-shim.py <stock-index.html> <shim.js> <output.html>

Called by run.sh with a page it just fetched from a throwaway ttyd instance.
ttyd embeds its frontend in the binary; `--index` is the only supported way to
serve a different one, so the page has to be read out of ttyd first and patched
here rather than being maintained as a static file (which would silently drift
from whatever bundle the installed ttyd actually ships).
"""
import sys


def main(argv):
    if len(argv) != 4:
        sys.exit(__doc__)
    src_path, shim_path, out_path = argv[1:]

    with open(src_path, encoding="utf-8") as fh:
        src = fh.read()
    with open(shim_path, encoding="utf-8") as fh:
        shim = fh.read()

    # Exactly one <head> is the assumption the injection rests on. If a future
    # ttyd ever changes that, fail loudly here — run.sh then falls back to the
    # stock frontend instead of serving a page patched in the wrong place.
    if src.count("<head>") != 1:
        sys.exit("unexpected ttyd index layout: %d <head> tags" % src.count("<head>"))

    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(src.replace("<head>", "<head><script>" + shim + "</script>", 1))


if __name__ == "__main__":
    main(sys.argv)
