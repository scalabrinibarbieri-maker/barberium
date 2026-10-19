#!/usr/bin/env python3
"""Compara a impressão digital do schema da produção com a do banco reconstruído.

Uso:
  comparar_impressao.py PRODUCAO.json RECONSTRUIDO.json \
      [--migrations supabase/migrations --versoes-producao versoes.txt]

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
    args = ap.parse_args()

    prod = carregar(args.producao)
    rec = carregar(args.reconstruido)

    linhas = []
    total = 0
    for secao in sorted(set(prod) | set(rec)):
        so_prod, so_rec, dif = comparar_secao(prod.get(secao), rec.get(secao))
        n = len(so_prod) + len(so_rec) + len(dif)
        total += n
        qtd = len(prod.get(secao) or {}) if isinstance(prod.get(secao), dict) else "-"
        linhas.append(f"{secao}: {qtd} itens na produção, {n} diferença(s)")
        for k in so_prod:
            linhas.append(f"  só na produção: {k}")
        for k in so_rec:
            linhas.append(f"  só no reconstruído: {k}")
        for k, campos in dif.items():
            linhas.append(f"  diferente: {k}")
            for c, (a, b) in campos.items():
                linhas.append(f"    {c}: produção={curto(a)} | reconstruído={curto(b)}")

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
        linhas.append(f"histórico: {len(repo)} arquivos no repositório, {len(producao)} versões na produção")
        for v in sem_arquivo:
            linhas.append(f"  ERRO: versão {v} aplicada na produção sem arquivo em supabase/migrations")
        for v in nao_registradas:
            avisos_hist.append(v)
            linhas.append(f"  aviso: versão {v} existe no repositório e não consta no histórico da produção")
        erros_hist = len(sem_arquivo)

    print("\n".join(linhas))
    print()
    if total == 0 and erros_hist == 0:
        print("RESULTADO: banco reconstruído do repositório é idêntico à produção.")
    else:
        print(f"RESULTADO: {total} diferença(s) de schema, {erros_hist} migration(s) sem arquivo.")

    if os.environ.get("GITHUB_ACTIONS") == "true":
        for v in avisos_hist:
            print(f"::warning::Migration {v} está no repositório e não consta no histórico da produção.")
        if total:
            print(f"::error::{total} diferença(s) entre a produção e o banco reconstruído. Veja o log acima.")
        if erros_hist:
            print(f"::error::{erros_hist} migration(s) aplicada(s) na produção sem arquivo no repositório.")
        resumo = os.environ.get("GITHUB_STEP_SUMMARY")
        if resumo:
            with open(resumo, "a", encoding="utf-8") as f:
                ok = total == 0 and erros_hist == 0
                f.write("## Banco reproduzível\n\n")
                f.write("**Idêntico à produção.**\n\n" if ok else f"**{total} diferença(s) de schema, {erros_hist} migration(s) sem arquivo.**\n\n")
                f.write("```\n" + "\n".join(linhas[:400]) + "\n```\n")

    sys.exit(0 if total == 0 and erros_hist == 0 else 1)


if __name__ == "__main__":
    main()
