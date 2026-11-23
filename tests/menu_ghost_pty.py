#!/usr/bin/env python3
"""Drives select_team (and probes menu_read_key directly) with GHOST keys (OAV2-25).

The target is NOT a specific terminal: Orchestra runs on macOS, Linux and WSL,
and each terminal encodes Alt/Shift/Ctrl+arrow differently. Two families of
encoding, both with MORE than 2 bytes after the ESC, which the old engine
only read 2 of, leaving a leftover:

  CSI WITH A MODIFIER PARAMETER ('\\e[1;3D')   — GNOME Terminal/VTE, Konsole,
    kitty, alacritty (Linux); Windows Terminal + WSL. It is the most common
    form on Linux/WSL.
  ESC-PREFIXED ('\\e\\e[D')                        — xterm with metaSendsEscape,
    tmux, screen, iTerm2 "Esc+", Terminal.app with Option=Meta.

When the leftover contains a letter that matches a menu shortcut, it fires on
its own: the 'D' of any modified Left falls into the 'd/D' branch and deletes
the agent under the cursor (agent_rm writes directly, without confirmation);
the 'A' of any modified Up falls into the 'a/A' branch and opens the add
prompt. The SESSION_CASES below drive the real select_team, through a pty, one
process per case (no shared state between them), and look at the REAL EFFECT
(team.json or the "nome do agente" prompt on screen), not at the returned key.

Another family has NO letter bound to a shortcut inside the sequence:
Delete/PageUp/F5 end in '~', the kitty keyboard protocol (CSI 'u') ends in
'u', SS3 in application mode is 'O' + a letter that never shows up alone. A
byte leftover from these is INVISIBLE in select_team: none of those bytes
match d/D/a/A/k/j/h/l/q/Q, so the effect on team.json/screen is IDENTICAL
with or without the leftover (the lost byte just becomes one more costless
'unknown' iteration, and the menu carries on normally). That is why the
PROBE_CASES below test the FUNCTION directly: they write the suspect sequence
followed by a KNOWN loose key ('x', which also has no shortcut; all that
matters is WHETHER it arrives whole, not what it would do) and compare what
menu_read_key returns for that following key. If a byte was left over, the
'x' is not the next thing read.

Two extra entries in PROBE_CASES came from the OAV2-25 REVIEW, not from a real
keyboard: the reviewer found two holes in the draining itself, the same
failure mode (a byte is left over, becomes a command) in a form no key emits
today:
  'space_in_csi'  ('\\e[2 q', cursor style) — a space (0x20) INSIDE the CSI,
    read without 'IFS=', becomes an EMPTY variable (bash uses $IFS to split
    fields), and the loop confuses "read a space" with "nothing arrived".
  'long_params'   (17 parameter bytes) — the draining byte cap
    (_menu_drain_csi) was 16, and the longest real producer (SGR mouse)
    already reaches 15: almost scraping it. They stay as a known regression:
    if they come back, CI must catch them.

It lives in its OWN file, not in tests/menu_pty.py: that file covers the
ENGINE (arrows, redraw, Esc), and this script also needs to inspect the
resulting team.json, a different purpose from what that one covers.

OAV2-26 expanded this matrix with three items measured in the OAV2-25 review:
  - shift_up and ctrl_left enter SESSION_CASES: the leftover they leave in the
    OLD engine is 'A'/'D', the TWO dangerous shortcuts (open 'adicionar',
    delete without confirmation) that shift_left/ctrl_up already proved from
    the other side (left/up); up/left cover the four directions.
  - DEAD_KEY_BATCH covers Delete/Home/End/PageUp/F1/Shift+Down-Right/
    Ctrl+Down-Right/application-mode arrows: by inspection, NONE of them
    leaves a leftover bound to a shortcut, not even in the old engine, so
    they run in a SINGLE process (instead of one per key) without losing
    coverage.
  - PROBE_K1_CASES gains 'alt_space': Alt+Space ('\e ') is the only form that
    hits lib/menu.sh:129/:146 exactly, the two lines the old matrix (13
    cases) did not cover: with the 'IFS=' removed from them, the 13 stayed
    13/13 green (measured). The verdict here is the 1st read (K1), not the
    2nd: the defect is the sequence becoming 'esc' (cancels the session), not
    a byte left over for the following key.
  - drain_until swaps waiting for SILENCE for waiting for a MARKER in three
    places (first render, cancelling the 'adicionar' prompt, TEAM_FILE= at the
    end), the same reason as the 'quiet=1.5' it replaces: getting through
    the 'sleep 1' of _st_add without depending on a hand-calibrated time
    threshold. Sending the SUSPECT sequence is still by silence ('send'
    function, unchanged on this point): draining by marker there would stop
    at the FIRST redraw, which in the old engine happens SEVERAL times BEFORE
    the shortcut leaks (each leftover byte is a loop iteration with its own
    _st_render), and changing the technique there would make the test stop
    catching it, exactly the opposite of what Rule 4 asks for.

ISOLATION: each case spins up its OWN ORCHESTRA_STATE (tempdir, deleted at the
end), never that of the process calling this script. Run standalone, without
going through tests/smoke.sh (which exports its own ORCHESTRA_STATE before
invoking this script), without this the child bash would inherit the user's
environment and lib/core.sh would fall back to the default
($HOME/.local/state/orchestra-agents), writing the test team.json into the
user's REAL state. No test may touch that.

Usage:  menu_ghost_pty.py <ORCHESTRA_HOME>
Prints one line 'CASE:<name>=OK|FAIL:<reason>' or 'PROBE:<name>=OK|FAIL:<reason>'
per case, and 'SESSION_ALIVE' at the end; smoke.sh matches with 'case'/'grep'.
"""

import fcntl
import json
import os
import pty
import select
import shutil
import struct
import sys
import tempfile
import termios
import time

ROWS, COLS = 24, 90
# default team that team_ensure creates (leader + coder + reviewer, see CLAUDE.md).
# The source of truth for the per-session cases is team.json, not the screen:
# any suspect sequence, drained or not, must leave exactly THESE two agents,
# neither one more nor one fewer.
EXPECTED_AGENTS = ["coder", "reviewer"]


def drain(fd, seconds=1.2, quiet=0.3):
    """Reads from the pty until it stays quiet for 'quiet's (or the deadline passes)."""
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
        end = time.time() + quiet
    return buf


# shown every time _st_render draws the menu screen, including on the first
# draw at startup and on the redraw that follows the 'sleep 1' of a cancelled _st_add.
RENDER_MARK = "q sai sem abrir".encode("utf-8")
# shown when _st_add really opens (the agent name prompt).
PROMPT_MARK = "nome do agente".encode("utf-8")
# shown when a 'delete' leftover leaks into the 'd/D' branch and opens the
# _st_del confirmation (OAV2-27): fixed suffix of menu_confirm(), lib/menu.sh.
CONFIRM_MARK = "[s/N]".encode("utf-8")


def drain_until(fd, markers, deadline=8.0):
    """Reads from the pty until ANY of the 'markers' appears in the
    accumulated output, or the deadline passes. Replaces waiting for SILENCE
    in the three places that do not depend on observing MULTIPLE redraws in
    sequence (first render, cancelling the 'adicionar' prompt, TEAM_FILE= at
    the end). See the module comment for why NOT to use this when sending the
    suspect sequence.
    Returns (bytes read, marker found or None)."""
    buf, end = b"", time.time() + deadline
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
        for m in markers:
            if m in buf:
                return buf, m
    return buf, None


def _spawn(script):
    """Starts a bash in a new pty running 'script'. Returns (pid, fd)."""
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


def _team_agent_names(team_file):
    """Agent names (without the leader) straight from team.json: file, not screen."""
    with open(team_file) as f:
        data = json.load(f)
    return sorted(a.get("name", "") for a in data.get("agents", []))


# ---------------------------------------------------------------------------
# Per-SESSION cases: they drive the real select_team. (name, bytes, what the
# leftover would trigger in the old engine: 'delete' via the d/D branch, 'add' via a/A)
# ---------------------------------------------------------------------------

SESSION_CASES = [
    ("shift_left",      b"\x1b[1;2D",  "delete"),  # Shift+Left — original
    ("ctrl_up",         b"\x1b[1;5A",  "add"),      # Ctrl+Up — original
    ("alt_left_csi",    b"\x1b[1;3D",  "delete"),  # Alt+Left, CSI w/ parameter (Linux/WSL)
    ("alt_up_csi",      b"\x1b[1;3A",  "add"),      # Alt+Up, CSI w/ parameter (Linux/WSL)
    ("alt_left_escpfx", b"\x1b\x1b[D", "delete"),  # Alt+Left, ESC-prefixed (tmux/screen/xterm/macOS)
    ("alt_up_escpfx",   b"\x1b\x1b[A", "add"),      # Alt+Up, ESC-prefixed (tmux/screen/xterm/macOS)
    # OAV2-26: the two directions that were missing (the CSI family already
    # covers left/up above): Shift+Up leaves 'A' (opens 'adicionar'),
    # Ctrl+Left leaves 'D' (deletes without confirmation).
    ("shift_up",        b"\x1b[1;2A",  "add"),
    ("ctrl_left",       b"\x1b[1;5D",  "delete"),
]

# OAV2-26: keys the task asks to cover but which, by inspection, NEVER leave a
# leftover bound to a shortcut, not even in the OLD engine (checked case by
# case: each one's leftover falls on ';', digits, '~', 'B' or 'C', none
# matching a/d/k/j/h/l/q). Tested together in run_dead_key_batch, a single
# process, instead of one per key; see that function's comment for why.
DEAD_KEY_BATCH = [
    ("home",        b"\x1b[H"),
    ("end",         b"\x1b[F"),
    ("f1",          b"\x1bOP"),
    ("pageup",      b"\x1b[5~"),
    ("delete",      b"\x1b[3~"),
    ("shift_down",  b"\x1b[1;2B"),
    ("shift_right", b"\x1b[1;2C"),
    ("ctrl_down",   b"\x1b[1;5B"),
    ("ctrl_right",  b"\x1b[1;5C"),
    ("ss3_up",      b"\x1bOA"),   # arrow in application mode (DECCKM)
    ("ss3_down",    b"\x1bOB"),
    ("ss3_left",    b"\x1bOD"),
    ("ss3_right",   b"\x1bOC"),
]


def run_session_case(home, seq, kind):
    """Starts an isolated select_team (own project and ORCHESTRA_STATE), sends
    Down (leader -> coder) and the suspect sequence, and checks team.json at
    the END, not the screen: the team must come out EXACTLY as it went in.

    'kind' only decides how the script stays alive to the end: 'add' knows
    the sequence MAY open the 'nome do agente' prompt (switches the terminal
    to LINE reading) and cancels with an empty line if that happens, so as not
    to hang waiting for an Enter that will not come; 'delete' does not need
    this. The verdict itself ('did the sequence still leave the team intact?')
    is always taken from the file, comparing with EXPECTED_AGENTS.
    """
    proj = tempfile.mkdtemp()
    state = tempfile.mkdtemp()
    pid = fd = None
    try:
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
            'echo "TEAM_FILE=$(team_file)"',
        ])
        pid, fd = _spawn(script)
        # OAV2-26: marker instead of silence on the first render: it shows up as
        # soon as _st_render draws for the first time, without waiting the fixed 2s.
        output, _ = drain_until(fd, [RENDER_MARK], deadline=8.0)

        def send(bts, wait=1.2, quiet=0.3):
            nonlocal output
            os.write(fd, bts)
            output += drain(fd, wait, quiet)

        try:
            send(b"\x1b[B")  # leader -> coder: this is the agent the sequence targets
            # Here the sending stays by SILENCE, on purpose (see the module
            # comment): in the old engine the shortcut can leak several loop
            # iterations after the first redraw, and stopping at the first
            # marker would miss exactly that leak.
            send(seq)
        except OSError:
            return "FAIL:menu_died"

        # In the OLD engine, the leftover of a 'delete' sequence falls into the
        # 'd/D' branch and opens the _st_del confirmation (OAV2-27), which blocks
        # waiting for an answer on /dev/tty. Without checking this here, the 'q'
        # sent further below to leave the menu becomes the ANSWER to the question
        # (not the 'q' that exits): the menu never exits, TEAM_FILE= never
        # appears, and the case blows the following 8s deadline with
        # 'FAIL:no_team_file', the SAME generic reason as a dead pty, which no
        # longer proves anything about the leak (finding from the OAV2-27/OAV2-29
        # review). 'send(seq)' is synchronous enough for this: the question
        # appears as soon as _st_del runs, with no sleep in between.
        if kind == "delete" and CONFIRM_MARK in output:
            return "FAIL:delete_prompt_leaked"

        opened = kind == "add" and b"nome do agente" in output
        try:
            if opened:
                # _st_add treats '' as cancel, prints 'cancelado' and only THEN
                # sleeps 1s before handing control back to the main loop. The
                # help line 'q sai sem abrir' only reappears when _st_render
                # runs AFTER that sleep: waiting for IT instead of for silence
                # gets through the gap without depending on a hand-calibrated
                # time threshold (it was 'quiet=1.5', ~1.5s extra per 'add'
                # case; OAV2-26 finding, measured).
                os.write(fd, b"\n")
                chunk, _ = drain_until(fd, [RENDER_MARK], deadline=10.0)
                output += chunk
            os.write(fd, b"q")
        except OSError:
            pass
        # marker again, not silence, for the end of the process.
        chunk, _ = drain_until(fd, [b"TEAM_FILE="], deadline=8.0)
        output += chunk

        team_file = ""
        for line in output.decode("utf-8", "replace").splitlines():
            if line.startswith("TEAM_FILE="):
                team_file = line.split("=", 1)[1].strip()
        if not team_file or not os.path.isfile(team_file):
            return "FAIL:no_team_file"
        try:
            current = _team_agent_names(team_file)
        except (ValueError, OSError):
            return "FAIL:invalid_team_json"

        # 'opened' is the direct symptom of the bug on top of 'add' keys (the
        # leftover hit the a/A branch and the prompt opened without the user
        # asking): it fails even if the cancellation left team.json intact,
        # because the prompt opening on its own IS the leak this test exists
        # to catch. 'team_changed' is the belt-and-suspenders: it covers both
        # the direct deletion (d/D branch) and any way the sequence could have
        # left the team different from what it was, even without the prompt
        # showing up.
        if opened:
            return "FAIL:add_opened_unprompted"
        if current != EXPECTED_AGENTS:
            return "FAIL:team_changed:%s" % ",".join(current)
        return "OK"
    finally:
        if fd is not None:
            _close(pid, fd)
        shutil.rmtree(proj, ignore_errors=True)
        shutil.rmtree(state, ignore_errors=True)


def run_dead_key_batch(home):
    """A SINGLE select_team driven by the WHOLE DEAD_KEY_BATCH sequence.

    Unlike run_session_case, here NO sequence has a leftover bound to a
    shortcut (checked case by case, see the list's comment), not even in the
    OLD engine. So they need no isolation from each other: testing the 13 in a
    single process, instead of one per key, saves ~13 bash+pty startups
    without losing coverage. Each sequence travels TOGETHER with a KNOWN arrow
    (↓) in a single write (one 'drain' per pair, not two), and we confirm in
    the response that it navigated (the menu neither died nor opened any
    prompt) before moving on to the next one. Since they are inert in both
    engines, this function does not enter the negative control (it would
    prove nothing there); the regression proof of this round is
    shift_up/ctrl_left, in SESSION_CASES.
    """
    proj = tempfile.mkdtemp()
    state = tempfile.mkdtemp()
    pid = fd = None
    issues = []
    try:
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
            'echo "TEAM_FILE=$(team_file)"',
        ])
        pid, fd = _spawn(script)
        output, _ = drain_until(fd, [RENDER_MARK], deadline=8.0)

        def send(bts, wait=1.2, quiet=0.3):
            nonlocal output
            os.write(fd, bts)
            output += drain(fd, wait, quiet)

        try:
            send(b"\x1b[B")  # leader -> coder
            for name, seq in DEAD_KEY_BATCH:
                before = len(output)
                # the suspect sequence and the liveness-proof arrow travel
                # TOGETHER in a single write/drain: half the trips to the pty
                # of sending the two separately, without losing what each proves.
                send(seq + b"\x1b[B")
                chunk = output[before:]
                if b"nome do agente" in chunk:
                    issues.append("%s:opened_add" % name)
                    send(b"\n")  # cancel the prompt and carry on with the script
                elif not chunk:
                    issues.append("%s:menu_stuck" % name)
            os.write(fd, b"q")
        except OSError:
            return "FAIL:menu_died"
        chunk, _ = drain_until(fd, [b"TEAM_FILE="], deadline=8.0)
        output += chunk

        team_file = ""
        for line in output.decode("utf-8", "replace").splitlines():
            if line.startswith("TEAM_FILE="):
                team_file = line.split("=", 1)[1].strip()
        if not team_file or not os.path.isfile(team_file):
            return "FAIL:no_team_file"
        try:
            current = _team_agent_names(team_file)
        except (ValueError, OSError):
            return "FAIL:invalid_team_json"
        if current != EXPECTED_AGENTS:
            issues.append("team_changed:%s" % ",".join(current))
        if issues:
            return "FAIL:" + ";".join(issues)
        return "OK"
    finally:
        if fd is not None:
            _close(pid, fd)
        shutil.rmtree(proj, ignore_errors=True)
        shutil.rmtree(state, ignore_errors=True)


# ---------------------------------------------------------------------------
# Direct probe of menu_read_key: see the module comment. Sequences with NO
# letter bound to a shortcut produce no observable effect in select_team,
# drained or not, so the proof has to be at the function level.
# ---------------------------------------------------------------------------

PROBE_CASES = [
    ("delete", b"\x1b[3~"),      # Delete — ends in '~'
    ("pageup", b"\x1b[5~"),      # PageUp — ends in '~'
    ("f5",     b"\x1b[15~"),     # F5 — ends in '~', 2-digit parameter
    ("ss3_up", b"\x1bOA"),       # Up arrow in application mode (DECCKM) — SS3
    ("kitty_u", b"\x1b[97;3u"),  # kitty keyboard protocol — CSI ends in 'u'
    # Findings from the OAV2-25 REVIEW (see the module comment): no real key
    # emits these forms today, but the failure mode is the same.
    ("space_in_csi", b"\x1b[2 q"),                    # space (0x20) INSIDE the CSI, without IFS= becomes ''
    ("long_params", b"\x1b[1;1;1;1;1;1;1;1;1D"),      # 17 parameter bytes, blew the cap of 16
]


def run_probe_case(home, seq):
    """Writes <sequence><'x'> in one go (already sitting in the buffer before
    the 1st read) and calls menu_read_key twice: the 1st consumes the suspect
    sequence, the 2nd must return exactly 'x'; if a byte was left over, the
    2nd call returns the rest of the sequence, not 'x'.
    """
    script = "\n".join([
        'export ORCHESTRA_MUX=stub',
        '. "%s/lib/menu.sh"' % home,
        'menu_read_key K1',
        'menu_read_key K2',
        'echo "K1=[$K1] K2=[$K2]"',
    ])
    pid, fd = _spawn(script)
    time.sleep(0.15)  # bash starts up and reaches the first read before we write
    try:
        os.write(fd, seq + b"x")
    except OSError:
        _close(pid, fd)
        return "FAIL:menu_died"
    output = drain(fd, 2.5, quiet=0.4)
    _close(pid, fd)
    k1 = k2 = None
    for line in output.decode("utf-8", "replace").splitlines():
        if line.startswith("K1="):
            try:
                k1 = line.split("K1=[", 1)[1].split("]", 1)[0]
                k2 = line.split("K2=[", 1)[1].split("]", 1)[0]
            except IndexError:
                pass
    if k2 is None:
        return "FAIL:no_response"
    return "OK" if k2 == "x" else "FAIL:K1=%s,K2=%s(expected x)" % (k1, k2)


# OAV2-26: finding from the OAV2-25 review that only got a test now: the two
# uncovered lines were lib/menu.sh:129 and :146 (measured: removing the
# 'IFS=' from them, the 13 cases above stay 13/13 green).
PROBE_K1_CASES = [
    ("alt_space", b"\x1b "),   # ESC + space — Alt+Space in a terminal with Meta
]


def run_probe_k1_case(home, seq):
    """Like run_probe_case, but the verdict is on the 1st read (K1), not the
    2nd: the defect here is not a byte left over for the following key, it is
    the sequence ITSELF being classified wrong. Alt+Space ('\\e ', ESC
    followed by a space) is a space (0x20) right after the ESC: without 'IFS='
    on the first read of the ESC branch (lib/menu.sh:129), bash strips the
    space at the edges of what it read (the field-splitting rule of 'read'
    without an empty 'IFS=') and the variable ends up EMPTY, the same value
    that a 'lone Esc' produces. menu_read_key returns 'esc' instead of
    'unknown', and 'esc' cancels the whole session: a key combination should
    never have that power by accident. We do not write a proof 'x' afterwards:
    there is no leftover to verify here.
    """
    script = "\n".join([
        'export ORCHESTRA_MUX=stub',
        '. "%s/lib/menu.sh"' % home,
        'menu_read_key K1',
        'echo "K1=[$K1]"',
    ])
    pid, fd = _spawn(script)
    time.sleep(0.15)  # bash starts up and reaches the first read before we write
    try:
        os.write(fd, seq)
    except OSError:
        _close(pid, fd)
        return "FAIL:menu_died"
    output = drain(fd, 2.5, quiet=0.4)
    _close(pid, fd)
    k1 = None
    for line in output.decode("utf-8", "replace").splitlines():
        if line.startswith("K1="):
            try:
                k1 = line.split("K1=[", 1)[1].split("]", 1)[0]
            except IndexError:
                pass
    if k1 is None:
        return "FAIL:no_response"
    return "OK" if k1 == "unknown" else "FAIL:K1=%s(expected unknown)" % k1


def main():
    home = sys.argv[1]
    # optional second argv: comma-separated list of names. Used by the negative
    # control of case 20 (tests/smoke.sh) to run ONLY the cases that the
    # pre-OAV2-25 engine has to fail: dead_key_batch (~13s: 13 sequences, each
    # followed by a liveness-proof arrow) and ss3_up are NOT in that list (they
    # are inert in both engines, proving no regression there), and running them
    # again against the old copy would only waste time; that is what pushed the
    # suite past 1min30 (measured).
    only = set(sys.argv[2].split(",")) if len(sys.argv) > 2 and sys.argv[2] else None

    def wants(name):
        return only is None or name in only

    for name, seq, kind in SESSION_CASES:
        if wants(name):
            print("CASE:%s=%s" % (name, run_session_case(home, seq, kind)))
    if wants("dead_key_batch"):
        print("CASE:dead_key_batch=%s" % run_dead_key_batch(home))
    for name, seq in PROBE_CASES:
        if wants(name):
            print("PROBE:%s=%s" % (name, run_probe_case(home, seq)))
    for name, seq in PROBE_K1_CASES:
        if wants(name):
            print("PROBE:%s=%s" % (name, run_probe_k1_case(home, seq)))
    print("SESSION_ALIVE")


if __name__ == "__main__":
    main()
