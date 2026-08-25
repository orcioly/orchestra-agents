#!/usr/bin/env bash
# Orchestra Agents — motor do menu: desenha na tela e lê teclas. Só isso.
#
# POR QUE ESTE ARQUIVO EXISTE, E POR QUE ELE É ÚNICO
#
# Um menu tem duas metades: o MOTOR (esconder o cursor, apagar o desenho anterior,
# ler uma tecla e dizer que tecla foi) e o CONTEÚDO (quais linhas existem, o que
# cada tecla faz ali). O conteúdo muda de menu para menu; o motor, não.
#
# O motor carrega duas armadilhas que já quebraram o produto na mão do usuário, e
# as duas são INVISÍVEIS em bash 5 e fora de um terminal de verdade:
#
#   A1  'read -t' não aceita fração no bash 3.2. O /bin/bash do macOS é o 3.2.57 e
#       recusa 'read -t 0.05' com "invalid timeout specification": devolve 1 na hora
#       e deixa a variável VAZIA, que é exatamente como se reconhece "Esc sozinho".
#       Resultado: TODA seta fechava o menu, select_team voltava 2 e o zellij nem
#       abria. Vive em menu_esc_wait, detectado uma vez só.
#
#   A2  O redesenho é RELATIVO, nunca ancorado. '\033[s' / '\033[u' guardam a LINHA
#       ABSOLUTA da tela; quando o menu não cabe na janela o terminal ROLA, a âncora
#       passa a apontar para o meio do bloco e o redesenho começa lá, deixando as
#       primeiras linhas do menu antigo acima. Foi a duplicação que o usuário viu.
#       Vive em menu_draw_begin/menu_draw_end, que sobem 'drawn' linhas a partir de
#       onde o cursor está.
#
# Por isso o motor mora AQUI e em nenhum outro lugar: duas cópias e uma delas
# regride, sem que quem escreveu veja o bug na própria máquina.
#
# Este módulo não conhece agente, time nem zellij — só teclas e caracteres. Todo o
# desenho sai por /dev/tty, nunca por stdout, para que o menu nunca contamine a
# saída de um comando.
#
# Não executar diretamente; é "sourced" por lib/core.sh.

# Linhas ocupadas pelo último desenho. 0 = "não há desenho anterior aqui".
_MENU_DRAWN=0
# 1 enquanto um menu está na tela (cursor escondido). Usado por menu_confirm e
# menu_prompt para devolver o cursor à pergunta e escondê-lo de novo depois.
_MENU_ACTIVE=0
# Memória de menu_esc_wait (A1). Vazio = ainda não detectado.
_MENU_ESC_WAIT=""
# Traps de INT/TERM/EXIT que existiam antes de menu_begin, para restaurar no fim.
_MENU_TRAP_INT=""
_MENU_TRAP_TERM=""
_MENU_TRAP_EXIT=""

# ----- Saída -----

menu_tty() { # $1 formato  $@ argumentos — printf para o terminal, nunca para stdout
  # Sem terminal controlador o redirecionamento falha; silenciar e seguir é o
  # comportamento certo, porque sem TTY nenhum menu abre de todo jeito.
  { printf "$@" >/dev/tty; } 2>/dev/null
  return 0
}

menu_has_tty() { ( : >/dev/tty ) 2>/dev/null; }

# ----- Teclado -----

_menu_esc_detect() { # popula _MENU_ESC_WAIT; só faz trabalho na primeira vez (A1)
  [ -n "$_MENU_ESC_WAIT" ] && return 0
  _MENU_ESC_WAIT=0.05
  case "$( { read -rst 0.05 -n1 _ </dev/null; } 2>&1 )" in
    *'invalid timeout'*) _MENU_ESC_WAIT=1 ;;
  esac
  return 0
}

menu_esc_wait() { # ecoa o timeout de Esc que este bash aceita: 0.05 ou 1
  _menu_esc_detect
  printf '%s' "$_MENU_ESC_WAIT"
}

menu_read_key() { # $1 nome da variável — lê uma tecla e devolve o nome dela
  local __mrk_var="$1" __mrk_key __mrk_rest
  IFS= read -rsn1 __mrk_key </dev/tty || return 1
  case "$__mrk_key" in
    $'\e')
      # Esc e as setas começam com o MESMO byte. O que distingue é o resto chegar
      # ou não dentro do timeout — e o timeout tem de ser o que ESTE bash aceita.
      # Chamamos _menu_esc_detect direto, e não "$(menu_esc_wait)": a substituição
      # de comando roda em subshell, então a memória ficaria lá e a detecção se
      # repetiria a cada tecla.
      _menu_esc_detect
      __mrk_rest=""
      read -rsn2 -t "$_MENU_ESC_WAIT" __mrk_rest </dev/tty
      case "$__mrk_rest" in
        '[A') __mrk_key=up ;;
        '[B') __mrk_key=down ;;
        '[C') __mrk_key=right ;;
        '[D') __mrk_key=left ;;
        # Vazio = o 'read' do resto não trouxe NADA dentro do timeout: é Esc
        # sozinho, quem chama trata como cancelar.
        '')   __mrk_key=esc ;;
        # Não-vazio mas não é seta: reconhecemos que veio uma sequência (Delete,
        # Home/End, PageUp/PageDown, F1-F12, ou uma seta em modo aplicação/DECCKM
        # como '\eOB') sem saber que tecla é. NÃO pode virar "esc": o desenho na
        # tela é idêntico ao de apertar Esc de verdade, mas a intenção do usuário
        # é outra — e a ajuda do menu diz "d remover", então procurar a tecla
        # Delete é o erro mais natural do mundo. Se isto colapsasse em "esc", quem
        # chama cancelaria a sessão inteira ao apertar Delete. "unknown" deixa
        # quem chama decidir (tipicamente: ignorar e continuar).
        *)    __mrk_key=unknown ;;
      esac ;;
    '')  __mrk_key=enter ;;
    ' ') __mrk_key=space ;;
    # k/j/h/l NÃO são traduzidos aqui: são atalhos de CONTEÚDO, e cada menu decide
    # o que fazem. O motor devolve o caractere como veio.
  esac
  printf -v "$__mrk_var" '%s' "$__mrk_key"
}

# ----- Ciclo de vida do desenho -----

_menu_trap_arm() {
  _MENU_TRAP_INT="$(trap -p INT)"
  _MENU_TRAP_TERM="$(trap -p TERM)"
  _MENU_TRAP_EXIT="$(trap -p EXIT)"
  # RETURN ficou DE FORA de propósito, e não por esquecimento: um 'trap ... RETURN'
  # armado aqui dispara ao retornar de menu_begin — devolvendo o cursor no exato
  # instante em que acabamos de escondê-lo — e depois continua armado, disparando
  # em toda função que retornar no shell. Medido no bash 3.2 do macOS. INT, TERM e
  # EXIT cobrem o dano real (o usuário ficar com o terminal sem cursor); o caminho
  # normal é menu_end.
  trap 'menu_tty "\033[?25h"' INT TERM EXIT
}

_menu_trap_disarm() {
  eval "${_MENU_TRAP_INT:-trap - INT}"
  eval "${_MENU_TRAP_TERM:-trap - TERM}"
  eval "${_MENU_TRAP_EXIT:-trap - EXIT}"
  _MENU_TRAP_INT=""; _MENU_TRAP_TERM=""; _MENU_TRAP_EXIT=""
}

menu_begin() { # esconde o cursor e protege contra deixá-lo escondido
  _MENU_DRAWN=0
  _MENU_ACTIVE=1
  menu_tty '\033[?25l'
  _menu_trap_arm
}

menu_draw_begin() { # apaga o desenho anterior, se houver (A2)
  # Sobe 'drawn' linhas a partir de ONDE O CURSOR ESTÁ (o fim do desenho anterior)
  # e limpa dali para baixo. Movimento relativo é imune ao scroll do terminal.
  [ "${_MENU_DRAWN:-0}" -gt 0 ] && menu_tty '\033[%dA\r\033[J' "$_MENU_DRAWN"
  return 0
}

menu_draw_end() { # $1 quantas linhas o desenho ocupou
  _MENU_DRAWN="${1:-0}"
}

menu_erase() { # tira o menu da tela; o próximo desenho começa daqui
  menu_draw_begin
  _MENU_DRAWN=0
}

menu_end() { # devolve o cursor e desarma a proteção
  menu_tty '\033[?25h'
  _menu_trap_disarm
  _MENU_DRAWN=0
  _MENU_ACTIVE=0
}

# ----- Perguntas -----

_menu_cursor_show() { menu_tty '\033[?25h'; }
_menu_cursor_restore() { # esconde de novo só se ainda houver menu na tela
  [ "${_MENU_ACTIVE:-0}" = 1 ] && menu_tty '\033[?25l'
  return 0
}

menu_confirm() { # $1 pergunta  $2 aviso (opcional) — default NÃO
  local __mc_ask="$1" __mc_warn="${2:-}" __mc_ans=""
  _menu_cursor_show
  [ -n "$__mc_warn" ] && menu_tty '  \033[1;33m⚠\033[0m  %s\n' "$__mc_warn"
  menu_tty '  %s \033[2m[s/N]\033[0m ' "$__mc_ask"
  IFS= read -r __mc_ans </dev/tty || __mc_ans=""
  _menu_cursor_restore
  # Default NÃO: Enter sozinho não destrói nada.
  case "$__mc_ans" in
    s|S|sim|SIM|Sim) return 0 ;;
    *) return 1 ;;
  esac
}

menu_prompt() { # $1 variável  $2 rótulo  $3 default (opcional)
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
