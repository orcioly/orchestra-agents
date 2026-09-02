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

ACHADO ao escrever este roteiro: _st_del ('d', lib/core.sh) remove o agente
IMEDIATAMENTE — não há 'menu_confirm' nenhuma no caminho, embora
'menu_confirm' exista em lib/menu.sh (linha 253) — está definida, mas sem
NENHUMA chamada no repositório inteiro. O caso 'del_sem_confirmacao' abaixo
testa o comportamento REAL (sem confirmação) e não o que seria mais seguro;
relatado, não corrigido — mexer em lib/core.sh está fora do escopo desta task.

ISOLAMENTO: cada caso sobe seu PRÓPRIO ORCHESTRA_STATE e projeto (tempdir,
apagados no fim) — nunca o do processo que chama este script (mesma razão
de tests/menu_ghost_pty.py).

BACKENDS FALSOS: agent_add recusa uma IA sem o binário no PATH
(backend_available). Dentro de tests/smoke.sh isso já vem coberto (FAKEBIN
no PATH antes de qualquer teste); para rodar este arquivo sozinho, ele sobe
os mesmos stubs num tempdir próprio e antepõe ao PATH.

Uso:  menu_compose_pty.py <ORCHESTRA_HOME>
Imprime 'CASE:<nome>=OK|FAIL:<motivo>' por caso e 'SESSAO_VIVA' no fim.
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
PROMPT_NOME = "nome do agente".encode("utf-8")
PROMPT_FUNCAO = "função — pronta".encode("utf-8")
PROMPT_IA = "qual IA roda esse agente".encode("utf-8")
PROMPT_DESC = "o que ele faz?".encode("utf-8")
MARK_CANCELADO = "cancelado".encode("utf-8")


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


class Sessao:
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
        self.saida, self.achou = drain_until(self.fd, [RENDER_MARK], deadline=8.0)

    def enviar(self, bts, markers=(RENDER_MARK,), deadline=8.0):
        """Escreve bytes e espera por QUALQUER marcador da lista. Devolve o
        marcador achado (ou None, se estourou o prazo)."""
        os.write(self.fd, bts)
        pedaco, achou = drain_until(self.fd, list(markers), deadline)
        self.saida += pedaco
        self.achou = achou
        return achou

    def texto(self):
        return self.saida.decode("utf-8", "replace")

    def fechar(self, extra=b"q"):
        try:
            if b"TEAM_FILE=" not in self.saida:
                if extra:
                    os.write(self.fd, extra)
                pedaco, _ = drain_until(self.fd, [b"TEAM_FILE="], deadline=8.0)
                self.saida += pedaco
            elif extra:
                os.write(self.fd, extra)
        except OSError:
            pass
        _close(self.pid, self.fd)

    def team_file(self):
        for linha in self.texto().splitlines():
            if linha.startswith("TEAM_FILE="):
                return linha.split("=", 1)[1].strip()
        return ""

    def rc(self):
        for linha in self.texto().splitlines():
            if linha.startswith("RC="):
                return linha.split("=", 1)[1].strip()
        return None

    def limpar(self):
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
    s = Sessao(home)
    try:
        if s.achou != RENDER_MARK:
            return "FAIL:sem_1o_render"
        if s.enviar(b"a", markers=(PROMPT_NOME,)) != PROMPT_NOME:
            return "FAIL:prompt_nome_nao_abriu"
        if s.enviar(b"compx\n", markers=(PROMPT_FUNCAO,)) != PROMPT_FUNCAO:
            return "FAIL:prompt_funcao_nao_abriu"
        if s.enviar(b"deploy-role\n", markers=(PROMPT_IA,)) != PROMPT_IA:
            return "FAIL:prompt_ia_nao_abriu"
        if s.enviar(b"opencode\n", markers=(PROMPT_DESC,)) != PROMPT_DESC:
            return "FAIL:prompt_descricao_nao_abriu"
        if s.enviar(b"Faz deploy para producao sem downtime\n",
                     markers=(RENDER_MARK,)) != RENDER_MARK:
            return "FAIL:nao_voltou_ao_menu"
        s.fechar(b"q")
        tf = s.team_file()
        if not tf or not os.path.isfile(tf):
            return "FAIL:sem_team_file"
        a = _agent(tf, "compx")
        if a is None:
            return "FAIL:agente_nao_entrou_no_team_json"
        if a.get("backend") != "opencode":
            return "FAIL:backend_errado:%s" % a.get("backend")
        if a.get("role") != "custom":
            return "FAIL:role_deveria_ser_custom:%s" % a.get("role")
        pf = a.get("prompt_file") or ""
        if pf != "prompts/compx.md":
            return "FAIL:prompt_file_inesperado:%s" % pf
        prompt_path = os.path.join(os.path.dirname(tf), pf)
        if not os.path.isfile(prompt_path):
            return "FAIL:prompt_nao_foi_gerado"
        conteudo = open(prompt_path, encoding="utf-8").read()
        if "Faz deploy para producao sem downtime" not in conteudo:
            return "FAIL:prompt_sem_a_descricao_digitada"
        if "compx" not in conteudo:
            return "FAIL:prompt_sem_o_nome_do_agente"
        return "OK"
    finally:
        s.limpar()


def case_add_cancel(home):
    """'a' com nome em branco: imprime 'cancelado' e NÃO cria agente nenhum."""
    s = Sessao(home)
    try:
        if s.enviar(b"a", markers=(PROMPT_NOME,)) != PROMPT_NOME:
            return "FAIL:prompt_nome_nao_abriu"
        # Enter sozinho = nome vazio. _st_add trata como cancelar, imprime
        # 'cancelado', dorme 1s e só ENTÃO redesenha — RENDER_MARK atravessa
        # esse sono sem depender de um limiar de tempo calibrado à mão.
        if s.enviar(b"\n", markers=(RENDER_MARK,), deadline=10.0) != RENDER_MARK:
            return "FAIL:nao_voltou_ao_menu"
        if MARK_CANCELADO not in s.saida:
            return "FAIL:nao_imprimiu_cancelado"
        s.fechar(b"q")
        tf = s.team_file()
        if not tf or not os.path.isfile(tf):
            return "FAIL:sem_team_file"
        if _agent_names(tf) != EXPECTED_AGENTS:
            return "FAIL:time_alterado:%s" % ",".join(_agent_names(tf))
        return "OK"
    finally:
        s.limpar()


def case_del_sem_confirmacao(home):
    """'d' na linha do coder: remove IMEDIATAMENTE — sem confirmação (achado,
    ver o comentário do módulo). O teste verifica o comportamento REAL."""
    s = Sessao(home)
    try:
        if s.enviar(b"\x1b[B") != RENDER_MARK:            # líder -> coder
            return "FAIL:nao_desceu_para_coder"
        antes = len(s.saida)
        if s.enviar(b"d") != RENDER_MARK:                 # remove e redesenha
            return "FAIL:nao_redesenhou_apos_d"
        pedaco = s.saida[antes:]
        # nenhum prompt de confirmação apareceu no meio do caminho — se
        # existisse, teria enviado uma pergunta ANTES do redesenho.
        if b"[s/N]" in pedaco:
            return "FAIL:apareceu_confirmacao_onde_nao_deveria(codigo_mudou?)"
        s.fechar(b"q")
        tf = s.team_file()
        if not tf or not os.path.isfile(tf):
            return "FAIL:sem_team_file"
        nomes = _agent_names(tf)
        if nomes != ["reviewer"]:
            return "FAIL:coder_nao_sumiu:%s" % ",".join(nomes)
        return "OK"
    finally:
        s.limpar()


def case_space_nao_persiste_no_quit(home):
    """Espaço troca a IA da linha em memória; saindo com 'q' (cancelamento),
    a troca é DESCARTADA — team.json continua com o backend original."""
    s = Sessao(home)
    try:
        if s.enviar(b"\x1b[B") != RENDER_MARK:             # líder -> coder
            return "FAIL:nao_desceu_para_coder"
        if s.enviar(b" ") != RENDER_MARK:                  # cicla a IA
            return "FAIL:nao_redesenhou_apos_espaco"
        s.fechar(b"q")
        if s.rc() != "2":
            return "FAIL:rc_deveria_ser_2_ao_sair_por_q:%s" % s.rc()
        tf = s.team_file()
        if not tf or not os.path.isfile(tf):
            return "FAIL:sem_team_file"
        a = _agent(tf, "coder")
        if a is None or a.get("backend") != "opencode":
            return "FAIL:backend_coder_mudou_sem_persistir:%s" % (a or {}).get("backend")
        return "OK"
    finally:
        s.limpar()


def case_enter_persiste(home):
    """Espaço troca a IA, Enter NA LINHA (não em 'adicionar'/'sair') sai do
    laço sem cancelar e persiste via team_replace — team.json reflete a
    troca, e select_team devolve rc 0 (não 2)."""
    s = Sessao(home)
    try:
        if s.enviar(b"\x1b[B") != RENDER_MARK:             # líder -> coder
            return "FAIL:nao_desceu_para_coder"
        if s.enviar(b" ") != RENDER_MARK:                  # opencode -> codex
            return "FAIL:nao_redesenhou_apos_espaco"
        s.enviar(b"\r", markers=(b"TEAM_FILE=",), deadline=8.0)
        s.fechar(extra=b"")
        if s.rc() != "0":
            return "FAIL:rc_deveria_ser_0_ao_sair_por_enter:%s" % s.rc()
        tf = s.team_file()
        if not tf or not os.path.isfile(tf):
            return "FAIL:sem_team_file"
        a = _agent(tf, "coder")
        if a is None or a.get("backend") != "codex":
            return "FAIL:backend_coder_nao_persistiu:%s" % (a or {}).get("backend")
        return "OK"
    finally:
        s.limpar()


CASES = [
    ("add_full", case_add_full),
    ("add_cancel", case_add_cancel),
    ("del_sem_confirmacao", case_del_sem_confirmacao),
    ("space_nao_persiste_no_quit", case_space_nao_persiste_no_quit),
    ("enter_persiste", case_enter_persiste),
]


def main():
    home = sys.argv[1]
    for nome, fn in CASES:
        try:
            resultado = fn(home)
        except Exception as exc:  # nunca deixar o roteiro morrer calado
            resultado = "FAIL:excecao:%s" % exc
        print("CASE:%s=%s" % (nome, resultado))
    print("SESSAO_VIVA")


if __name__ == "__main__":
    main()
