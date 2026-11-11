import sys
from PIL import Image, ImageChops, ImageFilter, ImageEnhance
src, out = sys.argv[1], sys.argv[2]
im = Image.open(src).convert("RGB")
sim = im.crop((150,165,610,480))            # só o símbolo, sem o texto
claro = Image.new("RGB", sim.size, (244,244,241))
mask = ImageChops.difference(sim, claro).convert("L").point(lambda v: 0 if v < 22 else min(255, v*3))
mask = mask.filter(ImageFilter.GaussianBlur(1.2))
sim = ImageEnhance.Brightness(sim).enhance(1.35)   # o azul-marinho sumiria no escuro
W, H = 1080, 2340
fundo = (14, 21, 20)                         # superfície do tema escuro do app
larg = int(W * 1.5)                          # maior que a tela: marca d'água, não figura
alt = int(sim.height * larg / sim.width)
sim = sim.resize((larg, alt), Image.LANCZOS); mask = mask.resize((larg, alt), Image.LANCZOS)
c = Image.new("RGB", (W, H), fundo)
c.paste(sim, ((W - larg)//2, int(H*0.42) - alt//2), mask)
c.save(out, "JPEG", quality=85, optimize=True, progressive=True)
