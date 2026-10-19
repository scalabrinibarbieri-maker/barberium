#!/usr/bin/env python3
"""Compara a impressão digital do schema da produção com a do banco reconstruído.

Uso:
  comparar_impressao.py PRODUCAO.json RECONSTRUIDO.json \
      [--migrations supabase/migrations --versoes-producao versoes.txt]
      [--alvo teste] [--exigir-todas] [--titulo "Banco reproduzível"]

--alvo teste troca "produção" por "banco de teste" nas mensagens. --exigir-todas trata como
erro uma migration do repositório que não está no histórico do banco (usado depois de publicar).

Os dois JSON vêm de supabase/reconstrucao/impressao_digital.sql. Sai com código 1 se houver
qualquer diferença de schema ou se a produção tiver migration sem arquivo no repositório.
Migration que existe no repositório e ainda não consta no histórico da produção gera aviso.
"""
import argparse
import json
import os
import sys


def carregar(caminho):
    with open(caminho, encoding="utf-8") as f:
        texto = f.read().strip()
    if not texto:
        sys.exit(f"ERRO: {caminho} está vazio.")
    return json.loads(texto)


def curto(valor, limite=160):
    s = json.dumps(valor, ensure_ascii=False, sort_keys=True) if not isinstance(valor, str) else valor
    return s if len(s) <= limite else s[: limite - 1] + "…"


def comparar_secao(prod, rec):
    prod = prod or {}
    rec = rec or {}
    if not isinstance(prod, dict) or not isinstance(rec, dict):
        return ([], [], {"(valor)": [prod, rec]}) if prod != rec else ([], [], {})
    so_prod = sorted(set(prod) - set(rec))
    so_rec = sorted(set(rec) - set(prod))
    diferentes = {}
    for k in sorted(set(prod) & set(rec)):
        a, b = prod[k], rec[k]
        if a == b:
            continue
        if isinstance(a, dict) and isinstance(b, dict):
            campos = {c: [a.get(c), b.get(c)] for c in sorted(set(a) | set(b)) if a.get(c) != b.get(c)}
        else:
            campos = {"(valor)": [a, b]}
        diferentes[k] = campos
    return so_prod, so_rec, diferentes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("producao")
    ap.add_argument("reconstruido")
    ap.add_argument("--migrations", help="pasta com os arquivos <versão>_<nome>.sql")
    ap.add_argument("--versoes-producao", help="arquivo com uma versão por linha, lida da produção")
    ap.add_argument("--alvo", choices=["producao", "teste"], default="producao")
    ap.add_argument("--exigir-todas", action="store_true")
    ap.add_argument("--titulo", default="Banco reproduzível")
    args = ap.parse_args()
    if args.alvo == "producao":
        A, NA, DA, AO, A_ART = "produção", "na produção", "da produção", "à produção", "a produção"
    else:
        A, NA, DA, AO, A_ART = "banco de teste", "no banco de teste", "do banco de teste", "ao banco de teste", "o banco de teste"

    prod = carregar(args.producao)
    rec = carregar(args.reconstruido)

    linhas = []
    total = 0
    for secao in sorted(set(prod) | set(rec)):
        so_prod, so_rec, dif = comparar_secao(prod.get(secao), rec.get(secao))
        n = len(so_prod) + len(so_rec) + len(dif)
        total += n
        qtd = len(prod.get(secao) or {}) if isinstance(prod.get(secao), dict) else "-"
        linhas.append(f"{secao}: {qtd} itens {NA}, {n} diferença(s)")
        for k in so_prod:
            linhas.append(f"  só {NA}: {k}")
        for k in so_rec:
            linhas.append(f"  só no reconstruído: {k}")
        for k, campos in dif.items():
            linhas.append(f"  diferente: {k}")
            for c, (a, b) in campos.items():
                linhas.append(f"    {c}: {A}={curto(a)} | reconstruído={curto(b)}")

    erros_hist = 0
    avisos_hist = []
    if args.migrations and args.versoes_producao:
        repo = set()
        for nome in os.listdir(args.migrations):
            if nome.endswith(".sql"):
                repo.add(nome.split("_", 1)[0])
        with open(args.versoes_producao, encoding="utf-8") as f:
            producao = {l.strip() for l in f if l.strip()}
        sem_arquivo = sorted(producao - repo)
        nao_registradas = sorted(repo - producao)
        linhas.append(f"histórico: {len(repo)} arquivos no repositório, {len(producao)} versões {NA}")
        for v in sem_arquivo:
            linhas.append(f"  ERRO: versão {v} aplicada {NA} sem arquivo em supabase/migrations")
        for v in nao_registradas:
            avisos_hist.append(v)
            tipo = "ERRO" if args.exigir_todas else "aviso"
            linhas.append(f"  {tipo}: versão {v} existe no repositório e não consta no histórico {DA}")
        erros_hist = len(sem_arquivo) + (len(nao_registradas) if args.exigir_todas else 0)

    print("\n".join(linhas))
    print()
    if total == 0 and erros_hist == 0:
        print(f"RESULTADO: banco reconstruído do repositório é idêntico {AO}.")
    else:
        print(f"RESULTADO: {total} diferença(s) de schema, {erros_hist} problema(s) no histórico de migrations.")

    if os.environ.get("GITHUB_ACTIONS") == "true":
        if not args.exigir_todas:
            for v in avisos_hist:
                print(f"::notice::Migration {v} ainda não foi publicada {NA}.")
        if total:
            print(f"::error::{total} diferença(s) entre {A_ART} e o banco reconstruído. Veja o log acima.")
        if erros_hist:
            print(f"::error::{erros_hist} problema(s) no histórico de migrations {NA}. Veja o log acima.")
        resumo = os.environ.get("GITHUB_STEP_SUMMARY")
        if resumo:
            with open(resumo, "a", encoding="utf-8") as f:
                ok = total == 0 and erros_hist == 0
                f.write(f"## {args.titulo}\n\n")
                f.write(f"**Idêntico {AO}.**\n\n" if ok else f"**{total} diferença(s) de schema, {erros_hist} problema(s) no histórico.**\n\n")
                f.write("```\n" + "\n".join(linhas[:400]) + "\n```\n")

    sys.exit(0 if total == 0 and erros_hist == 0 else 1)


if __name__ == "__main__":
    main()
