# Contribuindo com o Orchestra Agents

Obrigado pelo interesse em contribuir! 🎼 Issues e pull requests são bem-vindos.

## 🧰 Pré-requisitos

- **Claude Code** e **OpenCode** instalados e configurados (veja o [README](README.md#-pré-requisitos))
- **zellij**, `git`, `python3`, `curl`
- `bash` (os scripts usam `#!/usr/bin/env bash`)

## 🛠️ Setup de desenvolvimento

```bash
# 1) faça um fork e clone o seu fork
git clone git@github.com:SEU_USUARIO/orchestra-agents.git
cd orchestra-agents

# 2) instale a partir da cópia local (sem baixar do GitHub)
ORCHESTRA_LOCAL_SRC="$PWD" bash install.sh
```

Para iterar, edite os arquivos no repositório e rode `ORCHESTRA_LOCAL_SRC="$PWD" bash install.sh` de novo para sincronizar a instalação em `~/.orchestra-agents`.

## ✅ Rodando os testes

Sempre rode o smoke test antes de abrir um PR:

```bash
./tests/smoke.sh                 # completo (precisa de OpenCode autenticado)
SKIP_DISPATCH=1 ./tests/smoke.sh # rápido: só sintaxe + doctor
```

Ele valida sintaxe (`bash -n`), o `orchestra doctor` e um despacho async real. O CI (GitHub Actions) roda automaticamente a cada push/PR na `main`.

## 🎨 Estilo de código

- Todo script começa com `#!/usr/bin/env bash`.
- Garanta que passa em `bash -n` e, de preferência, em `shellcheck -S warning`.
- Use aspas em variáveis (`"$var"`), prefira `[ ... ]`/`case`, e funções pequenas e nomeadas.
- Mantenha a mesma densidade de comentários e idioma das mensagens já existentes (mensagens ao usuário em PT-BR).
- Não introduza dependências além de `bash`, `python3`, `curl`, `git` e as ferramentas já usadas (`opencode`, `zellij`, `claude`).

## 📝 Mensagens de commit

Seguimos o padrão de **[iuricode/padroes-de-commits](https://github.com/iuricode/padroes-de-commits)**, com as mensagens **em inglês**: `<emoji> <tipo>: <descrição no imperativo>`.

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
