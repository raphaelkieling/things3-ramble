"""Build an offline HTML report from the benchmark and/or opt-in app timings."""
import collections
import html
import json
import math
from pathlib import Path
import re
import statistics
import sys
import unicodedata

root = Path(__file__).resolve().parent
corpus = {c["id"]: c for c in json.loads((root / "corpus.json").read_text())}
source = root / "results.jsonl"
runs = [json.loads(row) for row in source.read_text().splitlines()] if source.exists() else []
if "--app" in sys.argv:
    folder = Path.home() / "Library/Application Support/Things 3 Ramble/Timings"
    runs += [{"clip": "app", "timing": json.loads(p.read_text())} for p in sorted(folder.glob("*.json"))]

def words(text):
    return re.findall(r"[^\W_]+", unicodedata.normalize("NFC", text).casefold())

def has(text, phrase):
    return f" {' '.join(words(phrase))} " in f" {' '.join(words(text))} "

def wer(expected, actual):
    expected, actual = words(expected), words(actual)
    row = list(range(len(actual) + 1))
    for i, a in enumerate(expected, 1):
        new = [i]
        for j, b in enumerate(actual, 1):
            new.append(min(row[j] + 1, new[-1] + 1, row[j - 1] + (a != b)))
        row = new
    return 100 * row[-1] / max(1, len(expected))

def f1(expected, actual):
    a = collections.Counter(" ".join(words(s)) for s in expected)
    b = collections.Counter(" ".join(words(s)) for s in actual)
    size = a.total() + b.total()
    return 100 * 2 * (a & b).total() / size if size else 100

def metrics(run):
    timing = run["timing"]
    by_name = collections.defaultdict(list)
    for event in timing["events"]:
        by_name[event["name"]].append(event)
    values = collections.defaultdict(list)

    def pair(label, start, end, match=False):
        for finish in by_name[end]:
            candidates = [s for s in by_name[start] if s["ms"] <= finish["ms"]
                          and (not match or s.get("segment") == finish.get("segment"))]
            if candidates:
                values[label].append(finish["ms"] - candidates[-1]["ms"])

    pair("Acionamento → primeiro buffer (ms)", "trigger", "first_buffer")
    pair("Preparação/replay → primeiro buffer (ms)", "start", "first_buffer")
    pair("Conexão ou preparo (ms)", "start", "ready")
    pair("Texto → chamada (ms)", "transcript", "extract_start", True)
    pair("Extração (ms)", "extract_start", "extract_end", True)
    pair("Extração → atualização AppKit (ms)", "extract_end", "preview", True)
    pair("Texto → atualização AppKit (ms)", "transcript", "preview", True)
    pair("Texto → dados prontos no replay (ms)", "transcript", "preview_ready", True)
    pair("Enter → prévia final (ms)", "enter", "final_preview")
    pair("Enter → resultado final sem mudança de tarefas (ms)", "enter", "final_unchanged")
    pair("Enter → dados finais no replay (ms)", "enter", "final_ready")
    if by_name["audio_origin"] or by_name["first_buffer"]:
        origin = (by_name["audio_origin"] or by_name["first_buffer"])[0]["ms"]
        for event_name, label in [("segment_partial", "Fala → parcial (ms)"), ("segment_final", "Fala → final (ms)")]:
            seen = set()
            for event in by_name[event_name]:
                end = event.get("audioEndMS")
                segment = event.get("segment")
                if end is not None and segment not in seen and event["ms"] >= origin + end:
                    values[label].append(event["ms"] - origin - end)
                    seen.add(segment)
        for name, label in [("preview", "Fala → atualização AppKit (ms)"),
                            ("preview_ready", "Fala → dados prontos no replay (ms)")]:
            for screen in by_name[name]:
                text = next((e for e in by_name["transcript"] if e.get("segment") == screen.get("segment")), None)
                if text and text.get("audioEndMS") is not None and screen["ms"] >= origin + text["audioEndMS"]:
                    values[label].append(screen["ms"] - origin - text["audioEndMS"])

    values["Falhas da prévia"].append(len(by_name["preview_failure"]))
    values["Chamadas de extração"].append(len(by_name["extract_start"]))
    for field, label in [("inputTokens", "Tokens de entrada"), ("outputTokens", "Tokens de saída")]:
        tokens = [event[field] for event in by_name["extract_end"] if field in event]
        if tokens:
            values[label].append(sum(tokens))
    clip = corpus.get(run["clip"])
    text = run.get("transcript")
    if clip and text is not None and timing["transcriber"] in ("apple", "gpt"):
        values["WER (%)"].append(wer(clip["text"], text))
        values["Termos esperados reconhecidos (%)"].append(100 * sum(has(text, t) for t in clip["terms"]) / len(clip["terms"]))
        values["Termos ausentes inseridos (%)"].append(100 * sum(has(text, t) for t in clip["absent"]) / len(clip["absent"]))
    if clip and run.get("tasks") is not None:
        tasks = run["tasks"]
        values["Títulos exatos F1 (%)"].append(f1(clip["titles"], [t["title"] for t in tasks]))
        values["Prazos F1 (%)"].append(f1(clip["deadlines"], [t["deadline"] for t in tasks if t.get("deadline")]))
        values["Checklist exato F1 (%)"].append(f1(clip["checklist"], [s for t in tasks for s in t["checklist"]]))
    return values

def esc(text):
    return html.escape(str(text))

groups = collections.defaultdict(list)
for run in runs:
    t = run["timing"]
    key = (t["transcriber"], t["model"], t["language"], t["strategy"], "1ª" if t["first"] else "seguinte", "com voc." if t["vocabulary"] else "sem voc.")
    groups[key].append(run)

cloud = any(r["timing"]["transcriber"] in ("gpt", "reference") for r in runs)
cloud_note = "" if cloud else "<p><strong>OpenAI:</strong> sem execuções do benchmark na nuvem. Extração comparativa, estratégias e métricas de tokens dependem da matriz com chave.</p>"
data = collections.defaultdict(list)
summary = []
for group, rows in sorted(groups.items()):
    label = " / ".join(group)
    failures = sum(bool(row.get("error")) or any(e["name"] in ("failure", "extraction_failure") for e in row["timing"]["events"]) for row in rows)
    canceled = sum(any(e["name"] == "canceled" for e in row["timing"]["events"]) for row in rows)
    local = collections.defaultdict(list)
    for row in rows:
        for metric, samples in metrics(row).items():
            local[metric].extend(samples)
    for metric, samples in local.items():
        p95 = sorted(samples)[math.ceil(.95 * len(samples)) - 1]
        data[metric].append((label, statistics.median(samples), p95, len(samples)))
    summary.append(f"<tr><td>{esc(label)}</td><td>{len(rows)}</td><td>{failures}</td><td>{canceled}</td></tr>")

charts = []
for metric, rows in sorted(data.items()):
    maximum = max(1, *(r[2] for r in rows))
    bars = []
    for label, median, p95, n in rows:
        bars.append(f"<tr><td>{esc(label)}</td><td><div class='bar'><i style='width:{100*p95/maximum:.2f}%'></i>"
                    f"<b style='width:{100*median/maximum:.2f}%'></b></div></td>"
                    f"<td>{median:.1f}</td><td>{p95:.1f}</td><td>{n}</td></tr>")
    charts.append(f"<section><h2>{esc(metric)}</h2><table><tr><th>Configuração</th><th>Comparação</th>"
                  f"<th>Mediana</th><th>p95</th><th>Amostras</th></tr>{''.join(bars)}</table></section>")

details = []
for run in runs:
    t = run["timing"]
    rows = "".join(f"<tr><td>{e['ms']:.1f}</td><td>{esc(e['name'])}</td><td>{esc(e.get('segment', ''))}</td>"
                   f"<td>{esc(e.get('audioEndMS', ''))}</td></tr>" for e in t["events"])
    payload = {k: run[k] for k in ("error", "transcript", "tasks") if k in run}
    details.append(f"<details><summary>{esc(run['clip'])} · {esc(t['transcriber'])} · {esc(t['strategy'])} · "
                   f"{esc(t['capture'])}</summary><table><tr><th>ms</th><th>Evento</th><th>Trecho/revisão</th>"
                   f"<th>Fim no áudio (ms)</th></tr>{rows}</table><pre>{esc(json.dumps(payload, ensure_ascii=False, indent=2))}</pre></details>")

page = f"""<!doctype html><html lang="pt-BR"><meta charset="utf-8"><title>Ramble — desempenho</title>
<style>
:root{{color-scheme:light dark;font:15px system-ui}}body{{max-width:1100px;margin:50px auto;padding:0 24px}}
h1{{font-size:34px}} h2{{font-size:19px}}p{{max-width:78ch}}table{{width:100%;border-collapse:collapse}}
td,th{{padding:7px 9px;text-align:left;border-bottom:1px solid #8884}}td:nth-child(n+3){{font-variant-numeric:tabular-nums}}
section,details{{margin:25px 0}}.bar{{position:relative;height:10px;min-width:110px}}
.bar i,.bar b{{position:absolute;inset:0 auto 0 0;border-radius:4px;background:#83b9fc}}.bar b{{background:#2177d5}}
pre{{white-space:pre-wrap}}summary{{cursor:pointer}}
</style><h1>Desempenho do Things 3 Ramble</h1>
<p>{len(runs)} execuções. Azul escuro indica a mediana e azul claro o p95 por ordem de amostra. 
A primeira execução é a primeira observada por configuração nesta sessão, mesmo com o modelo já instalado.
F1 de títulos e checklist usa correspondência exata após normalizar caixa e pontuação.</p>
<p>O corpus usa vozes sintéticas. O replay mede quando os dados ficam prontos.
A atualização AppKit marca o ciclo de desenho da janela. O benchmark usa o último trecho anotado e o primeiro parcial que contém sua frase.
Para GPT ao vivo no app, os eventos ficam associados ao turno. Sem marcação de trecho no protocolo, o relatório omite fala → parcial/final/tela.</p>
{cloud_note}<h2>Execuções</h2><table><tr><th>Transcritor / modelo / idioma / estratégia / sessão / vocabulário</th><th>N</th><th>Falhas</th><th>Canceladas</th></tr>
{''.join(summary)}</table>{''.join(charts)}<h2>Linha do tempo por captura</h2>{''.join(details)}
</html>"""
path = root / "report.html"
path.write_text(page)
print(path)
