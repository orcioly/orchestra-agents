#!/usr/bin/env python3
"""Drives the compose menu engine (select_team) through a pty and reports what
it observed: only the ENGINE (arrows, redraw, lone Esc). Flows that CHANGE
state (add, remove, switch IA, Enter on a row) live in
tests/menu_compose_pty.py (OAV2-26); classification of ghost keys via
draining lives in tests/menu_ghost_pty.py.

It exists because the bugs this test covers only show up in a REAL terminal:

  1. The live arrow. Bash 3.2 (what macOS ships as /bin/bash) refuses a
     fractional timeout in 'read -t': it returns 1 immediately and leaves the
     variable empty, which is exactly the "lone Esc" case. Result: EVERY arrow
     closed the menu, and select_team returned 2, so zellij never opened.
     Running the function in any shell does not catch this: without a pty, the
     menu never even gets to read a key.

  2. The redraw with no leftovers. With an absolute anchor ('\033[s' / '\033[u')
     the saved position is the SCREEN LINE; when the menu does not fit in the
     window the terminal scrolls, the anchor ends up pointing into the middle
     of the block and the redraw starts there, leaving the top of the old menu
     above. That is why the window here is short on purpose: the scroll is
     what triggers the bug.

  3. A lone Esc cancels (rc 2) and the 4 arrows really keep navigating.
     Without this, an Esc that gets "stuck" (the same trap as item 1, on a
     byte that is not an arrow) would return rc 2 when it should not, or the
     up/left/right arrows, never exercised before, could have regressed
     unnoticed (only the down arrow was driven here).

  4. "The pty responded" is not "the arrow worked". Finding from the OAV2-26
     review: the previous version of case_four_arrows only measured whether ANY
     byte came out after each key, and since _st_render runs again on every
     loop turn, that is true even for a 100% inert arrow. Proof: replacing
     'up) row=...' with 'up) : ;;' and 'left|right) _st_cycle' with
     'left|right) : ;;' in lib/core.sh left up/left/right completely without
     effect, and the whole suite kept passing. That is why each arrow now has
     an assertion on its EFFECT on screen (cursor ▸ on the right row, or IA
     highlight on the right cell); see case_four_arrows.

ISOLATION: ORCHESTRA_STATE points to a tempdir of its own, deleted at the end
(finding from OAV2-26). Without it, run standalone (outside tests/smoke.sh,
which exports its own ORCHESTRA_STATE before calling this script), the child
bash inherited the user's environment and lib/core.sh fell back to the default
($HOME/.local/state/orchestra-agents), writing the test team.json into the
user's REAL state; it already produced 6 ghost projects deleted by hand.

Usage:  menu_pty.py <ORCHESTRA_HOME> <project>
Prints markers, one per line, which smoke.sh matches with 'case'.
"""

import fcntl
import os
import pty
import re
import select
import struct
import sys
import tempfile
import termios
import time

# short window on purpose: the menu does not fit and the terminal SCROLLS
ROWS, COLS = 14, 90


def drain(fd, seconds=0.8):
    """Reads from the pty until it stays quiet for 0.3s (or the deadline passes)."""
    buf, end = b"", time.time() + seconds
    while time.time() < end:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if not ready:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        buf += chunk
        end = time.time() + 0.3
    return buf


def _spawn(home, proj, state):
    script = "\n".join([
        'export ORCHESTRA_HOME="%s"' % home,
        'export ORCHESTRA_STATE="%s"' % state,
        'export ORCHESTRA_MUX=stub',
        'export ORCHESTRA_PROJECT="%s"' % proj,
        'cd "$ORCHESTRA_PROJECT"',
        '. "$ORCHESTRA_HOME/lib/core.sh"',
        'team_ensure >/dev/null 2>&1',
        'select_team',
        'echo "RC=$?"',
    ])
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.execv("/bin/bash", ["/bin/bash", "-c", script])
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
    return pid, fd


def _close(pid, fd):
    try:
        os.close(fd)
        os.waitpid(pid, 0)
    except OSError:
        pass


# highlighted arrow (cyan) and highlighted IA cell (reverse+bold+cyan) —
# the same codes _st_render (lib/core.sh) uses to mark the current row and
# IA. Matching "on the same screen line" (without crossing '\n') is what
# guarantees the arrow/highlight found belongs to the right row, not to
# another one below.
_ARROW = "\033[1;36m▸\033[0m".encode("utf-8")
_HIGHLIGHT = "\033[1;7;36m".encode("utf-8")
_RESET = "\033[0m".encode("utf-8")


def cursor_on_line(label, screen):
    """The highlighted ▸ appears before 'label' (e.g. 'CODER'), with no '\\n'
    between the two, that is, on the SAME line drawn by _st_render."""
    pattern = re.escape(_ARROW) + rb"[^\n]*?" + label.encode("utf-8")
    return re.search(pattern, screen) is not None


def backend_is_highlighted(label, backend, screen):
    """The IA cell 'backend' is highlighted on the row of 'label'."""
    pattern = (label.encode("utf-8") + rb"[^\n]*?" + re.escape(_HIGHLIGHT)
               + backend.encode("utf-8") + re.escape(_RESET))
    return re.search(pattern, screen) is not None


def case_arrows_and_redraw(home):
    """Down arrow three times (leader → coder → reviewer → add): covers the
    relative redraw and arriving at '+ adicionar agente'."""
    proj = tempfile.mkdtemp()
    state = tempfile.mkdtemp()
    try:
        pid, fd = _spawn(home, proj, state)
        drain(fd, 2.0)

        output = []
        for _ in range(3):
            try:
                os.write(fd, b"\x1b[B")
            except OSError:
                print("MENU_DIED")
                return
            chunk = drain(fd, 0.8)
            if not chunk:                      # the menu went away: pty not responding
                print("MENU_DIED")
                return
            if b"invalid timeout" in chunk:
                print("INVALID_TIMEOUT")
            output.append(chunk)

        combined = b"".join(output)
        print("ARROW_ALIVE")
        if b"\x1b[u" in combined:
            print("ABSOLUTE_ANCHOR")
        if re.search(rb"\x1b\[\d+A", combined):
            print("RELATIVE_REDRAW")
        # the arrow (▸ = U+25B8) parked on the '+ adicionar agente' row
        if re.search("\033\\[1;36m▸\033\\[0m \033\\[1m\\+".encode("utf-8"), combined):
            print("REACHED_ADD")

        try:
            os.write(fd, b"q")
            drain(fd, 0.8)
            _close(pid, fd)
        except OSError:
            pass
    finally:
        import shutil
        shutil.rmtree(proj, ignore_errors=True)
        shutil.rmtree(state, ignore_errors=True)


def case_four_arrows(home):
    """The 4 arrows really navigate (not just ↓, already covered above), each
    with an OBSERVABLE EFFECT on screen, not merely "some byte came out" (see
    item 4 of the module header):
      ↓  leader   -> coder     (▸ lands on the CODER row)
      ↓  coder    -> reviewer  (▸ lands on the REVIEWER row)
      ↑  reviewer -> coder     (▸ goes back to CODER)
      →  cycles the IA of the current row (coder): opencode -> codex
      ←  cycles again: codex -> claude. ←/→ call the SAME _st_cycle in
         lib/core.sh, always moving forward; there is no "undo" in the real
         code, so here the proof is the highlight CHANGING, not a return to
         the original IA."""
    proj = tempfile.mkdtemp()
    state = tempfile.mkdtemp()
    try:
        pid, fd = _spawn(home, proj, state)
        drain(fd, 2.0)

        def press_key(seq):
            try:
                os.write(fd, seq)
            except OSError:
                return None
            return drain(fd, 0.6)

        screen = press_key(b"\x1b[B")                  # down: leader -> coder
        if not screen:
            print("MENU_DIED"); return
        if cursor_on_line("CODER", screen):
            print("MOVES_DOWN_TO_CODER")

        screen = press_key(b"\x1b[B")                  # down: coder -> reviewer
        if not screen:
            print("MENU_DIED"); return
        if cursor_on_line("REVIEWER", screen):
            print("MOVES_DOWN_TO_REVIEWER")

        screen = press_key(b"\x1b[A")                  # up: reviewer -> coder
        if not screen:
            print("MENU_DIED"); return
        if cursor_on_line("CODER", screen):
            print("MOVES_UP_TO_CODER")

        screen = press_key(b"\x1b[C")                  # right: opencode -> codex
        if not screen:
            print("MENU_DIED"); return
        if backend_is_highlighted("CODER", "codex", screen):
            print("RIGHT_SWITCHES_TO_CODEX")

        screen = press_key(b"\x1b[D")                  # left: codex -> claude
        if not screen:
            print("MENU_DIED"); return
        if backend_is_highlighted("CODER", "claude", screen):
            print("LEFT_SWITCHES_TO_CLAUDE")

        print("FOUR_ARROWS_ALIVE")
        try:
            os.write(fd, b"q")
            drain(fd, 0.8)
            _close(pid, fd)
        except OSError:
            pass
    finally:
        import shutil
        shutil.rmtree(proj, ignore_errors=True)
        shutil.rmtree(state, ignore_errors=True)


def case_esc_cancels(home):
    """A lone Esc cancels the whole session: select_team returns rc 2 and
    'up' does not open zellij."""
    proj = tempfile.mkdtemp()
    state = tempfile.mkdtemp()
    try:
        pid, fd = _spawn(home, proj, state)
        output = drain(fd, 2.0)
        try:
            os.write(fd, b"\x1b")
        except OSError:
            print("MENU_DIED")
            return
        output += drain(fd, 1.5)
        _close(pid, fd)
        if b"RC=2" in output:
            print("ESC_CANCELS")
    finally:
        import shutil
        shutil.rmtree(proj, ignore_errors=True)
        shutil.rmtree(state, ignore_errors=True)


def main():
    home, proj = sys.argv[1], sys.argv[2]
    case_arrows_and_redraw(home)
    case_four_arrows(home)
    case_esc_cancels(home)
    # 'proj' is still accepted for call compatibility (tests/smoke.sh
    # passes a project directory); it is no longer used directly here:
    # each case spins up its own, isolated.
    _ = proj


if __name__ == "__main__":
    main()
