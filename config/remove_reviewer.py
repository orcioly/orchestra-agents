#!/usr/bin/env python3
"""Removes from the OpenCode config the 'reviewer' agent that Orchestra added.

Usage: remove_reviewer.py <opencode.jsonc>

Counterpart of merge_reviewer.py, so that 'orchestra uninstall' returns the
machine to its previous state. Only called when the merge recorded that IT was
the one that inserted the agent ($ORCHESTRA_STATE/opencode.reviewer.ours): a
reviewer that already belonged to the user never gets here.

Conservative on purpose: rewrites the file only when it is plain JSON
(no comments). With a commented JSONC, a surgical removal could ruin the
user's formatting and comments, so we prefer not to touch it and return 3,
which makes the caller print the manual instruction.

Exit codes:
  0  reviewer removed
  10 there was no reviewer (nothing to do)
  3  config has comments/JSONC: we do not touch it, the caller guides the manual edit
  2  unreadable config
  1  usage error
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from merge_reviewer import strip_jsonc  # noqa: E402


def main():
    if len(sys.argv) != 2:
        print("uso: remove_reviewer.py <opencode.jsonc>", file=sys.stderr)
        return 1
    cfg_path = sys.argv[1]
    if not os.path.exists(cfg_path):
        return 10

    try:
        with open(cfg_path, 'r', encoding='utf-8') as f:
            raw = f.read()
        cfg = json.loads(strip_jsonc(raw))
    except Exception:
        return 2
    if not isinstance(cfg, dict):
        return 2

    agent = cfg.get('agent')
    if not isinstance(agent, dict) or 'reviewer' not in agent:
        return 10

    # does the file have comments/trailing commas? then it is not ours to rewrite
    if strip_jsonc(raw).strip() != raw.strip():
        return 3

    del agent['reviewer']
    # an empty 'agent' block goes away too: it only held what Orchestra had put there
    if not agent:
        del cfg['agent']

    tmp = cfg_path + '.orchestra-tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
        f.write('\n')
    os.replace(tmp, cfg_path)
    return 0


if __name__ == '__main__':
    sys.exit(main())
