#!/usr/bin/env python3
"""Carimba a versão da publicação no site montado (etapa 4).

Uso: carimbar_versao.py PASTA_DO_SITE VERSAO COMMIT DATA

A versão é o commit publicado (7 primeiros caracteres). Ela vai para:
  - o fim de todo endereço de script e estilo do próprio site (?v=VERSAO), nas páginas e nos
    "import" dos scripts. Endereço novo a cada publicação: nenhum navegador reaproveita o
    arquivo da versão anterior, mesmo com o cache de 4 horas do domínio;
  - <meta name="barberium-versao"> nas páginas, que o shared/atualizacao.js compara com
  - /versao.json, publicado junto;
  - o service worker (sw.js), que usa um cache por versão.
Sai com código 1 se algo ficar sem carimbo.
"""
import json
import os
import re
import sys

ASPAS_ATTR = re.compile(r"""\b((?:src|href)\s*=\s*)(["'])([^"'?#]+\.(?:js|mjs|css))(?:\?[^"'#]*)?\2""", re.I)
IMPORT_JS = re.compile(r"""(["'`])(\.{1,2}/[^"'`?\s]+\.(?:js|mjs|css))\?v=[^"'`]*\1""")
META_CHARSET = re.compile(r"""<meta\s+charset=["']?utf-8["']?\s*/?>""", re.I)
V_LOCAL = re.compile(r"""(["'`])((?:\.{1,2}/)?[A-Za-z0-9_\-][A-Za-z0-9_\-./]*\.(?:js|mjs|css))\?v=([^"'`]*)\1""")


def local(caminho):
    return not re.match(r"^(?:[a-z][a-z0-9+.-]*:|//)", caminho, re.I)


def main():
    pasta, versao, commit, data = sys.argv[1:5]
    if not re.fullmatch(r"[0-9a-f]{7,40}", versao):
        sys.exit(f"versão inválida: {versao!r}")
    erros = []
    n_paginas = n_refs = n_imports = 0

    for base, _, arquivos in os.walk(pasta):
        for nome in arquivos:
            caminho = os.path.join(base, nome)
            rel = os.path.relpath(caminho, pasta).replace(os.sep, "/")
            if nome.endswith(".html"):
                html = open(caminho, encoding="utf-8").read()

                def trocar_attr(m):
                    nonlocal n_refs
                    if not local(m.group(3)):
                        return m.group(0)
                    n_refs += 1
                    return f"{m.group(1)}{m.group(2)}{m.group(3)}?v={versao}{m.group(2)}"

                html = ASPAS_ATTR.sub(trocar_attr, html)
                if "barberium-versao" in html:
                    erros.append(f"{rel}: já tem <meta name=\"barberium-versao\">")
                html, n = META_CHARSET.subn(lambda m: f'{m.group(0)}\n  <meta name="barberium-versao" content="{versao}">', html, count=1)
                if n != 1:
                    erros.append(f"{rel}: sem <meta charset=\"utf-8\"> para pôr a versão ao lado")
                open(caminho, "w", encoding="utf-8").write(html)
                n_paginas += 1
            elif nome.endswith((".js", ".mjs")):
                js = open(caminho, encoding="utf-8").read()
                js, n = IMPORT_JS.subn(lambda m: f"{m.group(1)}{m.group(2)}?v={versao}{m.group(1)}", js)
                n_imports += n
                if rel == "sw.js":
                    if js.count("__VERSAO__") != 1:
                        erros.append("sw.js: esperava exatamente um __VERSAO__")
                    js = js.replace("__VERSAO__", versao)
                open(caminho, "w", encoding="utf-8").write(js)

    # Conferência: nenhum ?v= local com outra versão.
    for base, _, arquivos in os.walk(pasta):
        for nome in arquivos:
            if not nome.endswith((".html", ".js", ".mjs")):
                continue
            caminho = os.path.join(base, nome)
            texto = open(caminho, encoding="utf-8").read()
            for m in V_LOCAL.finditer(texto):
                if m.group(3) != versao:
                    erros.append(f"{os.path.relpath(caminho, pasta)}: {m.group(2)}?v={m.group(3)} ficou sem a versão nova")
            if "__VERSAO__" in texto:
                erros.append(f"{os.path.relpath(caminho, pasta)}: sobrou __VERSAO__")

    with open(os.path.join(pasta, "versao.json"), "w", encoding="utf-8") as f:
        json.dump({"versao": versao, "commit": commit, "data": data}, f, ensure_ascii=False)
        f.write("\n")

    if erros:
        print("ERRO ao carimbar a versão:", file=sys.stderr)
        for e in erros:
            print(f"  {e}", file=sys.stderr)
        sys.exit(1)
    print(f"Versão {versao} carimbada: {n_paginas} páginas, {n_refs} scripts e estilos nas páginas, "
          f"{n_imports} import(s) entre scripts, service worker e versao.json.")


if __name__ == "__main__":
    main()
