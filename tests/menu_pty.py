#!/usr/bin/env python3
"""Dirige o motor do menu de composição (select_team) por um pty e relata o
que observou: só o MOTOR — setas, redesenho, Esc solitário. Fluxos que
ALTERAM estado (adicionar, remover, trocar IA, Enter numa linha) ficam em
tests/menu_compose_pty.py (OAV2-26); classificação de tecla-fantasma via
drenagem fica em tests/menu_ghost_pty.py.

Existe porque os bugs que este teste cobre só aparecem num terminal DE VERDADE:

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

  3. Esc sozinho cancela (rc 2) e as 4 setas continuam navegando de verdade —
     sem isto, um Esc que fica "preso" (a mesma armadilha do item 1, num byte
     que não é seta) sairia batendo rc 2 quando não devia, ou as setas cima/
     esquerda/direita — nunca exercitadas antes — poderiam ter regredido sem
     ninguém notar (só a seta ↓ era dirigida aqui).

  4. "O pty respondeu" não é "a seta funcionou". Achado da revisão da
     OAV2-26: a versão anterior de caso_quatro_setas só media se ALGUM byte
     saiu depois de cada tecla — e como _st_render roda de novo a cada volta
     do laço, isso é verdade mesmo para uma seta 100% inerte. Prova: trocar
     'up) row=...' por 'up) : ;;' e 'left|right) _st_cycle' por
     'left|right) : ;;' em lib/core.sh deixava ↑/←/→ completamente sem
     efeito, e a suíte inteira continuava passando. Por isso cada seta agora
     tem uma asserção de EFEITO na tela (cursor ▸ na linha certa, ou destaque
     de IA na célula certa) — ver caso_quatro_setas.

ISOLAMENTO: ORCHESTRA_STATE aponta para um tempdir próprio, apagado no fim —
achado da OAV2-26. Sem isto, rodado standalone (fora de tests/smoke.sh, que
exporta o seu próprio ORCHESTRA_STATE antes de chamar este roteiro), o bash
filho herdava o ambiente do usuário e lib/core.sh caía no default
($HOME/.local/state/orchestra-agents), gravando o team.json de teste no
estado REAL do usuário — já rendeu 6 projetos-fantasma apagados à mão.

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
import tempfile
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


# seta em destaque (cyan) e célula de IA em destaque (reverso+negrito+cyan) —
# os mesmos códigos que _st_render (lib/core.sh) usa para marcar a linha e a
# IA correntes. Casar "na mesma linha de tela" (sem cruzar '\n') é o que
# garante que a seta/destaque achado é da linha certa, não de outra abaixo.
_SETA = "\033[1;36m▸\033[0m".encode("utf-8")
_DESTAQUE = "\033[1;7;36m".encode("utf-8")
_RESET = "\033[0m".encode("utf-8")


def cursor_na_linha(rotulo, tela):
    """O ▸ em destaque aparece antes de 'rotulo' (ex.: 'CODER'), sem '\\n'
    entre os dois — ou seja, na MESMA linha desenhada por _st_render."""
    padrao = re.escape(_SETA) + rb"[^\n]*?" + rotulo.encode("utf-8")
    return re.search(padrao, tela) is not None


def destaque_no_backend(rotulo, backend, tela):
    """A célula de IA 'backend' está em destaque na linha de 'rotulo'."""
    padrao = (rotulo.encode("utf-8") + rb"[^\n]*?" + re.escape(_DESTAQUE)
               + backend.encode("utf-8") + re.escape(_RESET))
    return re.search(padrao, tela) is not None


def caso_setas_e_redesenho(home):
    """Seta ↓ três vezes (líder → coder → reviewer → adicionar): cobre o
    redesenho relativo e a chegada em '+ adicionar agente'."""
    proj = tempfile.mkdtemp()
    state = tempfile.mkdtemp()
    try:
        pid, fd = _spawn(home, proj, state)
        drain(fd, 2.0)

        saida = []
        for _ in range(3):
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
            _close(pid, fd)
        except OSError:
            pass
    finally:
        import shutil
        shutil.rmtree(proj, ignore_errors=True)
        shutil.rmtree(state, ignore_errors=True)


def caso_quatro_setas(home):
    """As 4 setas navegam de verdade (não só ↓, que já é coberta acima), cada
    uma com um EFEITO OBSERVÁVEL na tela — não apenas "saiu algum byte" (ver
    item 4 do cabeçalho do módulo):
      ↓  líder    -> coder     (▸ chega na linha CODER)
      ↓  coder    -> reviewer  (▸ chega na linha REVIEWER)
      ↑  reviewer -> coder     (▸ volta para CODER)
      →  cicla a IA da linha corrente (coder): opencode -> codex
      ←  cicla de novo: codex -> claude — ←/→ chamam o MESMO _st_cycle em
         lib/core.sh, sempre avançando; não há "desfazer" no código real,
         então aqui a prova é a MUDANÇA de destaque, não o retorno à IA
         original."""
    proj = tempfile.mkdtemp()
    state = tempfile.mkdtemp()
    try:
        pid, fd = _spawn(home, proj, state)
        drain(fd, 2.0)

        def tecla(seq):
            try:
                os.write(fd, seq)
            except OSError:
                return None
            return drain(fd, 0.6)

        tela = tecla(b"\x1b[B")                        # desce: líder -> coder
        if not tela:
            print("MENU_MORREU"); return
        if cursor_na_linha("CODER", tela):
            print("DESCE_PARA_CODER")

        tela = tecla(b"\x1b[B")                        # desce: coder -> reviewer
        if not tela:
            print("MENU_MORREU"); return
        if cursor_na_linha("REVIEWER", tela):
            print("DESCE_PARA_REVIEWER")

        tela = tecla(b"\x1b[A")                        # sobe: reviewer -> coder
        if not tela:
            print("MENU_MORREU"); return
        if cursor_na_linha("CODER", tela):
            print("SOBE_PARA_CODER")

        tela = tecla(b"\x1b[C")                        # direita: opencode -> codex
        if not tela:
            print("MENU_MORREU"); return
        if destaque_no_backend("CODER", "codex", tela):
            print("DIREITA_TROCA_PARA_CODEX")

        tela = tecla(b"\x1b[D")                        # esquerda: codex -> claude
        if not tela:
            print("MENU_MORREU"); return
        if destaque_no_backend("CODER", "claude", tela):
            print("ESQUERDA_TROCA_PARA_CLAUDE")

        print("QUATRO_SETAS_VIVAS")
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


def caso_esc_cancela(home):
    """Esc sozinho cancela a sessão inteira: select_team devolve rc 2 e o
    'up' não abre o zellij."""
    proj = tempfile.mkdtemp()
    state = tempfile.mkdtemp()
    try:
        pid, fd = _spawn(home, proj, state)
        saida = drain(fd, 2.0)
        try:
            os.write(fd, b"\x1b")
        except OSError:
            print("MENU_MORREU")
            return
        saida += drain(fd, 1.5)
        _close(pid, fd)
        if b"RC=2" in saida:
            print("ESC_CANCELA")
    finally:
        import shutil
        shutil.rmtree(proj, ignore_errors=True)
        shutil.rmtree(state, ignore_errors=True)


def main():
    home, proj = sys.argv[1], sys.argv[2]
    caso_setas_e_redesenho(home)
    caso_quatro_setas(home)
    caso_esc_cancela(home)
    # 'proj' segue aceito por compatibilidade de chamada (tests/smoke.sh
    # passa um diretório de projeto); não é mais usado diretamente aqui —
    # cada caso sobe o seu próprio, isolado.
    _ = proj


if __name__ == "__main__":
    main()
