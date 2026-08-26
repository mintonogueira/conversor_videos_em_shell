# Conversor de Vídeos em Shell POSIX

Conversor de vídeos em **Shell POSIX (`/bin/sh`)** com FFmpeg/ffprobe, criado com foco em preservação do arquivo original, dual-audio/multi-audio e operação segura.

A versão **2.0.0** torna o uso manual totalmente interativo. Basta executar:

```sh
./conversor_video_posix.sh
```

O modo por parâmetros continua disponível para automações.

## Recursos principais

- Shell 100% POSIX, sem dependência de Bash.
- Arquivo único, curinga, pasta ou pasta recursiva.
- Padrões como `/caminho/*.rmvb`, `/caminho/*.mkv` e `/caminho/*.*`.
- Caminhos absolutos e caminhos com espaços.
- RM/RMVB como entrada, além dos formatos decodificáveis pelo FFmpeg instalado.
- Saída MKV, MP4, MOV, WebM, AVI, OGV, MPEG, TS, RMVB, 3GP ou extensão personalizada.
- Arquivo original nunca é apagado, movido, renomeado ou sobrescrito.
- Preservação de dual-audio e multi-audio.
- Validação com ffprobe antes da publicação do arquivo final.
- Áudio copiado bit a bit sempre que possível.
- Sem `loudnorm`, compressor, limiter, ganho automático ou resampling arbitrário.
- Remux sem recodificação.
- Lossless verdadeiro.
- Qualidade máxima, alta, equilibrada ou compacta.
- Upscale/downscale opcional com Lanczos.
- Tamanho-alvo aproximado em MB.
- Processamento em lote com opção de continuar ou parar em caso de erro.
- Modo recursivo com preservação opcional da árvore de subpastas.

## Requisitos

### Arch Linux

```sh
sudo pacman -S ffmpeg
```

### Debian / Ubuntu

```sh
sudo apt install ffmpeg
```

Depois:

```sh
git clone https://github.com/mintonogueira/conversor_videos_em_shell.git
cd conversor_videos_em_shell
chmod +x conversor_video_posix.sh
./conversor_video_posix.sh
```

## Assistente interativo

O primeiro menu pergunta como selecionar os vídeos:

```text
1) Um arquivo específico
2) Padrão/coringa
3) Todos os vídeos diretamente dentro de uma pasta
4) Pasta e subpastas recursivamente
```

### Um arquivo

Informe o caminho completo, por exemplo:

```text
/home/usuario/Vídeos/filme.rmvb
```

### Curinga

No próprio assistente, informe literalmente:

```text
/home/usuario/Vídeos/*.rmvb
```

ou:

```text
/home/usuario/Vídeos/*.*
```

O script **não usa `eval`** para expandir o padrão. O texto fornecido é usado apenas para comparação de nomes, evitando que seja interpretado como código de shell.

### Pasta inteira

Informe:

```text
/home/usuario/Vídeos
```

O programa consulta os arquivos com ffprobe e inclui apenas aqueles com stream de vídeo. Imagens comuns são ignoradas para evitar que sejam tratadas como vídeos de um único frame.

### Recursivo

No modo recursivo o programa percorre subpastas e pergunta se a estrutura original deve ser preservada no destino.

Exemplo:

```text
Origem:  /mnt/Acervo/Filmes/Drama/filme.mkv
Destino: /mnt/Convertidos
```

Com preservação da árvore:

```text
/mnt/Convertidos/Filmes/Drama/filme.mkv
```

## Destino e nomes

O assistente pergunta o diretório de saída e cria a pasta mediante autorização se ela ainda não existir.

Também pergunta um sufixo opcional, por exemplo:

```text
_convertido
_hevc
_720p
```

Se a combinação de pasta, nome e extensão resultaria no mesmo caminho do original, o programa força `_convertido` para impedir sobrescrita.

O mecanismo interno também cria nomes únicos quando o destino já existe, como:

```text
filme.mkv
filme_1.mkv
filme_2.mkv
```

## Formato de saída

O menu oferece:

```text
1) MKV / Matroska
2) MP4
3) MOV
4) WebM
5) AVI
6) OGV
7) MPEG / MPG
8) MPEG-TS / TS
9) RMVB / RealMedia
10) 3GP
11) Manter extensão original
12) Outra extensão
```

**MKV é recomendado** para arquivos com múltiplos áudios, legendas, capítulos e codecs variados.

## Modos de conversão

```text
1) Remux / cópia integral
2) Lossless verdadeiro
3) Qualidade máxima
4) Qualidade alta
5) Qualidade equilibrada
6) Compressão forte / compacta
7) Tamanho-alvo em MB
```

### Remux

Copia streams sem recodificação quando o contêiner de destino é compatível. Não há perda introduzida por encoder.

### Lossless

Recodifica o vídeo sem perda matemática quando implementado para o destino. Lossless não significa arquivo menor; dependendo do material, a saída pode crescer bastante.

### Perfis de qualidade

`max`, `high`, `balanced` e `compact` alteram o nível de compressão do vídeo. A política de áudio é tratada separadamente.

### Tamanho-alvo

No modo `target`, o programa pergunta o tamanho em MB. O core estima o bitrate de vídeo preservando o áudio por cópia e utiliza 2-pass quando aplicável.

## Resolução

Nos modos que permitem redimensionamento:

```text
1) Original
2) 480p
3) 720p
4) 1080p
5) 1440p
6) 2160p / 4K
7) Personalizada
```

O upscale não recria detalhes ausentes no original; apenas aumenta a resolução por interpolação.

## Áudio e dual-audio

A política recomendada é **PRESERVAR**:

```text
codec compatível -> copiar bit a bit
codec incompatível -> alternativa lossless segura, quando disponível
sem solução lossless segura -> abortar
```

A opção **COMPATÍVEL** autoriza recodificação somente quando necessária para o contêiner.

Mesmo nessa opção o script não aplica automaticamente:

```text
loudnorm
dynaudnorm
acompressor
limiter
```

Depois da conversão, o core compara a quantidade de faixas de áudio. Se a entrada possuir duas faixas e a saída temporária somente uma, o resultado é rejeitado.

## Proteção do original

Fluxo:

```text
ORIGINAL
   |
   | leitura
   v
FFmpeg
   |
   v
TEMPORÁRIO
   |
   v
ffprobe / validação
   |
   v
SAÍDA FINAL
```

O original não é removido, substituído, renomeado ou movido.

## RMVB

RMVB pode ser selecionado diretamente:

```text
/home/usuario/Vídeos/filme.rmvb
```

ou em lote:

```text
/home/usuario/Vídeos/*.rmvb
```

RV30/RV40 normalmente precisam ser recodificados ao migrar para codecs modernos. RM/RMVB como saída possui limitações no FFmpeg moderno; o programa prefere falhar a eliminar uma faixa de áudio.

## Processamento em lote

Para padrão, pasta ou modo recursivo, cada arquivo é processado isoladamente. O assistente pergunta se deve continuar caso um item falhe.

Ao final mostra um resumo semelhante a:

```text
Selecionados: 20
Concluídos: 19
Falhas: 1
Arquivos originais: preservados
```

## Modo avançado / automação

A interface anterior continua funcionando:

```sh
./conversor_video_posix.sh [opções] ARQUIVO_ENTRADA ARQUIVO_SAIDA
```

Opções:

```text
-m MODO       remux | lossless | max | high | balanced | compact | target
-r ALTURA     original | 480 | 720 | 1080 | 1440 | 2160 | inteiro
-s MB         tamanho-alvo aproximado em MB
-a POLITICA   preserve | compatible
```

Exemplos:

```sh
./conversor_video_posix.sh -m high -r original -a preserve filme.rmvb filme.mkv
```

```sh
./conversor_video_posix.sh -m lossless entrada.rmvb saida.mkv
```

```sh
./conversor_video_posix.sh -m compact -r 720 entrada.mkv saida.mkv
```

```sh
./conversor_video_posix.sh -m target -s 30 entrada.mp4 saida.mp4
```

Para curingas e lotes, prefira o assistente interativo: um curinga digitado diretamente no terminal sem aspas é expandido pelo shell antes da execução do programa.

## Estrutura do projeto

```text
conversor_video_posix.sh       interface interativa e compatibilidade CLI
lib/conversor_video_core.sh    mecanismo FFmpeg/ffprobe e validações
```

A separação permite que a interface faça processamento em lote sem duplicar a lógica crítica de conversão.

## POSIX

A interface foi validada sintaticamente em:

```text
sh
dash
BusyBox ash
```

Não usa arrays Bash, `[[ ... ]]`, `local`, `mapfile`, globstar ou process substitution.

No modo lote, nomes com espaços, tabs e acentos são suportados. Nomes Unix contendo uma **quebra de linha literal** não são suportados pela lista interna POSIX.

## Testes da versão 2.0.0

Foram testados:

- seleção `*.mkv`;
- seleção `*.*` com arquivo `.txt` na mesma pasta;
- nome de arquivo com espaço;
- diretório recursivo com subpasta contendo espaço;
- preservação da árvore de subpastas;
- dual-audio AC3 Português + Inglês;
- modo avançado por parâmetros;
- entrada RealMedia/RMVB para MKV;
- checksum do original antes e depois da conversão.

Nos testes, as duas faixas de áudio foram preservadas e o checksum do arquivo original permaneceu inalterado.
