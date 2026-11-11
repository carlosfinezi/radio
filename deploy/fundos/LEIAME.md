# Fundos do player, por emissora

O app busca `https://radio.1bit.net.br/fundos/<slug>.jpg` (slug = `shortcode`
do AzuraCast). Sem arquivo → 404 → o player fica com o visual padrão. Não é
preciso nova versão do app para incluir ou trocar um fundo.

Publicar:

    scp -i ~/.ssh/contabo_ssh <slug>.jpg cloud-user@147.93.147.40:/var/www/radio-publico/fundos/

O app põe um véu escuro (65%) por cima e usa `BoxFit.cover`, então:

- **Formato vertical, 1080×2340.** Imagem quadrada perde as laterais na tela.
- **Nada de texto no meio.** A capa da música (240 px) e o título ficam no
  centro; texto do logo atrás deles vira borrão. O nome da emissora já está
  na barra do topo.
- **Fundo escuro.** O tema do app é escuro; fundo claro sob o véu vira cinza.

`compor-porto-do-capim.py` mostra como a Porto do Capim foi feita a partir do
logo deles (fundo claro, com texto): recorta só o símbolo, remove o fundo com
máscara e o amplia como marca d'água sobre a cor do tema. O cache do nginx é de
1 dia: troca de imagem pode levar até um dia para chegar a todos.
