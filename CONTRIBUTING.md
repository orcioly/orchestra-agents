# Contribuindo com o Orchestra Agents

Obrigado pelo interesse em contribuir! 🎼 Issues e pull requests são bem-vindos.

## 🧰 Pré-requisitos

- Ao menos um backend de agente — **Claude Code**, **OpenCode** ou **Codex** (veja os
  [pré-requisitos](README.md#-pré-requisitos)). Para rodar os testes, nenhum é necessário.
- **zellij**, `git`, `python3` (e `curl` para rodar o instalador)
- `bash` (os scripts usam `#!/usr/bin/env bash`)

## 🛠️ Setup de desenvolvimento

```bash
# 1) faça um fork e clone o seu fork
git clone git@github.com:SEU_USUARIO/orchestra-agents.git
cd orchestra-agents

# 2) instale a partir da cópia local (sem baixar do GitHub)
ORCHESTRA_LOCAL_SRC="$PWD" bash install.sh
```

Para iterar, edite os arquivos no repositório e rode `ORCHESTRA_LOCAL_SRC="$PWD" bash install.sh` de novo para sincronizar a instalação em `~/.orchestra-agents`. O modo dev copia o working tree inteiro (menos `.git`, `.orchestra` e caches) e **recria** o diretório de instalação, então arquivos removidos no repositório somem da instalação também.

Depois de sincronizar, lembre que **painéis já abertos seguem com o código antigo**: encerre com `orchestra down` e suba de novo para testar as mudanças.

## ✅ Rodando os testes

Sempre rode o smoke test antes de abrir um PR:

```bash
./tests/smoke.sh
```

Ele cobre sintaxe (`bash -n`), o modelo do time, composição por env, `add`/`rm`, prompts de papel, o ciclo completo `send → done → await`, exit codes, o layout gerado e o `doctor`. Roda com `ORCHESTRA_MUX=stub` num projeto temporário — não precisa de zellij nem de backend autenticado, e não encosta numa sessão real. O CI (GitHub Actions) roda automaticamente a cada push/PR na `main`.

## 🎨 Estilo de código

- Todo script começa com `#!/usr/bin/env bash`.
- Garanta que passa em `bash -n` e, de preferência, em `shellcheck -S warning`.
- Use aspas em variáveis (`"$var"`), prefira `[ ... ]`/`case`, e funções pequenas e nomeadas.
- Mantenha a mesma densidade de comentários e idioma das mensagens já existentes (mensagens ao usuário em PT-BR).
- Não introduza dependências além de `bash`, `python3`, `git` e as ferramentas já usadas (`zellij`, `claude`, `opencode`, `codex`).
- Todo acesso ao multiplexador passa por `lib/mux.sh` — não chame `zellij` direto em outro arquivo.

## 📝 Mensagens de commit

As mensagens são **em inglês** e adotam, **como referência de convenção**, o guia **[Padrões de Commits (iuricode)](https://github.com/iuricode/padroes-de-commits)**: `<emoji> <tipo>: <descrição no imperativo>`. (É só uma referência externa de padronização — não há vínculo com o projeto.)

Exemplos:

| Tipo | Quando | Exemplo |
|------|--------|---------|
| ✨ `feat` | nova funcionalidade | `✨ feat: add 'orchestra logs' command` |
| 🐛 `fix` | correção de bug | `🐛 fix: handle empty project directory` |
| 📝 `docs` | documentação | `📝 docs: clarify model configuration` |
| ✅ `test` | testes | `✅ test: cover dispatch error path` |
| ♻️ `refactor` | refatoração | `♻️ refactor: extract session helpers` |
| 🔧 `chore` | tarefas/config | `🔧 chore: tidy install paths` |
| 👷 `ci` | CI/CD | `👷 ci: cache shellcheck install` |
| 🔖 `chore` | bump de versão | `🔖 chore: bump version to v0.2.0` |

## 🔀 Abrindo um Pull Request

1. Crie uma branch a partir da `main`: `git checkout -b minha-feature`
2. Faça suas mudanças e rode `./tests/smoke.sh` (deve passar).
3. Faça commits no padrão acima.
4. Abra o PR contra a `main` descrevendo **o quê** e **por quê**.
5. Garanta que o CI esteja verde.

## 🚢 Lançando uma versão

Mantenedores: o processo de release está documentado no [README](README.md#-processo-de-release).

---

Dúvidas? Abra uma [issue](https://github.com/orcioly/orchestra-agents/issues). 🙌
