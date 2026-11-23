#!/usr/bin/env python3
"""Drives select_team through the flows that CHANGE (or could change) the
team: 'a' to the end, 'a' cancelled, 'd', Space and Enter on an agent row.
This is the blind spot tests/menu_pty.py (arrows/redraw) always left: that
script never pressed 'a', 'd', Space or Enter, only the down arrow to
'+ adicionar agente' and 'q' (OAV2-26).

Why in its OWN file, and not in tests/menu_pty.py (engine: arrows,
redraw, Esc) nor in tests/menu_ghost_pty.py (key classification via
draining, with SESSION_CASES in the same spirit of driving the real
select_team): this script inspects the STATE EFFECT of keys the user presses
on purpose (team.json and the generated prompt_file), not leftover bytes or
redraw. It reuses the isolation pattern and drain_until (marker instead of
silence) already validated in tests/menu_ghost_pty.py.

OAV2-27: the finding recorded here when the original script was written,
_st_del ('d', lib/core.sh) removed the agent IMMEDIATELY, with no call to
'menu_confirm' (lib/menu.sh line 253) anywhere in the repository, has been
fixed. 'd' now asks for confirmation (agent name visible in the question,
default NO: a lone Enter does not remove) before calling agent_rm. The
'delete_with_confirmation' case below covers 's'/'n'/lone Enter; it replaces
the old 'del_sem_confirmacao'.

There is no "ghost key stopped at the confirmation" case here: with the
CURRENT engine the ghost sequence is already drained as 'unknown' before
reaching 'd', and a case that sends that sequence from here never really
exercises _st_del. Finding from the round 3 review (the reviewer reverted
_st_del to the version without confirmation and the case stayed 'OK', proof
that it tested nothing). The second layer (the leftover REALLY reaching 'd',
against a copy of the PRE-OAV2-25 engine) is the responsibility of
'run_session_case' in tests/menu_ghost_pty.py, which now returns
'FAIL:delete_prompt_leaked' precisely when that happens.

ISOLATION: each case spins up its OWN ORCHESTRA_STATE and project (tempdirs,
deleted at the end), never those of the process calling this script (same
reason as tests/menu_ghost_pty.py).

FAKE BACKENDS: agent_add refuses an IA without the binary on PATH
(backend_available). Inside tests/smoke.sh this is already covered (FAKEBIN
on PATH before any test); to run this file alone, it creates the same stubs
in a tempdir of its own and prepends it to PATH.

Usage:  menu_compose_pty.py <ORCHESTRA_HOME>
Prints 'CASE:<name>=OK|FAIL:<reason>' per case and 'SESSION_ALIVE' at the end.
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

# same short window as tests/menu_pty.py (the scroll is what triggers the menu
# duplication bug, see the header of that file). Measured: the five cases
# below pass at 14x90 just as they did at 24x90, so there is no reason for
# a larger window here.
ROWS, COLS = 14, 90
EXPECTED_AGENTS = ["coder", "reviewer"]

# shown on screen whenever _st_render draws the menu (first draw on
# startup, and every redraw after an action): a "back to the main loop"
# marker, instead of waiting for silence.
RENDER_MARK = "q sai sem abrir".encode("utf-8")
PROMPT_NAME = "nome do agente".encode("utf-8")
PROMPT_ROLE = "função — pronta".encode("utf-8")
PROMPT_BACKEND = "qual IA roda esse agente".encode("utf-8")
PROMPT_DESCRIPTION = "o que ele faz?".encode("utf-8")
MARK_CANCELLED = "cancelado".encode("utf-8")
# menu_confirm() (lib/menu.sh) always ends the question with this suffix,
# regardless of the question text itself.
MARK_CONFIRM = "[s/N]".encode("utf-8")


def _fake_backends():
    """claude/opencode/codex stubs in a tempdir of its own, so this file can
    run alone without depending on the FAKEBIN that tests/smoke.sh prepares."""
    d = tempfile.mkdtemp()
    for b in ("claude", "opencode", "codex"):
        p = os.path.join(d, b)
        with open(p, "w") as f:
            f.write("#!/bin/sh\necho stub\n")
        os.chmod(p, 0o755)
    return d


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


def drain_until(fd, markers, deadline=8.0):
    """Reads from the pty until ANY of the 'markers' appears in the
    accumulated output, or the deadline passes. Replaces waiting for SILENCE:
    each step of the 'add' flow has its OWN on-screen prompt (name → role →
    IA → description → back to the menu), and waiting for that prompt's TEXT
    instead of a fixed time gets through even the 'sleep 1' that _st_add does
    on cancel (lib/core.sh) with no threshold to calibrate: the same
    technique (and the same reason) as tests/menu_ghost_pty.py (OAV2-26)."""
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


def _team(team_file):
    with open(team_file) as f:
        return json.load(f)


def _agent_names(team_file):
    return sorted(a.get("name", "") for a in _team(team_file).get("agents", []))


def _agent(team_file, name):
    for a in _team(team_file).get("agents", []):
        if a.get("name") == name:
            return a
    return None


class Session:
    """An isolated select_team, driven through a pty. Each case creates its own."""

    def __init__(self, home):
        self.proj = tempfile.mkdtemp()
        self.state = tempfile.mkdtemp()
        self.fakebin = _fake_backends()
        script = "\n".join([
            'export PATH="%s:$PATH"' % self.fakebin,
            'export ORCHESTRA_HOME="%s"' % home,
            'export ORCHESTRA_STATE="%s"' % self.state,
            'export ORCHESTRA_MUX=stub',
            'export ORCHESTRA_PROJECT="%s"' % self.proj,
            'cd "$ORCHESTRA_PROJECT"',
            '. "$ORCHESTRA_HOME/lib/core.sh"',
            'team_ensure >/dev/null 2>&1',
            'select_team',
            'echo "RC=$?"',
            'echo "TEAM_FILE=$(team_file)"',
        ])
        self.pid, self.fd = _spawn(script)
        self.output, self.found = drain_until(self.fd, [RENDER_MARK], deadline=8.0)

    def send(self, bts, markers=(RENDER_MARK,), deadline=8.0):
        """Writes bytes and waits for ANY marker in the list. Returns the
        marker found (or None, if the deadline passed)."""
        os.write(self.fd, bts)
        chunk, found = drain_until(self.fd, list(markers), deadline)
        self.output += chunk
        self.found = found
        return found

    def text(self):
        return self.output.decode("utf-8", "replace")

    def close(self, extra=b"q"):
        try:
            if b"TEAM_FILE=" not in self.output:
                if extra:
                    os.write(self.fd, extra)
                chunk, _ = drain_until(self.fd, [b"TEAM_FILE="], deadline=8.0)
                self.output += chunk
            elif extra:
                os.write(self.fd, extra)
        except OSError:
            pass
        _close(self.pid, self.fd)

    def team_file(self):
        for line in self.text().splitlines():
            if line.startswith("TEAM_FILE="):
                return line.split("=", 1)[1].strip()
        return ""

    def rc(self):
        for line in self.text().splitlines():
            if line.startswith("RC="):
                return line.split("=", 1)[1].strip()
        return None

    def cleanup(self):
        shutil.rmtree(self.proj, ignore_errors=True)
        shutil.rmtree(self.state, ignore_errors=True)
        shutil.rmtree(self.fakebin, ignore_errors=True)


# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

def case_add_full(home):
    """'a' end to end: name, role (non-preset, so it asks for a description),
    IA and description; confirms the new agent in team.json (role=custom,
    prompt_file) AND the content of the generated prompt."""
    s = Session(home)
    try:
        if s.found != RENDER_MARK:
            return "FAIL:no_first_render"
        if s.send(b"a", markers=(PROMPT_NAME,)) != PROMPT_NAME:
            return "FAIL:name_prompt_did_not_open"
        if s.send(b"compx\n", markers=(PROMPT_ROLE,)) != PROMPT_ROLE:
            return "FAIL:role_prompt_did_not_open"
        if s.send(b"deploy-role\n", markers=(PROMPT_BACKEND,)) != PROMPT_BACKEND:
            return "FAIL:backend_prompt_did_not_open"
        if s.send(b"opencode\n", markers=(PROMPT_DESCRIPTION,)) != PROMPT_DESCRIPTION:
            return "FAIL:description_prompt_did_not_open"
        if s.send(b"Faz deploy para producao sem downtime\n",
                   markers=(RENDER_MARK,)) != RENDER_MARK:
            return "FAIL:did_not_return_to_menu"
        s.close(b"q")
        tf = s.team_file()
        if not tf or not os.path.isfile(tf):
            return "FAIL:no_team_file"
        a = _agent(tf, "compx")
        if a is None:
            return "FAIL:agent_missing_from_team_json"
        if a.get("backend") != "opencode":
            return "FAIL:wrong_backend:%s" % a.get("backend")
        if a.get("role") != "custom":
            return "FAIL:role_should_be_custom:%s" % a.get("role")
        pf = a.get("prompt_file") or ""
        if pf != "prompts/compx.md":
            return "FAIL:unexpected_prompt_file:%s" % pf
        prompt_path = os.path.join(os.path.dirname(tf), pf)
        if not os.path.isfile(prompt_path):
            return "FAIL:prompt_not_generated"
        content = open(prompt_path, encoding="utf-8").read()
        if "Faz deploy para producao sem downtime" not in content:
            return "FAIL:prompt_missing_typed_description"
        if "compx" not in content:
            return "FAIL:prompt_missing_agent_name"
        return "OK"
    finally:
        s.cleanup()


def case_add_cancel(home):
    """'a' with a blank name: prints 'cancelado' and creates NO agent."""
    s = Session(home)
    try:
        if s.send(b"a", markers=(PROMPT_NAME,)) != PROMPT_NAME:
            return "FAIL:name_prompt_did_not_open"
        # A lone Enter = empty name. _st_add treats it as cancel, prints
        # 'cancelado', sleeps 1s and only THEN redraws; RENDER_MARK gets
        # through that sleep without depending on a hand-calibrated time threshold.
        if s.send(b"\n", markers=(RENDER_MARK,), deadline=10.0) != RENDER_MARK:
            return "FAIL:did_not_return_to_menu"
        if MARK_CANCELLED not in s.output:
            return "FAIL:did_not_print_cancelled"
        s.close(b"q")
        tf = s.team_file()
        if not tf or not os.path.isfile(tf):
            return "FAIL:no_team_file"
        if _agent_names(tf) != EXPECTED_AGENTS:
            return "FAIL:team_changed:%s" % ",".join(_agent_names(tf))
        return "OK"
    finally:
        s.cleanup()


def _delete_with_response(home, response):
    """Spins up a session of its own, presses 'd' on the coder row and answers
    the confirmation with 'response' (bytes). Returns the agent names left in
    team.json at the end, or a 'FAIL:...' string."""
    s = Session(home)
    try:
        if s.send(b"\x1b[B") != RENDER_MARK:                # leader -> coder
            return "FAIL:did_not_move_down_to_coder"
        before = len(s.output)
        if s.send(b"d", markers=(MARK_CONFIRM,)) != MARK_CONFIRM:
            return "FAIL:confirmation_did_not_appear"
        question = s.output[before:]
        if b"coder" not in question:
            return "FAIL:question_missing_agent_name"
        if s.send(response, markers=(RENDER_MARK,), deadline=10.0) != RENDER_MARK:
            return "FAIL:did_not_return_to_menu_after_response"
        s.close(b"q")
        tf = s.team_file()
        if not tf or not os.path.isfile(tf):
            return "FAIL:no_team_file"
        return _agent_names(tf)
    finally:
        s.cleanup()


def case_delete_with_confirmation(home):
    """'d' on the coder row asks for confirmation: agent name visible in the
    question, default NO (lib/menu.sh menu_confirm). 'n' and a lone Enter
    preserve the team; only 's' removes (OAV2-27). Replaces the old
    'del_sem_confirmacao': removal is no longer immediate."""
    for response, expected, label in (
        (b"n\n", EXPECTED_AGENTS, "n_does_not_remove"),
        (b"\n", EXPECTED_AGENTS, "enter_alone_does_not_remove"),  # default NO
        (b"s\n", ["reviewer"], "s_removes"),
    ):
        names = _delete_with_response(home, response)
        if isinstance(names, str):
            return "FAIL:%s:%s" % (label, names)
        if names != expected:
            return "FAIL:%s:%s" % (label, ",".join(names))
    return "OK"


def case_space_does_not_persist_on_quit(home):
    """Space switches the row's IA in memory; quitting with 'q' (cancel),
    the switch is DISCARDED: team.json keeps the original backend."""
    s = Session(home)
    try:
        if s.send(b"\x1b[B") != RENDER_MARK:               # leader -> coder
            return "FAIL:did_not_move_down_to_coder"
        if s.send(b" ") != RENDER_MARK:                    # cycles the IA
            return "FAIL:did_not_redraw_after_space"
        s.close(b"q")
        if s.rc() != "2":
            return "FAIL:rc_should_be_2_when_quitting_with_q:%s" % s.rc()
        tf = s.team_file()
        if not tf or not os.path.isfile(tf):
            return "FAIL:no_team_file"
        a = _agent(tf, "coder")
        if a is None or a.get("backend") != "opencode":
            return "FAIL:coder_backend_changed_without_persisting:%s" % (a or {}).get("backend")
        return "OK"
    finally:
        s.cleanup()


def case_enter_persists(home):
    """Space switches the IA, Enter ON THE ROW (not on 'adicionar'/'sair') leaves
    the loop without cancelling and persists via team_replace: team.json
    reflects the switch, and select_team returns rc 0 (not 2)."""
    s = Session(home)
    try:
        if s.send(b"\x1b[B") != RENDER_MARK:               # leader -> coder
            return "FAIL:did_not_move_down_to_coder"
        if s.send(b" ") != RENDER_MARK:                    # opencode -> codex
            return "FAIL:did_not_redraw_after_space"
        s.send(b"\r", markers=(b"TEAM_FILE=",), deadline=8.0)
        s.close(extra=b"")
        if s.rc() != "0":
            return "FAIL:rc_should_be_0_when_exiting_with_enter:%s" % s.rc()
        tf = s.team_file()
        if not tf or not os.path.isfile(tf):
            return "FAIL:no_team_file"
        a = _agent(tf, "coder")
        if a is None or a.get("backend") != "codex":
            return "FAIL:coder_backend_did_not_persist:%s" % (a or {}).get("backend")
        return "OK"
    finally:
        s.cleanup()


CASES = [
    ("add_full", case_add_full),
    ("add_cancel", case_add_cancel),
    ("delete_with_confirmation", case_delete_with_confirmation),
    ("space_does_not_persist_on_quit", case_space_does_not_persist_on_quit),
    ("enter_persists", case_enter_persists),
]


def main():
    home = sys.argv[1]
    for name, fn in CASES:
        try:
            result = fn(home)
        except Exception as exc:  # never let the script die silently
            result = "FAIL:exception:%s" % exc
        print("CASE:%s=%s" % (name, result))
    print("SESSION_ALIVE")


if __name__ == "__main__":
    main()
