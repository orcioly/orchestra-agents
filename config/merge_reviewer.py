#!/usr/bin/env python3
"""Ensures the Orchestra 'reviewer' agent exists in the OpenCode config, automatically.

Usage: merge_reviewer.py <opencode.jsonc> <opencode.reviewer.jsonc>

- Idempotent: if 'agent.reviewer' already exists, it does nothing.
- JSONC-aware: respects comments (// and /* */) and trailing commas.
- Preserves the user's file: does a surgical insertion keeping comments/formatting.
  Only falls back to a full rewrite (plain JSON, with backup) if the insertion is unsafe.
- Never corrupts: if the existing config cannot be read safely, exits with
  code 2 so the caller shows manual instructions (fallback).

Exit codes:
  0  reviewer added (or file created from scratch)
  10 reviewer was already present (nothing to do)
  2  config exists but could not be read/merged safely (manual fallback)
  1  usage/argument error
"""
import json
import os
import sys


def strip_jsonc(text):
    """Removes // and /* */ comments and trailing commas, respecting strings."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':  # string: copy it whole, respecting escapes
            out.append(c)
            i += 1
            while i < n:
                out.append(text[i])
                if text[i] == '\\' and i + 1 < n:
                    out.append(text[i + 1])
                    i += 2
                    continue
                if text[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        if c == '/' and i + 1 < n and text[i + 1] == '/':  # line comment
            while i < n and text[i] != '\n':
                i += 1
            continue
        if c == '/' and i + 1 < n and text[i + 1] == '*':  # block comment
            i += 2
            while i + 1 < n and not (text[i] == '*' and text[i + 1] == '/'):
                i += 1
            i += 2
            continue
        out.append(c)
        i += 1
    cleaned = ''.join(out)
    # remove trailing commas before } or ]
    result = []
    j, m = 0, len(cleaned)
    while j < m:
        ch = cleaned[j]
        if ch == ',':
            k = j + 1
            while k < m and cleaned[k] in ' \t\r\n':
                k += 1
            if k < m and cleaned[k] in '}]':
                j += 1  # drop the comma
                continue
        result.append(ch)
        j += 1
    return ''.join(result)


def load_jsonc(path):
    with open(path, 'r', encoding='utf-8') as f:
        return json.loads(strip_jsonc(f.read()))


def find_open_braces(text):
    """Locates, ignoring strings/comments: the index right after the '{' of the
    root object and, if an 'agent' key exists at level 1, the index right after
    the '{' of the agent object. Returns (after_root, after_agent, agent_key_seen)."""
    i, n = 0, len(text)
    depth = 0
    after_root = None
    after_agent = None
    agent_key_seen = False
    pending_key = None  # last key (string) seen at level 1
    while i < n:
        c = text[i]
        if c == '"':
            start = i + 1
            i += 1
            buf = []
            while i < n:
                if text[i] == '\\' and i + 1 < n:
                    buf.append(text[i + 1])
                    i += 2
                    continue
                if text[i] == '"':
                    i += 1
                    break
                buf.append(text[i])
                i += 1
            if depth == 1:
                pending_key = ''.join(buf)
                if pending_key == 'agent':
                    agent_key_seen = True
            continue
        if c == '/' and i + 1 < n and text[i + 1] == '/':
            while i < n and text[i] != '\n':
                i += 1
            continue
        if c == '/' and i + 1 < n and text[i + 1] == '*':
            i += 2
            while i + 1 < n and not (text[i] == '*' and text[i + 1] == '/'):
                i += 1
            i += 2
            continue
        if c in '{[':
            if c == '{':
                depth += 1
                if depth == 1 and after_root is None:
                    after_root = i + 1
                elif depth == 2 and pending_key == 'agent' and after_agent is None:
                    after_agent = i + 1
            else:
                depth += 1
            pending_key = None
            i += 1
            continue
        if c in '}]':
            depth -= 1
            i += 1
            continue
        if c == ',' and depth == 1:
            pending_key = None
        i += 1
    return after_root, after_agent, agent_key_seen


def entry_text(reviewer, indent):
    """Serializes the "reviewer": {...} entry, indented for surgical insertion."""
    body = json.dumps(reviewer, indent=2, ensure_ascii=False)
    body = ('\n' + ' ' * indent).join(body.split('\n'))
    return '"reviewer": ' + body


def surgical_insert(text, reviewer):
    """Inserts the reviewer preserving comments. Returns the new text or None
    if there is no safe insertion point."""
    after_root, after_agent, agent_key_seen = find_open_braces(text)
    if after_agent is not None:
        # insert as the first key inside the existing agent object
        entry = entry_text(reviewer, 6)
        return text[:after_agent] + '\n    ' + entry + ',' + text[after_agent:]
    if not agent_key_seen and after_root is not None:
        # there is no "agent" block: create one at the top of the root object
        entry = entry_text(reviewer, 6)
        block = '\n  "agent": {\n    ' + entry + ',\n  },'
        return text[:after_root] + block + text[after_root:]
    # agent exists but not as an object (or root not found): not safe
    return None


def main():
    if len(sys.argv) != 3:
        print("uso: merge_reviewer.py <opencode.jsonc> <opencode.reviewer.jsonc>",
              file=sys.stderr)
        return 1
    cfg_path, tmpl_path = sys.argv[1], sys.argv[2]

    try:
        reviewer = load_jsonc(tmpl_path)['agent']['reviewer']
    except Exception as e:  # a broken template is a packaging error, not the user's
        print("template do reviewer ilegível: %s" % e, file=sys.stderr)
        return 1

    # file does not exist: create it from scratch, complete
    if not os.path.exists(cfg_path):
        os.makedirs(os.path.dirname(cfg_path), exist_ok=True)
        data = {"$schema": "https://opencode.ai/config.json",
                "agent": {"reviewer": reviewer}}
        with open(cfg_path, 'w', encoding='utf-8') as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
            f.write('\n')
        return 0

    # file exists: it must be read safely
    try:
        with open(cfg_path, 'r', encoding='utf-8') as f:
            raw = f.read()
        cfg = json.loads(strip_jsonc(raw))
    except Exception:
        return 2  # we could not understand the config: manual fallback

    if not isinstance(cfg, dict):
        return 2
    agent = cfg.get('agent')
    if isinstance(agent, dict) and 'reviewer' in agent:
        return 10  # already configured

    # 1) try surgical insertion (preserves the user's comments)
    new_text = None
    if not isinstance(agent, dict) or isinstance(agent, dict):
        new_text = surgical_insert(raw, reviewer)
    if new_text is not None:
        try:
            json.loads(strip_jsonc(new_text))  # validate the result
        except Exception:
            new_text = None
    if new_text is not None:
        with open(cfg_path + '.orchestra.bak', 'w', encoding='utf-8') as f:
            f.write(raw)
        with open(cfg_path, 'w', encoding='utf-8') as f:
            f.write(new_text)
        return 0

    # 2) fallback: merge into the object + rewrite (loses comments, with backup)
    if not isinstance(agent, dict):
        agent = {}
    agent['reviewer'] = reviewer
    cfg['agent'] = agent
    with open(cfg_path + '.orchestra.bak', 'w', encoding='utf-8') as f:
        f.write(raw)
    with open(cfg_path, 'w', encoding='utf-8') as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
        f.write('\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
