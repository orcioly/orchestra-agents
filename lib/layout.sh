#!/usr/bin/env bash
# Orchestra Agents — zellij layout generator for the current team.
#
# The layout stopped being static because the team is dynamic: N agents, chosen
# per project. We generate the KDL in $ORCHESTRA_STATE/team.kdl on every 'orchestra'.
#
# Do not execute directly; it is sourced by lib/core.sh.

_kdl_pane() { # $1 agent  $2 label
  printf '                pane name="%s" command="bash" {\n' "$2"
  printf '                    args "-lc" "exec %s/agents/run-agent.sh %s"\n' "$ORCHESTRA_HOME" "$1"
  printf '                }\n'
}

# writes the team KDL and echoes the file path
generate_layout() {
  team_ensure
  local out="$ORCHESTRA_STATE/team.kdl"
  local workers=() n r half i
  while IFS= read -r n; do [ -n "$n" ] && workers+=("$n"); done < <(team_names)

  {
    printf '// Orchestra Agents — layout GERADO automaticamente (não editar à mão).\n'
    printf '// Regenerado a cada "orchestra" a partir de %s\n' "$(team_file)"
    printf 'layout {\n'
    printf '    pane size=1 borderless=true {\n        plugin location="zellij:tab-bar"\n    }\n'
    printf '    pane split_direction="horizontal" {\n'
    printf '        pane name="%s" size="%s" command="bash" {\n' \
      "$(pane_label leader)" "$([ ${#workers[@]} -gt 3 ] && echo 35% || echo 45%)"
    printf '            args "-lc" "exec %s/agents/run-agent.sh leader"\n' "$ORCHESTRA_HOME"
    printf '        }\n'

    if [ "${#workers[@]}" -eq 0 ]; then
      :   # team with only the leader (solo mode)
    elif [ "${#workers[@]}" -le 3 ]; then
      printf '        pane split_direction="vertical" {\n'
      for n in "${workers[@]}"; do
        _kdl_pane "$n" "$(pane_label "$n")"
      done
      printf '        }\n'
    else
      # more than 3 workers: two rows, so no pane gets squeezed
      half=$(( (${#workers[@]} + 1) / 2 ))
      printf '        pane split_direction="horizontal" {\n'
      printf '            pane split_direction="vertical" {\n'
      for i in "${!workers[@]}"; do
        [ "$i" -lt "$half" ] || continue
        n="${workers[$i]}"
        _kdl_pane "$n" "$(pane_label "$n")"
      done
      printf '            }\n'
      printf '            pane split_direction="vertical" {\n'
      for i in "${!workers[@]}"; do
        [ "$i" -ge "$half" ] || continue
        n="${workers[$i]}"
        _kdl_pane "$n" "$(pane_label "$n")"
      done
      printf '            }\n'
      printf '        }\n'
    fi

    printf '    }\n'
    printf '    pane size=1 borderless=true {\n        plugin location="zellij:status-bar"\n    }\n'
    printf '}\n'
  } >"$out"

  echo "$out"
}
