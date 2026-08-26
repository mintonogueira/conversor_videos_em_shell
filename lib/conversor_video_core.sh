#!/bin/sh
# ============================================================================
# conversor_video_posix.sh
# ============================================================================
# Conversor universal de vídeo orientado à preservação, escrito para /bin/sh
# POSIX. Não usa arrays, [[ ... ]], (( ... )), "local", process substitution,
# ou qualquer outra construção exclusiva do Bash.
#
# OBJETIVOS DO PROJETO
# --------------------
# 1. Ler qualquer formato que o FFmpeg instalado consiga decodificar,
#    incluindo RM/RMVB (RealMedia/RealVideo).
# 2. Gravar formatos suportados pelos muxers/encoders disponíveis no FFmpeg.
# 3. Preservar SEMPRE o arquivo original: ele é somente entrada e nunca é
#    removido, renomeado, movido ou sobrescrito.
# 4. Preservar TODAS as faixas de áudio (dual-audio, triple-audio etc.).
# 5. Evitar "áudio quicando": o script não aplica normalização dinâmica,
#    compressor, limiter, alteração de ganho, mudança de canais ou resampling
#    arbitrário. O áudio é copiado bit a bit sempre que possível.
# 6. Preservar metadata, capítulos e, quando o contêiner permitir, legendas,
#    anexos e streams auxiliares.
# 7. Oferecer:
#       - remux sem recodificação;
#       - transcodificação de vídeo verdadeiramente lossless;
#       - perfis de qualidade máxima/alta/equilibrada/compacta;
#       - alteração opcional de resolução (upscale/downscale);
#       - modo de tamanho-alvo aproximado em MB com 2-pass quando aplicável.
# 8. Nunca descartar um stream silenciosamente. Quando o contêiner de destino
#    não consegue preservar algo, o script falha com uma mensagem clara.
#
# IMPORTANTE SOBRE "AUMENTAR QUALIDADE"
# -------------------------------------
# Aumentar bitrate, usar um codec melhor ou fazer upscale NÃO recria detalhes
# já perdidos no arquivo original. Os perfis de maior qualidade servem para
# reduzir a perda ADICIONAL durante uma nova codificação. O upscale apenas
# aumenta a resolução espacial usando Lanczos, preservando a proporção.
#
# DEPENDÊNCIAS
# ------------
# Obrigatórias:
#   - ffmpeg
#   - ffprobe
#   - awk, sed, grep, tr, dirname, basename, mv, rm, mkdir, wc
#     (utilitários POSIX usuais)
#
# Exemplos:
#   ./conversor_video_posix.sh filme.rmvb filme.mkv
#
#   ./conversor_video_posix.sh -m high -r 1080 filme.rmvb filme.mkv
#
#   ./conversor_video_posix.sh -m remux entrada.mkv saida.mkv
#
#   ./conversor_video_posix.sh -m lossless entrada.rmvb arquivo.mkv
#
#   ./conversor_video_posix.sh -m target -s 30 entrada.mp4 saida.mp4
#
# Códigos de saída:
#   0 = sucesso
#   1 = erro de uso/configuração
#   2 = falha de conversão
#   3 = validação da saída falhou
# ============================================================================

# Não usamos "set -e" deliberadamente. Muitos comandos FFmpeg são executados
# dentro de testes e podem falhar de maneira esperada. O script trata esses
# retornos explicitamente e produz mensagens melhores.
set -u

PROGRAM=${0##*/}
VERSION="1.0.0"

# ---------------------------------------------------------------------------
# Configurações globais
# ---------------------------------------------------------------------------
MODE=""
SCALE_HEIGHT="original"
SCALE_SET="0"
TARGET_MB=""
AUDIO_POLICY="preserve"
INPUT=""
OUTPUT_REQUESTED=""
OUTPUT=""
TMP_OUTPUT=""
PASSLOG=""
VIDEO_ENCODER=""
OUTPUT_EXT=""
OUTPUT_FAMILY=""
OUTPUT_MUXER=""
DURATION=""
AUDIO_COUNT="0"
VIDEO_COUNT="0"
SUBTITLE_COUNT="0"
ATTACHMENT_COUNT="0"
DATA_COUNT="0"
AUDIO_CODECS=""
SUBTITLE_CODECS=""

# ---------------------------------------------------------------------------
# Funções de apresentação e tratamento de erro
# ---------------------------------------------------------------------------
print_line()
{
    printf '%s\n' "------------------------------------------------------------"
}

info()
{
    printf '%s\n' "$*"
}

warn()
{
    printf '%s\n' "AVISO: $*" >&2
}

die()
{
    printf '%s\n' "ERRO: $*" >&2
    exit 1
}

conversion_die()
{
    printf '%s\n' "ERRO DE CONVERSÃO: $*" >&2
    exit 2
}

validation_die()
{
    printf '%s\n' "ERRO DE VALIDAÇÃO: $*" >&2
    exit 3
}

usage()
{
    cat <<USAGE
$PROGRAM $VERSION

Uso:
  $PROGRAM [opções] ARQUIVO_ENTRADA ARQUIVO_SAIDA

Opções:
  -m MODO       remux | lossless | max | high | balanced | compact | target
  -r ALTURA     original | 480 | 720 | 1080 | 1440 | 2160 | número inteiro
  -s MB         tamanho-alvo aproximado em MB (usado com -m target)
  -a POLITICA   preserve | compatible
  -h            mostra esta ajuda

Política de áudio:
  preserve      padrão. Copia o áudio bit a bit sempre que possível. Quando
                isso não é possível, só usa alternativa sem perdas quando
                houver uma opção segura. Caso contrário, aborta.

  compatible    permite recodificação de áudio para um codec compatível com
                o contêiner. Nenhum filtro de volume/dinâmica é aplicado e
                todas as faixas continuam sendo mapeadas. Esta opção pode
                introduzir perda geracional no áudio e é opt-in.

Modos:
  remux         apenas troca/remuxa o contêiner; áudio/vídeo são copiados.
  lossless      recodifica o vídeo sem perda matemática quando necessário.
  max           máxima fidelidade prática; arquivo normalmente maior.
  high          alta qualidade; bom padrão para acervo.
  balanced      equilíbrio entre qualidade e tamanho.
  compact       compressão mais forte.
  target        tenta atingir um tamanho específico em MB.

Exemplos:
  $PROGRAM filme.rmvb filme.mkv
  $PROGRAM -m high -r 1080 filme.rmvb filme.mkv
  $PROGRAM -m remux filme.mkv filme.mp4
  $PROGRAM -m lossless filme.rmvb filme.mkv
  $PROGRAM -m target -s 30 filme.mp4 filme_30mb.mp4
USAGE
}

# ---------------------------------------------------------------------------
# Dependências
# ---------------------------------------------------------------------------
require_command()
{
    if ! command -v "$1" >/dev/null 2>&1; then
        die "dependência obrigatória não encontrada: $1"
    fi
}

check_dependencies()
{
    require_command ffmpeg
    require_command ffprobe
    require_command awk
    require_command sed
    require_command grep
    require_command tr
    require_command dirname
    require_command basename
    require_command mv
    require_command rm
    require_command wc
}

# ---------------------------------------------------------------------------
# Limpeza
# ---------------------------------------------------------------------------
# O temporário é removido em qualquer saída anormal. O arquivo ORIGINAL não
# aparece aqui de propósito: nenhuma rotina de limpeza toca na entrada.
cleanup()
{
    if [ -n "$TMP_OUTPUT" ] && [ -f "$TMP_OUTPUT" ]; then
        rm -f "$TMP_OUTPUT"
    fi

    if [ -n "$PASSLOG" ]; then
        rm -f "${PASSLOG}-0.log" "${PASSLOG}-0.log.mbtree" \
              "${PASSLOG}.log" "${PASSLOG}.log.mbtree" 2>/dev/null
    fi
}

trap 'cleanup' 0 1 2 3 15

# ---------------------------------------------------------------------------
# Utilidades de caminho
# ---------------------------------------------------------------------------
# Gera uma representação canônica do diretório + basename. Isso permite
# impedir que o usuário use exatamente o mesmo caminho como entrada e saída.
# Não depende de "readlink -f", que não é POSIX.
canonical_path()
{
    cp_path=$1

    case $cp_path in
        /*) ;;
        *) cp_path=`pwd`/$cp_path ;;
    esac

    cp_dir=`dirname "$cp_path"`
    cp_base=`basename "$cp_path"`

    if cp_real_dir=`cd "$cp_dir" 2>/dev/null && pwd -P`; then
        printf '%s/%s\n' "$cp_real_dir" "$cp_base"
    else
        # Se o diretório de saída ainda não existir, devolvemos a forma
        # absoluta lexical. A criação do diretório não é feita automaticamente.
        printf '%s\n' "$cp_path"
    fi
}

# Se o arquivo de saída já existir, não o sobrescrevemos. Criamos automaticamente
# nome_1.ext, nome_2.ext etc. Isso elimina o risco de perda acidental.
make_unique_output()
{
    mu_path=$1

    if [ ! -e "$mu_path" ]; then
        printf '%s\n' "$mu_path"
        return
    fi

    mu_dir=`dirname "$mu_path"`
    mu_base=`basename "$mu_path"`

    case $mu_base in
        *.*)
            mu_stem=${mu_base%.*}
            mu_ext=.${mu_base##*.}
            ;;
        *)
            mu_stem=$mu_base
            mu_ext=""
            ;;
    esac

    mu_n=1
    while :
    do
        mu_candidate=$mu_dir/${mu_stem}_$mu_n$mu_ext
        if [ ! -e "$mu_candidate" ]; then
            printf '%s\n' "$mu_candidate"
            return
        fi
        mu_n=$((mu_n + 1))
    done
}

# Cria apenas o NOME do temporário, no mesmo diretório do destino. Manter o
# temporário no mesmo filesystem torna o "mv" final atômico na maioria dos
# sistemas locais e evita copiar um arquivo enorme entre filesystems.
make_temp_output_name()
{
    mt_dir=`dirname "$OUTPUT"`
    mt_base=`basename "$OUTPUT"`

    case $mt_base in
        *.*)
            mt_stem=${mt_base%.*}
            mt_ext=.${mt_base##*.}
            ;;
        *)
            mt_stem=$mt_base
            mt_ext=""
            ;;
    esac

    mt_n=0
    while :
    do
        mt_candidate=$mt_dir/.${mt_stem}.partial.$$.$mt_n$mt_ext
        if [ ! -e "$mt_candidate" ]; then
            printf '%s\n' "$mt_candidate"
            return
        fi
        mt_n=$((mt_n + 1))
    done
}

# ---------------------------------------------------------------------------
# Detecção do contêiner de saída pela extensão
# ---------------------------------------------------------------------------
# A extensão NÃO é usada para detectar a entrada; a entrada é analisada pelo
# ffprobe. Aqui ela é usada apenas para escolher um perfil de mux/codec seguro
# para o arquivo que o usuário explicitamente pediu como saída.
detect_output_family()
{
    do_base=`basename "$OUTPUT"`

    case $do_base in
        *.*) OUTPUT_EXT=`printf '%s' "${do_base##*.}" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz'` ;;
        *) OUTPUT_EXT="" ;;
    esac

    case $OUTPUT_EXT in
        mkv|mka|mks) OUTPUT_FAMILY="matroska"; OUTPUT_MUXER="matroska" ;;
        mp4|m4v) OUTPUT_FAMILY="mp4"; OUTPUT_MUXER="mp4" ;;
        mov) OUTPUT_FAMILY="mov"; OUTPUT_MUXER="mov" ;;
        webm) OUTPUT_FAMILY="webm"; OUTPUT_MUXER="webm" ;;
        avi) OUTPUT_FAMILY="avi"; OUTPUT_MUXER="avi" ;;
        ogv|ogg) OUTPUT_FAMILY="ogg"; OUTPUT_MUXER="ogg" ;;
        flv) OUTPUT_FAMILY="flv"; OUTPUT_MUXER="flv" ;;
        mpg|mpeg) OUTPUT_FAMILY="mpeg"; OUTPUT_MUXER="mpeg" ;;
        vob) OUTPUT_FAMILY="vob"; OUTPUT_MUXER="vob" ;;
        ts|mts|m2ts) OUTPUT_FAMILY="mpegts"; OUTPUT_MUXER="mpegts" ;;
        wmv|asf) OUTPUT_FAMILY="asf"; OUTPUT_MUXER="asf" ;;
        rm|rmvb) OUTPUT_FAMILY="rm"; OUTPUT_MUXER="rm" ;;
        3gp|3g2) OUTPUT_FAMILY="3gp"; OUTPUT_MUXER="3gp" ;;
        *) OUTPUT_FAMILY="generic"; OUTPUT_MUXER="" ;;
    esac
}

# ---------------------------------------------------------------------------
# Análise da entrada
# ---------------------------------------------------------------------------
probe_input()
{
    # Duração em segundos, decimal. Alguns arquivos quebrados podem retornar
    # N/A; o modo de tamanho-alvo exige duração válida.
    DURATION=`ffprobe -v error \
        -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 \
        "$INPUT" 2>/dev/null | sed -n '1p'`

    VIDEO_COUNT=`ffprobe -v error -select_streams v \
        -show_entries stream=index -of csv=p=0 "$INPUT" 2>/dev/null | wc -l | tr -d ' '`

    AUDIO_COUNT=`ffprobe -v error -select_streams a \
        -show_entries stream=index -of csv=p=0 "$INPUT" 2>/dev/null | wc -l | tr -d ' '`

    SUBTITLE_COUNT=`ffprobe -v error -select_streams s \
        -show_entries stream=index -of csv=p=0 "$INPUT" 2>/dev/null | wc -l | tr -d ' '`

    ATTACHMENT_COUNT=`ffprobe -v error -select_streams t \
        -show_entries stream=index -of csv=p=0 "$INPUT" 2>/dev/null | wc -l | tr -d ' '`

    DATA_COUNT=`ffprobe -v error -select_streams d \
        -show_entries stream=index -of csv=p=0 "$INPUT" 2>/dev/null | wc -l | tr -d ' '`

    AUDIO_CODECS=`ffprobe -v error -select_streams a \
        -show_entries stream=codec_name -of csv=p=0 "$INPUT" 2>/dev/null`

    SUBTITLE_CODECS=`ffprobe -v error -select_streams s \
        -show_entries stream=codec_name -of csv=p=0 "$INPUT" 2>/dev/null`

    if [ "$VIDEO_COUNT" -eq 0 ]; then
        die "nenhum stream de vídeo foi encontrado na entrada."
    fi
}

show_probe_summary()
{
    print_line
    info "ANÁLISE DA ENTRADA"
    print_line
    info "Arquivo: $INPUT"
    info "Duração: ${DURATION:-desconhecida} s"
    info "Vídeos: $VIDEO_COUNT"
    info "Áudios: $AUDIO_COUNT"
    info "Legendas: $SUBTITLE_COUNT"
    info "Anexos: $ATTACHMENT_COUNT"
    info "Dados auxiliares: $DATA_COUNT"
    info ""

    # Exibição detalhada. O ffprobe é a fonte de verdade; não inferimos codec
    # de entrada pela extensão, por isso RMVB renomeado continua funcionando.
    ffprobe -v error \
        -show_entries \
stream=index,codec_type,codec_name,width,height,pix_fmt,r_frame_rate,sample_rate,channels,channel_layout:stream_tags=language,title \
        -of compact=p=0:nk=0 "$INPUT" 2>/dev/null || :
    print_line
}

# ---------------------------------------------------------------------------
# Validação de opções do usuário
# ---------------------------------------------------------------------------
validate_scale_height()
{
    case $SCALE_HEIGHT in
        original) return ;;
        '') SCALE_HEIGHT="original"; return ;;
        *[!0-9]*) die "altura inválida: $SCALE_HEIGHT" ;;
        *)
            if [ "$SCALE_HEIGHT" -lt 2 ]; then
                die "a altura deve ser 'original' ou um inteiro >= 2."
            fi
            ;;
    esac
}

validate_mode()
{
    case $MODE in
        remux|lossless|max|high|balanced|compact|target) ;;
        *) die "modo inválido: $MODE" ;;
    esac
}

validate_audio_policy()
{
    case $AUDIO_POLICY in
        preserve|compatible) ;;
        *) die "política de áudio inválida: $AUDIO_POLICY" ;;
    esac
}

# ---------------------------------------------------------------------------
# Menu interativo
# ---------------------------------------------------------------------------
# Se -m não foi fornecido, o usuário recebe um menu. O mesmo script continua
# utilizável de forma não-interativa em automações quando -m é informado.
interactive_mode_menu()
{
    if [ -n "$MODE" ]; then
        return
    fi

    cat <<'MENU'
Escolha o modo:

  1) Remux / cópia integral, zero recodificação
  2) Lossless verdadeiro
  3) Qualidade máxima
  4) Qualidade alta
  5) Qualidade equilibrada
  6) Compressão forte / compacta
  7) Tamanho-alvo em MB
MENU

    printf '%s' "Opção [4]: "
    IFS= read -r im_choice || im_choice=""

    case $im_choice in
        1) MODE="remux" ;;
        2) MODE="lossless" ;;
        3) MODE="max" ;;
        ''|4) MODE="high" ;;
        5) MODE="balanced" ;;
        6) MODE="compact" ;;
        7) MODE="target" ;;
        *) die "opção inválida." ;;
    esac
}

interactive_scale_menu()
{
    case $MODE in
        remux|lossless|target) return ;;
    esac

    # Se -r foi fornecido, não perguntamos novamente, inclusive quando
    # o valor explicitamente escolhido foi "original".
    if [ "$SCALE_SET" -eq 1 ]; then
        return
    fi

    cat <<'MENU'
Resolução de saída:

  1) Manter resolução original
  2) 480p
  3) 720p
  4) 1080p
  5) 1440p
  6) 2160p / 4K
  7) Altura personalizada

Observação: upscale não recupera detalhes que não existem no original.
MENU

    printf '%s' "Opção [1]: "
    IFS= read -r is_choice || is_choice=""

    case $is_choice in
        ''|1) SCALE_HEIGHT="original" ;;
        2) SCALE_HEIGHT="480" ;;
        3) SCALE_HEIGHT="720" ;;
        4) SCALE_HEIGHT="1080" ;;
        5) SCALE_HEIGHT="1440" ;;
        6) SCALE_HEIGHT="2160" ;;
        7)
            printf '%s' "Altura em pixels: "
            IFS= read -r SCALE_HEIGHT || SCALE_HEIGHT=""
            ;;
        *) die "opção de resolução inválida." ;;
    esac
}

interactive_target_size()
{
    if [ "$MODE" != "target" ]; then
        return
    fi

    if [ -n "$TARGET_MB" ]; then
        return
    fi

    printf '%s' "Tamanho-alvo em MB (ex.: 30): "
    IFS= read -r TARGET_MB || TARGET_MB=""
}

# ---------------------------------------------------------------------------
# Detecção de encoder disponível
# ---------------------------------------------------------------------------
encoder_available()
{
    ffmpeg -hide_banner -encoders 2>/dev/null | \
        grep "[[:space:]]$1[[:space:]]" >/dev/null 2>&1
}

choose_video_encoder()
{
    case $OUTPUT_FAMILY in
        matroska)
            # HEVC oferece excelente eficiência para acervo. Se libx265 não
            # existir, caímos para H.264.
            if encoder_available libx265; then
                VIDEO_ENCODER="libx265"
            elif encoder_available libx264; then
                VIDEO_ENCODER="libx264"
            else
                VIDEO_ENCODER="mpeg4"
            fi
            ;;
        mp4|mov|3gp)
            if encoder_available libx264; then
                VIDEO_ENCODER="libx264"
            else
                VIDEO_ENCODER="mpeg4"
            fi
            ;;
        webm)
            if encoder_available libvpx-vp9; then
                VIDEO_ENCODER="libvpx-vp9"
            elif encoder_available libsvtav1; then
                VIDEO_ENCODER="libsvtav1"
            else
                conversion_die "nenhum encoder VP9/AV1 adequado ao WebM foi encontrado."
            fi
            ;;
        ogg)
            if encoder_available libtheora; then
                VIDEO_ENCODER="libtheora"
            else
                VIDEO_ENCODER="theora"
            fi
            ;;
        avi)
            VIDEO_ENCODER="mpeg4"
            ;;
        flv)
            if encoder_available libx264; then
                VIDEO_ENCODER="libx264"
            else
                VIDEO_ENCODER="flv"
            fi
            ;;
        mpeg|vob)
            VIDEO_ENCODER="mpeg2video"
            ;;
        mpegts)
            if encoder_available libx264; then
                VIDEO_ENCODER="libx264"
            else
                VIDEO_ENCODER="mpeg2video"
            fi
            ;;
        asf)
            VIDEO_ENCODER="wmv2"
            ;;
        rm)
            # FFmpeg normalmente oferece rv10/rv20 como encoders. RV30/RV40
            # são comuns como DECODERS em RMVB, mas não devem ser presumidos
            # como encoders disponíveis.
            if encoder_available rv20; then
                VIDEO_ENCODER="rv20"
            else
                VIDEO_ENCODER="rv10"
            fi
            ;;
        generic)
            # Para extensões menos comuns, tentamos H.264 e deixamos o muxer
            # do FFmpeg validar se o contêiner solicitado realmente aceita.
            if encoder_available libx264; then
                VIDEO_ENCODER="libx264"
            else
                VIDEO_ENCODER="mpeg4"
            fi
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Compatibilidade de áudio
# ---------------------------------------------------------------------------
# Retorna 0 se TODOS os codecs de áudio de entrada forem razoavelmente seguros
# para cópia dentro do contêiner de saída. Essa tabela é conservadora: quando
# há dúvida, preferimos não prometer algo que o contêiner talvez rejeite.
all_audio_copy_compatible()
{
    if [ "$AUDIO_COUNT" -eq 0 ]; then
        return 0
    fi

    for aac_codec in $AUDIO_CODECS
    do
        case $OUTPUT_FAMILY:$aac_codec in
            matroska:*) ;;

            mp4:aac|mp4:mp3|mp4:ac3|mp4:eac3|mp4:alac) ;;
            mov:aac|mov:mp3|mov:ac3|mov:eac3|mov:alac|mov:pcm_s16le|mov:pcm_s24le|mov:pcm_s32le|mov:pcm_f32le|mov:pcm_f64le) ;;
            3gp:aac|3gp:amr_nb|3gp:amr_wb) ;;
            webm:opus|webm:vorbis) ;;
            ogg:opus|ogg:vorbis|ogg:flac) ;;
            avi:mp3|avi:ac3|avi:pcm_s16le|avi:pcm_s24le|avi:pcm_s32le|avi:pcm_u8) ;;
            flv:aac|flv:mp3|flv:speex) ;;
            mpeg:mp2|mpeg:mp3|mpeg:ac3) ;;
            vob:mp2|vob:ac3|vob:dts|vob:pcm_dvd) ;;
            mpegts:aac|mpegts:ac3|mpegts:eac3|mpegts:mp2|mpegts:mp3|mpegts:dts|mpegts:truehd) ;;
            asf:wmav1|asf:wmav2|asf:mp3) ;;
            rm:ac3|rm:cook|rm:ra_144|rm:ra_288) ;;
            generic:*) ;;
            *) return 1 ;;
        esac
    done

    return 0
}

# Escolhe o que fazer com áudio quando a cópia direta não é compatível.
# "preserve" nunca escolhe codec lossy escondido.
choose_audio_action()
{
    AUDIO_ACTION="copy"
    AUDIO_ENCODER=""
    AUDIO_BITRATE=""

    if all_audio_copy_compatible; then
        AUDIO_ACTION="copy"
        return
    fi

    if [ "$AUDIO_POLICY" = "preserve" ]; then
        case $OUTPUT_FAMILY in
            mp4|mov)
                if encoder_available alac; then
                    AUDIO_ACTION="lossless"
                    AUDIO_ENCODER="alac"
                else
                    conversion_die "áudio incompatível com $OUTPUT_EXT e encoder ALAC não disponível. Use MKV para preservar o áudio sem perdas."
                fi
                ;;
            ogg)
                if encoder_available flac; then
                    AUDIO_ACTION="lossless"
                    AUDIO_ENCODER="flac"
                else
                    conversion_die "áudio incompatível com Ogg e encoder FLAC não disponível. Use MKV."
                fi
                ;;
            *)
                conversion_die "o contêiner .$OUTPUT_EXT não consegue preservar todas as faixas de áudio atuais sem uma conversão potencialmente lossy. Use MKV ou execute com '-a compatible' se aceitar recodificação de áudio."
                ;;
        esac
    else
        # Política opt-in: recodifica apenas para compatibilidade. O script
        # continua preservando quantidade de faixas, canais e sample rate na
        # medida suportada pelo encoder; NÃO aplica filtros de dinâmica.
        case $OUTPUT_FAMILY in
            mp4|mov|3gp|flv)
                AUDIO_ACTION="lossy"
                AUDIO_ENCODER="aac"
                AUDIO_BITRATE="320k"
                ;;
            webm)
                if encoder_available libopus; then
                    AUDIO_ENCODER="libopus"
                else
                    AUDIO_ENCODER="opus"
                fi
                AUDIO_ACTION="lossy"
                AUDIO_BITRATE="256k"
                ;;
            ogg)
                if encoder_available libvorbis; then
                    AUDIO_ENCODER="libvorbis"
                else
                    AUDIO_ENCODER="vorbis"
                fi
                AUDIO_ACTION="lossy"
                ;;
            avi)
                if encoder_available libmp3lame; then
                    AUDIO_ENCODER="libmp3lame"
                else
                    AUDIO_ENCODER="mp3"
                fi
                AUDIO_ACTION="lossy"
                AUDIO_BITRATE="320k"
                ;;
            mpeg)
                AUDIO_ACTION="lossy"
                AUDIO_ENCODER="mp2"
                AUDIO_BITRATE="384k"
                ;;
            vob|mpegts|rm)
                AUDIO_ACTION="lossy"
                AUDIO_ENCODER="ac3"
                AUDIO_BITRATE="448k"
                ;;
            asf)
                AUDIO_ACTION="lossy"
                AUDIO_ENCODER="wmav2"
                AUDIO_BITRATE="320k"
                ;;
            matroska)
                AUDIO_ACTION="copy"
                ;;
            generic)
                AUDIO_ACTION="copy"
                ;;
        esac
    fi
}

# ---------------------------------------------------------------------------
# Compatibilidade de streams auxiliares
# ---------------------------------------------------------------------------
# O projeto adota política conservadora: não descartamos legenda, attachment
# ou data stream só para a conversão "passar". Matroska é o destino recomendado
# para preservação integral de arquivos complexos.
check_aux_stream_policy()
{
    case $OUTPUT_FAMILY in
        matroska)
            return
            ;;
        mp4|mov)
            if [ "$ATTACHMENT_COUNT" -gt 0 ]; then
                conversion_die "a entrada contém anexos/attachments. Para preservá-los integralmente, use MKV."
            fi

            # MP4/MOV não preserva todos os codecs de legenda de Matroska.
            for cas_codec in $SUBTITLE_CODECS
            do
                case $cas_codec in
                    mov_text) ;;
                    subrip|ass|ssa|webvtt|text)
                        # Será convertido para mov_text posteriormente. Conteúdo
                        # textual é mantido, mas estilos avançados ASS podem não
                        # ser representáveis no MP4.
                        warn "legenda $cas_codec será convertida para mov_text; estilos avançados podem não ser preservados."
                        ;;
                    *)
                        conversion_die "legenda '$cas_codec' não pode ser preservada com segurança em .$OUTPUT_EXT. Use MKV."
                        ;;
                esac
            done
            ;;
        webm)
            if [ "$ATTACHMENT_COUNT" -gt 0 ] || [ "$DATA_COUNT" -gt 0 ]; then
                conversion_die "WebM não é adequado para preservar os streams auxiliares deste arquivo. Use MKV."
            fi
            for cas_codec in $SUBTITLE_CODECS
            do
                case $cas_codec in
                    webvtt|subrip|ass|ssa|text) ;;
                    *) conversion_die "legenda '$cas_codec' não pode ser preservada com segurança em WebM. Use MKV." ;;
                esac
            done
            ;;
        *)
            if [ "$SUBTITLE_COUNT" -gt 0 ] || [ "$ATTACHMENT_COUNT" -gt 0 ] || [ "$DATA_COUNT" -gt 0 ]; then
                conversion_die "o destino .$OUTPUT_EXT não é considerado seguro para preservar todos os streams auxiliares encontrados. Use MKV para preservação integral."
            fi
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Construção das opções de qualidade de vídeo
# ---------------------------------------------------------------------------
# Esta função NÃO executa o ffmpeg. Ela é chamada de dentro de run_transcode,
# onde os argumentos são acumulados de forma segura usando "set --".
#
# Os números CRF/Q são específicos de cada família de encoder; não são uma
# escala universal. Por isso os valores são mapeados separadamente.
append_video_quality_args()
{
    # Os argumentos existentes são recebidos como parâmetros da função.
    # A função imprime um conjunto simples de tokens delimitados por newline,
    # mas, para evitar problemas com quoting, não a usamos diretamente na
    # execução. A lógica correspondente está duplicada de forma explícita em
    # run_transcode. Esta função existe apenas como documentação conceitual.
    :
}

# ---------------------------------------------------------------------------
# Mapeamento comum de streams
# ---------------------------------------------------------------------------
# Em transcodificação, mapeamos TODOS os vídeos, áudios e legendas. Matroska
# também recebe attachments e data streams. Em outros contêineres, a checagem
# anterior impede perda silenciosa de streams não representáveis.
append_common_maps()
{
    :
}

# ---------------------------------------------------------------------------
# REMUX: zero recodificação
# ---------------------------------------------------------------------------
run_remux()
{
    info "Modo REMUX: nenhum stream será recodificado."
    info "Tentando preservar todos os streams exatamente como estão..."

    set -- ffmpeg -hide_banner -nostdin -stats \
        -i "$INPUT" \
        -map 0 \
        -map_metadata 0 \
        -map_chapters 0 \
        -c copy

    if [ -n "$OUTPUT_MUXER" ]; then
        set -- "$@" -f "$OUTPUT_MUXER"
    fi

    if "$@" "$TMP_OUTPUT"; then
        return 0
    fi

    conversion_die "remux não é compatível com o contêiner de destino. Nenhum fallback lossy foi executado. Tente MKV ou um modo de transcodificação."
}

# ---------------------------------------------------------------------------
# LOSSLESS verdadeiro
# ---------------------------------------------------------------------------
run_lossless()
{
    info "Modo LOSSLESS: o vídeo será codificado sem perda matemática."
    info "Isso NÃO garante arquivo menor; em muitos casos ele ficará maior."

    check_aux_stream_policy
    choose_audio_action

    # Lossless é deliberadamente rígido: se a política de áudio escolhida
    # resultar em codec lossy, abortamos.
    if [ "$AUDIO_ACTION" = "lossy" ]; then
        conversion_die "modo lossless não aceita áudio lossy. Use -a preserve ou escolha MKV."
    fi

    set -- ffmpeg -hide_banner -nostdin -stats -i "$INPUT"
    set -- "$@" -map '0:v?' -map '0:a?' -map '0:s?'

    if [ "$OUTPUT_FAMILY" = "matroska" ]; then
        set -- "$@" -map '0:t?' -map '0:d?'
    fi

    set -- "$@" -map_metadata 0 -map_chapters 0

    case $OUTPUT_FAMILY in
        matroska)
            if encoder_available ffv1; then
                # FFV1 é excelente para arquivo lossless/arquivamento.
                set -- "$@" -c:v ffv1 -level 3 -coder 1 -context 1 -g 1 -slicecrc 1
            elif encoder_available libx264; then
                set -- "$@" -c:v libx264 -preset veryslow -qp 0
            else
                conversion_die "nenhum encoder de vídeo lossless adequado foi encontrado."
            fi
            ;;
        mp4|mov)
            if encoder_available libx264; then
                set -- "$@" -c:v libx264 -preset veryslow -qp 0
            else
                conversion_die "libx264 é necessário para este modo lossless em .$OUTPUT_EXT."
            fi
            ;;
        webm)
            if encoder_available libvpx-vp9; then
                set -- "$@" -c:v libvpx-vp9 -lossless 1 -row-mt 1
            else
                conversion_die "libvpx-vp9 é necessário para lossless WebM."
            fi
            ;;
        avi)
            if encoder_available ffv1; then
                set -- "$@" -c:v ffv1
            else
                conversion_die "FFV1 é necessário para lossless AVI nesta implementação."
            fi
            ;;
        *)
            conversion_die "modo lossless seguro não está definido para .$OUTPUT_EXT. Use MKV, MP4/MOV, WebM ou AVI."
            ;;
    esac

    # Áudio: sem filtros. Ou bitstream copy ou codec lossless.
    case $AUDIO_ACTION in
        copy) set -- "$@" -c:a copy ;;
        lossless) set -- "$@" -c:a "$AUDIO_ENCODER" ;;
    esac

    case $OUTPUT_FAMILY in
        matroska) set -- "$@" -c:s copy -c:t copy -c:d copy ;;
        mp4|mov)
            if [ "$SUBTITLE_COUNT" -gt 0 ]; then
                set -- "$@" -c:s mov_text
            fi
            ;;
        webm)
            if [ "$SUBTITLE_COUNT" -gt 0 ]; then
                set -- "$@" -c:s webvtt
            fi
            ;;
    esac

    if [ -n "$OUTPUT_MUXER" ]; then
        set -- "$@" -f "$OUTPUT_MUXER"
    fi

    if "$@" "$TMP_OUTPUT"; then
        return 0
    fi

    conversion_die "a conversão lossless falhou. O original permanece intacto."
}

# ---------------------------------------------------------------------------
# Transcodificação com perfis de qualidade
# ---------------------------------------------------------------------------
run_transcode()
{
    check_aux_stream_policy
    choose_video_encoder
    choose_audio_action

    info "Encoder de vídeo: $VIDEO_ENCODER"
    info "Política de áudio: $AUDIO_POLICY / ação: $AUDIO_ACTION"

    set -- ffmpeg -hide_banner -nostdin -stats -i "$INPUT"
    set -- "$@" -map '0:v?' -map '0:a?' -map '0:s?'

    if [ "$OUTPUT_FAMILY" = "matroska" ]; then
        set -- "$@" -map '0:t?' -map '0:d?'
    fi

    set -- "$@" -map_metadata 0 -map_chapters 0
    set -- "$@" -c:v "$VIDEO_ENCODER"

    # Qualidade de vídeo. Cada encoder recebe parâmetros coerentes com sua
    # própria escala. "max" significa mínima perda adicional, não restauração.
    case $VIDEO_ENCODER in
        libx264)
            case $MODE in
                max) set -- "$@" -preset veryslow -crf 14 ;;
                high) set -- "$@" -preset slow -crf 18 ;;
                balanced) set -- "$@" -preset medium -crf 22 ;;
                compact) set -- "$@" -preset slow -crf 27 ;;
            esac
            ;;
        libx265)
            case $MODE in
                max) set -- "$@" -preset veryslow -crf 16 ;;
                high) set -- "$@" -preset slow -crf 20 ;;
                balanced) set -- "$@" -preset medium -crf 24 ;;
                compact) set -- "$@" -preset slow -crf 29 ;;
            esac
            ;;
        libvpx-vp9)
            case $MODE in
                max) set -- "$@" -crf 15 -b:v 0 -row-mt 1 ;;
                high) set -- "$@" -crf 22 -b:v 0 -row-mt 1 ;;
                balanced) set -- "$@" -crf 30 -b:v 0 -row-mt 1 ;;
                compact) set -- "$@" -crf 38 -b:v 0 -row-mt 1 ;;
            esac
            ;;
        libsvtav1)
            case $MODE in
                max) set -- "$@" -preset 4 -crf 18 ;;
                high) set -- "$@" -preset 6 -crf 24 ;;
                balanced) set -- "$@" -preset 8 -crf 30 ;;
                compact) set -- "$@" -preset 9 -crf 38 ;;
            esac
            ;;
        mpeg4|mpeg2video|wmv2|rv20|rv10|flv|libtheora|theora)
            case $MODE in
                max) set -- "$@" -q:v 2 ;;
                high) set -- "$@" -q:v 3 ;;
                balanced) set -- "$@" -q:v 5 ;;
                compact) set -- "$@" -q:v 8 ;;
            esac
            ;;
        *)
            case $MODE in
                max) set -- "$@" -q:v 2 ;;
                high) set -- "$@" -q:v 3 ;;
                balanced) set -- "$@" -q:v 5 ;;
                compact) set -- "$@" -q:v 8 ;;
            esac
            ;;
    esac

    # Alteração opcional de resolução. Não fazemos qualquer sharpening,
    # denoise ou "melhoria automática" porque esses filtros alteram a imagem.
    if [ "$SCALE_HEIGHT" != "original" ]; then
        set -- "$@" -vf "scale=-2:${SCALE_HEIGHT}:flags=lanczos"
    fi

    # Áudio: nenhuma normalização/compressão dinâmica. Não há -af, loudnorm,
    # dynaudnorm, acompressor, limiter ou alteração automática de volume.
    case $AUDIO_ACTION in
        copy)
            set -- "$@" -c:a copy
            ;;
        lossless)
            set -- "$@" -c:a "$AUDIO_ENCODER"
            ;;
        lossy)
            set -- "$@" -c:a "$AUDIO_ENCODER"
            if [ -n "$AUDIO_BITRATE" ]; then
                set -- "$@" -b:a "$AUDIO_BITRATE"
            fi
            ;;
    esac

    # Legendas e streams auxiliares.
    case $OUTPUT_FAMILY in
        matroska)
            set -- "$@" -c:s copy -c:t copy -c:d copy
            ;;
        mp4|mov)
            if [ "$SUBTITLE_COUNT" -gt 0 ]; then
                set -- "$@" -c:s mov_text
            fi
            ;;
        webm)
            if [ "$SUBTITLE_COUNT" -gt 0 ]; then
                set -- "$@" -c:s webvtt
            fi
            ;;
    esac

    # faststart melhora reprodução progressiva de MP4/MOV e não altera mídia.
    case $OUTPUT_FAMILY in
        mp4|mov) set -- "$@" -movflags +faststart ;;
    esac

    # Fila maior ajuda arquivos com muitos streams sem mexer na qualidade.
    set -- "$@" -max_muxing_queue_size 4096

    if [ -n "$OUTPUT_MUXER" ]; then
        set -- "$@" -f "$OUTPUT_MUXER"
    fi

    if "$@" "$TMP_OUTPUT"; then
        return 0
    fi

    conversion_die "transcodificação falhou. Nenhum arquivo original foi alterado."
}

# ---------------------------------------------------------------------------
# Modo de tamanho-alvo
# ---------------------------------------------------------------------------
# O cálculo preserva o áudio por cópia. Para isso, o script mede o tamanho dos
# pacotes de áudio do arquivo de origem (sem decodificá-los), subtrai esse
# espaço do orçamento total e reserva 2% para overhead de contêiner.
#
# 2-pass é usado para libx264/libx265/libvpx-vp9 quando possível. Outros
# encoders usam bitrate médio em uma passagem, portanto o tamanho é aproximado.
measure_audio_bytes()
{
    if [ "$AUDIO_COUNT" -eq 0 ]; then
        printf '%s\n' "0"
        return
    fi

    # ffprobe pode imprimir N/A para pacotes anômalos. O awk soma apenas
    # valores numéricos positivos.
    ffprobe -v error -select_streams a -show_packets \
        -show_entries packet=size -of csv=p=0 "$INPUT" 2>/dev/null | \
        awk '
            /^[0-9]+$/ { sum += $1 }
            END { printf "%.0f\n", sum + 0 }
        '
}

validate_target_parameters()
{
    case $TARGET_MB in
        ''|*[!0-9.]*|*.*.*) die "tamanho-alvo inválido: '$TARGET_MB'" ;;
    esac

    # POSIX awk é usado para aritmética decimal.
    if ! awk "BEGIN { exit !($TARGET_MB > 0) }"; then
        die "o tamanho-alvo deve ser maior que zero."
    fi

    case $DURATION in
        ''|N/A) die "não foi possível determinar a duração; modo target indisponível." ;;
    esac

    if ! awk "BEGIN { exit !($DURATION > 0) }"; then
        die "duração inválida para cálculo de tamanho-alvo."
    fi
}

run_target_size()
{
    validate_target_parameters
    check_aux_stream_policy
    choose_video_encoder

    # Para respeitar o requisito de áudio sem perda, tamanho-alvo só continua
    # se o áudio puder ser copiado sem recodificação.
    if ! all_audio_copy_compatible; then
        conversion_die "modo target preserva o áudio por cópia. As faixas atuais não são compatíveis com .$OUTPUT_EXT. Use MKV ou outro destino compatível."
    fi

    ts_audio_bytes=`measure_audio_bytes`

    # Reserva 2% do arquivo para headers/index/overhead. O restante, menos o
    # áudio, é convertido em bitrate de vídeo.
    ts_video_bps=`awk -v mb="$TARGET_MB" -v dur="$DURATION" -v abytes="$ts_audio_bytes" '
        BEGIN {
            target = mb * 1000 * 1000;
            usable = target * 0.98;
            video_bytes = usable - abytes;
            if (video_bytes <= 0 || dur <= 0) {
                print 0;
                exit;
            }
            printf "%.0f\n", (video_bytes * 8) / dur;
        }
    '`

    if [ "$ts_video_bps" -le 10000 ]; then
        conversion_die "o tamanho-alvo é pequeno demais depois de reservar espaço para o áudio."
    fi

    ts_video_kbps=`awk -v b="$ts_video_bps" 'BEGIN { printf "%.0f\n", b / 1000 }'`

    info "Tamanho-alvo: $TARGET_MB MB"
    info "Bytes de áudio preservados (aprox.): $ts_audio_bytes"
    info "Bitrate de vídeo calculado: ${ts_video_kbps} kbit/s"
    info "Encoder: $VIDEO_ENCODER"

    PASSLOG=`dirname "$OUTPUT"`/.video_convert_pass_$$

    case $VIDEO_ENCODER in
        libx264|libx265|libvpx-vp9)
            # PRIMEIRA PASSAGEM: só vídeo, saída descartada. Não toca no original.
            set -- ffmpeg -hide_banner -nostdin -stats -i "$INPUT" \
                -map '0:v:0?' -c:v "$VIDEO_ENCODER" -b:v "${ts_video_kbps}k" \
                -pass 1 -passlogfile "$PASSLOG" -an -sn -dn

            case $VIDEO_ENCODER in
                libx264) set -- "$@" -preset slow ;;
                libx265) set -- "$@" -preset slow ;;
                libvpx-vp9) set -- "$@" -row-mt 1 ;;
            esac

            if ! "$@" -f null /dev/null; then
                conversion_die "primeira passagem do modo target falhou."
            fi

            # SEGUNDA PASSAGEM: agora mapeamos TODOS os áudios e legendas.
            set -- ffmpeg -hide_banner -nostdin -stats -i "$INPUT" \
                -map '0:v?' -map '0:a?' -map '0:s?'

            if [ "$OUTPUT_FAMILY" = "matroska" ]; then
                set -- "$@" -map '0:t?' -map '0:d?'
            fi

            set -- "$@" -map_metadata 0 -map_chapters 0 \
                -c:v "$VIDEO_ENCODER" -b:v "${ts_video_kbps}k" \
                -pass 2 -passlogfile "$PASSLOG" -c:a copy

            case $VIDEO_ENCODER in
                libx264) set -- "$@" -preset slow ;;
                libx265) set -- "$@" -preset slow ;;
                libvpx-vp9) set -- "$@" -row-mt 1 ;;
            esac

            case $OUTPUT_FAMILY in
                matroska) set -- "$@" -c:s copy -c:t copy -c:d copy ;;
                mp4|mov)
                    if [ "$SUBTITLE_COUNT" -gt 0 ]; then
                        set -- "$@" -c:s mov_text
                    fi
                    set -- "$@" -movflags +faststart
                    ;;
                webm)
                    if [ "$SUBTITLE_COUNT" -gt 0 ]; then
                        set -- "$@" -c:s webvtt
                    fi
                    ;;
            esac

            set -- "$@" -max_muxing_queue_size 4096
            if [ -n "$OUTPUT_MUXER" ]; then
                set -- "$@" -f "$OUTPUT_MUXER"
            fi

            if ! "$@" "$TMP_OUTPUT"; then
                conversion_die "segunda passagem do modo target falhou."
            fi
            ;;
        *)
            # Fallback de uma passagem para encoders sem 2-pass confiável nesta
            # implementação. O resultado é aproximado.
            warn "encoder $VIDEO_ENCODER: usando bitrate médio em uma passagem; tamanho final é aproximado."

            set -- ffmpeg -hide_banner -nostdin -stats -i "$INPUT" \
                -map '0:v?' -map '0:a?' -map '0:s?' \
                -map_metadata 0 -map_chapters 0 \
                -c:v "$VIDEO_ENCODER" -b:v "${ts_video_kbps}k" -c:a copy

            set -- "$@" -max_muxing_queue_size 4096
            if [ -n "$OUTPUT_MUXER" ]; then
                set -- "$@" -f "$OUTPUT_MUXER"
            fi

            if ! "$@" "$TMP_OUTPUT"; then
                conversion_die "modo target falhou."
            fi
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Validação pós-conversão
# ---------------------------------------------------------------------------
# Não basta o ffmpeg retornar 0: antes de publicar o arquivo final, validamos:
#   - arquivo temporário existe e não está vazio;
#   - ffprobe consegue abri-lo;
#   - há pelo menos um vídeo;
#   - quantidade de faixas de áudio é EXATAMENTE a mesma da entrada.
#
# Essa última regra protege explicitamente dual-audio/multi-audio.
validate_output()
{
    if [ ! -f "$TMP_OUTPUT" ] || [ ! -s "$TMP_OUTPUT" ]; then
        validation_die "arquivo temporário não existe ou está vazio."
    fi

    if ! ffprobe -v error -show_entries format=format_name \
        -of default=noprint_wrappers=1:nokey=1 "$TMP_OUTPUT" >/dev/null 2>&1
    then
        validation_die "ffprobe não consegue abrir o arquivo convertido."
    fi

    vo_video_count=`ffprobe -v error -select_streams v \
        -show_entries stream=index -of csv=p=0 "$TMP_OUTPUT" 2>/dev/null | wc -l | tr -d ' '`

    vo_audio_count=`ffprobe -v error -select_streams a \
        -show_entries stream=index -of csv=p=0 "$TMP_OUTPUT" 2>/dev/null | wc -l | tr -d ' '`

    if [ "$vo_video_count" -lt 1 ]; then
        validation_die "a saída não contém vídeo."
    fi

    if [ "$vo_audio_count" -ne "$AUDIO_COUNT" ]; then
        validation_die "número de faixas de áudio mudou: entrada=$AUDIO_COUNT, saída=$vo_audio_count. O resultado NÃO será publicado."
    fi

    # Para Matroska/remux, também exigimos preservação das legendas porque o
    # contêiner oferece bom suporte a elas.
    if [ "$OUTPUT_FAMILY" = "matroska" ] || [ "$MODE" = "remux" ]; then
        vo_sub_count=`ffprobe -v error -select_streams s \
            -show_entries stream=index -of csv=p=0 "$TMP_OUTPUT" 2>/dev/null | wc -l | tr -d ' '`

        if [ "$vo_sub_count" -ne "$SUBTITLE_COUNT" ]; then
            validation_die "número de legendas mudou: entrada=$SUBTITLE_COUNT, saída=$vo_sub_count."
        fi
    fi
}

# ---------------------------------------------------------------------------
# Publicação atômica do resultado
# ---------------------------------------------------------------------------
commit_output()
{
    # Só chegamos aqui depois da validação. O mv transforma o temporário no
    # arquivo final. A entrada continua intocada.
    if ! mv "$TMP_OUTPUT" "$OUTPUT"; then
        validation_die "não foi possível mover o temporário para o nome final."
    fi

    TMP_OUTPUT=""
}

# ---------------------------------------------------------------------------
# Parse de opções POSIX via getopts
# ---------------------------------------------------------------------------
while getopts "m:r:s:a:h" opt
 do
    case $opt in
        m) MODE=$OPTARG ;;
        r) SCALE_HEIGHT=$OPTARG; SCALE_SET="1" ;;
        s) TARGET_MB=$OPTARG ;;
        a) AUDIO_POLICY=$OPTARG ;;
        h) usage; exit 0 ;;
        \?) usage >&2; exit 1 ;;
    esac
 done
shift $((OPTIND - 1))

if [ "$#" -ne 2 ]; then
    usage >&2
    exit 1
fi

INPUT=$1
OUTPUT_REQUESTED=$2

check_dependencies

if [ ! -f "$INPUT" ]; then
    die "arquivo de entrada não encontrado ou não é arquivo regular: $INPUT"
fi

out_dir=`dirname "$OUTPUT_REQUESTED"`
if [ ! -d "$out_dir" ]; then
    die "diretório de saída não existe: $out_dir"
fi

input_canon=`canonical_path "$INPUT"`
output_canon=`canonical_path "$OUTPUT_REQUESTED"`

if [ "$input_canon" = "$output_canon" ]; then
    die "entrada e saída apontam para o mesmo caminho. O original nunca pode ser sobrescrito."
fi

OUTPUT=`make_unique_output "$OUTPUT_REQUESTED"`

if [ "$OUTPUT" != "$OUTPUT_REQUESTED" ]; then
    warn "o destino já existia. Para preservá-lo, a saída será: $OUTPUT"
fi

TMP_OUTPUT=`make_temp_output_name`

detect_output_family
probe_input
show_probe_summary
interactive_mode_menu
interactive_scale_menu
interactive_target_size
validate_mode
validate_scale_height
validate_audio_policy

print_line
info "PLANO DE EXECUÇÃO"
print_line
info "Modo: $MODE"
info "Entrada protegida: $INPUT"
info "Saída final: $OUTPUT"
info "Temporário: $TMP_OUTPUT"
info "Família de destino: $OUTPUT_FAMILY"
info "Muxer FFmpeg: ${OUTPUT_MUXER:-automático}"
info "Resolução: $SCALE_HEIGHT"
info "Política de áudio: $AUDIO_POLICY"
info "Faixas de áudio que DEVEM existir na saída: $AUDIO_COUNT"
print_line

case $MODE in
    remux) run_remux ;;
    lossless) run_lossless ;;
    max|high|balanced|compact) run_transcode ;;
    target) run_target_size ;;
esac

info ""
info "Validando arquivo convertido antes de publicar..."
validate_output
commit_output

print_line
info "CONVERSÃO CONCLUÍDA COM SUCESSO"
print_line
info "Original preservado: $INPUT"
info "Novo arquivo: $OUTPUT"
info "Faixas de áudio preservadas: $AUDIO_COUNT"
info ""
info "O original não foi removido, renomeado, movido nem sobrescrito."
print_line

exit 0
