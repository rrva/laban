#!/bin/sh
# Sync scroll-test.txt from the exact rendered text of scroll-test.html,
# so Chrome and Laban scroll byte-identical content.
set -e
html="${1:-$HOME/scroll-test.html}"
txt="${2:-$HOME/scroll-test.txt}"
python3 - "$html" "$txt" <<'EOF'
import html, re, sys
src, dst = sys.argv[1], sys.argv[2]
m = re.search(r'<pre>\n?(.*?)</pre>', open(src).read(), re.S)
if not m:
    sys.exit("no <pre> block found in " + src)
open(dst, "w").write(html.unescape(m.group(1)))
EOF
wc -l "$txt"
