# Ficha do BitRádio na Google Play

Textos e respostas para o Play Console. **Copiar e colar** — os limites de
caracteres já estão respeitados (validados por `docs/validar-ficha.py`).

O app é `br.net.onebit.bitradio`. O identificador de pacote é **imutável**
depois de criado: o rascunho antigo (`br.net.onebit.radio_porto_do_capim`)
carregava o nome de um cliente e foi abandonado de propósito.

---

## Nome do app  (máx. 30)

```
BitRádio
```

Alternativa, se quiser ajudar a busca dentro da loja — o Google indexa o nome,
e "BitRádio" sozinho não diz o que o app faz para quem nunca ouviu falar:

```
BitRádio - Rádios ao vivo
```

## Descrição curta  (máx. 80)

```
Ouça rádios ao vivo em alta qualidade, mesmo com a tela do celular desligada.
```

## Descrição completa  (máx. 4000)

```
O BitRádio reúne as emissoras de web rádio hospedadas na plataforma da 1bit.
Escolha a rádio que quer ouvir e o som começa — sem cadastro, sem login e sem
anúncios.

ESCOLHA SUA EMISSORA
Ao abrir pela primeira vez, o aplicativo mostra as rádios disponíveis. Toque
em uma e pronto. A escolha fica salva no aparelho: nas próximas vezes o app
abre direto no player. Para ouvir outra, use o botão de troca no topo da tela.

CONTINUA TOCANDO EM SEGUNDO PLANO
O som não para quando você bloqueia a tela ou abre outro aplicativo. Os
controles aparecem na notificação e na tela de bloqueio, e funcionam pelos
botões do fone de ouvido, do Bluetooth e do sistema de som do carro.

SAIBA O QUE ESTÁ NO AR
A tela principal mostra a música ou o programa que está tocando agora,
atualizado automaticamente. A aba de programação lista o que vem pela frente,
já convertido para o horário do seu aparelho.

TRANSMISSÃO DE QUALIDADE
Áudio a 128 kbps ou superior, entregue por HLS com queda automática para
transmissão contínua quando necessário — a conexão se recupera sozinha ao
trocar do Wi-Fi para os dados móveis.

LEVE E RESPEITOSO COM SEUS DADOS
Sem cadastro. Sem coleta de nome, e-mail ou telefone. Sem acesso a contatos,
fotos, câmera ou microfone. Sem rastreadores de publicidade.

A programação de cada emissora é de responsabilidade da própria emissora.

Política de privacidade: https://radio.1bit.net.br/privacidade.html
Contato: atendimento@1bit.net.br
```

---

## Recursos gráficos

| Item | Exigência da loja | Onde está |
|---|---|---|
| Ícone | 512×512 PNG, 32 bits | `app/assets/icone-512.png` |
| Gráfico de destaque | 1024×500 PNG/JPG | `app/assets/destaque-1024x500.png` |
| Capturas de telefone | mín. 2, entre 320 e 3840 px | **faltam — tirar do aparelho** |

As capturas precisam ser do app novo (a tela de seleção de emissora não existia
na versão anterior). Tire quatro, no próprio celular, com o APK instalado:

1. Tela de seleção, com as emissoras listadas
2. Player tocando, mostrando a faixa no ar
3. Aba de programação
4. Notificação do player com a tela bloqueada

No Android: **Volume− + Power**. As imagens saem no tamanho certo.

---

## Segurança dos dados (Data safety)

> Estas são **declarações legais** com consequência jurídica. As respostas
> abaixo refletem o que o sistema faz de fato e batem com a política publicada,
> mas quem confirma no formulário é você.

**O app coleta ou compartilha dados do usuário?** → **Sim**

Não porque o aplicativo colete, mas porque o servidor de streaming registra o
endereço IP de quem se conecta e o guarda por até 60 dias. Isso passa da
exceção de "processamento efêmero" do Google, então precisa ser declarado.

| Tipo de dado | Coletado | Finalidade | Obrigatório |
|---|---|---|---|
| Localização aproximada | Sim | Análise (relatório de alcance por região, agregado) | Sim |
| Atividade no app → outras ações | Sim | Análise (duração da escuta, audiência) | Sim |

Não marcar: identificadores de dispositivo, informações pessoais, contatos,
fotos, mensagens, arquivos, informações financeiras, saúde.

Demais respostas:

- Dados são **criptografados em trânsito** → Sim (HTTPS/TLS)
- Usuário pode **solicitar exclusão** → Sim (por e-mail, conforme a política)
- Dados são **compartilhados com terceiros** → Não
- Coleta é **necessária ao funcionamento** → Sim (sem IP não há como entregar áudio)

## Classificação de conteúdo (IARC)

Categoria: **Música e áudio**. Responder honestamente ao questionário —
o app não tem violência, conteúdo sexual, linguagem ofensiva, apostas nem
compras. Não há interação entre usuários, nem compartilhamento de localização,
nem conteúdo gerado por usuários (a programação é da emissora, não do público).

## Público-alvo

**13 anos ou mais** — coerente com a seção 6 da política de privacidade.
Marcar 13-15, 16-17 e 18+. **Não** inscrever no programa *Designed for
Families*: isso traria exigências adicionais sem benefício aqui.

## Categoria e contato

- Categoria do app: **Música e áudio**
- Tipo: Aplicativo (não é jogo)
- Gratuito, sem compras no app
- E-mail de contato: `atendimento@1bit.net.br`
- Site: `https://radio.1bit.net.br`
- Política de privacidade: `https://radio.1bit.net.br/privacidade.html`

---

## Ordem das etapas no Play Console

O Console não deixa publicar fora desta ordem — cada etapa destrava a seguinte.

1. **Criar app** → nome `BitRádio`, português (Brasil), Aplicativo, Gratuito
2. **Ficha da loja** → textos e gráficos acima
3. **Classificação de conteúdo** → questionário IARC
4. **Público-alvo** → 13+
5. **Segurança dos dados** → tabela acima
6. **Teste fechado** → subir o AAB, criar a lista de testadores
7. Só aqui nasce a **URL de teste** (`play.google.com/apps/testing/br.net.onebit.bitradio`),
   que é o que o serviço de testadores pede
8. **14 dias corridos** com 12 testadores aceitos → destrava a produção

O passo 8 é o gargalo real do prazo, e não depende de código. Conta de
**organização** é isenta dessa exigência, mas pede D-U-N-S — que leva de dias
a semanas para sair. Vale decidir isso antes, não depois.
