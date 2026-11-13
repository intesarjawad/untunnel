#!/bin/sh
# Times the same tiers with reuse-rs and fills the reuse-rs section of docs/bench.md.
#
# Set REUSE_RS_REPO to the checkout's Git URL and, if the pinned release is not the one you
# measured, REUSE_RS_PIN to the commit you want. Default features keep Accelerate on macOS;
# do not add --features metal, whose README reports worse tail latency.

set -eu

print_root() {
    directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
    while [ "$directory" != "/" ]; do
        if [ -f "$directory/Package.swift" ]; then
            printf '%s\n' "$directory"
            return 0
        fi
        directory=$(dirname -- "$directory")
    done
    printf 'no Package.swift above %s\n' "$0" >&2
    return 1
}

usage() {
    cat >&2 <<'EOF'
Usage: bench_reuse_rs.sh [--frames N] [--load N] [--tiers "RATE:EXIT:LOOKAHEAD ..."]

Set REUSE_RS_REPO to the reuse-rs Git URL. REUSE_RS_PIN defaults to v0.4.0.
REUSE_RS_BENCH_ARGS is a format string for the bench example; it may use
{rate}, {exit}, {lookahead}, {frames}, {load} and {input}.
EOF
}

FRAMES=3000
LOAD=0
TIERS=${TIERS:-"16000:4:0 24000:5:1 32000:6:1 48000:7:1"}
REUSE_RS_PIN=${REUSE_RS_PIN:-v0.4.0}
REUSE_RS_REPO=${REUSE_RS_REPO:-}
if [ -z "${REUSE_RS_BENCH_ARGS:-}" ]; then
    REUSE_RS_BENCH_ARGS='--sample-rate {rate} --exit-layer {exit} --lookahead {lookahead} --frames {frames}'
fi
BENCH_INPUT=${BENCH_INPUT:-}

while [ $# -gt 0 ]; do
    case "$1" in
        --print-root)
            print_root
            exit 0
            ;;
        --frames)
            [ $# -ge 2 ] || { usage; exit 2; }
            FRAMES=$2
            shift 2
            ;;
        --load)
            [ $# -ge 2 ] || { usage; exit 2; }
            LOAD=$2
            shift 2
            ;;
        --tiers)
            [ $# -ge 2 ] || { usage; exit 2; }
            TIERS=$2
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

if [ -z "$REUSE_RS_REPO" ]; then
    printf 'REUSE_RS_REPO is not set; point it at the reuse-rs Git checkout\n' >&2
    exit 2
fi

ROOT=$(print_root)
BENCH_MD="$ROOT/docs/bench.md"
if [ ! -f "$BENCH_MD" ]; then
    printf '%s is missing; run "untunnel bench" first\n' "$BENCH_MD" >&2
    exit 2
fi

CACHE=${REUSE_RS_CACHE:-"$ROOT/.cache/reuse-rs"}
mkdir -p "$(dirname -- "$CACHE")"
if [ ! -d "$CACHE/.git" ]; then
    git clone "$REUSE_RS_REPO" "$CACHE"
fi
git -C "$CACHE" fetch --tags origin
git -C "$CACHE" checkout --detach "$REUSE_RS_PIN"
COMMIT=$(git -C "$CACHE" rev-parse HEAD)
cargo build --release --manifest-path "$CACHE/Cargo.toml" --example bench
BENCH_BIN="$CACHE/target/release/examples/bench"

power_source() {
    case "$(pmset -g batt 2>/dev/null || true)" in
        *"AC Power"*)
            printf 'AC power'
            ;;
        *"Battery Power"*)
            printf 'battery'
            ;;
        *)
            printf 'unknown'
            ;;
    esac
}

format_args() {
    rate=$1
    exit_layer=$2
    lookahead=$3
    printf '%s' "$REUSE_RS_BENCH_ARGS" |
        sed \
            -e "s/{rate}/$rate/g" \
            -e "s/{exit}/$exit_layer/g" \
            -e "s/{lookahead}/$lookahead/g" \
            -e "s/{frames}/$FRAMES/g" \
            -e "s/{load}/$LOAD/g" \
            -e "s|{input}|$BENCH_INPUT|g"
}

read_number() {
    printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1
}

MACHINE=$(sysctl -n hw.model 2>/dev/null || uname -m)
TABLE=$(mktemp -t untunnel-bench)
trap 'rm -f "$TABLE"' EXIT INT TERM
{
    printf 'reuse-rs %s at %s; run %s on %s, macOS %s, %s\n\n' \
        "$REUSE_RS_PIN" "$COMMIT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$MACHINE" "$(sw_vers -productVersion)" "$(power_source)"
    printf '| Tier | Median ms | p95 ms | p99 ms | Max ms | Result |\n'
    printf '| --- | --- | --- | --- | --- | --- |\n'
} >"$TABLE"

for tier in $TIERS; do
    rate=$(printf '%s' "$tier" | cut -d: -f1)
    exit_layer=$(printf '%s' "$tier" | cut -d: -f2)
    lookahead=$(printf '%s' "$tier" | cut -d: -f3)
    lookahead=${lookahead:-0}

    args=$(format_args "$rate" "$exit_layer" "$lookahead")
    if output=$("$BENCH_BIN" $args 2>&1); then
        median=$(read_number "$output" median_ms)
        p95=$(read_number "$output" p95_ms)
        p99=$(read_number "$output" p99_ms)
        maximum=$(read_number "$output" max_ms)
        if [ -n "$median" ] && [ -n "$p95" ] && [ -n "$p99" ] && [ -n "$maximum" ]; then
            printf '| %s | %s | %s | %s | %s | measured |\n' \
                "$tier" "$median" "$p95" "$p99" "$maximum" >>"$TABLE"
        else
            printf '| %s | - | - | - | - | output not parsed |\n' "$tier" >>"$TABLE"
        fi
    else
        printf '| %s | - | - | - | - | not supported |\n' "$tier" >>"$TABLE"
    fi
done

REPLACED=$(mktemp -t untunnel-bench-md)
trap 'rm -f "$TABLE" "$REPLACED"' EXIT INT TERM
awk -v content="$TABLE" '
    /<!-- reuse-rs:start -->/ {
        print
        while ((getline line < content) > 0) print line
        close(content)
        inside = 1
        next
    }
    /<!-- reuse-rs:end -->/ { inside = 0 }
    !inside { print }
' "$BENCH_MD" >"$REPLACED"
mv "$REPLACED" "$BENCH_MD"
printf 'Wrote the reuse-rs rows to %s\n' "$BENCH_MD"
