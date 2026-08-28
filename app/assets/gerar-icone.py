#!/usr/bin/env python3
"""
Gerador do ícone PROVISÓRIO da Web Rádio Porto do Capim.

POR QUE UM SCRIPT E NÃO SÓ O PNG:
Este ícone é temporário — existe para destravar a publicação enquanto a
identidade visual real da emissora não chega. Deixar o gerador versionado
permite regerar em qualquer tamanho, ajustar a cor, e deixa explícito para
quem vier depois que isto NÃO é a marca definitiva.

DECISÕES DE DESENHO, e o motivo de cada uma:

  Sem cantos arredondados. A Play Store e o Android aplicam a própria
  máscara (círculo, squircle, etc.). Arredondar aqui produz canto duplo,
  aquele halo escuro nas bordas.

  Sem texto. "Web Rádio Porto do Capim" é ilegível a 48px, que é o tamanho
  real em que o ícone vive na tela do usuário. Ícone de app é símbolo.

  Ondas concêntricas em vez de torre. A torre de transmissão vira um borrão
  vertical quando reduzida; arcos mantêm a silhueta reconhecível.

  Margem de 18%. As máscaras do Android cortam até ~10% da borda. Elementos
  próximos ao limite somem em aparelhos com máscara circular.

Uso:
    python3 gerar-icone.py            # gera todos os tamanhos
    python3 gerar-icone.py --check    # só valida o que já existe
"""

import sys
from pathlib import Path
from PIL import Image, ImageDraw

AQUI = Path(__file__).parent

# Mesma cor do tema do app (main.dart: Color(0xFF00695C) na família teal)
# e do player web. Manter as três iguais evita a sensação de coisas
# diferentes coladas.
FUNDO = (18, 137, 122)      # #12897a
TINTA = (255, 255, 255)

# 512 é o exigido pela Play Store. Renderizamos em 4x e reduzimos com
# LANCZOS: desenhar direto em 512 deixa os arcos serrilhados.
BASE = 2048


def desenhar(tamanho: int) -> Image.Image:
    img = Image.new("RGBA", (BASE, BASE), FUNDO + (255,))
    d = ImageDraw.Draw(img)

    cx, cy = BASE // 2, BASE // 2
    ponto_r = int(BASE * 0.058)

    # Ponto emissor, ao centro
    d.ellipse([cx - ponto_r, cy - ponto_r, cx + ponto_r, cy + ponto_r], fill=TINTA)

    # Arcos SIMÉTRICOS, à esquerda e à direita.
    #
    # A primeira versão tinha arcos só para cima e ficou indistinguível do
    # ícone de Wi-Fi — numa lista de apps isso confunde e não comunica
    # "rádio". Ondas saindo dos dois lados de um ponto central é a leitura
    # convencional de transmissão sonora.
    for raio_f, esp_f in [(0.15, 0.032), (0.245, 0.036), (0.34, 0.040)]:
        r = int(BASE * raio_f)
        esp = int(BASE * esp_f)
        caixa = [cx - r, cy - r, cx + r, cy + r]
        d.arc(caixa, start=-52, end=52, fill=TINTA, width=esp)      # direita
        d.arc(caixa, start=128, end=232, fill=TINTA, width=esp)     # esquerda

    return img.resize((tamanho, tamanho), Image.LANCZOS).convert("RGB")


def main():
    if "--check" in sys.argv:
        for p in sorted(AQUI.glob("icone-*.png")):
            im = Image.open(p)
            print(f"  {p.name}: {im.size[0]}x{im.size[1]} {im.mode}")
        return

    # 512: Play Store e Testers Community
    # 1024: App Store (iOS exige, e sem canal alfa)
    # 192/144/96/72/48: densidades do launcher Android
    for tam in (1024, 512, 192, 144, 96, 72, 48):
        img = desenhar(tam)
        saida = AQUI / f"icone-{tam}.png"
        img.save(saida, "PNG", optimize=True)
        kb = saida.stat().st_size / 1024
        print(f"  icone-{tam}.png  {tam}x{tam}  {kb:.1f} KB")

    print()
    print("  PROVISÓRIO — substituir pela identidade visual da emissora")
    print("  antes da publicação definitiva nas lojas.")


if __name__ == "__main__":
    main()
