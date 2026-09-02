#!/usr/bin/env python3
"""Dirige select_team (e sonda menu_read_key direto) com teclas-FANTASMA (OAV2-25).

O alvo NÃO é um terminal específico: o Orchestra roda em macOS, Linux e WSL, e
cada terminal codifica Alt/Shift/Ctrl+seta de um jeito diferente. Duas famílias
de codificação, ambas com MAIS de 2 bytes depois do ESC — o que o motor antigo
só lia 2, deixando sobra:

  CSI COM PARÂMETRO DE MODIFICADOR ('\\e[1;3D')   — GNOME Terminal/VTE, Konsole,
    kitty, alacritty (Linux); Windows Terminal + WSL. É a forma mais comum em
    Linux/WSL.
  ESC-PREFIXADO ('\\e\\e[D')                        — xterm com metaSendsEscape,
    tmux, screen, iTerm2 "Esc+", Terminal.app com Option=Meta.

Quando a sobra contém uma letra que bate com um atalho do menu, ela dispara
sozinha: o 'D' de qualquer Esquerda-com-modificador cai no ramo 'd/D' e apaga
o agente sob o cursor (agent_rm grava direto, sem confirmação); o 'A' de
qualquer Cima-com-modificador cai no ramo 'a/A' e abre o prompt de adicionar.
Os SESSION_CASES abaixo dirigem select_team de verdade, por pty, um processo
por caso (sem estado compartilhado entre eles), e olham o EFEITO REAL —
team.json ou o prompt "nome do agente" na tela — não a tecla devolvida.

Outra família não tem NENHUMA letra vinculada a atalho dentro da sequência:
Delete/PageUp/F5 terminam em '~', o protocolo de teclado do kitty (CSI 'u')
termina em 'u', SS3 em modo aplicação é 'O' + uma letra que nunca aparece
sozinha. Uma sobra de byte destas é INVISÍVEL em select_team — nenhum desses
bytes bate com d/D/a/A/k/j/h/l/q/Q, então o efeito em team.json/tela é
IDÊNTICO com ou sem a sobra (o byte perdido vira só mais uma iteração de
'unknown' sem custo, e o menu segue normal). Por isso os PROBE_CASES abaixo
testam a FUNÇÃO diretamente: escrevem a sequência suspeita seguida de uma
tecla solta CONHECIDA ('x', que também não tem atalho — só interessa SE ela
chega inteira, não o que ela faria) e comparam o que menu_read_key devolve
para essa tecla seguinte. Se sobrou byte, o 'x' não é a próxima coisa lida.

Duas entradas a mais em PROBE_CASES vieram da REVISÃO da OAV2-25, não de um
teclado real — o revisor achou dois furos na própria drenagem, o mesmo modo
de falha (byte sobra, vira comando) numa forma que nenhuma tecla emite hoje:
  'space_in_csi'  ('\\e[2 q', estilo de cursor) — um espaço (0x20) DENTRO da
    CSI, lido sem 'IFS=', vira variável VAZIA (bash usa $IFS pra separar
    campos), e o laço confunde "li um espaço" com "não chegou nada".
  'long_params'   (17 bytes de parâmetro) — o teto de bytes da drenagem
    (_menu_drain_csi) era 16, e o produtor real mais longo (mouse SGR) já
    chega a 15: quase raspando. Ficam como regressão conhecida — se
    voltarem, o CI tem de pegar.

Fica em arquivo PRÓPRIO, e não em tests/menu_pty.py: aquele arquivo cobre o
MOTOR (setas, redesenho, Esc), e este roteiro também precisa inspecionar o
team.json produzido, finalidade diferente do que ele cobre.

OAV2-26 ampliou esta matriz com três itens medidos na revisão da OAV2-25:
  - shift_up e ctrl_left entram em SESSION_CASES: a sobra que eles deixam no
    motor ANTIGO é 'A'/'D' — os DOIS atalhos perigosos (abrir 'adicionar',
    apagar sem confirmação) que shift_left/ctrl_up já provavam por outro
    lado (esquerda/cima); cima/esquerda cobrem os quatro sentidos.
  - DEAD_KEY_BATCH cobre Delete/Home/End/PageUp/F1/Shift+Baixo-Direita/
    Ctrl+Baixo-Direita/setas em modo aplicação — por inspeção, NENHUMA delas
    deixa sobra vinculada a atalho, nem no motor antigo, então region num
    ÚNICO processo (em vez de um por tecla) sem perder cobertura.
  - PROBE_K1_CASES ganha 'alt_space': Alt+Espaço ('\e ') é a única forma que
    bate exatamente em lib/menu.sh:129/:146, as duas linhas que a matriz
    antiga (13 casos) não cobria — removido o 'IFS=' delas, os 13 seguiam
    13/13 verde (medido). O veredito aqui é a 1ª leitura (K1), não a 2ª: o
    defeito é a sequência virar 'esc' (cancela a sessão) e não um byte
    sobrando para a tecla seguinte.
  - drain_until troca espera por SILÊNCIO por espera por MARCADOR em três
    pontos (1º render, cancelamento do prompt 'adicionar', TEAM_FILE= no
    fim) — mesmo motivo do 'quiet=1.5' que ela substitui: atravessar o
    'sleep 1' de _st_add sem depender de um limiar de tempo calibrado à mão.
    O envio da sequência SUSPEITA continua por silêncio (função 'enviar',
    inalterada nesse ponto): drenar por marcador ali pararia no PRIMEIRO
    redesenho, que no motor antigo acontece VÁRIAS vezes ANTES do atalho
    vazar (cada byte sobrando é uma iteração de laço com seu próprio
    _st_render) — trocar a técnica ali faria o teste parar de pegar,
    exatamente o oposto do que a Regra 4 pede.

ISOLAMENTO: cada caso sobe seu PRÓPRIO ORCHESTRA_STATE (tempdir, apagado no
fim) — nunca o do processo que chama este script. Rodado standalone, sem
passar pelo tests/smoke.sh (que exporta o seu próprio ORCHESTRA_STATE antes de
invocar este roteiro), sem isto o bash filho herdaria o ambiente do usuário e
lib/core.sh cairia no default ($HOME/.local/state/orchestra-agents), gravando
o team.json de teste no estado REAL do usuário. Nenhum teste pode encostar
nisso.

Uso:  menu_ghost_pty.py <ORCHESTRA_HOME>
Imprime uma linha 'CASE:<nome>=OK|FAIL:<motivo>' ou 'PROBE:<nome>=OK|FAIL:<motivo>'
por caso, e 'SESSAO_VIVA' no fim — o smoke.sh casa com 'case'/'grep'.
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

ROWS, COLS = 24, 90
# time padrão que team_ensure cria (líder + coder + reviewer, ver CLAUDE.md).
# Fonte da verdade dos casos por sessão é o team.json, não a tela — qualquer
# sequência suspeita, drenada ou não, tem de deixar exatamente ESTES dois
# agentes, nem um a mais nem a menos.
EXPECTED_AGENTS = ["coder", "reviewer"]


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


# aparece toda vez que _st_render desenha a tela do menu — inclusive no 1º
# desenho da subida e no redesenho que segue o 'sleep 1' de _st_add cancelado.
RENDER_MARK = "q sai sem abrir".encode("utf-8")
# aparece quando _st_add abre de verdade (o prompt de nome do agente).
PROMPT_MARK = "nome do agente".encode("utf-8")


def drain_until(fd, markers, deadline=8.0):
    """Lê do pty até QUALQUER byte de 'markers' aparecer no acumulado, ou
    estourar o prazo — substitui esperar por SILÊNCIO nos três pontos que
    não dependem de observar MÚLTIPLOS redesenhos em sequência (1º render,
    cancelamento do prompt 'adicionar', TEAM_FILE= no fim). Ver o porquê de
    NÃO usar isto no envio da sequência suspeita no comentário do módulo.
    Devolve (bytes lidos, marcador achado ou None)."""
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
    """Sobe um bash num pty novo rodando 'script'. Devolve (pid, fd)."""
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


def _team_agent_names(team_file):
    """Nomes dos agentes (sem o líder) direto do team.json — arquivo, não tela."""
    with open(team_file) as f:
        data = json.load(f)
    return sorted(a.get("name", "") for a in data.get("agents", []))


# ---------------------------------------------------------------------------
# Casos por SESSÃO: dirigem select_team de verdade. (nome, bytes, o que a
# sobra dispararia no motor antigo — 'delete' pelo ramo d/D, 'add' pelo a/A)
# ---------------------------------------------------------------------------

SESSION_CASES = [
    ("shift_left",      b"\x1b[1;2D",  "delete"),  # Shift+Esquerda — original
    ("ctrl_up",         b"\x1b[1;5A",  "add"),      # Ctrl+Cima — original
    ("alt_left_csi",    b"\x1b[1;3D",  "delete"),  # Alt+Esquerda, CSI c/ parâmetro (Linux/WSL)
    ("alt_up_csi",      b"\x1b[1;3A",  "add"),      # Alt+Cima, CSI c/ parâmetro (Linux/WSL)
    ("alt_left_escpfx", b"\x1b\x1b[D", "delete"),  # Alt+Esquerda, ESC-prefixado (tmux/screen/xterm/macOS)
    ("alt_up_escpfx",   b"\x1b\x1b[A", "add"),      # Alt+Cima, ESC-prefixado (tmux/screen/xterm/macOS)
    # OAV2-26: os dois sentidos que faltavam (a família CSI já cobre
    # esquerda/cima acima) — Shift+Cima sobra 'A' (abre 'adicionar'),
    # Ctrl+Esquerda sobra 'D' (apaga sem confirmação).
    ("shift_up",        b"\x1b[1;2A",  "add"),
    ("ctrl_left",       b"\x1b[1;5D",  "delete"),
]

# OAV2-26: teclas que a task pede cobrir mas que, por inspeção, NUNCA deixam
# sobra vinculada a atalho — nem no motor ANTIGO (conferido caso a caso: a
# sobra de cada uma cai em ';', dígitos, '~', 'B' ou 'C', nenhuma bate com
# a/d/k/j/h/l/q). Testadas juntas em run_dead_key_batch, um processo só, em
# vez de um por tecla — ver o comentário daquela função para o porquê.
DEAD_KEY_BATCH = [
    ("home",        b"\x1b[H"),
    ("end",         b"\x1b[F"),
    ("f1",          b"\x1bOP"),
    ("pageup",      b"\x1b[5~"),
    ("delete",      b"\x1b[3~"),
    ("shift_down",  b"\x1b[1;2B"),
    ("shift_right", b"\x1b[1;2C"),
    ("ctrl_down",   b"\x1b[1;5B"),
    ("ctrl_right",  b"\x1b[1;5C"),
    ("ss3_up",      b"\x1bOA"),   # seta em modo aplicação (DECCKM)
    ("ss3_down",    b"\x1bOB"),
    ("ss3_left",    b"\x1bOD"),
    ("ss3_right",   b"\x1bOC"),
]


def run_session_case(home, seq, kind):
    """Sobe um select_team isolado (projeto e ORCHESTRA_STATE próprios), manda
    Baixo (líder -> coder) e a sequência suspeita, e verifica o team.json no
    FIM — não a tela: o time tem de sair EXATAMENTE como entrou.

    'kind' só decide como o roteiro segue vivo até o fim: 'add' sabe que a
    sequência PODE abrir o prompt 'nome do agente' (troca o terminal para
    leitura de LINHA) e cancela com uma linha vazia se isso acontecer, para
    não travar esperando um Enter que não vai vir; 'delete' não precisa disso.
    O veredito em si — 'a sequência ainda deixou o time intacto?' — é sempre
    tirado do arquivo, comparando com EXPECTED_AGENTS.
    """
    proj = tempfile.mkdtemp()
    state = tempfile.mkdtemp()
    pid = fd = None
    try:
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
            'echo "TEAM_FILE=$(team_file)"',
        ])
        pid, fd = _spawn(script)
        # OAV2-26: marcador em vez de silêncio no 1º render — ele aparece assim
        # que _st_render desenha pela primeira vez, sem esperar os 2s fixos.
        saida, _ = drain_until(fd, [RENDER_MARK], deadline=8.0)

        def enviar(bts, wait=1.2, quiet=0.3):
            nonlocal saida
            os.write(fd, bts)
            saida += drain(fd, wait, quiet)

        try:
            enviar(b"\x1b[B")  # líder -> coder: é sob este agente que a sequência mira
            # Aqui o envio continua por SILÊNCIO, de propósito (ver o comentário
            # do módulo): no motor antigo o atalho pode vazar várias iterações
            # de laço depois do 1º redesenho, e parar no primeiro marcador
            # perderia justamente esse vazamento.
            enviar(seq)
        except OSError:
            return "FAIL:menu_morreu"

        abriu = kind == "add" and b"nome do agente" in saida
        try:
            if abriu:
                # _st_add trata '' como cancelar, imprime 'cancelado' e só ENTÃO
                # dorme 1s antes de devolver o controle ao laço principal. A
                # linha de ajuda 'q sai sem abrir' só reaparece quando
                # _st_render roda DEPOIS desse sono — esperar por ELA em vez de
                # por silêncio atravessa o buraco sem depender de um limiar de
                # tempo calibrado à mão (era 'quiet=1.5', ~1,5s a mais por caso
                # 'add'; achado da OAV2-26, medido).
                os.write(fd, b"\n")
                pedaco, _ = drain_until(fd, [RENDER_MARK], deadline=10.0)
                saida += pedaco
            os.write(fd, b"q")
        except OSError:
            pass
        # marcador de novo, não silêncio, para o fim do processo.
        pedaco, _ = drain_until(fd, [b"TEAM_FILE="], deadline=8.0)
        saida += pedaco

        team_file = ""
        for linha in saida.decode("utf-8", "replace").splitlines():
            if linha.startswith("TEAM_FILE="):
                team_file = linha.split("=", 1)[1].strip()
        if not team_file or not os.path.isfile(team_file):
            return "FAIL:sem_team_file"
        try:
            atual = _team_agent_names(team_file)
        except (ValueError, OSError):
            return "FAIL:team_json_invalido"

        # 'abriu' é o sintoma direto do bug em cima de teclas 'add' (a sobra
        # bateu no ramo a/A e o prompt abriu sem o usuário pedir) — reprova
        # mesmo se o cancelamento tiver deixado o team.json intacto, porque o
        # prompt ter aberto sozinho JÁ é o vazamento que este teste existe pra
        # pegar. 'time_alterado' é o cinto-e-suspensório: cobre tanto o
        # apagão direto (ramo d/D) quanto qualquer forma de a sequência ter
        # deixado o time diferente do que era, mesmo sem o prompt aparecer.
        if abriu:
            return "FAIL:add_opened_sem_pedido"
        if atual != EXPECTED_AGENTS:
            return "FAIL:time_alterado:%s" % ",".join(atual)
        return "OK"
    finally:
        if fd is not None:
            _close(pid, fd)
        shutil.rmtree(proj, ignore_errors=True)
        shutil.rmtree(state, ignore_errors=True)


def run_dead_key_batch(home):
    """Um ÚNICO select_team dirigido pela sequência INTEIRA de DEAD_KEY_BATCH.

    Diferente de run_session_case, aqui NENHUMA sequência tem uma sobra
    vinculada a atalho (conferido caso a caso, ver o comentário da lista) —
    nem no motor ANTIGO. Por isso não precisam de isolamento entre si: testar
    as 13 num processo só, em vez de um por tecla, economiza ~13 subidas de
    bash+pty sem perder cobertura. Cada sequência viaja JUNTO com uma seta
    CONHECIDA (↓) num único write — um só 'drain' por par, não dois —, e
    confirmamos na resposta que ela navegou (o menu não morreu nem abriu
    prompt nenhum) antes de seguir para a próxima. Por serem inertes nos
    dois motores, esta função não entra no controle negativo (não provaria
    nada lá); a prova de regressão desta rodada é shift_up/ctrl_left, em
    SESSION_CASES.
    """
    proj = tempfile.mkdtemp()
    state = tempfile.mkdtemp()
    pid = fd = None
    problemas = []
    try:
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
            'echo "TEAM_FILE=$(team_file)"',
        ])
        pid, fd = _spawn(script)
        saida, _ = drain_until(fd, [RENDER_MARK], deadline=8.0)

        def enviar(bts, wait=1.2, quiet=0.3):
            nonlocal saida
            os.write(fd, bts)
            saida += drain(fd, wait, quiet)

        try:
            enviar(b"\x1b[B")  # líder -> coder
            for nome, seq in DEAD_KEY_BATCH:
                antes = len(saida)
                # a sequência suspeita e a seta de prova de vida viajam JUNTAS
                # num único write/drain — metade das idas ao pty de mandar as
                # duas em separado, sem perder o que cada uma prova.
                enviar(seq + b"\x1b[B")
                pedaco = saida[antes:]
                if b"nome do agente" in pedaco:
                    problemas.append("%s:abriu_add" % nome)
                    enviar(b"\n")  # cancela o prompt e segue o roteiro
                elif not pedaco:
                    problemas.append("%s:menu_travou" % nome)
            os.write(fd, b"q")
        except OSError:
            return "FAIL:menu_morreu"
        pedaco, _ = drain_until(fd, [b"TEAM_FILE="], deadline=8.0)
        saida += pedaco

        team_file = ""
        for linha in saida.decode("utf-8", "replace").splitlines():
            if linha.startswith("TEAM_FILE="):
                team_file = linha.split("=", 1)[1].strip()
        if not team_file or not os.path.isfile(team_file):
            return "FAIL:sem_team_file"
        try:
            atual = _team_agent_names(team_file)
        except (ValueError, OSError):
            return "FAIL:team_json_invalido"
        if atual != EXPECTED_AGENTS:
            problemas.append("time_alterado:%s" % ",".join(atual))
        if problemas:
            return "FAIL:" + ";".join(problemas)
        return "OK"
    finally:
        if fd is not None:
            _close(pid, fd)
        shutil.rmtree(proj, ignore_errors=True)
        shutil.rmtree(state, ignore_errors=True)


# ---------------------------------------------------------------------------
# Sonda direta de menu_read_key — ver o comentário do módulo: sequências sem
# NENHUMA letra vinculada a atalho não produzem efeito observável em
# select_team, drenadas ou não, então a prova tem de ser no nível da função.
# ---------------------------------------------------------------------------

PROBE_CASES = [
    ("delete", b"\x1b[3~"),      # Delete — termina em '~'
    ("pageup", b"\x1b[5~"),      # PageUp — termina em '~'
    ("f5",     b"\x1b[15~"),     # F5 — termina em '~', 2 dígitos de parâmetro
    ("ss3_up", b"\x1bOA"),       # seta Cima em modo aplicação (DECCKM) — SS3
    ("kitty_u", b"\x1b[97;3u"),  # protocolo de teclado do kitty — CSI termina em 'u'
    # Achados da REVISÃO da OAV2-25 (ver o comentário do módulo) — nenhuma
    # tecla real emite estas formas hoje, mas o modo de falha é o mesmo.
    ("space_in_csi", b"\x1b[2 q"),                    # espaço (0x20) DENTRO da CSI, sem IFS= vira ''
    ("long_params", b"\x1b[1;1;1;1;1;1;1;1;1D"),      # 17 bytes de parâmetro, estourava o teto de 16
]


def run_probe_case(home, seq):
    """Escreve <sequência><'x'> de uma vez só (já sentado no buffer antes do
    1º read) e chama menu_read_key duas vezes: a 1ª consome a sequência
    suspeita, a 2ª tem de devolver exatamente 'x' — se sobrou byte, a 2ª
    chamada devolve o resto da sequência, não 'x'.
    """
    script = "\n".join([
        'export ORCHESTRA_MUX=stub',
        '. "%s/lib/menu.sh"' % home,
        'menu_read_key K1',
        'menu_read_key K2',
        'echo "K1=[$K1] K2=[$K2]"',
    ])
    pid, fd = _spawn(script)
    time.sleep(0.15)  # bash sobe e chega no primeiro read antes de escrever
    try:
        os.write(fd, seq + b"x")
    except OSError:
        _close(pid, fd)
        return "FAIL:menu_morreu"
    saida = drain(fd, 2.5, quiet=0.4)
    _close(pid, fd)
    k1 = k2 = None
    for linha in saida.decode("utf-8", "replace").splitlines():
        if linha.startswith("K1="):
            try:
                k1 = linha.split("K1=[", 1)[1].split("]", 1)[0]
                k2 = linha.split("K2=[", 1)[1].split("]", 1)[0]
            except IndexError:
                pass
    if k2 is None:
        return "FAIL:sem_resposta"
    return "OK" if k2 == "x" else "FAIL:K1=%s,K2=%s(esperado x)" % (k1, k2)


# OAV2-26: achado da revisão da OAV2-25 que só ganhou teste agora — as duas
# linhas sem cobertura eram lib/menu.sh:129 e :146 (medido: removendo o
# 'IFS=' delas, os 13 casos acima seguem 13/13 verde).
PROBE_K1_CASES = [
    ("alt_space", b"\x1b "),   # ESC + espaço — Alt+Espaço em terminal com Meta
]


def run_probe_k1_case(home, seq):
    """Como run_probe_case, mas o veredito está na 1ª leitura (K1), não na
    2ª: o defeito aqui não é sobrar byte para a tecla seguinte, é a PRÓPRIA
    sequência ser classificada errado. Alt+Espaço ('\\e ', ESC seguido de um
    espaço) é um espaço (0x20) logo após o ESC: sem 'IFS=' no primeiro read
    do ramo ESC (lib/menu.sh:129), o bash descarta o espaço nas bordas do
    que leu — regra de field-splitting do 'read' sem 'IFS=' vazio — e a
    variável fica VAZIA, o mesmo valor que 'Esc sozinho' produz. menu_read_key
    devolve 'esc' em vez de 'unknown', e 'esc' cancela a sessão inteira: uma
    combinação de tecla nunca deveria ter esse poder por acidente. Não
    escrevemos um 'x' de prova depois — não há sobra para verificar aqui.
    """
    script = "\n".join([
        'export ORCHESTRA_MUX=stub',
        '. "%s/lib/menu.sh"' % home,
        'menu_read_key K1',
        'echo "K1=[$K1]"',
    ])
    pid, fd = _spawn(script)
    time.sleep(0.15)  # bash sobe e chega no primeiro read antes de escrever
    try:
        os.write(fd, seq)
    except OSError:
        _close(pid, fd)
        return "FAIL:menu_morreu"
    saida = drain(fd, 2.5, quiet=0.4)
    _close(pid, fd)
    k1 = None
    for linha in saida.decode("utf-8", "replace").splitlines():
        if linha.startswith("K1="):
            try:
                k1 = linha.split("K1=[", 1)[1].split("]", 1)[0]
            except IndexError:
                pass
    if k1 is None:
        return "FAIL:sem_resposta"
    return "OK" if k1 == "unknown" else "FAIL:K1=%s(esperado unknown)" % k1


def main():
    home = sys.argv[1]
    # segundo argv opcional: lista de nomes separados por vírgula. Usado pelo
    # controle negativo do caso 20 (tests/smoke.sh) para rodar SÓ os casos que
    # o motor de ANTES da OAV2-25 tem de reprovar — dead_key_batch (~13s: 13
    # sequências, cada uma seguida de uma seta de prova de vida) e ss3_up NÃO
    # entram nessa lista (são inertes nos dois motores, não provam regressão
    # nenhuma ali), e rodá-los de novo contra a cópia antiga só gastaria tempo
    # à toa — foi o que estourou a suíte para além de 1min30 (medido).
    somente = set(sys.argv[2].split(",")) if len(sys.argv) > 2 and sys.argv[2] else None

    def quer(nome):
        return somente is None or nome in somente

    for name, seq, kind in SESSION_CASES:
        if quer(name):
            print("CASE:%s=%s" % (name, run_session_case(home, seq, kind)))
    if quer("dead_key_batch"):
        print("CASE:dead_key_batch=%s" % run_dead_key_batch(home))
    for name, seq in PROBE_CASES:
        if quer(name):
            print("PROBE:%s=%s" % (name, run_probe_case(home, seq)))
    for name, seq in PROBE_K1_CASES:
        if quer(name):
            print("PROBE:%s=%s" % (name, run_probe_k1_case(home, seq)))
    print("SESSAO_VIVA")


if __name__ == "__main__":
    main()
