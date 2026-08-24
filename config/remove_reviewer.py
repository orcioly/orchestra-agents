#!/usr/bin/env python3
"""Remove do config do OpenCode o agente 'reviewer' que o Orchestra adicionou.

Uso: remove_reviewer.py <opencode.jsonc>

Contrapartida do merge_reviewer.py, para que 'orchestra uninstall' devolva a
máquina ao estado anterior. Só é chamado quando o merge registrou que FOI ELE
quem inseriu o agente ($ORCHESTRA_STATE/opencode.reviewer.ours) — um reviewer
que já era do usuário nunca chega aqui.

Conservador de propósito: reescreve o arquivo apenas quando ele é JSON puro
(sem comentários). Com JSONC comentado a remoção cirúrgica poderia estragar a
formatação e os comentários do usuário, então preferimos não tocar e devolver 3,
que faz o chamador imprimir a instrução manual.

Exit codes:
  0  reviewer removido
  10 não havia reviewer (nada a fazer)
  3  config tem comentários/JSONC — não mexemos, o chamador orienta à mão
  2  config ilegível
  1  erro de uso
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

    # o arquivo tem comentários/vírgulas finais? então não é nosso para reescrever
    if strip_jsonc(raw).strip() != raw.strip():
        return 3

    del agent['reviewer']
    # bloco 'agent' vazio some junto: era só o que o Orchestra tinha posto lá
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
