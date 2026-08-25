#!/usr/bin/env python3
"""Check what actually reaches the browser through tmux + ttyd.

Usage:  python3 verify-osc52.py <ttyd-port>

Speaks ttyd's websocket protocol directly, so it needs no browser. Requires the
`websockets` package (already present in the add-on image).

Two traps that produced contradictory readings while this was being worked out:

  * A freshly attached tmux client emits ?1049h plus a screen clear of its own.
    Start listening too early and that burst eats the measurement window, which
    reads as "nothing arrived". Hence the settle delay below.

  * Every websocket connection spawns ANOTHER tmux client in the same session.
    With several attached, tmux may hand the OSC 52 to a client this script is
    not listening on. Run `tmux kill-server` between runs.

  * If the previous ttyd did not actually die, the new one fails to bind and you
    silently measure the OLD config on that port — two different configs then
    score identically. Compare runs on separate ports, and confirm both are
    listening (`ss -ltn | grep <port>`) before believing the numbers.
"""
import asyncio
import json
import sys

import websockets

SETTLE = 3.0     # let the attach redraw finish before we start measuring
LISTEN = 4.0

CHECKS = [
    ("alt-screen ?1049h", b"\x1b[?1049h"),
    ("mouse ?1000h",      b"\x1b[?1000h"),
    ("mouse SGR ?1006h",  b"\x1b[?1006h"),
    ("OSC 52 clipboard",  b"\x1b]52;c;dGVzdA==\x07"),
]

# Enable mouse tracking, fire an OSC 52, and enter the alternate screen. Sent as
# one line so a single listening window covers all of it.
CMD = (
    'printf "\\033[?1000h\\033[?1002h\\033[?1006h"; '
    'printf "\\033]52;c;dGVzdA==\\007"; '
    'printf "\\033[?1049h"; sleep 0.4; printf "\\033[?1049l"\n'
)


async def main(port: int) -> int:
    uri = f"ws://127.0.0.1:{port}/ws"
    got = bytearray()
    async with websockets.connect(uri, subprotocols=["tty"], max_size=None) as ws:
        await ws.send(json.dumps({"AuthToken": ""}))
        await ws.send("1" + json.dumps({"columns": 100, "rows": 30}))
        await asyncio.sleep(SETTLE)
        got.clear()
        await ws.send("0" + CMD)
        deadline = asyncio.get_event_loop().time() + LISTEN
        while asyncio.get_event_loop().time() < deadline:
            try:
                msg = await asyncio.wait_for(ws.recv(), timeout=1)
            except asyncio.TimeoutError:
                continue
            if isinstance(msg, str):
                msg = msg.encode()
            if msg[:1] == b"0":          # '0' == OUTPUT frame
                got += msg[1:]

    failed = 0
    for name, seq in CHECKS:
        ok = seq in got
        failed += not ok
        print(f"   {name:20s} = {ok}")
    if failed:
        print(f"\n{failed} check(s) failed — see the two traps in this file's docstring "
              f"before concluding the config is wrong.")
    return 1 if failed else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    sys.exit(asyncio.run(main(int(sys.argv[1]))))
