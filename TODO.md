# Transcrição e desempenho do Ramble

## O que o app usa hoje

| Etapa | Modelo ou API | Como funciona |
| --- | --- | --- |
| Voz → texto no Mac | Apple SpeechAnalyzer com SpeechTranscriber, preset `.progressiveTranscription` | É o caminho padrão quando disponível no macOS 26 ou posterior. O modelo de voz é gerenciado pelo macOS e o idioma segue **Ajustes → Idioma**. A primeira captura em cada idioma pode baixar o modelo. |
| Voz → texto na nuvem | OpenAI `gpt-live-transcribe`, pela API Realtime com `delay: minimal` | É usado ao selecionar GPT nos Ajustes e é o padrão em Macs sem suporte à API local. O áudio é enviado à OpenAI. |
| Texto → tarefas | OpenAI `gpt-6.1-sol`, pela API Responses em modo Ultrafast com `reasoning.effort: low` | Nos dois caminhos, o app envia o texto para extrair título, notas, checklist e prazo. O modelo que transcreve a voz e o modelo que extrai as tarefas são escolhidos em etapas diferentes. |

A prévia espera 180 ms antes da primeira extração e 600 ms antes das seguintes. O app permite uma extração de prévia por vez. Esses intervalos e a espera pela resposta de extração também entram no tempo até aparecer um cartão.

## Escolha do transcritor

- [x] Adicionar **Transcrição** aos Ajustes, com **Apple (no Mac)** e **GPT (OpenAI)**. Salvar a escolha e aplicá-la à próxima captura.
- [x] Mostrar nos Ajustes a disponibilidade do idioma e o estado do download do modelo da Apple.

## Vocabulário personalizado

- [x] Permitir cadastrar, editar e remover palavras ou expressões nos Ajustes. Começar por nomes próprios, projetos, siglas e termos técnicos. Usar a experiência do Handy como referência.
- [ ] Completar o teste de sugestões no GPT e no modelo Apple es-ES. Medir o reconhecimento dos termos com e sem a lista e conferir se o recurso introduz palavras que a pessoa não disse.

## Relatório de velocidade

- [x] Registrar os eventos com um relógio monotônico e associá-los à mesma captura e ao mesmo trecho de áudio.

| Medida | Início | Fim |
| --- | --- | --- |
| Início da gravação | Atalho ou clique para capturar | Primeiro buffer do microfone recebido |
| Fala → transcrição | Fim do trecho falado, conforme a marcação do áudio | Primeira parcial que contém o trecho e, separadamente, sua versão final |
| Transcrição → tela | Chegada do texto que gerou a atualização | Cartão correspondente aparece ou muda na prévia |
| Fala → tela | Fim do trecho falado | Atualização correspondente na prévia |

- [x] Dentro de **Transcrição → tela**, medir separadamente a espera antes de chamar a API, o tempo da extração e o tempo até a atualização visual. Medir também o intervalo entre Enter e a prévia final.
- [x] Gerar um relatório com uma linha do tempo por captura e gráficos por transcritor, modelo, idioma e estratégia. Mostrar mediana, p95, número de execuções e falhas. Separar a primeira execução, que pode incluir download ou conexão, das execuções seguintes.

## Testes comparativos

- [x] Montar um conjunto fixo de áudios com transcrições e tarefas esperadas em português do Brasil, inglês e espanhol. Incluir fala rápida, ruído, nomes e siglas, várias tarefas no mesmo ditado, correções e datas relativas que devem virar prazos.
- [ ] Comparar Apple e `gpt-live-transcribe` com os mesmos áudios e o mesmo extrator. Depois, comparar modelos de extração com a mesma transcrição de referência para isolar o efeito de cada etapa.
- [ ] Comparar a prévia atual com outras estratégias de extração, como atualizar após uma pausa na fala ou processar só ao finalizar. Registrar quantas chamadas e quantos tokens cada estratégia usa.
- [ ] Cruzar velocidade com qualidade. Medir erros de transcrição, acerto dos termos cadastrados e acerto dos títulos, prazos e checklists. Usar o relatório para decidir o padrão e identificar quando vale trocar de transcritor.

## Execução

- [x] Ligar vocabulário aos dois transcritores e aos Ajustes.
- [x] Registrar eventos locais e gerar relatório por captura e configuração.
- [x] Rodar a matriz local com os modelos Apple disponíveis e guardar o relatório.
- [ ] Rodar a matriz da OpenAI com uma chave de API e completar es-ES após o download.
- [x] Validar build, testes e comandos do README. Registrar resultados e lacunas.

### Resultado de 14/11/2026

- Apple, corpus sintético, duas repetições por condição. Das 24 tentativas, 16 concluíram em pt-BR e en-US. As oito de es-ES ficaram indisponíveis porque o modelo não estava instalado. A tentativa de download excedeu 30 s.
- Nos dois idiomas medidos, os 12 termos-alvo foram reconhecidos por condição, com e sem lista. Nenhum termo de controle apareceu nas 16 transcrições. O corpus é pequeno e sintético.
- Fala → parcial no Apple ficou em 192–193 ms de mediana e 215–222 ms de p95 por idioma e condição. Fala → final ficou em 208–217 ms de mediana e 232–242 ms de p95. Cada recorte tem quatro amostras, incluindo a primeira quando aplicável. A página separa a primeira das demais.
- A matriz da OpenAI está implementada e compilada. Sem chave disponível para o benchmark, a decisão sobre o melhor transcritor, extrator e estratégia continua pendente.
- Manter o padrão atual até a comparação. O GPT é uma opção quando o Apple está indisponível ou o idioma ainda aguarda instalação. O perfil do app continua GPT-6.1 Sol em Ultrafast com esforço baixo.
- Os tempos de capturas reais do app ficam disponíveis via opção nos Ajustes. Para GPT ao vivo, o protocolo oferece o ID do turno, sem marcação temporal por palavra. A comparação fala → texto no corpus usa a marca do trecho de referência e só conta a resposta que contém a frase.
