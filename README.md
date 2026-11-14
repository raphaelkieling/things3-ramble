# Things 3 Ramble

A macOS menu bar app that turns speech into tasks, previews them, and sends them to Things 3.


<div align="center">
  <img width="512" height="252" alt="image" src="https://github.com/user-attachments/assets/0562e036-1fd2-4234-9878-19fd80b30043" />
</div>


## Build and run

Runs on macOS 14 or later. Building requires the macOS 26 SDK or later.

```sh
./build.sh && open "dist/Things 3 Ramble.app"
```

Open **Ajustes…** (Settings) from the Ramble menu and save your OpenAI API key and Things 3 URL token. In Things, find the token under **Settings → General → Enable Things URLs → Manage**.

Press **⌘⇧.** and grant microphone access on your first capture. Say your tasks, review the preview, then press **Enter** to send or **Esc** to cancel.

In **Settings → Transcription**, choose Apple to transcribe on a supported Mac or GPT to stream audio to OpenAI. The first Apple capture in each language may download the speech model. **Show live transcript** controls whether the dictation appears between the task cards and the waveform. Both options use GPT-6.1 Sol in Ultrafast mode to extract tasks from the text.

## Test

```sh
./test.sh          # Automated tests
./build.sh --demo  # Demo with sample data, no credentials or microphone needed
```

## Vocabulário e desempenho

Em **Ajustes → Vocabulário personalizado**, escreva um nome, projeto, sigla ou expressão por linha. Edite ou apague a linha para alterar a lista. As mudanças entram na próxima captura. O modo Apple usa a lista no Mac. O modo GPT envia os termos como sugestões à OpenAI.

Ative **Registrar tempos localmente** nos Ajustes para medir capturas reais. Faça uma captura, use Enter ou Esc e gere o relatório. Os registros do app guardam eventos e contagens, sem guardar áudio, texto ou credenciais.

```sh
python3 Benchmarks/report.py --app
open Benchmarks/report.html
```

Para rodar a comparação com os seis WAVs sintéticos fixos em pt-BR, en-US e es-ES:

```sh
./benchmark.sh 2
open Benchmarks/report.html
```

O benchmark requer macOS 26 ou posterior, Swift e Python 3. A primeira opção testa os modelos Apple já instalados. Use `./benchmark.sh 2 --download` para solicitar as vozes de reconhecimento faltantes. Com `OPENAI_API_KEY` já definida no ambiente, o mesmo comando mede GPT, os dois extratores e as três estratégias de prévia. Isso usa a API faturável. Use `./benchmark.sh 2 --openai-only` para rodar só a matriz da nuvem. O benchmark usa apenas os WAVs de teste e não cria tarefas no Things.

Os WAVs versionados evitam variações da síntese entre máquinas. Para regenerar as amostras, use `python3 Benchmarks/prepare.py` com `say` e `ffmpeg`. Cada execução da matriz atualiza `Benchmarks/results.jsonl` e `Benchmarks/report.html`. O replay mede dados prontos. A visualização na janela é medida nas capturas reais.
