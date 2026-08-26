# Conversor de Vídeos em Shell POSIX

Conversor universal de vídeos escrito em **Shell POSIX (`/bin/sh`)**, usando **FFmpeg** e **ffprobe** para análise, conversão, remux, compressão, preservação de áudio e validação do resultado.

O projeto foi desenvolvido com uma política conservadora: **o arquivo original nunca é sobrescrito, removido, renomeado ou movido**, e o script tenta preservar **todas as faixas de áudio**, incluindo arquivos dual-audio e multi-audio.

## Principais recursos

- Shell **100% POSIX**, sem dependência de Bash.
- Entrada em qualquer formato que o FFmpeg instalado consiga decodificar.
- Suporte explícito a **RM/RMVB**, inclusive arquivos RealVideo antigos.
- Saída para MKV, MP4, MOV, WebM, AVI, OGG/OGV, FLV, MPEG, VOB, TS/M2TS, WMV/ASF, RM/RMVB, 3GP e outros formatos aceitos pelo FFmpeg.
- Preservação do **arquivo original**.
- Preservação de **dual-audio e multi-audio**.
- Preservação de idioma e metadata das faixas quando suportados pelo contêiner de destino.
- Áudio copiado bit a bit sempre que possível.
- Sem normalização automática de volume.
- Sem `loudnorm`, compressor, limiter, ganho automático ou resampling arbitrário.
- Remux sem recodificação.
- Conversão de vídeo verdadeiramente **lossless**.
- Perfis de qualidade máxima, alta, equilibrada e compacta.
- Upscale/downscale opcional com Lanczos.
- Conversão para **tamanho-alvo em MB**.
- 2-pass quando o encoder utilizado permite.
- Preservação de legendas, capítulos, metadata, attachments e streams auxiliares quando o contêiner permite.
- Validação do resultado com `ffprobe` antes de publicar o arquivo final.
- Nunca descarta silenciosamente uma faixa de áudio.

---

## Requisitos

O programa depende de:

- `ffmpeg`
- `ffprobe`
- utilitários POSIX usuais: `awk`, `sed`, `grep`, `tr`, `dirname`, `basename`, `mv`, `rm` e `wc`

### Arch Linux

```sh
sudo pacman -S ffmpeg
```

### Debian / Ubuntu

```sh
sudo apt install ffmpeg
```

Confira a instalação:

```sh
ffmpeg -version
ffprobe -version
```

---

## Instalação do script

Clone o repositório:

```sh
git clone https://github.com/mintonogueira/conversor_videos_em_shell.git
cd conversor_videos_em_shell
```

Dê permissão de execução:

```sh
chmod +x conversor_video_posix.sh
```

Veja a ajuda:

```sh
./conversor_video_posix.sh -h
```

Também é possível executá-lo explicitamente com `sh`:

```sh
sh conversor_video_posix.sh -h
```

---

# Uso básico

Sintaxe:

```sh
./conversor_video_posix.sh [opções] ARQUIVO_ENTRADA ARQUIVO_SAIDA
```

Exemplo simples:

```sh
./conversor_video_posix.sh filme.rmvb filme.mkv
```

Se o modo não for informado com `-m`, o script abre um menu interativo.

---

# Modos de conversão

| Modo | Finalidade |
|---|---|
| `remux` | Troca o contêiner sem recodificar áudio ou vídeo |
| `lossless` | Recodifica o vídeo sem perda matemática |
| `max` | Máxima fidelidade prática, minimizando perda adicional |
| `high` | Alta qualidade; bom padrão para acervo |
| `balanced` | Equilíbrio entre qualidade e tamanho |
| `compact` | Compressão mais forte |
| `target` | Tenta atingir um tamanho específico em MB |

## 1. Remux sem perda

Quando os codecs existentes são compatíveis com o contêiner de destino:

```sh
./conversor_video_posix.sh -m remux entrada.mkv saida.mkv
```

O modo `remux` utiliza cópia de streams. Portanto:

- vídeo não é recodificado;
- áudio não é recodificado;
- não existe perda de qualidade causada pelo processo;
- todas as faixas são mapeadas;
- metadata e capítulos são preservados.

Se o contêiner de destino não aceitar algum stream, o script **aborta** em vez de recodificar ou eliminar conteúdo silenciosamente.

---

## 2. Lossless verdadeiro

```sh
./conversor_video_posix.sh -m lossless entrada.rmvb arquivo.mkv
```

Para MKV, o script prefere **FFV1** quando disponível. Em outros contêineres utiliza um encoder lossless seguro quando implementado.

> **Importante:** lossless significa ausência de perda matemática, não necessariamente arquivo menor. Um vídeo originalmente muito comprimido pode ficar consideravelmente maior após ser convertido para um codec lossless.

---

## 3. Qualidade máxima

```sh
./conversor_video_posix.sh -m max entrada.rmvb saida.mkv
```

O modo `max` utiliza parâmetros de alta fidelidade para reduzir ao mínimo a perda adicional causada pela nova codificação.

Ele **não recupera detalhes que já não existem no arquivo original**.

---

## 4. Alta qualidade

```sh
./conversor_video_posix.sh -m high entrada.rmvb saida.mkv
```

É um bom perfil geral para manter qualidade alta com compressão moderna.

---

## 5. Qualidade equilibrada

```sh
./conversor_video_posix.sh -m balanced entrada.mkv saida.mkv
```

Busca um compromisso entre qualidade visual, velocidade e tamanho final.

---

## 6. Compressão forte

```sh
./conversor_video_posix.sh -m compact entrada.mkv saida.mkv
```

Usa parâmetros mais agressivos de compressão para reduzir o tamanho do vídeo.

Por padrão, isso **não significa sacrificar as faixas de áudio**: a política de áudio continua sendo tratada separadamente.

---

# Converter RMVB

RM/RMVB é tratado como formato normal de entrada. O FFmpeg analisa o codec real do arquivo, em vez de confiar apenas na extensão.

### RMVB para MKV

```sh
./conversor_video_posix.sh -m high filme.rmvb filme.mkv
```

### RMVB para MP4

```sh
./conversor_video_posix.sh -m high filme.rmvb filme.mp4
```

RealVideo, como RV30/RV40, normalmente precisa ser recodificado quando o destino é um contêiner moderno como MP4.

Para arquivos antigos e complexos, **MKV é o destino recomendado** porque aceita uma variedade muito maior de codecs de áudio, legendas e streams auxiliares.

### Sobre criar RM/RMVB como saída

O FFmpeg moderno possui limitações importantes para codificação e multiplexação RealMedia. O script pode tentar gerar `.rm`/`.rmvb`, mas a disponibilidade dos encoders e a capacidade de manter múltiplos streams dependem da compilação do FFmpeg.

O programa prefere **abortar** a eliminar uma segunda faixa de áudio silenciosamente.

---

# Dual-audio e multi-audio

Preservar todas as faixas de áudio é um requisito central do projeto.

Um arquivo como:

```text
Vídeo
├── Áudio 1 — Português
├── Áudio 2 — Inglês
└── Áudio 3 — Comentários
```

é tratado de forma que a saída continue contendo a mesma quantidade de streams de áudio.

Após a conversão, o script utiliza `ffprobe` para verificar a contagem. Se a entrada possuir 3 áudios e o arquivo temporário possuir somente 2, a saída **não é publicada**.

---

# Política de áudio

A opção é:

```text
-a preserve
-a compatible
```

## `preserve` — padrão

```sh
./conversor_video_posix.sh -a preserve -m high entrada.mkv saida.mkv
```

Com essa política, o script:

1. tenta usar `-c:a copy`;
2. mantém o áudio bit a bit quando o destino aceita o codec;
3. não aplica filtros de dinâmica;
4. não muda volume automaticamente;
5. não faz downmix automático para estéreo;
6. não altera sample rate arbitrariamente;
7. quando necessário e seguro, utiliza uma alternativa lossless, como ALAC em MP4/MOV;
8. aborta se a única solução restante exigir conversão lossy não autorizada.

Essa é a política recomendada.

## `compatible` — conversão de áudio autorizada

```sh
./conversor_video_posix.sh -a compatible -m high entrada.mkv saida.mp4
```

Permite recodificar áudio quando o codec original não é compatível com o contêiner de destino.

Dependendo do destino, o script pode usar AAC, Opus, MP3, AC3, MP2 ou WMA.

Esta opção é **opt-in** porque uma nova codificação com codec lossy pode introduzir perda geracional.

Mesmo nesse modo, o script não aplica normalização dinâmica, compressor ou alterações automáticas de volume.

---

# Evitar áudio "quicando"

O conversor foi projetado para não aplicar automaticamente filtros que possam provocar pumping, mudanças artificiais de volume ou alterações desnecessárias da dinâmica.

Por isso não são aplicados automaticamente filtros como:

```text
loudnorm
dynaudnorm
acompressor
limiter
```

Quando possível, o áudio é simplesmente copiado:

```text
entrada → bitstream copy → saída
```

Isso também evita uma recodificação desnecessária de faixas dual-audio.

---

# Alterar resolução

Use `-r` com a altura desejada:

```sh
./conversor_video_posix.sh -m high -r 1080 entrada.rmvb saida.mkv
```

Valores comuns:

```text
480
720
1080
1440
2160
```

Ou mantenha a resolução original:

```sh
./conversor_video_posix.sh -m high -r original entrada.mkv saida.mkv
```

O redimensionamento usa Lanczos e mantém a proporção do vídeo.

### Upscale

É possível fazer:

```sh
./conversor_video_posix.sh -m high -r 1080 video_720p.mkv video_1080p.mkv
```

Porém, upscale **não recria detalhes ausentes no original**. Ele aumenta a resolução espacial por interpolação.

---

# Converter para um tamanho específico

Exemplo para aproximadamente **30 MB**:

```sh
./conversor_video_posix.sh -m target -s 30 entrada.mp4 saida_30mb.mp4
```

O programa:

1. mede a duração do vídeo;
2. mede aproximadamente o espaço ocupado pelos pacotes de áudio;
3. preserva os áudios por cópia;
4. reserva uma margem para overhead do contêiner;
5. calcula o bitrate disponível para vídeo;
6. usa 2-pass em H.264, H.265 ou VP9 quando disponível.

O tamanho final é um **alvo aproximado**, não uma garantia byte a byte, porque contêineres possuem overhead e alguns codecs variam em eficiência.

Se as faixas de áudio por si só já ocuparem espaço demais para o tamanho pedido, o script aborta em vez de reduzir a qualidade do áudio silenciosamente.

---

# Proteção do arquivo original

O arquivo de entrada é tratado somente como fonte.

Fluxo simplificado:

```text
ARQUIVO ORIGINAL
       │
       │ leitura
       ▼
    FFmpeg
       │
       ▼
arquivo temporário
       │
       ▼
    ffprobe
       │
       ├── arquivo válido?
       ├── contém vídeo?
       ├── quantidade de áudios correta?
       └── legendas preservadas quando exigido?
                │
                ▼
             arquivo final
```

O original não é:

- apagado;
- substituído;
- renomeado;
- movido;
- usado como arquivo temporário.

Se entrada e saída forem o mesmo caminho, o script aborta.

---

# Arquivo de saída já existente

O script não sobrescreve silenciosamente um arquivo existente.

Se você solicitar:

```text
filme_convertido.mkv
```

e ele já existir, o programa procura automaticamente outro nome:

```text
filme_convertido_1.mkv
filme_convertido_2.mkv
filme_convertido_3.mkv
```

---

# Exemplos rápidos

### RMVB para MKV, alta qualidade

```sh
./conversor_video_posix.sh -m high filme.rmvb filme.mkv
```

### RMVB para MP4

```sh
./conversor_video_posix.sh -m high filme.rmvb filme.mp4
```

### MKV para MP4 autorizando conversão de áudio incompatível

```sh
./conversor_video_posix.sh -m high -a compatible entrada.mkv saida.mp4
```

### Converter mantendo a resolução

```sh
./conversor_video_posix.sh -m balanced -r original entrada.mkv saida.mkv
```

### Reduzir para 720p

```sh
./conversor_video_posix.sh -m compact -r 720 entrada.mkv saida.mkv
```

### Aumentar para 1080p

```sh
./conversor_video_posix.sh -m high -r 1080 entrada_720p.mkv saida_1080p.mkv
```

### Lossless para MKV

```sh
./conversor_video_posix.sh -m lossless entrada.rmvb arquivo_lossless.mkv
```

### Remux

```sh
./conversor_video_posix.sh -m remux entrada.mkv saida.mkv
```

### Aproximadamente 30 MB

```sh
./conversor_video_posix.sh -m target -s 30 entrada.mp4 saida_30mb.mp4
```

---

# Códigos de saída

| Código | Significado |
|---:|---|
| `0` | sucesso |
| `1` | erro de uso ou configuração |
| `2` | falha de conversão |
| `3` | falha de validação do arquivo de saída |

Isso permite utilizar o programa em outros scripts e automações POSIX.

---

# Compatibilidade POSIX

O programa usa:

```sh
#!/bin/sh
```

Ele evita deliberadamente recursos exclusivos do Bash, como:

- `[[ ... ]]`;
- arrays;
- `local`;
- process substitution;
- sintaxe específica de Bash.

A disponibilidade real dos codecs depende da compilação do **FFmpeg** instalada no sistema.

---

# Recomendação de formato

Para preservação de arquivos com múltiplos áudios, legendas, capítulos, attachments e codecs variados, **MKV/Matroska é o formato recomendado**.

MP4 é excelente para compatibilidade com dispositivos, mas possui uma lista mais restrita de codecs e tipos de stream.

---

## Versão

Versão inicial do script: **1.0.0**.

## Projeto

Código-fonte principal:

```text
conversor_video_posix.sh
```

O código contém comentários detalhados explicando as decisões de compatibilidade, preservação, escolha de codecs, validação, arquivos temporários e política de áudio.
