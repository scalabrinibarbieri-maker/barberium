#!/usr/bin/env python3
"""Personaliza uma cópia do site montado para o endereço de uma barbearia (painel do dono).

Uso: personalizar_barbearia.py PASTA_DO_SITE JSON_DO_ENDERECO

JSON_DO_ENDERECO é a resposta de barberium_resolve_tenant(host). O site já descobre a barbearia
pelo endereço ao abrir; esta cópia troca o que aparece ANTES do JavaScript rodar e o que ele não
troca: título e descrição (Google e prévia do link no WhatsApp), ícone, logo da tela de abertura,
nome do app instalado, WhatsApp e mapa do cartão da unidade, e o horário escrito à mão, que é o
da Scalabrini. Cada trecho trocado precisa existir: se o index.html mudar, a publicação para aqui
em vez de publicar a barbearia com texto da Scalabrini.
"""
import html
import urllib.parse
import json
import os
import re
import sys


def trocar(texto, antigo, novo, onde):
    if texto.count(antigo) != 1:
        sys.exit(f"{onde}: esperava 1 ocorrência de {antigo[:60]!r}, achei {texto.count(antigo)}")
    return texto.replace(antigo, novo)


def main():
    pasta, dados = sys.argv[1], json.loads(sys.argv[2])
    b, u = dados["barbershop"], dados.get("unit") or {}
    nome = b["name"].strip()
    unidade = (u.get("name") or "").strip()
    cidade = (u.get("city") or "").strip()
    estado = (u.get("state") or "").strip()
    local = " • ".join(x for x in [unidade, cidade] if x) or nome
    logo = dados.get("logo_url") or "/barberium.svg"
    whats = re.sub(r"\D", "", u.get("whatsapp") or "")
    mapa = u.get("maps_url") or ""
    e = lambda s: html.escape(s, quote=True)

    caminho = os.path.join(pasta, "index.html")
    t = open(caminho, encoding="utf-8").read()
    t = trocar(t, '<meta name="description" content="Agende seu horário na Scalabrini Barbiere — II Unidade, Bragança Paulista.">',
               f'<meta name="description" content="Agende seu horário na {e(nome)}{" — " + e(unidade) if unidade else ""}{", " + e(cidade) if cidade else ""}.">', "index.html")
    t = trocar(t, "let logo='./assets/logo-sb.webp';", f"let logo={json.dumps(logo)};", "index.html")
    # O cache antigo da tela de abertura é da Scalabrini: neste endereço, não vale.
    t = trocar(t, "||localStorage.getItem('barberium:brand-logo:scalabrini-barbieri:braganca-paulista')", "", "index.html")
    t = trocar(t, '<link rel="icon" href="./assets/logo-sb.webp">', f'<link rel="icon" href="{e(logo)}">', "index.html")
    titulo_antigo = re.search(r"<title>(\[TESTE\] )?Scalabrini Barbiere • Bragança Paulista</title>", t)
    if not titulo_antigo:
        sys.exit("index.html: título da Scalabrini não encontrado")
    t = t.replace(titulo_antigo.group(0), f"<title>{titulo_antigo.group(1) or ''}{e(nome)} • {e(cidade or unidade or 'Agendamento')}</title>")
    t = trocar(t, '<img id="barberiumSplashLogo" src="./assets/logo-sb.webp" alt="">', f'<img id="barberiumSplashLogo" src="{e(logo)}" alt="">', "index.html")
    t = trocar(t, '<img src="./assets/logo-sb.webp" alt="" class="mini-logo">', f'<img src="{e(logo)}" alt="" class="mini-logo">', "index.html")
    t = trocar(t, "<span><strong>Scalabrini Barbiere</strong><small>II Unidade • Bragança Paulista</small></span>",
               f"<span><strong>{e(nome)}</strong><small>{e(local)}</small></span>", "index.html")
    t = trocar(t, '<img class="hero-bg" src="./assets/barbearia.webp" alt="Interior da Scalabrini Barbiere" fetchpriority="high">',
               f'<img class="hero-bg" src="./assets/capa-padrao.webp" alt="Interior da {e(nome)}" fetchpriority="high">', "index.html")
    t = trocar(t, '<img class="hero-logo" src="./assets/logo-sb.webp" alt="Scalabrini Barbiere">', f'<img class="hero-logo" src="{e(logo)}" alt="{e(nome)}">', "index.html")
    t = trocar(t, '<p class="hero-unit">Casa Scalabrini</p>', f'<p class="hero-unit">{e(nome)}</p>', "index.html")
    t = trocar(t, '<div class="unit-logo-wrap"><img src="./assets/logo-sb.webp" alt=""></div>', f'<div class="unit-logo-wrap"><img src="{e(logo)}" alt=""></div>', "index.html")
    t = trocar(t, "<h2>II Unidade — Bragança Paulista</h2>", f"<h2>{e(unidade or nome)}</h2>", "index.html")
    t = trocar(t, "<strong>Segunda a sábado<br>10:00 — 20:00</strong>", "<strong>Veja os horários livres<br>ao agendar</strong>", "index.html")
    t = trocar(t, "<strong>+55 11 94524-6544</strong>", f"<strong>{e(u.get('whatsapp') or 'Fale pelo site')}</strong>", "index.html")
    t = trocar(t, 'href="https://wa.me/5511945246544"', f'href="{e("https://wa.me/" + whats) if whats else "#"}"', "index.html")
    t = trocar(t, 'href="https://maps.app.goo.gl/ztpb7NShYtjQES897?g_st=ac"',
               f'href="{e(mapa) if mapa else e("https://www.google.com/maps/search/?api=1&query=" + urllib.parse.quote(" ".join(x for x in [nome, cidade, estado] if x)))}"', "index.html")
    t = trocar(t, "<p>Os dados usados nos seus agendamentos da Scalabrini Barbiere.</p>", f"<p>Os dados usados nos seus agendamentos da {e(nome)}.</p>", "index.html")
    sobra = re.search(r"scalabrini|94524|ztpb7|logo-sb|barbearia\.webp", t, re.I)
    if sobra:
        sys.exit(f"index.html: sobrou referência à Scalabrini: {t[max(0, sobra.start() - 60):sobra.end() + 30]!r}")
    open(caminho, "w", encoding="utf-8").write(t)

    caminho = os.path.join(pasta, "equipe", "index.html")
    t = open(caminho, encoding="utf-8").read()
    for antigo in ['<link rel="icon" href="../assets/logo-sb.webp">', '<img src="../assets/logo-sb.webp" alt="">']:
        if antigo not in t:
            sys.exit(f"equipe/index.html: não achei {antigo!r}")
        t = t.replace(antigo, antigo.replace("../assets/logo-sb.webp", e(logo)))
    open(caminho, "w", encoding="utf-8").write(t)

    caminho = os.path.join(pasta, "site.webmanifest")
    m = json.load(open(caminho, encoding="utf-8"))
    m["name"] = f"{nome}{' — ' + cidade if cidade else ''}"
    m["short_name"] = nome[:24]
    m["icons"] = [{"src": logo, "sizes": "any", "type": "image/svg+xml" if logo.endswith(".svg") else "image/webp", "purpose": "any"}]
    open(caminho, "w", encoding="utf-8").write(json.dumps(m, ensure_ascii=False, indent=2) + "\n")
    print(f"{dados['host']}: personalizado para {nome}")


if __name__ == "__main__":
    main()
