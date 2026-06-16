#!/usr/bin/env python3
"""Garante o agente 'reviewer' do Orchestra no config do OpenCode — automático.

Uso: merge_reviewer.py <opencode.jsonc> <opencode.reviewer.jsonc>

- Idempotente: se 'agent.reviewer' já existe, não faz nada.
- JSONC-aware: respeita comentários (// e /* */) e vírgulas finais (trailing commas).
- Preserva o arquivo do usuário: faz inserção cirúrgica mantendo comentários/formatação.
  Só recorre a reescrita completa (JSON puro, com backup) se a inserção não for segura.
- Nunca corrompe: se o config existente não puder ser lido com segurança, sai com
  código 2 para o chamador exibir instruções manuais (fallback).

Exit codes:
  0  reviewer adicionado (ou arquivo criado do zero)
  10 reviewer já estava presente (nada a fazer)
  2  config existe mas não pôde ser lido/mesclado com segurança (fallback manual)
  1  erro de uso/argumentos
"""
import json
import os
import sys


def strip_jsonc(text):
    """Remove comentários // e /* */ e vírgulas finais, respeitando strings."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':  # string: copia integralmente, respeitando escapes
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
        if c == '/' and i + 1 < n and text[i + 1] == '/':  # comentário de linha
            while i < n and text[i] != '\n':
                i += 1
            continue
        if c == '/' and i + 1 < n and text[i + 1] == '*':  # comentário de bloco
            i += 2
            while i + 1 < n and not (text[i] == '*' and text[i + 1] == '/'):
                i += 1
            i += 2
            continue
        out.append(c)
        i += 1
    cleaned = ''.join(out)
    # remove vírgulas finais antes de } ou ]
    result = []
    j, m = 0, len(cleaned)
    while j < m:
        ch = cleaned[j]
        if ch == ',':
            k = j + 1
            while k < m and cleaned[k] in ' \t\r\n':
                k += 1
            if k < m and cleaned[k] in '}]':
                j += 1  # descarta a vírgula
                continue
        result.append(ch)
        j += 1
    return ''.join(result)


def load_jsonc(path):
    with open(path, 'r', encoding='utf-8') as f:
        return json.loads(strip_jsonc(f.read()))


def find_open_braces(text):
    """Localiza, ignorando strings/comentários: índice logo após o '{' do objeto
    raiz e, se existir uma chave 'agent' no nível 1, o índice logo após o '{'
    do objeto agent. Retorna (after_root, after_agent, agent_key_seen)."""
    i, n = 0, len(text)
    depth = 0
    after_root = None
    after_agent = None
    agent_key_seen = False
    pending_key = None  # última chave (string) vista no nível 1
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
    """Serializa a entrada "reviewer": {...} indentada para inserção cirúrgica."""
    body = json.dumps(reviewer, indent=2, ensure_ascii=False)
    body = ('\n' + ' ' * indent).join(body.split('\n'))
    return '"reviewer": ' + body


def surgical_insert(text, reviewer):
    """Insere o reviewer preservando comentários. Retorna o novo texto ou None
    se não houver ponto de inserção seguro."""
    after_root, after_agent, agent_key_seen = find_open_braces(text)
    if after_agent is not None:
        # insere como primeira chave dentro do objeto agent existente
        entry = entry_text(reviewer, 6)
        return text[:after_agent] + '\n    ' + entry + ',' + text[after_agent:]
    if not agent_key_seen and after_root is not None:
        # não há bloco "agent": cria um no topo do objeto raiz
        entry = entry_text(reviewer, 6)
        block = '\n  "agent": {\n    ' + entry + ',\n  },'
        return text[:after_root] + block + text[after_root:]
    # agent existe mas não como objeto (ou raiz não encontrada): não é seguro
    return None


def main():
    if len(sys.argv) != 3:
        print("uso: merge_reviewer.py <opencode.jsonc> <opencode.reviewer.jsonc>",
              file=sys.stderr)
        return 1
    cfg_path, tmpl_path = sys.argv[1], sys.argv[2]

    try:
        reviewer = load_jsonc(tmpl_path)['agent']['reviewer']
    except Exception as e:  # template quebrado é erro de empacotamento, não do usuário
        print("template do reviewer ilegível: %s" % e, file=sys.stderr)
        return 1

    # arquivo não existe: cria do zero, completo
    if not os.path.exists(cfg_path):
        os.makedirs(os.path.dirname(cfg_path), exist_ok=True)
        data = {"$schema": "https://opencode.ai/config.json",
                "agent": {"reviewer": reviewer}}
        with open(cfg_path, 'w', encoding='utf-8') as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
            f.write('\n')
        return 0

    # arquivo existe: precisa ser lido com segurança
    try:
        with open(cfg_path, 'r', encoding='utf-8') as f:
            raw = f.read()
        cfg = json.loads(strip_jsonc(raw))
    except Exception:
        return 2  # não conseguimos entender o config — fallback manual

    if not isinstance(cfg, dict):
        return 2
    agent = cfg.get('agent')
    if isinstance(agent, dict) and 'reviewer' in agent:
        return 10  # já configurado

    # 1) tenta inserção cirúrgica (preserva comentários do usuário)
    new_text = None
    if not isinstance(agent, dict) or isinstance(agent, dict):
        new_text = surgical_insert(raw, reviewer)
    if new_text is not None:
        try:
            json.loads(strip_jsonc(new_text))  # valida o resultado
        except Exception:
            new_text = None
    if new_text is not None:
        with open(cfg_path + '.orchestra.bak', 'w', encoding='utf-8') as f:
            f.write(raw)
        with open(cfg_path, 'w', encoding='utf-8') as f:
            f.write(new_text)
        return 0

    # 2) fallback: merge no objeto + reescrita (perde comentários, com backup)
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
