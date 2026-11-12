# Things 3 Ramble

App de barra de menus para macOS que transcreve sua fala com a OpenAI e mostra uma prévia das tarefas antes de enviá-las ao Things 3.

## Compilar e rodar

Requer macOS 14+ e as ferramentas de linha de comando do Xcode com Swift 6+.

```sh
./build.sh && open "dist/Things 3 Ramble.app"
```

Em **Ajustes…** do Ramble, salve a chave da API da OpenAI e o token de URL do Things 3. No Things, o token fica em **Ajustes → Geral → Ativar URLs do Things → Gerenciar**.

Pressione **⌘⇧.** e permita o acesso ao microfone na primeira captura. Fale suas tarefas, revise a prévia e pressione **Enter** para enviar ou **Esc** para cancelar.

## Testar

```sh
./test.sh          # Testes automatizados
./build.sh --demo  # Demonstração com dados simulados, sem credenciais ou microfone
```
