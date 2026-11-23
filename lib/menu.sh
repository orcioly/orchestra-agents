#!/usr/bin/env bash
# Orchestra Agents — menu engine: draws on screen and reads keys. Only that.
#
# WHY THIS FILE EXISTS, AND WHY IT IS THE ONLY ONE
#
# A menu has two halves: the ENGINE (hide the cursor, erase the previous drawing,
# read a key and say which key it was) and the CONTENT (which lines exist, what
# each key does there). The content changes from menu to menu; the engine does not.
#
# The engine carries two traps that already broke the product in the user's hands, and
# both are INVISIBLE in bash 5 and outside a real terminal:
#
#   A1  'read -t' does not accept a fraction in bash 3.2. macOS's /bin/bash is 3.2.57 and
#       rejects 'read -t 0.05' with "invalid timeout specification": it returns 1 at once
#       and leaves the variable EMPTY, which is exactly how a "lone Esc" is recognized.
#       Result: EVERY arrow key closed the menu, select_team returned 2 and zellij did not
#       even open. Lives in menu_esc_wait, detected only once.
#
#   A2  The redraw is RELATIVE, never anchored. '\033[s' / '\033[u' store the ABSOLUTE
#       screen LINE; when the menu does not fit in the window the terminal SCROLLS, the
#       anchor ends up pointing into the middle of the block and the redraw starts there,
#       leaving the first lines of the old menu above. That was the duplication the user saw.
#       Lives in menu_draw_begin/menu_draw_end, which go up 'drawn' lines from
#       where the cursor is.
#
# That is why the engine lives HERE and nowhere else: with two copies one of them
# regresses, without whoever wrote it seeing the bug on their own machine.
#
# This module knows nothing about agents, team or zellij — only keys and characters. All
# drawing goes out through /dev/tty, never stdout, so the menu never contaminates a
# command's output.
#
# Do not execute directly; it is sourced by lib/core.sh.

# Lines occupied by the last drawing. 0 = "there is no previous drawing here".
_MENU_DRAWN=0
# 1 while a menu is on screen (cursor hidden). Used by menu_confirm and
# menu_prompt to give the cursor back to the question and hide it again afterwards.
_MENU_ACTIVE=0
# Memory of menu_esc_wait (A1). Empty = not detected yet.
_MENU_ESC_WAIT=""
# INT/TERM/EXIT traps that existed before menu_begin, to restore at the end.
_MENU_TRAP_INT=""
_MENU_TRAP_TERM=""
_MENU_TRAP_EXIT=""

# ----- Output -----

menu_tty() { # $1 format  $@ arguments — printf to the terminal, never to stdout
  # Without a controlling terminal the redirection fails; silencing it and moving on is the
  # right behavior, because without a TTY no menu opens anyway.
  { printf "$@" >/dev/tty; } 2>/dev/null
  return 0
}

menu_has_tty() { ( : >/dev/tty ) 2>/dev/null; }

# ----- Keyboard -----

_menu_esc_detect() { # populates _MENU_ESC_WAIT; only does work the first time (A1)
  [ -n "$_MENU_ESC_WAIT" ] && return 0
  _MENU_ESC_WAIT=0.05
  case "$( { read -rst 0.05 -n1 _ </dev/null; } 2>&1 )" in
    *'invalid timeout'*) _MENU_ESC_WAIT=1 ;;
  esac
  return 0
}

menu_esc_wait() { # echoes the Esc timeout this bash accepts: 0.05 or 1
  _menu_esc_detect
  printf '%s' "$_MENU_ESC_WAIT"
}

_menu_drain_csi() { # $1 variable name — already holds the introducer byte ('[' or 'O')
  # A CSI sequence ('\e[…') or SS3 ('\eO.') ends at the first byte in the
  # range 0x40-0x7E ('@'-'~'); everything before that (digits, ';', other
  # separators) is a parameter. DRAINING until that terminator is found is what avoids
  # the leftover (OAV2-25): without it, sequences longer than 2 bytes — Shift/Ctrl/Alt+
  # arrow ('\e[1;2D'), Delete ('\e[3~'), PageUp/Down, Insert, F5-F12 — left
  # the rest in the terminal buffer for the NEXT loop turn to read as a LONE
  # key. When the leftover contained a letter matching a menu shortcut,
  # it fired that shortcut without the user asking: the 'D' of Shift+
  # Left deleted the agent under the cursor, the 'A' of Ctrl+Up opened the
  # add prompt. We compare by ORDINAL (printf '%d'), not by '[@-~]': a
  # collation range depends on LC_COLLATE, an ordinal depends on no
  # locale. A function of its own (and not an inline loop) because menu_read_key needs
  # it at TWO points: the direct arrow and the ESC-prefixed variant of Alt+arrow;
  # duplicating the loop is how one copy diverges from the other unnoticed.
  #
  # 'IFS=' on the read: without it, a 0x20 byte (space) — a legitimate
  # CSI intermediate parameter, e.g. '\e[2 q' (cursor style) — becomes an EMPTY variable
  # (bash uses $IFS to split fields and discards spaces at the edges of what it read),
  # and the loop confuses "read a space" with "nothing arrived" (reviewer finding
  # in the OAV2-25 review, the same failure mode it exists to eliminate: a
  # byte becomes a phantom command on the next turn). The SAME 'IFS=' applies to the
  # other two single-byte reads on the ESC path (menu_read_key).
  #
  # Cap of 64 (was 16): the SGR mouse-click sequence reaches 15 parameter
  # bytes, so 16 only just covered a REAL producer. 64 sits well
  # above any known sequence without opening an indefinite wait — the
  # cap only exists against an endless stream of valid bytes (which does not
  # happen in practice); each turn already has the A1 timeout on its own.
  local __mdc_var="$1" __mdc_acc="${!1}" __mdc_byte __mdc_ord __mdc_n=0
  while [ "$__mdc_n" -lt 64 ]; do
    __mdc_byte=""
    IFS= read -rsn1 -t "$_MENU_ESC_WAIT" __mdc_byte </dev/tty || break
    [ -n "$__mdc_byte" ] || break
    __mdc_acc="$__mdc_acc$__mdc_byte"
    __mdc_n=$((__mdc_n + 1))
    __mdc_ord="$(printf '%d' "'$__mdc_byte")"
    [ "$__mdc_ord" -ge 64 ] && [ "$__mdc_ord" -le 126 ] && break
  done
  printf -v "$__mdc_var" '%s' "$__mdc_acc"
}

menu_read_key() { # $1 variable name — reads a key and returns its name
  local __mrk_var="$1" __mrk_key __mrk_rest __mrk_chain
  IFS= read -rsn1 __mrk_key </dev/tty || return 1
  case "$__mrk_key" in
    $'\e')
      # Esc and the arrows (and any other CSI/SS3 sequence) start with the SAME
      # byte. What tells a lone Esc from the rest is whether the next byte arrives
      # within the timeout — and the timeout has to be what THIS bash accepts (A1).
      # We call _menu_esc_detect directly, and not "$(menu_esc_wait)": command
      # substitution runs in a subshell, so the memory would stay there and the detection would
      # repeat on every key.
      _menu_esc_detect
      __mrk_rest=""
      IFS= read -rsn1 -t "$_MENU_ESC_WAIT" __mrk_rest </dev/tty
      # ESC-prefixed (OAV2-25, reviewer finding): Alt+arrow arrives with an EXTRA ESC in front
      # of the normal sequence ('\e\e[D' for Alt+Left) in
      # iTerm2 ("Esc+" mode), Terminal.app with Option=Meta and xterm with
      # metaSendsEscape. The byte after the 1st ESC is itself ANOTHER ESC — neither '['
      # nor 'O' — and without handling that here the real sequence ('[D') stayed
      # intact in the buffer for the next turn, which read it as a LONE key: the
      # 'D' fell into the menu's d/D branch and deleted the agent under the cursor, without
      # confirmation. We drain the extra ESC(s) the SAME way as the lone Esc
      # — reading the next byte with the A1 timeout — until finding '[' or 'O' (then it
      # becomes the same CSI/SS3 drain loop) or exhausting the cap of 3 turns,
      # which exists only to avoid a long wait on chained ESCs: each
      # turn already uses the _menu_esc_detect timeout, never an indefinite wait.
      __mrk_chain=0
      while [ "$__mrk_rest" = $'\e' ] && [ "$__mrk_chain" -lt 3 ]; do
        __mrk_chain=$((__mrk_chain + 1))
        __mrk_rest=""
        IFS= read -rsn1 -t "$_MENU_ESC_WAIT" __mrk_rest </dev/tty
      done
      case "$__mrk_rest" in
        # Empty = nothing arrived within the timeout: it is a lone Esc, the caller handles it
        # as cancel.
        '') __mrk_key=esc ;;
        '['|'O')
          _menu_drain_csi __mrk_rest
          if [ "$__mrk_chain" -gt 0 ]; then
            # Only got here by crossing an extra ESC: it is Alt+arrow (or another
            # Alt+CSI), not the direct arrow. It is already fully drained (no
            # leftover), but stays "unknown" on purpose — making this navigate
            # would widen behavior that never existed; it is not this
            # task's defect.
            __mrk_key=unknown
          else
            # Sequence recognized (in full) but it is not an arrow: Delete,
            # Home/End, PageUp/PageDown, F1-F12, arrow in application mode, or a
            # modifier combination ('\e[1;2D'). It MUST NOT become "esc": the
            # drawing on screen is identical to pressing a real Esc, but the
            # user's intent is different — and the menu help says "d remover",
            # so looking for the Delete key is the most natural mistake in the world. If
            # this collapsed into "esc", the caller would cancel the whole session when
            # Delete is pressed. "unknown" lets the caller decide (typically:
            # ignore and continue) — and now without leaving leftovers for the next turn.
            case "$__mrk_rest" in
              '[A') __mrk_key=up ;;
              '[B') __mrk_key=down ;;
              '[C') __mrk_key=right ;;
              '[D') __mrk_key=left ;;
              *)    __mrk_key=unknown ;;
            esac
          fi ;;
        # It is neither '[' nor 'O' (and not another ESC, or the cap of the loop above
        # ran out): we do not know what sequence it is (e.g. a plain Alt+key, which
        # sends only ESC + the letter, with no CSI to drain) — the byte was
        # read in full, nothing is left over.
        *) __mrk_key=unknown ;;
      esac ;;
    '')  __mrk_key=enter ;;
    ' ') __mrk_key=space ;;
    # k/j/h/l are NOT translated here: they are CONTENT shortcuts, and each menu decides
    # what they do. The engine returns the character as it came.
  esac
  printf -v "$__mrk_var" '%s' "$__mrk_key"
}

# ----- Drawing lifecycle -----

_menu_trap_arm() {
  _MENU_TRAP_INT="$(trap -p INT)"
  _MENU_TRAP_TERM="$(trap -p TERM)"
  _MENU_TRAP_EXIT="$(trap -p EXIT)"
  # RETURN was left OUT on purpose, not by oversight: a 'trap ... RETURN'
  # armed here fires when returning from menu_begin — giving the cursor back at the exact
  # moment we just hid it — and then stays armed, firing
  # on every function that returns in the shell. Measured on macOS bash 3.2. INT, TERM and
  # EXIT cover the real damage (the user left with a terminal without a cursor); the normal
  # path is menu_end.
  trap 'menu_tty "\033[?25h"' INT TERM EXIT
}

_menu_trap_disarm() {
  eval "${_MENU_TRAP_INT:-trap - INT}"
  eval "${_MENU_TRAP_TERM:-trap - TERM}"
  eval "${_MENU_TRAP_EXIT:-trap - EXIT}"
  _MENU_TRAP_INT=""; _MENU_TRAP_TERM=""; _MENU_TRAP_EXIT=""
}

menu_begin() { # hides the cursor and guards against leaving it hidden
  _MENU_DRAWN=0
  _MENU_ACTIVE=1
  menu_tty '\033[?25l'
  _menu_trap_arm
}

menu_draw_begin() { # erases the previous drawing, if any (A2)
  # Goes up 'drawn' lines from WHERE THE CURSOR IS (the end of the previous drawing)
  # and clears from there downward. Relative movement is immune to terminal scroll.
  [ "${_MENU_DRAWN:-0}" -gt 0 ] && menu_tty '\033[%dA\r\033[J' "$_MENU_DRAWN"
  return 0
}

menu_draw_end() { # $1 how many lines the drawing occupied
  _MENU_DRAWN="${1:-0}"
}

menu_erase() { # takes the menu off the screen; the next drawing starts here
  menu_draw_begin
  _MENU_DRAWN=0
}

menu_end() { # gives the cursor back and disarms the protection
  menu_tty '\033[?25h'
  _menu_trap_disarm
  _MENU_DRAWN=0
  _MENU_ACTIVE=0
}

# ----- Questions -----

_menu_cursor_show() { menu_tty '\033[?25h'; }
_menu_cursor_restore() { # hides again only if there is still a menu on screen
  [ "${_MENU_ACTIVE:-0}" = 1 ] && menu_tty '\033[?25l'
  return 0
}

menu_confirm() { # $1 question  $2 warning (optional) — default is NO
  local __mc_ask="$1" __mc_warn="${2:-}" __mc_ans=""
  _menu_cursor_show
  [ -n "$__mc_warn" ] && menu_tty '  \033[1;33m⚠\033[0m  %s\n' "$__mc_warn"
  menu_tty '  %s \033[2m[s/N]\033[0m ' "$__mc_ask"
  IFS= read -r __mc_ans </dev/tty || __mc_ans=""
  _menu_cursor_restore
  # Default NO: a lone Enter destroys nothing.
  case "$__mc_ans" in
    s|S|sim|SIM|Sim) return 0 ;;
    *) return 1 ;;
  esac
}

menu_prompt() { # $1 variable  $2 label  $3 default (optional)
  local __mp_var="$1" __mp_label="$2" __mp_def="${3:-}" __mp_ans="" __mp_rc=0
  _menu_cursor_show
  if [ -n "$__mp_def" ]; then
    menu_tty '  %s \033[2m[Enter = %s]\033[0m\n  ▸ ' "$__mp_label" "$__mp_def"
  else
    menu_tty '  %s\n  ▸ ' "$__mp_label"
  fi
  IFS= read -r __mp_ans </dev/tty || { __mp_ans=""; __mp_rc=1; }
  _menu_cursor_restore
  [ -n "$__mp_ans" ] || __mp_ans="$__mp_def"
  printf -v "$__mp_var" '%s' "$__mp_ans"
  return "$__mp_rc"
}
