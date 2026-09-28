#!/usr/bin/env python3
"""LiveRate's speed patch (LiveRate.swift), on a stand-in for a video.

`python3 Tests/live_rate.py`. The script is taken from the source and run in
JavaScriptCore (osascript) over an element whose playbackRate works like
WebKit's: it throws on what WebKit refuses and remembers what it was given.
Nothing is started and no page is opened.

What it can't show is the pause itself. That was measured on a hidden probe
playing an MSE video with sound, speed set as X's player sets it (1, then
1.04 a quarter second later, every 4 s): eleven stalls of the picture in 26
seconds on 1.0.5 RC 2, none with this patch.
"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "Sources/Search/LiveRate.swift").read_text()
script = source.split('static let script = """', 1)[1].split('"""', 1)[0]

CHECKS = r"""
var out = [], v = new HTMLMediaElement();
function t(name, ok) { out.push((ok ? 'ok   ' : 'FAIL ') + name); }
v.playbackRate = 1;
t('a 1 before any nudge is played as 1', v.real === 1 && v.playbackRate === 1);
v.playbackRate = 1.04;
t('a catch-up speed is played as asked', v.real === 1.04 && v.playbackRate === 1.04);
v.playbackRate = 1;
t('a 1 after a nudge is played off 1, and read back as 1', v.real === 1.0001 && v.playbackRate === 1);
v.real = 1.5;
t('changed some other way: the speed it has now is read', v.playbackRate === 1.5);
v.playbackRate = 2;
t('a chosen speed is played as asked', v.real === 2 && v.playbackRate === 2);
var threw = false;
try { v.playbackRate = NaN; } catch (e) { threw = e instanceof TypeError; }
t('what WebKit refuses still throws, and nothing is kept', threw && v.real === 2 && v.playbackRate === 2);
var w = new HTMLMediaElement();
w.playbackRate = 1.5; w.playbackRate = 1;
t('a menu speed never starts it', w.real === 1 && w.playbackRate === 1);
var d = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'playbackRate');
t('the property keeps its shape', d.get.name === 'get playbackRate' && d.set.name === 'set playbackRate'
  && d.enumerable && d.configurable);
var wrong = false;
try { d.get.call({}); } catch (e) { wrong = true; }
t('only on a media element, as before', wrong);
out.join('\n');
"""

STAND_IN = r"""
var HTMLMediaElement = function () { this.real = 1; };
Object.defineProperty(HTMLMediaElement.prototype, 'playbackRate', {
  get: function () {
    if (!(this instanceof HTMLMediaElement)) throw new TypeError('not a media element');
    return this.real;
  },
  set: function (value) {
    if (!(this instanceof HTMLMediaElement)) throw new TypeError('not a media element');
    value = +value;
    if (!isFinite(value)) throw new TypeError('The provided value is non-finite');
    this.real = value;
  },
  enumerable: true, configurable: true
});
"""

result = subprocess.run(["osascript", "-l", "JavaScript", "-e", STAND_IN + script + CHECKS],
                        capture_output=True, text=True)
print(result.stdout.strip() or result.stderr.strip())
failed = result.returncode != 0 or "FAIL" in result.stdout or not result.stdout.strip()
print("failed" if failed else "all passed")
sys.exit(1 if failed else 0)
