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


def desenhar(tamanho: int, fundo=FUNDO + (255,), escala: float = 1.0) -> Image.Image:
    img = Image.new("RGBA", (BASE, BASE), fundo)
    d = ImageDraw.Draw(img)

    cx, cy = BASE // 2, BASE // 2
    ponto_r = int(BASE * 0.058 * escala)

    # Ponto emissor, ao centro
    d.ellipse([cx - ponto_r, cy - ponto_r, cx + ponto_r, cy + ponto_r], fill=TINTA)

    # Arcos SIMÉTRICOS, à esquerda e à direita.
    #
    # A primeira versão tinha arcos só para cima e ficou indistinguível do
    # ícone de Wi-Fi — numa lista de apps isso confunde e não comunica
    # "rádio". Ondas saindo dos dois lados de um ponto central é a leitura
    # convencional de transmissão sonora.
    for raio_f, esp_f in [(0.15, 0.032), (0.245, 0.036), (0.34, 0.040)]:
        r = int(BASE * raio_f * escala)
        esp = int(BASE * esp_f * escala)
        caixa = [cx - r, cy - r, cx + r, cy + r]
        d.arc(caixa, start=-52, end=52, fill=TINTA, width=esp)      # direita
        d.arc(caixa, start=128, end=232, fill=TINTA, width=esp)     # esquerda

    img = img.resize((tamanho, tamanho), Image.LANCZOS)
    return img.convert("RGB") if fundo[3] == 255 else img


# O ícone que o APARELHO mostra sai de android/app/src/main/res, não daqui.
# Até a v13 esses mipmaps eram o "F" padrão do `flutter create`, e o Google
# reprovou a versão por "ícone instalado difere do ícone da loja" (política
# de Declarações enganosas, out/2026). Por isso o gerador escreve os dois.
RES = AQUI.parent / "android" / "app" / "src" / "main" / "res"
DENSIDADES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}

# Ícone adaptativo (Android 8+): camada de 108dp, mas só o círculo central
# de 66dp é garantido sob qualquer máscara. Os arcos externos chegam a 0,36
# do lado; 0,7 os põe em ~0,25 — dentro da zona segura e com o mesmo
# tamanho aparente do ícone da loja depois do recorte de 72dp.
ESCALA_ADAPTATIVO = 0.7


def gerar_android():
    for nome, fator in DENSIDADES.items():
        pasta = RES / f"mipmap-{nome}"
        pasta.mkdir(parents=True, exist_ok=True)
        # Legado (Android < 8): o quadrado inteiro, igual ao da loja.
        desenhar(int(48 * fator)).save(pasta / "ic_launcher.png", "PNG", optimize=True)
        # Frente do adaptativo: só a tinta, fundo transparente.
        desenhar(int(108 * fator), fundo=(0, 0, 0, 0), escala=ESCALA_ADAPTATIVO).save(
            pasta / "ic_launcher_foreground.png", "PNG", optimize=True)

    anydpi = RES / "mipmap-anydpi-v26"
    anydpi.mkdir(parents=True, exist_ok=True)
    # monochrome = ícone temático do Android 13; usa só o alfa da frente.
    (anydpi / "ic_launcher.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background"/>\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        '    <monochrome android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        '</adaptive-icon>\n', encoding="utf-8")
    (RES / "values" / "ic_launcher_background.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<resources>\n'
        '    <color name="ic_launcher_background">#%02X%02X%02X</color>\n'
        '</resources>\n' % FUNDO, encoding="utf-8")
    print(f"  mipmaps do Android em {RES}")


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

    gerar_android()

    print()
    print("  PROVISÓRIO — substituir pela identidade visual da emissora")
    print("  antes da publicação definitiva nas lojas.")


if __name__ == "__main__":
    main()
