#!/usr/bin/env python3
"""
Valida os textos e imagens da ficha da Play Store antes de colar no Console.

POR QUE EXISTE: o Play Console só reclama do limite DEPOIS de você colar e
tentar salvar, um campo por vez, e o contador dele conta caracteres Unicode —
"BitRádio" tem 8, não 9. Descobrir aqui custa um segundo; descobrir lá custa
uma ida e volta por campo.

Uso:
    python3 validar-ficha.py
"""

import re
import sys
from pathlib import Path

AQUI = Path(__file__).parent
FICHA = AQUI / "play-store.md"
ASSETS = AQUI.parent / "app" / "assets"

# Limites da Google Play, na ordem em que os blocos ```...``` aparecem no .md
LIMITES = [
    ("Nome do app", 30),
    ("Nome do app (alternativa)", 30),
    ("Descrição curta", 80),
    ("Descrição completa", 4000),
]

IMAGENS = [
    ("icone-512.png", (512, 512)),
    ("destaque-1024x500.png", (1024, 500)),
]


def main() -> int:
    falhas = []

    blocos = re.findall(r"^```\n(.*?)^```", FICHA.read_text(encoding="utf-8"),
                        re.S | re.M)
    if len(blocos) != len(LIMITES):
        print(f"!! esperava {len(LIMITES)} blocos de texto, achei {len(blocos)}")
        return 1

    for (nome, limite), texto in zip(LIMITES, blocos):
        n = len(texto.strip())
        ok = n <= limite
        print(f"  {'ok ' if ok else 'FALHA'} {nome:<28} {n:>4}/{limite}")
        if not ok:
            falhas.append(f"{nome}: {n - limite} caracteres a mais")

    print()
    try:
        from PIL import Image
    except ImportError:
        print("  (PIL ausente — imagens não verificadas)")
        return 1 if falhas else 0

    for arquivo, esperado in IMAGENS:
        caminho = ASSETS / arquivo
        if not caminho.exists():
            print(f"  FALHA {arquivo:<28} ausente")
            falhas.append(f"{arquivo} não existe")
            continue
        tam = Image.open(caminho).size
        ok = tam == esperado
        print(f"  {'ok ' if ok else 'FALHA'} {arquivo:<28} {tam[0]}x{tam[1]}")
        if not ok:
            falhas.append(f"{arquivo}: esperado {esperado[0]}x{esperado[1]}")

    print()
    if falhas:
        for f in falhas:
            print(f"  ! {f}")
        return 1
    print("  ficha pronta para colar no Play Console")
    return 0


if __name__ == "__main__":
    sys.exit(main())
