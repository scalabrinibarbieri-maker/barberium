#!/usr/bin/env python3
"""Confere se tudo o que o site carrega está na pasta que vai ser publicada.

Uso: conferir_referencias.py PASTA_DO_SITE

Lê os HTML (src/href), os JS (import e textos com caminho de arquivo, como a lista do
service worker) e o manifest. Cada caminho local precisa existir na pasta. Sai com
código 1 se faltar algum: o deploy para antes de publicar um site quebrado.
"""
import json
import os
import re
import sys
from urllib.parse import urlsplit

EXT = r"(?:js|mjs|css|html|webp|svg|png|jpg|jpeg|ico|webmanifest|json)"
RE_ATTR = re.compile(r"""\b(?:src|href)\s*=\s*["']([^"']+)["']""", re.I)
RE_JS = re.compile(r"""(['"`])((?:\.{1,2}/)?[A-Za-z0-9_\-][A-Za-z0-9_\-./]*\.""" + EXT + r""")(\?[^'"`]*)?\1""")
RE_JS_DIR = re.compile(r"""(['"`])(\.{1,2}/(?:[A-Za-z0-9_\-]+/)*)\1""")


def locais(texto, tipo):
    refs = []
    if tipo == "html":
        refs += RE_ATTR.findall(texto)
    elif tipo == "js":
        refs += [m.group(2) + (m.group(3) or "") for m in RE_JS.finditer(texto)]
        refs += [m.group(2) for m in RE_JS_DIR.finditer(texto)]
    elif tipo == "manifest":
        try:
            dados = json.loads(texto)
        except ValueError:
            return refs
        refs += [i.get("src", "") for i in dados.get("icons", []) if isinstance(i, dict)]
    saida = []
    for r in refs:
        r = r.strip()
        if not r or "${" in r or r.startswith(("#", "data:", "mailto:", "tel:", "javascript:", "//")):
            continue
        partes = urlsplit(r)
        if partes.scheme or partes.netloc:
            continue
        saida.append(partes.path)
    return saida


def main():
    raiz = os.path.realpath(sys.argv[1])
    publicados = set()
    for base, _, arquivos in os.walk(raiz):
        for a in arquivos:
            publicados.add(os.path.relpath(os.path.join(base, a), raiz).replace(os.sep, "/"))

    faltando, usados = [], set()
    for arq in sorted(publicados):
        tipo = {"html": "html", "js": "js", "mjs": "js", "webmanifest": "manifest"}.get(arq.rsplit(".", 1)[-1])
        if not tipo:
            continue
        with open(os.path.join(raiz, arq), encoding="utf-8", errors="replace") as f:
            texto = f.read()
        pasta = os.path.dirname(arq)
        for caminho in locais(texto, tipo):
            alvo = os.path.normpath(os.path.join(pasta, caminho)) if not caminho.startswith("/") else caminho.lstrip("/")
            alvo = alvo.replace(os.sep, "/")
            if alvo in (".", ""):
                alvo = "index.html"
            elif caminho.endswith("/"):
                alvo = alvo + "/index.html"
            if alvo.startswith(".."):
                faltando.append((arq, caminho, "aponta para fora do site"))
                continue
            # Em JS, um caminho "solto" (sem ./ nem ../) costuma ser montado depois a partir da
            # raiz do site, como image_path vindo do banco. Vale se existir em qualquer um dos dois.
            if tipo == "js" and not caminho.startswith((".", "/")) and alvo not in publicados and caminho in publicados:
                alvo = caminho
            usados.add(alvo)
            if alvo not in publicados:
                faltando.append((arq, caminho, alvo))

    sem_uso = sorted(p for p in publicados - usados
                     if p not in ("index.html", "_headers", "_redirects") and not p.startswith("assets/"))
    print(f"Referências conferidas em {len(publicados)} arquivos publicados.")
    if sem_uso:
        print("Publicados sem nenhuma página carregando (não impede o deploy):")
        for p in sem_uso:
            print(f"  {p}")
    if faltando:
        print("FALTANDO no site (o deploy foi interrompido):")
        for arq, caminho, alvo in faltando:
            print(f"  {arq} carrega '{caminho}' -> {alvo}")
        sys.exit(1)
    print("OK: tudo o que as páginas carregam está publicado.")


if __name__ == "__main__":
    main()
