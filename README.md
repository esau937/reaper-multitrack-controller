# 🎵 Reaper Multitrack Controller

Controlador de multitracks para o Reaper DAW. Painel dockado na base da janela, full-width, com:

- **Visão geral temporal** com seções coloridas (lidas das regiões do projeto; não é uma forma de onda de áudio real)
- **Detecção automática do tom** pelo nome do projeto (`_D`, `- Am`, `[Cm]`…)
- **Botões cromáticos** (C Db D Eb E F Gb G Ab A Bb B) com tom ativo destacado
- **PAD** — dispara áudio local com baixa latência
- **SALVAR / ABRIR / REPERTÓRIO** — gestão de setlists em JSON
- **MARKER** — adiciona marcador na posição atual
- **Navegação por seção** — botões dinâmicos gerados dos marcadores do projeto

---

## ⚙️ Pré-requisitos

1. **Reaper 7.07+** (Windows ou macOS)
2. **js_ReaScriptAPI** — extensão gratuita
3. **ReaImGui** — extensão gratuita
4. **SWS/S&M Extension** — necessária apenas para o recurso **LOUDNESS**

### Como instalar as extensões (uma vez só)

1. No Reaper: `Extensions > ReaPack > Browse packages`
2. Busque por **`js_ReaScriptAPI`** → instalar (por *Julian Sader*)
3. Busque por **`ReaImGui`** → instalar (por *cfillion*)
4. Busque por **`SWS Extension`** → instalar (necessária para LOUDNESS)
4. Reinicie o Reaper

---

## 📁 Instalação do Script

Copie a pasta `MultitrackController/` para:

| Sistema | Caminho |
|---|---|
| **Windows** | `%APPDATA%\REAPER\Scripts\MultitrackController\` |
| **macOS**   | `~/Library/Application Support/REAPER/Scripts/MultitrackController/` |

### Estrutura esperada:
```
MultitrackController/
├── main.lua          ← script principal
├── modules/
│   ├── keydetect.lua
│   ├── sections.lua
│   ├── pads.lua
│   └── repertoire.lua
├── lib/
│   └── json.lua
└── data/
    └── setlists/     ← setlists salvos aqui
```

---

## ▶️ Como rodar

1. No Reaper: `Actions > Load ReaScript…`
2. Navegue até `MultitrackController/main.lua`
3. Clique em **Open**
4. O painel aparece na base da janela do Reaper

> **Dica:** Adicione o script às **Actions** e crie um botão na toolbar do Reaper para abrir com um clique.

---

## 🎹 Detecção de tom (TOM)

O script lê o tom do **nome do arquivo `.RPP`**. Formatos suportados:

| Nome do arquivo | Tom detectado |
|---|---|
| `Uma Carta Viva_D.RPP` | D |
| `Ninguém Como Ele - Am.RPP` | Am |
| `Oceans [G].RPP` | G |
| `Song (Cm).RPP` | Cm |
| `Song TOM Bb.RPP` | Bb |

---

## 🥁 Configurando os Pads

1. **Clique direito** no botão `PAD`
2. Selecione o arquivo MP3/WAV na caixa de diálogo
3. O nome do pad é atualizado automaticamente com o nome do arquivo

---

## 📋 Setlists (Repertório)

| Botão | Função |
|---|---|
| **SALVAR** | Salva os projetos abertos no Reaper como um setlist `.json` |
| **ABRIR** | Abre um arquivo `.json` de setlist e carrega os projetos |
| **REPERTÓRIO** | Lista setlists salvos para selecionar |

Os setlists ficam em `data/setlists/` dentro da pasta do script.

---

## 🗺️ Mapeamento de Seções

As seções (Intro, Verso, Refrão, etc.) são lidas diretamente das **regiões do projeto REAPER**:

1. No REAPER, crie regiões e nomeie-as como `Intro`, `Verso 1`, `Refrão`, etc.
2. O controlador detecta automaticamente e cria botões coloridos
3. Use o botão **MARKER** no controlador para adicionar marcadores na posição atual

Cores automáticas por nome de seção:
- 🟦 **Intro / Introdução / Contagem**
- 🟣 **Verso / Verse**
- 🟠 **Pré-Refrão**
- 🔴 **Refrão / Chorus**
- 🔵 **Ponte / Bridge**
- 🟢 **Final / Outro**

---

## 🛠️ Solução de problemas

**"ReaImGui não encontrado"**
→ Instale via ReaPack conforme descrito acima e reinicie o Reaper.

**Painel não aparece**
→ O script depende de `js_ReaScriptAPI` para posicionar na janela do Reaper. Verifique se está instalado.

**Tom não detectado**
→ Renomeie o arquivo `.RPP` para incluir o tom no formato suportado (ex: `MinhaMusica_D.RPP`).

**Setlist não abre os projetos**
→ Verifique se os caminhos dos arquivos `.RPP` ainda são válidos (arquivos não movidos).
