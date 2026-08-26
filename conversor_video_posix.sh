#!/bin/sh
# ============================================================================
# conversor_video_posix.sh - Interface interativa POSIX
# ============================================================================
# Versão 2.0.0
#
# Esta camada fornece o assistente interativo completo do projeto. O mecanismo
# de conversão permanece separado em lib/conversor_video_core.sh. Essa divisão
# é intencional:
#
#   - este arquivo cuida de seleção de arquivos, menus, lotes e nomes;
#   - o core cuida de FFmpeg, codecs, preservação de áudio e validação;
#   - cada item do lote é processado isoladamente pelo core;
#   - uma falha em um vídeo pode ser tratada sem corromper os demais;
#   - o arquivo original nunca é usado como saída.
#
# O script é /bin/sh POSIX: não usa arrays, [[ ]], local, mapfile, globstar,
# process substitution ou qualquer construção exclusiva do Bash.
# ============================================================================

set -u

PROGRAM=${0##*/}
VERSION="2.0.0"
SCRIPT_DIR=`CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd -P` || exit 1
CORE=$SCRIPT_DIR/lib/conversor_video_core.sh
LIST_FILE=""
LIST_ALL=""

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

cleanup()
{
    [ -n "$LIST_FILE" ] && [ -f "$LIST_FILE" ] && rm -f "$LIST_FILE"
    [ -n "$LIST_ALL" ] && [ -f "$LIST_ALL" ] && rm -f "$LIST_ALL"
}
trap 'cleanup' 0 1 2 3 15

usage()
{
    cat <<USAGE
$PROGRAM $VERSION

Uso recomendado:
  $PROGRAM
      Abre o assistente interativo completo.

Modo avançado/automação:
  $PROGRAM [opções] ARQUIVO_ENTRADA ARQUIVO_SAIDA
      Repassa os argumentos para o mecanismo de conversão.

No assistente é possível escolher interativamente:
  - arquivo único;
  - padrão/coringa, como /videos/*.rmvb ou /videos/*.*;
  - todos os vídeos de uma pasta;
  - pasta e subpastas recursivamente;
  - diretório de saída;
  - formato de saída;
  - sufixo dos nomes;
  - preservação da árvore de diretórios;
  - remux, lossless, máxima, alta, equilibrada, compacta ou tamanho-alvo;
  - resolução original, 480p, 720p, 1080p, 1440p, 2160p ou personalizada;
  - política de áudio;
  - continuar ou parar o lote em caso de erro.

A interface avançada continua aceitando as opções do core:
  -m MODO       remux | lossless | max | high | balanced | compact | target
  -r ALTURA     original | 480 | 720 | 1080 | 1440 | 2160 | inteiro
  -s MB         tamanho-alvo aproximado em MB
  -a POLITICA   preserve | compatible
  -h            ajuda
USAGE
}

require_command()
{
    command -v "$1" >/dev/null 2>&1 || die "dependência não encontrada: $1"
}

check_environment()
{
    [ -f "$CORE" ] || die "core não encontrado: $CORE"
    require_command ffprobe
    require_command dirname
    require_command basename
    require_command mkdir
    require_command find
    require_command wc
    require_command tr
    require_command sed
    require_command rm
}

# Pergunta S/N sem depender de recursos não POSIX.
yes_no()
{
    yn_text=$1
    yn_default=$2

    while :
    do
        if [ "$yn_default" = "yes" ]; then
            printf '%s' "$yn_text [S/n]: "
        else
            printf '%s' "$yn_text [s/N]: "
        fi
        IFS= read -r yn_answer || yn_answer=""
        yn_answer=`printf '%s' "$yn_answer" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz'`

        case $yn_answer:$yn_default in
            :yes|s:yes|sim:yes|y:yes|yes:yes|s:no|sim:no|y:no|yes:no) return 0 ;;
            :no|n:yes|nao:yes|não:yes|no:yes|n:no|nao:no|não:no|no:no) return 1 ;;
            *) warn "responda S ou N." ;;
        esac
    done
}

# Rejeita imagens comuns. Muitos formatos de imagem são expostos pelo FFmpeg
# como um stream de vídeo de um frame; numa varredura *.* isso seria indesejado.
is_video_file()
{
    iv_file=$1
    [ -f "$iv_file" ] || return 1

    iv_name=`basename "$iv_file"`
    case $iv_name in
        *.*) iv_ext=`printf '%s' "${iv_name##*.}" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz'` ;;
        *) iv_ext="" ;;
    esac

    case $iv_ext in
        jpg|jpeg|jpe|png|apng|bmp|gif|webp|tif|tiff|svg|heic|heif|avif|ico) return 1 ;;
    esac

    iv_stream=`ffprobe -v error -select_streams v:0 \
        -show_entries stream=index -of csv=p=0 "$iv_file" 2>/dev/null | sed -n '1p'`
    [ -n "$iv_stream" ]
}

choose_source()
{
    cat <<'MENU'
Como deseja selecionar os vídeos?

  1) Um arquivo específico
  2) Padrão/coringa, por exemplo /dados/videos/*.rmvb ou /dados/videos/*.*
  3) Todos os vídeos diretamente dentro de uma pasta
  4) Todos os vídeos de uma pasta e subpastas (recursivo)
MENU

    while :
    do
        printf '%s' "Opção [1]: "
        IFS= read -r cs_choice || cs_choice=""
        case $cs_choice in
            ''|1) SELECT_MODE="single"; break ;;
            2) SELECT_MODE="pattern"; break ;;
            3) SELECT_MODE="directory"; break ;;
            4) SELECT_MODE="recursive"; break ;;
            *) warn "opção inválida." ;;
        esac
    done

    case $SELECT_MODE in
        single)
            while :
            do
                printf '%s' "Caminho do vídeo: "
                IFS= read -r SINGLE_FILE || SINGLE_FILE=""
                if [ -f "$SINGLE_FILE" ]; then
                    SOURCE_ROOT=`dirname "$SINGLE_FILE"`
                    SOURCE_ROOT=`CDPATH= cd "$SOURCE_ROOT" 2>/dev/null && pwd -P`
                    SINGLE_FILE=$SOURCE_ROOT/`basename "$SINGLE_FILE"`
                    return
                fi
                warn "arquivo não encontrado."
            done
            ;;
        pattern)
            while :
            do
                printf '%s' "Padrão completo: "
                IFS= read -r PATTERN_FULL || PATTERN_FULL=""
                SOURCE_ROOT=`dirname "$PATTERN_FULL"`
                FILE_PATTERN=`basename "$PATTERN_FULL"`
                if [ -d "$SOURCE_ROOT" ] && [ -n "$FILE_PATTERN" ]; then
                    SOURCE_ROOT=`CDPATH= cd "$SOURCE_ROOT" 2>/dev/null && pwd -P`
                    return
                fi
                warn "padrão ou diretório inválido."
            done
            ;;
        directory|recursive)
            while :
            do
                printf '%s' "Caminho da pasta: "
                IFS= read -r SOURCE_ROOT || SOURCE_ROOT=""
                if [ -d "$SOURCE_ROOT" ]; then
                    SOURCE_ROOT=`CDPATH= cd "$SOURCE_ROOT" 2>/dev/null && pwd -P`
                    return
                fi
                warn "pasta não encontrada."
            done
            ;;
    esac
}

choose_destination()
{
    if [ "$SELECT_MODE" = "single" ]; then
        cd_default=$SOURCE_ROOT
    else
        cd_default=$SOURCE_ROOT/convertidos
    fi

    printf '%s' "Diretório de saída [$cd_default]: "
    IFS= read -r DESTINATION || DESTINATION=""
    [ -n "$DESTINATION" ] || DESTINATION=$cd_default

    if [ ! -d "$DESTINATION" ]; then
        if yes_no "O diretório não existe. Criá-lo?" yes; then
            mkdir -p "$DESTINATION" || die "não foi possível criar $DESTINATION"
        else
            die "diretório de saída não criado."
        fi
    fi

    DESTINATION=`CDPATH= cd "$DESTINATION" 2>/dev/null && pwd -P`
}

choose_extension()
{
    cat <<'MENU'
Formato/contêiner de saída:

  1) MKV / Matroska (recomendado para dual-audio e preservação)
  2) MP4
  3) MOV
  4) WebM
  5) AVI
  6) OGV
  7) MPEG / MPG
  8) MPEG-TS / TS
  9) RMVB / RealMedia
 10) 3GP
 11) Manter a extensão original de cada arquivo
 12) Outra extensão
MENU

    while :
    do
        printf '%s' "Opção [1]: "
        IFS= read -r ce_choice || ce_choice=""
        case $ce_choice in
            ''|1) OUT_EXTENSION="mkv"; return ;;
            2) OUT_EXTENSION="mp4"; return ;;
            3) OUT_EXTENSION="mov"; return ;;
            4) OUT_EXTENSION="webm"; return ;;
            5) OUT_EXTENSION="avi"; return ;;
            6) OUT_EXTENSION="ogv"; return ;;
            7) OUT_EXTENSION="mpg"; return ;;
            8) OUT_EXTENSION="ts"; return ;;
            9) OUT_EXTENSION="rmvb"; return ;;
            10) OUT_EXTENSION="3gp"; return ;;
            11) OUT_EXTENSION="original"; return ;;
            12)
                printf '%s' "Extensão sem ponto: "
                IFS= read -r OUT_EXTENSION || OUT_EXTENSION=""
                OUT_EXTENSION=`printf '%s' "$OUT_EXTENSION" | sed 's/^\.//' | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz'`
                case $OUT_EXTENSION in
                    ''|*[!A-Za-z0-9]*) warn "extensão inválida." ;;
                    *) return ;;
                esac
                ;;
            *) warn "opção inválida." ;;
        esac
    done
}

choose_mode()
{
    cat <<'MENU'
Modo de conversão:

  1) Remux / cópia integral, sem recodificação
  2) Lossless verdadeiro
  3) Qualidade máxima
  4) Qualidade alta
  5) Qualidade equilibrada
  6) Compressão forte / compacta
  7) Tamanho-alvo em MB
MENU

    while :
    do
        printf '%s' "Opção [4]: "
        IFS= read -r cm_choice || cm_choice=""
        case $cm_choice in
            1) MODE="remux"; return ;;
            2) MODE="lossless"; return ;;
            3) MODE="max"; return ;;
            ''|4) MODE="high"; return ;;
            5) MODE="balanced"; return ;;
            6) MODE="compact"; return ;;
            7) MODE="target"; return ;;
            *) warn "opção inválida." ;;
        esac
    done
}

choose_resolution()
{
    SCALE_HEIGHT="original"
    case $MODE in
        remux|lossless|target) return ;;
    esac

    cat <<'MENU'
Resolução:

  1) Manter a original
  2) 480p
  3) 720p
  4) 1080p
  5) 1440p
  6) 2160p / 4K
  7) Altura personalizada

Upscale aumenta a resolução, mas não recria detalhes perdidos no original.
MENU

    while :
    do
        printf '%s' "Opção [1]: "
        IFS= read -r cr_choice || cr_choice=""
        case $cr_choice in
            ''|1) SCALE_HEIGHT="original"; return ;;
            2) SCALE_HEIGHT="480"; return ;;
            3) SCALE_HEIGHT="720"; return ;;
            4) SCALE_HEIGHT="1080"; return ;;
            5) SCALE_HEIGHT="1440"; return ;;
            6) SCALE_HEIGHT="2160"; return ;;
            7)
                printf '%s' "Altura em pixels: "
                IFS= read -r cr_custom || cr_custom=""
                case $cr_custom in
                    ''|*[!0-9]*) warn "altura inválida." ;;
                    *)
                        if [ "$cr_custom" -ge 2 ] 2>/dev/null; then
                            SCALE_HEIGHT=$cr_custom
                            return
                        fi
                        warn "a altura precisa ser >= 2."
                        ;;
                esac
                ;;
            *) warn "opção inválida." ;;
        esac
    done
}

choose_audio()
{
    # O modo target do core mede o espaço ocupado pelo áudio original e o copia
    # bit a bit. Portanto, nele a política preserve é obrigatória.
    if [ "$MODE" = "target" ]; then
        AUDIO_POLICY="preserve"
        info "Modo tamanho-alvo: áudio será preservado por cópia bit a bit."
        return
    fi

    cat <<'MENU'
Política de áudio:

  1) PRESERVAR (recomendado)
     Cópia bit a bit sempre que possível; nunca aceita redução lossy escondida.

  2) COMPATÍVEL
     Autoriza recodificação apenas se o contêiner exigir. Todas as faixas são
     mantidas e não são aplicados normalização, compressor, limiter ou ganho.
MENU

    while :
    do
        printf '%s' "Opção [1]: "
        IFS= read -r ca_choice || ca_choice=""
        case $ca_choice in
            ''|1) AUDIO_POLICY="preserve"; return ;;
            2) AUDIO_POLICY="compatible"; return ;;
            *) warn "opção inválida." ;;
        esac
    done
}

choose_target_size()
{
    TARGET_MB=""
    [ "$MODE" = "target" ] || return

    while :
    do
        printf '%s' "Tamanho-alvo em MB (ex.: 30): "
        IFS= read -r TARGET_MB || TARGET_MB=""
        case $TARGET_MB in
            ''|*[!0-9.]*|.*|*.*.*) warn "informe um número positivo." ;;
            *)
                if awk -v n="$TARGET_MB" 'BEGIN { exit !(n > 0) }' 2>/dev/null; then
                    return
                fi
                warn "o valor precisa ser maior que zero."
                ;;
        esac
    done
}

append_candidate()
{
    ac_file=$1

    # Não recoloca arquivos que já estejam na pasta de saída quando o destino
    # foi escolhido dentro da árvore de origem.
    ac_parent=`dirname "$ac_file"`
    ac_parent=`CDPATH= cd "$ac_parent" 2>/dev/null && pwd -P`
    case $ac_parent in
        "$DESTINATION"|"$DESTINATION"/*) return ;;
    esac

    if is_video_file "$ac_file"; then
        printf '%s\n' "$ac_file" >> "$LIST_FILE"
    fi
}

build_file_list()
{
    LIST_FILE=${TMPDIR:-/tmp}/conversor_video_posix_$$.list
    LIST_ALL=${TMPDIR:-/tmp}/conversor_video_posix_$$.all
    : > "$LIST_FILE" || die "não foi possível criar a lista temporária."

    case $SELECT_MODE in
        single)
            append_candidate "$SINGLE_FILE"
            ;;
        pattern)
            # O padrão participa apenas do case. Não usamos eval; por isso
            # /pasta/*.rmvb e /pasta/*.* são aceitos sem executar texto do usuário.
            for bfl_file in "$SOURCE_ROOT"/* "$SOURCE_ROOT"/.[!.]* "$SOURCE_ROOT"/..?*
            do
                [ -f "$bfl_file" ] || continue
                bfl_base=`basename "$bfl_file"`
                case $bfl_base in
                    $FILE_PATTERN) append_candidate "$bfl_file" ;;
                esac
            done
            ;;
        directory)
            for bfl_file in "$SOURCE_ROOT"/* "$SOURCE_ROOT"/.[!.]* "$SOURCE_ROOT"/..?*
            do
                [ -f "$bfl_file" ] || continue
                append_candidate "$bfl_file"
            done
            ;;
        recursive)
            # find é POSIX. A lista suporta espaços, tabs e acentos. Nomes de
            # arquivo contendo newline literal não são suportados no modo lote.
            find "$SOURCE_ROOT" -type f -print > "$LIST_ALL" || die "falha ao percorrer a pasta."
            while IFS= read -r bfl_file
            do
                append_candidate "$bfl_file"
            done < "$LIST_ALL"
            ;;
    esac

    FILE_COUNT=`wc -l < "$LIST_FILE" | tr -d ' '`
    [ "$FILE_COUNT" -gt 0 ] || die "nenhum vídeo foi encontrado para a seleção informada."
}

effective_extension()
{
    ee_file=$1
    if [ "$OUT_EXTENSION" != "original" ]; then
        printf '%s\n' "$OUT_EXTENSION"
        return
    fi

    ee_name=`basename "$ee_file"`
    case $ee_name in
        *.*) ee_ext=`printf '%s' "${ee_name##*.}" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz'` ;;
        *) ee_ext="mkv" ;;
    esac
    [ -n "$ee_ext" ] || ee_ext="mkv"
    printf '%s\n' "$ee_ext"
}

output_directory_for()
{
    od_file=$1

    if [ "$SELECT_MODE" = "recursive" ] && [ "$PRESERVE_TREE" = "yes" ]; then
        od_parent=`dirname "$od_file"`
        case $od_parent in
            "$SOURCE_ROOT") od_rel="" ;;
            "$SOURCE_ROOT"/*) od_rel=${od_parent#"$SOURCE_ROOT"/} ;;
            *) od_rel="" ;;
        esac

        if [ -n "$od_rel" ]; then
            printf '%s/%s\n' "$DESTINATION" "$od_rel"
        else
            printf '%s\n' "$DESTINATION"
        fi
    else
        printf '%s\n' "$DESTINATION"
    fi
}

build_output_name()
{
    bo_input=$1
    bo_dir=$2
    bo_ext=$3
    bo_name=`basename "$bo_input"`

    case $bo_name in
        *.*) bo_stem=${bo_name%.*} ;;
        *) bo_stem=$bo_name ;;
    esac

    bo_candidate=$bo_dir/$bo_stem$NAME_SUFFIX.$bo_ext

    # Com mesma pasta/extensão e sem sufixo, força nome não destrutivo.
    bo_input_dir=`dirname "$bo_input"`
    if [ "$bo_input_dir" = "$bo_dir" ]; then
        bo_input_ext=`effective_extension "$bo_input"`
        if [ "$bo_ext" = "$bo_input_ext" ] && [ -z "$NAME_SUFFIX" ]; then
            bo_candidate=$bo_dir/${bo_stem}_convertido.$bo_ext
        fi
    fi

    printf '%s\n' "$bo_candidate"
}

run_one()
{
    ro_input=$1
    ro_ext=`effective_extension "$ro_input"`
    ro_dir=`output_directory_for "$ro_input"`

    [ -d "$ro_dir" ] || mkdir -p "$ro_dir" || return 1
    ro_output=`build_output_name "$ro_input" "$ro_dir" "$ro_ext"`

    set -- sh "$CORE" -m "$MODE" -r "$SCALE_HEIGHT" -a "$AUDIO_POLICY"
    if [ "$MODE" = "target" ]; then
        set -- "$@" -s "$TARGET_MB"
    fi
    set -- "$@" "$ro_input" "$ro_output"

    print_line
    info "Entrada: $ro_input"
    info "Saída solicitada: $ro_output"
    print_line
    "$@"
}

run_batch()
{
    rb_ok=0
    rb_fail=0
    rb_index=0

    while IFS= read -r rb_file
    do
        [ -n "$rb_file" ] || continue
        rb_index=$((rb_index + 1))
        info ""
        info "ARQUIVO $rb_index DE $FILE_COUNT"

        if run_one "$rb_file"; then
            rb_ok=$((rb_ok + 1))
        else
            rb_fail=$((rb_fail + 1))
            warn "falha: $rb_file"
            if [ "$ERROR_POLICY" = "stop" ]; then
                warn "lote interrompido conforme solicitado."
                break
            fi
        fi
    done < "$LIST_FILE"

    print_line
    info "RESUMO"
    print_line
    info "Selecionados: $FILE_COUNT"
    info "Concluídos: $rb_ok"
    info "Falhas: $rb_fail"
    info "Arquivos originais: preservados"
    print_line

    [ "$rb_fail" -eq 0 ]
}

interactive_wizard()
{
    check_environment

    SELECT_MODE=""
    SOURCE_ROOT=""
    SINGLE_FILE=""
    FILE_PATTERN=""
    DESTINATION=""
    OUT_EXTENSION="mkv"
    NAME_SUFFIX=""
    PRESERVE_TREE="no"
    MODE="high"
    SCALE_HEIGHT="original"
    AUDIO_POLICY="preserve"
    TARGET_MB=""
    ERROR_POLICY="continue"
    FILE_COUNT=0

    print_line
    info "$PROGRAM $VERSION - ASSISTENTE INTERATIVO"
    print_line
    info "O arquivo original nunca será sobrescrito, removido, movido ou renomeado."
    info "Dual-audio/multi-audio deve ser preservado; caso contrário o core rejeita a saída."
    print_line

    choose_source
    choose_destination
    choose_extension

    printf '%s' "Sufixo opcional para os arquivos de saída [nenhum]: "
    IFS= read -r NAME_SUFFIX || NAME_SUFFIX=""
    case $NAME_SUFFIX in
        */*) die "o sufixo não pode conter '/'." ;;
    esac

    if [ "$SELECT_MODE" = "recursive" ]; then
        if yes_no "Preservar a estrutura de subpastas no destino?" yes; then
            PRESERVE_TREE="yes"
        fi
    fi

    choose_mode
    choose_resolution
    choose_audio
    choose_target_size

    if [ "$SELECT_MODE" != "single" ]; then
        if ! yes_no "Se um arquivo falhar, continuar com os demais?" yes; then
            ERROR_POLICY="stop"
        fi
    fi

    build_file_list

    print_line
    info "CONFIGURAÇÃO FINAL"
    print_line
    info "Seleção: $SELECT_MODE"
    info "Origem: $SOURCE_ROOT"
    [ -n "$FILE_PATTERN" ] && info "Padrão: $FILE_PATTERN"
    info "Vídeos encontrados: $FILE_COUNT"
    info "Destino: $DESTINATION"
    info "Extensão de saída: $OUT_EXTENSION"
    info "Sufixo: ${NAME_SUFFIX:-nenhum}"
    info "Modo: $MODE"
    info "Resolução: $SCALE_HEIGHT"
    info "Áudio: $AUDIO_POLICY"
    [ "$MODE" = "target" ] && info "Tamanho-alvo: $TARGET_MB MB"
    [ "$SELECT_MODE" = "recursive" ] && info "Preservar subpastas: $PRESERVE_TREE"
    info "Original: sempre preservado"
    print_line

    if ! yes_no "Iniciar a conversão?" yes; then
        info "Cancelado. Nenhum arquivo foi alterado."
        exit 0
    fi

    if run_batch; then
        exit 0
    fi
    exit 2
}

# ---------------------------------------------------------------------------
# Entrada principal
# ---------------------------------------------------------------------------
# Sem argumentos, a experiência é integralmente interativa. Com argumentos,
# o wrapper mantém compatibilidade com a interface avançada do core.
case $# in
    0) interactive_wizard ;;
    *)
        case ${1-} in
            -h|--help) usage; exit 0 ;;
        esac
        [ -f "$CORE" ] || die "core não encontrado: $CORE"
        exec sh "$CORE" "$@"
        ;;
esac
