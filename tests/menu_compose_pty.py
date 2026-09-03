#!/usr/bin/env python3
"""Dirige select_team pelos fluxos que ALTERAM (ou poderiam alterar) o
time — 'a' até o fim, 'a' cancelado, 'd', Espaço e Enter numa linha de
agente — o ponto cego que tests/menu_pty.py (setas/redesenho) sempre
deixou: aquele roteiro nunca apertava 'a', 'd', Espaço ou Enter, só a seta
↓ até '+ adicionar agente' e 'q' (OAV2-26).

Por que em arquivo PRÓPRIO, e não em tests/menu_pty.py (motor: setas,
redesenho, Esc) nem em tests/menu_ghost_pty.py (classificação de tecla via
drenagem, com SESSION_CASES no mesmo espírito de dirigir select_team de
verdade): este roteiro inspeciona EFEITO DE ESTADO de teclas que o usuário
aperta de propósito — team.json e o prompt_file gerado —, não sobra de byte
nem redesenho. Reaproveita o padrão de isolamento e drain_until (marcador em
vez de silêncio) já validado em tests/menu_ghost_pty.py.

OAV2-27: o achado registrado aqui ao escrever o roteiro original — _st_del
('d', lib/core.sh) removia o agente IMEDIATAMENTE, sem nenhuma chamada a
'menu_confirm' (lib/menu.sh linha 253) em todo o repositório — foi corrigido.
'd' agora pede confirmação (nome do agente visível na pergunta, default NÃO:
Enter sozinho não remove) antes de chamar agent_rm. O caso
'delete_with_confirmation' abaixo cobre 's'/'n'/Enter sozinho; substitui o
antigo 'del_sem_confirmacao'.

Não há aqui um caso de "tecla fantasma parou na confirmação": com o motor
ATUAL a sequência ghost já é drenada como 'unknown' antes de chegar a 'd', e
um caso que manda essa sequência daqui nunca exercita _st_del de verdade —
achado da revisão da rodada 3 (o revisor reverteu _st_del para a versão sem
confirmação e o caso continuou 'OK', prova de que ele não testava nada). A
segunda camada (a sobra REALMENTE chegando a 'd', contra uma cópia do motor
PRÉ-OAV2-25) é responsabilidade de 'run_session_case' em
tests/menu_ghost_pty.py, que agora devolve 'FAIL:delete_prompt_leaked' com
precisão quando isso acontece.

ISOLAMENTO: cada caso sobe seu PRÓPRIO ORCHESTRA_STATE e projeto (tempdir,
apagados no fim) — nunca o do processo que chama este script (mesma razão
de tests/menu_ghost_pty.py).

BACKENDS FALSOS: agent_add recusa uma IA sem o binário no PATH
(backend_available). Dentro de tests/smoke.sh isso já vem coberto (FAKEBIN
no PATH antes de qualquer teste); para rodar este arquivo sozinho, ele sobe
os mesmos stubs num tempdir próprio e antepõe ao PATH.

Uso:  menu_compose_pty.py <ORCHESTRA_HOME>
Imprime 'CASE:<name>=OK|FAIL:<motivo>' por caso e 'SESSION_ALIVE' no fim.
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

# mesma janela curta de tests/menu_pty.py (é o scroll que dispara o bug de
# duplicação do menu, ver o cabeçalho daquele arquivo) — medido: os cinco
# casos abaixo passam em 14x90 tanto quanto passavam em 24x90, então não há
# motivo para uma janela maior aqui.
ROWS, COLS = 14, 90
EXPECTED_AGENTS = ["coder", "reviewer"]

# aparecem na tela sempre que _st_render desenha o menu (1º desenho da
# subida, e todo redesenho depois de uma ação) — marcador de "voltou ao
# laço principal", em vez de esperar por silêncio.
RENDER_MARK = "q sai sem abrir".encode("utf-8")
PROMPT_NAME = "nome do agente".encode("utf-8")
PROMPT_ROLE = "função — pronta".encode("utf-8")
PROMPT_BACKEND = "qual IA roda esse agente".encode("utf-8")
PROMPT_DESCRIPTION = "o que ele faz?".encode("utf-8")
MARK_CANCELLED = "cancelado".encode("utf-8")
# menu_confirm() (lib/menu.sh) sempre termina a pergunta com este sufixo,
# independente do texto da pergunta em si.
MARK_CONFIRM = "[s/N]".encode("utf-8")


def _fake_backends():
    """Stubs de claude/opencode/codex num tempdir próprio, para este arquivo
    rodar sozinho sem depender do FAKEBIN que tests/smoke.sh já prepara."""
    d = tempfile.mkdtemp()
    for b in ("claude", "opencode", "codex"):
        p = os.path.join(d, b)
        with open(p, "w") as f:
            f.write("#!/bin/sh\necho stub\n")
        os.chmod(p, 0o755)
    return d


def drain(fd, seconds=1.2, quiet=0.3):
    """Lê do pty até ficar quieto por 'quiet's (ou estourar o prazo)."""
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
    """Lê do pty até QUALQUER byte de 'markers' aparecer no acumulado, ou
    estourar o prazo. Substitui esperar por SILÊNCIO: cada passo do fluxo de
    'adicionar' tem um prompt de tela PRÓPRIO (nome → função → IA →
    descrição → volta ao menu), e esperar pelo TEXTO daquele prompt em vez
    de por um tempo fixo atravessa até o 'sleep 1' que _st_add faz ao
    cancelar (lib/core.sh) sem precisar calibrar limiar nenhum — a mesma
    técnica (e o mesmo motivo) de tests/menu_ghost_pty.py (OAV2-26)."""
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
    """Um select_team isolado, dirigido por pty. Cada caso cria a sua."""

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
        """Escreve bytes e espera por QUALQUER marcador da lista. Devolve o
        marcador achado (ou None, se estourou o prazo)."""
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
# Casos
# ---------------------------------------------------------------------------

def case_add_full(home):
    """'a' de ponta a ponta: nome, função (não-preset, então pede descrição),
    IA e descrição — confirma o agente novo no team.json (role=custom,
    prompt_file) E o conteúdo do prompt gerado."""
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
    """'a' com nome em branco: imprime 'cancelado' e NÃO cria agente nenhum."""
    s = Session(home)
    try:
        if s.send(b"a", markers=(PROMPT_NAME,)) != PROMPT_NAME:
            return "FAIL:name_prompt_did_not_open"
        # Enter sozinho = nome vazio. _st_add trata como cancelar, imprime
        # 'cancelado', dorme 1s e só ENTÃO redesenha — RENDER_MARK atravessa
        # esse sono sem depender de um limiar de tempo calibrado à mão.
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
    """Sobe uma sessão própria, aperta 'd' na linha do coder e responde a
    confirmação com 'response' (bytes). Devolve os nomes de agentes que
    sobraram no team.json ao final, ou uma string 'FAIL:...'."""
    s = Session(home)
    try:
        if s.send(b"\x1b[B") != RENDER_MARK:                # líder -> coder
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
    """'d' na linha do coder pede confirmação — nome do agente visível na
    pergunta, default NÃO (lib/menu.sh menu_confirm). 'n' e Enter sozinho
    preservam o time; só 's' remove (OAV2-27). Substitui o antigo
    'del_sem_confirmacao': a remoção deixou de ser imediata."""
    for response, expected, label in (
        (b"n\n", EXPECTED_AGENTS, "n_does_not_remove"),
        (b"\n", EXPECTED_AGENTS, "enter_alone_does_not_remove"),  # default NÃO
        (b"s\n", ["reviewer"], "s_removes"),
    ):
        names = _delete_with_response(home, response)
        if isinstance(names, str):
            return "FAIL:%s:%s" % (label, names)
        if names != expected:
            return "FAIL:%s:%s" % (label, ",".join(names))
    return "OK"


def case_space_does_not_persist_on_quit(home):
    """Espaço troca a IA da linha em memória; saindo com 'q' (cancelamento),
    a troca é DESCARTADA — team.json continua com o backend original."""
    s = Session(home)
    try:
        if s.send(b"\x1b[B") != RENDER_MARK:               # líder -> coder
            return "FAIL:did_not_move_down_to_coder"
        if s.send(b" ") != RENDER_MARK:                    # cicla a IA
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
    """Espaço troca a IA, Enter NA LINHA (não em 'adicionar'/'sair') sai do
    laço sem cancelar e persiste via team_replace — team.json reflete a
    troca, e select_team devolve rc 0 (não 2)."""
    s = Session(home)
    try:
        if s.send(b"\x1b[B") != RENDER_MARK:               # líder -> coder
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
        except Exception as exc:  # nunca deixar o roteiro morrer calado
            result = "FAIL:exception:%s" % exc
        print("CASE:%s=%s" % (name, result))
    print("SESSION_ALIVE")


if __name__ == "__main__":
    main()
