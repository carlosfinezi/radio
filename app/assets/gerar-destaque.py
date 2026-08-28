#!/usr/bin/env python3
"""
Gráfico de destaque (feature graphic) do BitRádio para a Play Store.

A Play Store EXIGE esta imagem em 1024x500 para publicar. É o banner que
aparece no topo da ficha do app e nas coleções editoriais.

DECISÕES DE DESENHO, e o motivo de cada uma:

  Área segura central. A loja recorta as bordas de formas diferentes
  conforme o dispositivo e o contexto (banner largo, card, coleção). Tudo
  que importa fica dentro dos 70% centrais; as ondas sangram de propósito.

  Texto grande e curto. Este banner aparece com ~300px de largura em
  celular. "BitRádio" cabe; um slogan longo vira ruído cinza.

  Sem screenshot embutido. A Play Store rejeita gráfico de destaque que
  seja só uma captura de tela do app, e o banner já convive com as capturas
  logo abaixo na mesma página.

  Mesma cor do ícone e do app (#12897a). Ver gerar-icone.py — as três
  peças iguais evitam a sensação de coisas diferentes coladas.

Uso:
    python3 gerar-destaque.py
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

AQUI = Path(__file__).parent

L, A = 1024, 500
FUNDO = (18, 137, 122)          # #12897a — igual ao ícone e ao tema do app
TINTA = (255, 255, 255)

FONTE_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
FONTE = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"

# Renderiza em 2x e reduz com LANCZOS: os arcos ficam serrilhados se
# desenhados direto no tamanho final.
E = 2


def desenhar() -> Image.Image:
    img = Image.new("RGB", (L * E, A * E), FUNDO)
    d = ImageDraw.Draw(img)

    # Ondas concêntricas saindo da direita, sangrando pela borda — mesma
    # linguagem do ícone, mas em posição que não briga com o texto.
    cx, cy = int(L * 0.80) * E, int(A * 0.50) * E
    for i, raio in enumerate([70, 130, 190, 250, 310]):
        r = raio * E
        # Opacidade decrescente: o desenho some para dentro do fundo em vez
        # de terminar num corte seco na borda da imagem.
        clareza = 255 - i * 38
        cor = tuple(int(f + (255 - f) * (clareza / 255) * 0.55) for f in FUNDO)
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=cor, width=int(7 * E))

    # Ponto emissor
    pr = int(26 * E)
    d.ellipse([cx - pr, cy - pr, cx + pr, cy + pr], fill=TINTA)

    # Texto à esquerda, dentro da área segura
    nome = ImageFont.truetype(FONTE_BOLD, int(96 * E))
    sub = ImageFont.truetype(FONTE, int(35 * E))

    x = int(72 * E)
    d.text((x, int(178 * E)), "BitRádio", font=nome, fill=TINTA)
    d.text((x, int(292 * E)), "Rádios ao vivo, sem travar",
           font=sub, fill=(214, 240, 236))

    return img.resize((L, A), Image.LANCZOS)


if __name__ == "__main__":
    saida = AQUI / "destaque-1024x500.png"
    desenhar().save(saida, "PNG", optimize=True)
    print(f"{saida.name}: {saida.stat().st_size // 1024} KB")
