# hosts-blacklist

Mantém uma blacklist de domínios dentro de um **bloco delimitado** do `/etc/hosts`, de forma que ela sobreviva a edições manuais, reinicializações e atualizações das listas. Tudo fora do bloco é preservado.

```
# BEGIN hosts-blacklist
# gerenciado por hosts-blacklist: 3 domínios. Não edite dentro deste bloco.
0.0.0.0 anuncios.exemplo.com
0.0.0.0 rastreador.exemplo.net
...
# END hosts-blacklist
```

## Como funciona

```
 local.txt ─┐
 cache/*.list ─┼─► normaliza, valida, deduplica ─► (− allowlist) ─► lista final
 (fontes)  ─┘                                                          │
                                                                       ▼
 inotify (watch) ─┐                                   compara o bloco atual com o esperado
 timer (15 min)  ─┼─► hosts-blacklist apply ─────────► igual?  → não faz nada
 boot            ─┘                                    diferente? → escrita atômica no /etc/hosts
```

| Componente | Responsabilidade |
|---|---|
| `bin/hosts-blacklist` | Gerenciador. Funciona sozinho, sem depender do monitoramento. |
| `bin/hosts-blacklist-watch` | Só observa o `/etc` com inotify e chama o gerenciador. Não conhece listas nem fontes. |
| `hosts-blacklist.service` + `.timer` | Aplica o bloco no boot e a cada 15 min (rede de segurança). |
| `hosts-blacklist-update.service` + `.timer` | Baixa as fontes uma vez por dia e reaplica. |
| `hosts-blacklist-watch.service` | Mantém o watcher rodando (`Restart=always`). |

### Problemas tratados

| Problema | Solução |
|---|---|
| Restauração gera novo evento inotify (ciclo) | O gerenciador compara o hash do bloco atual com o esperado e **não escreve nada** se estiver correto. |
| Arquivo substituído por `rename` derruba o watch | O watcher observa o **diretório** e filtra pelo nome. |
| Gravações simultâneas / corrupção | Arquivo temporário + `rename`, mais `flock`. Cai para escrita direta se o `/etc/hosts` for bind mount (containers). |
| Eventos em rajada | Debounce no watcher (`HB_WATCH_DEBOUNCE`, padrão 2 s) e `StartLimitIntervalSec=0` no serviço. |
| Falha de internet ou lista corrompida | Download para temporário, validação, e a **última versão válida fica no cache**. |
| Lista nova muito menor / vazia (erro 200 com HTML, por exemplo) | Rejeitada se tiver menos de `MIN_SOURCE_DOMAINS` ou menos de `MIN_SOURCE_RATIO`% da versão anterior. |
| Fonte bloqueando a si mesma | Os hosts das URLs de `sources.txt` nunca são bloqueados. |
| Listas originais alteradas | Nunca. `local.txt` e `allowlist.txt` são só leitura para o programa; fontes remotas vão para `/var/lib/hosts-blacklist/cache/`. |
| Marcadores corrompidos | Duplicatas "limpas" são recompostas; casos ambíguos são recusados (código 3) a menos que se use `--force`. |
| Lista vazia por engano apagando o bloqueio | Recusa (código 6); para remover de propósito use `hosts-blacklist remove`. |
| Permissões, dono e SELinux | Preservados (`chmod/chown/chcon --reference`, `restorecon`). |

## Instalação

Dependências: `bash` ≥ 4, `awk`, `sed`, `grep`, `coreutils`, `curl`, `flock` (util-linux) e `inotify-tools` (só para o monitoramento).

```bash
# Debian/Ubuntu
sudo apt install curl inotify-tools
# Fedora
sudo dnf install curl inotify-tools
# Arch
sudo pacman -S curl inotify-tools

git clone https://github.com/SEU_USUARIO/hosts-blacklist.git
cd hosts-blacklist
sudo ./install.sh
```

O instalador copia os programas para `/usr/local/bin`, as units para `/etc/systemd/system`, cria `/etc/hosts-blacklist/` (sem sobrescrever arquivos existentes) e ativa o timer, o timer de atualização e o watcher.

## Uso

```bash
echo "anuncios.exemplo.com" | sudo tee -a /etc/hosts-blacklist/local.txt
sudo hosts-blacklist apply          # aplica agora
hosts-blacklist --dry-run apply     # mostra o diff sem escrever
hosts-blacklist status              # resumo
hosts-blacklist check               # saída 0 se o bloco está íntegro
sudo hosts-blacklist update         # baixa as fontes e reaplica
sudo hosts-blacklist remove         # tira o bloco do hosts
journalctl -t hosts-blacklist -t hosts-blacklist-watch -f
```

### Arquivos em `/etc/hosts-blacklist/`

| Arquivo | Conteúdo |
|---|---|
| `local.txt` | Seus domínios, um por linha (também aceita formato hosts). |
| `sources.txt` | Listas remotas: `nome  URL`. Aceita formato hosts ou um domínio por linha. |
| `allowlist.txt` | Domínios que nunca devem ser bloqueados (correspondência exata). |
| `config.conf` | Opções (veja os comentários no arquivo). |

Estado gerado fica em `/var/lib/hosts-blacklist/`: `cache/`, `merged.txt`, `last-update`, `hosts.bak` (antes da última alteração) e `hosts.orig` (cópia da primeira execução).

Exemplo de fonte em `sources.txt`:

```
stevenblack  https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts
```

### Mensagens no journal

```
aplicado: bloco ausente (12043 domínios)
aplicado: conteúdo do bloco diverge do esperado (12043 domínios)
aplicado: listas atualizadas (12310 domínios)
fonte1: lista encolheu de 12000 para 40 domínios (mínimo 50%); mantendo versão anterior
```

### Códigos de saída

| Código | Significado |
|---|---|
| 0 | Sucesso (inclui "nada a fazer") |
| 1 | Uso incorreto |
| 2 | Configuração inválida / comando ausente |
| 3 | Marcadores ambíguos no hosts (use `--force` depois de conferir) |
| 4 | Falha ao escrever ou verificar o hosts |
| 5 | Não conseguiu obter o lock |
| 6 | Lista vazia, mas existe bloco (recusa apagar) |
| 7 | `update` terminou, mas alguma fonte falhou |

## Limitações e escolhas de projeto

- **`/etc/hosts` não tem curinga.** `*.exemplo.com` não existe; cada nome precisa estar listado. Para listas muito grandes (centenas de milhares de entradas) ou bloqueio por domínio inteiro, `dnsmasq` ou `unbound` com blocklist escalam melhor.
- **Quem tem root pode parar o serviço.** O projeto protege contra edições acidentais e ferramentas que reescrevem o arquivo, não contra um administrador. `IMMUTABLE=yes` aplica `chattr +i` depois de cada escrita, mas atrapalha NetworkManager, Docker, cloud-init e similares.
- **`HOSTS_PER_LINE`** (1 a 9): `1` é o formato mais compatível. Valores maiores reduzem o arquivo, mas alguns resolvedores/sistemas limitam o tamanho da linha.
- Entradas antigas que ficarem **fora** do bloco (por exemplo, depois de usar `--force` num caso ambíguo) não são apagadas, porque o programa só mexe entre os marcadores.
- Só aceita fontes `https://` por padrão (`ALLOW_HTTP=yes` libera `http://`). Domínios com IDN devem estar em punycode.

## Desinstalação

```bash
sudo ./uninstall.sh            # para os serviços, remove o bloco e os arquivos
sudo ./uninstall.sh --purge    # apaga também /etc/hosts-blacklist e /var/lib/hosts-blacklist
```

## Testes

```bash
bash tests/run.sh
```

Não precisam de root: usam diretórios temporários e um `inotifywait` simulado para o watcher. O CI (GitHub Actions) também roda o ShellCheck.

## Licença

MIT
