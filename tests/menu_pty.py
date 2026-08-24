#!/usr/bin/env python3
"""Dirige o menu de composição (select_team) por um pty e relata o que observou.

Existe porque os dois bugs que este teste cobre só aparecem num terminal DE VERDADE:

  1. A seta viva. O bash 3.2 — o que o macOS traz em /bin/bash — recusa timeout
     fracionário em 'read -t': devolve 1 na hora e deixa a variável vazia, que é
     exatamente o caso "Esc sozinho". Resultado: TODA seta fechava o menu, e o
     select_team voltava 2, então o zellij nem abria. Rodar a função num shell
     qualquer não pega isso: sem pty, o menu nem chega a ler tecla.

  2. O redesenho sem sobra. Com âncora absoluta ('\033[s' / '\033[u') a posição
     guardada é a LINHA DA TELA; quando o menu não cabe na janela o terminal rola,
     a âncora passa a apontar para o meio do bloco e o redesenho começa lá,
     deixando o começo do menu antigo acima. Por isso a janela aqui é curta de
     propósito: é o scroll que dispara o bug.

Uso:  menu_pty.py <ORCHESTRA_HOME> <projeto>
Imprime marcadores, uma por linha, que o smoke.sh casa com 'case'.
"""

import fcntl
import os
import pty
import re
import select
import struct
import sys
import termios
import time

# janela curta de propósito: o menu não cabe e o terminal ROLA
ROWS, COLS = 14, 90


def drain(fd, seconds=0.8):
    """Lê do pty até ficar quieto por 0.3s (ou estourar o prazo)."""
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


def main():
    home, proj = sys.argv[1], sys.argv[2]
    script = "\n".join([
        'export ORCHESTRA_HOME="%s"' % home,
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
    drain(fd, 2.0)

    saida = []
    for _ in range(3):                     # líder → coder → reviewer → adicionar
        try:
            os.write(fd, b"\x1b[B")
        except OSError:
            print("MENU_MORREU")
            return
        pedaco = drain(fd, 0.8)
        if not pedaco:                     # o menu saiu do ar: pty sem resposta
            print("MENU_MORREU")
            return
        if b"invalid timeout" in pedaco:
            print("TIMEOUT_INVALIDO")
        saida.append(pedaco)

    tudo = b"".join(saida)
    print("SETA_VIVA")
    if b"\x1b[u" in tudo:
        print("ANCORA_ABSOLUTA")
    if re.search(rb"\x1b\[\d+A", tudo):
        print("REDESENHO_RELATIVO")
    # a seta (▸ = U+25B8) parada na linha do '+ adicionar agente'
    if re.search("\033\\[1;36m▸\033\\[0m \033\\[1m\\+".encode("utf-8"), tudo):
        print("CHEGOU_NO_ADICIONAR")

    try:
        os.write(fd, b"q")
        drain(fd, 0.8)
        os.close(fd)
    except OSError:
        pass


if __name__ == "__main__":
    main()
