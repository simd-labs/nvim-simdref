#!/usr/bin/env bash
# D5 headless screenshots: Xvfb + xterm + scrot. Mount the repo at /src,
# this dir at /shot, and a HOME at /tmp/shothome with a populated venv and
# catalog (/tmp/shothome/venv/bin/simdref-lsp,
# /tmp/shothome/.local/share/simdref/catalog.db).
set -u
export DISPLAY=:99
export HOME=/tmp/shothome
export PATH="$HOME/venv/bin:$PATH"

if [ ! -x "$HOME/venv/bin/simdref-lsp" ] || [ ! -f "$HOME/.local/share/simdref/catalog.db" ]; then
  echo "shothome incomplete: venv or catalog.db missing"; exit 1
fi
echo "venv simdref: $("$HOME/venv/bin/pip" show simdref | grep -i '^Version')"

Xvfb :99 -screen 0 1600x1000x24 >/tmp/xvfb.log 2>&1 &
XVFB_PID=$!
i=0
while [ $i -lt 100 ]; do
  [ -e /tmp/.X11-unix/X99 ] && break
  sleep 0.2; i=$((i + 1))
done
if [ ! -e /tmp/.X11-unix/X99 ]; then
  echo "Xvfb did not start"; cat /tmp/xvfb.log; exit 1
fi

waitflag() { # $1=path $2=seconds
  local n=$(( $2 * 5 ))
  local i=0
  while [ $i -lt $n ]; do
    [ -e "$1" ] && return 0
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

fail=0
phase() { # $1=asm|cpp
  rm -f /tmp/ready-hints /tmp/do-hover /tmp/ready-hover
  # fs 13 -> 11px cells: 140 cols = 1544px, fits the 1600px Xvfb screen.
  # fs 18 gives 15px cells (2104px): the window is clipped at the screen
  # edge and the hover float's right border plus its wrapped lines land
  # off-screen, so text looks cut mid-word at the screenshot edge.
  xterm -fa 'DejaVu Sans Mono' -fs 13 -geometry 140x30+0+0 \
    -e nvim -u NONE --cmd 'set rtp+=/src' --cmd "luafile /shot/shot-$1.lua" \
    >/tmp/xterm-$1.log 2>&1 &
  local xpid=$!
  if ! waitflag /tmp/ready-hints 150; then
    echo "TIMEOUT: $1 hints"; tail -20 /tmp/xterm-$1.log; fail=1
    kill "$xpid" 2>/dev/null; wait "$xpid" 2>/dev/null; return
  fi
  sleep 0.5
  scrot -o "/shot/shot-$1-hints.png" || fail=1
  cp "/tmp/xterm-$1.log" "/shot/xterm-$1-prehover.log" 2>/dev/null
  touch /tmp/do-hover
  if ! waitflag /tmp/ready-hover 90; then
    echo "TIMEOUT: $1 hover"; tail -20 /tmp/xterm-$1.log; fail=1
    kill "$xpid" 2>/dev/null; wait "$xpid" 2>/dev/null; return
  fi
  sleep 0.5
  scrot -o "/shot/shot-$1-hover.png" || fail=1
  wait "$xpid"
  cp "/tmp/xterm-$1.log" "/shot/xterm-$1.log" 2>/dev/null
  echo "phase $1 done"
}

phase asm
phase cpp
kill "$XVFB_PID" 2>/dev/null
wait 2>/dev/null
if [ $fail -eq 0 ]; then
  echo "=== screenshots done ==="
else
  echo "=== screenshots FAILED ==="
fi
exit $fail
