#!/usr/bin/env bash
# spinwheel.sh — Terminal Gameshow Spin Wheel
# Usage: ./spinwheel.sh prizes.csv
#
# CSV format (no header required, or header will be auto-detected):
#   label,probability
#   Grand Prize,0.05
#   $100,0.15
#   Try Again,0.40
#   ...
# Probabilities are normalized so they don't need to sum to 1.

set -euo pipefail

# ─── Config ────────────────────────────────────────────────────────────────────
SPLIT_THRESHOLD=0.08      # Probabilities below this get ONE small slice (no splitting)
MAX_TOTAL_SLICES=100       # Hard cap on total slices across all entries
MIN_SLICES_PER_ENTRY=1    # Low-prob entries get exactly this many slices
BASE_SLICES=8             # Each entry starts with this many slices
SPIN_FRAMES=80            # Total animation frames
SPIN_DELAY_START=0.03     # Seconds per frame at start (fast)
SPIN_DELAY_END=0.1       # Seconds per frame at end   (slow)

# ─── Terminal colors & styles ──────────────────────────────────────────────────
ESC=$'\033'
BOLD="${ESC}[1m"
DIM="${ESC}[2m"
RESET="${ESC}[0m"
HIDE_CURSOR="${ESC}[?25l"
SHOW_CURSOR="${ESC}[?25h"
CLEAR_LINE="${ESC}[2K\r"

# Wheel segment colors (cycling)
COLORS=(
  "${ESC}[38;5;196m"  # red
  "${ESC}[38;5;214m"  # orange
  "${ESC}[38;5;226m"  # yellow
  "${ESC}[38;5;46m"   # green
  "${ESC}[38;5;51m"   # cyan
  "${ESC}[38;5;21m"   # blue
  "${ESC}[38;5;201m"  # magenta
  "${ESC}[38;5;229m"  # light yellow
  "${ESC}[38;5;119m"  # lime
  "${ESC}[38;5;105m"  # purple
)
NC=${#COLORS[@]}

# ─── Argument check ────────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <prizes.csv>"
  echo ""
  echo "CSV columns: label,probability"
  echo "Example:"
  echo "  Grand Prize,0.05"
  echo "  \$100,0.20"
  echo "  Try Again,0.50"
  exit 1
fi

CSV_FILE="$1"
if [[ ! -f "$CSV_FILE" ]]; then
  echo "Error: file not found: $CSV_FILE" >&2
  exit 1
fi

# ─── Parse CSV ─────────────────────────────────────────────────────────────────
declare -a LABELS
declare -a PROBS

while IFS=',' read -r label prob; do
  label="${label//\"/}"    # strip quotes
  label="${label//$'\r'/}" # strip Windows \r
  prob="${prob//\"/}"
  prob="${prob//$'\r'/}"   # strip Windows \r
  prob="${prob// /}"       # strip spaces
  label="${label## }"; label="${label%% }"

  # Skip blank lines or header-looking lines
  [[ -z "$label" ]] && continue
  [[ "$prob" =~ ^[Pp]rob ]] && continue
  [[ "$label" =~ ^[Ll]abel ]] && continue
  # Skip if prob is not a number
  if ! [[ "$prob" =~ ^[0-9]*\.?[0-9]+$ ]]; then
    continue
  fi

  LABELS+=("$label")
  PROBS+=("$prob")
# Use printf to guarantee a trailing newline (fixes files saved without one)
done < <(printf '%s\n' "$(cat "$CSV_FILE")")

N=${#LABELS[@]}
if [[ $N -eq 0 ]]; then
  echo "Error: no valid entries found in CSV." >&2
  exit 1
fi

# ─── Normalize probabilities with awk ─────────────────────────────────────────
# Build a string of probs for awk
PROB_STR="${PROBS[*]}"

read -r NORM_PROBS_STR < <(awk -v probs="$PROB_STR" -v n="$N" 'BEGIN {
  split(probs, p, " ")
  total = 0
  for (i = 1; i <= n; i++) total += p[i]
  if (total == 0) { print "ERROR"; exit 1 }
  out = ""
  for (i = 1; i <= n; i++) {
    out = out (i > 1 ? " " : "") (p[i] / total)
  }
  print out
}')

if [[ "$NORM_PROBS_STR" == "ERROR" ]]; then
  echo "Error: probabilities sum to zero." >&2; exit 1
fi

read -ra NORM_PROBS <<< "$NORM_PROBS_STR"

# ─── Compute slice counts ──────────────────────────────────────────────────────
# Strategy:
#   1. Low-prob entries (< threshold) → MIN_SLICES_PER_ENTRY
#   2. Others → BASE_SLICES * normalized_prob / max_prob  (at least MIN_SLICES_PER_ENTRY+1)
#   3. Scale everything so total <= MAX_TOTAL_SLICES
#   4. Ensure every entry has >= 1 slice

declare -a RAW_SLICES
MAX_PROB=0
for p in "${NORM_PROBS[@]}"; do
  is_bigger=$(awk -v a="$p" -v b="$MAX_PROB" 'BEGIN{print (a>b)?1:0}')
  [[ $is_bigger -eq 1 ]] && MAX_PROB="$p"
done

for i in "${!NORM_PROBS[@]}"; do
  p="${NORM_PROBS[$i]}"
  is_low=$(awk -v p="$p" -v t="$SPLIT_THRESHOLD" 'BEGIN{print (p<t)?1:0}')
  if [[ $is_low -eq 1 ]]; then
    RAW_SLICES[$i]=$MIN_SLICES_PER_ENTRY
  else
    computed=$(awk -v p="$p" -v mp="$MAX_PROB" -v bs="$BASE_SLICES" -v min="$MIN_SLICES_PER_ENTRY" 'BEGIN{
      v = int(bs * p / mp + 0.5)
      if (v < min+1) v = min+1
      print v
    }')
    RAW_SLICES[$i]=$computed
  fi
done

# Sum raw slices
TOTAL_RAW=0
for s in "${RAW_SLICES[@]}"; do TOTAL_RAW=$((TOTAL_RAW + s)); done

# Scale down if over MAX_TOTAL_SLICES
declare -a SLICE_COUNTS
if [[ $TOTAL_RAW -gt $MAX_TOTAL_SLICES ]]; then
  SCALE=$(awk -v t="$TOTAL_RAW" -v m="$MAX_TOTAL_SLICES" 'BEGIN{printf "%.6f", m/t}')
  for i in "${!RAW_SLICES[@]}"; do
    scaled=$(awk -v r="${RAW_SLICES[$i]}" -v s="$SCALE" -v min="$MIN_SLICES_PER_ENTRY" 'BEGIN{
      v = int(r * s + 0.5)
      if (v < min) v = min
      print v
    }')
    SLICE_COUNTS[$i]=$scaled
  done
else
  SLICE_COUNTS=("${RAW_SLICES[@]}")
fi

# Build the wheel: expand each label into its slice count
declare -a WHEEL
for i in "${!LABELS[@]}"; do
  cnt=${SLICE_COUNTS[$i]}
  for ((j=0; j<cnt; j++)); do
    WHEEL+=("${LABELS[$i]}")
  done
done

WHEEL_SIZE=${#WHEEL[@]}

# ─── Weighted random spin result (based on original probabilities) ──────────────
# Pick winner according to actual normalized probs
WINNER=$(awk -v probs="$NORM_PROBS_STR" -v labels="$(printf '%s\n' "${LABELS[@]}" | tr '\n' '|')" -v n="$N" -v seed="$RANDOM$RANDOM" 'BEGIN{
  srand(seed)
  split(probs, p, " ")
  split(labels, l, "|")
  r = rand()
  cum = 0
  for (i = 1; i <= n; i++) {
    cum += p[i]
    if (r <= cum) { print l[i]; exit }
  }
  print l[n]
}')

# Find winner's position in WHEEL (pick a random slot matching the winner)
declare -a WINNER_SLOTS
for i in "${!WHEEL[@]}"; do
  [[ "${WHEEL[$i]}" == "$WINNER" ]] && WINNER_SLOTS+=($i)
done
SLOT_COUNT=${#WINNER_SLOTS[@]}
RAND_IDX=$((RANDOM % SLOT_COUNT))
FINAL_POS=${WINNER_SLOTS[$RAND_IDX]}

# ─── Drawing helpers ───────────────────────────────────────────────────────────
TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
WHEEL_WIDTH=52   # inner display width

center_text() {
  local text="$1"
  local width="${2:-$TERM_WIDTH}"
  local textlen=${#text}
  local pad=$(( (width - textlen) / 2 ))
  printf "%${pad}s%s%${pad}s" "" "$text" ""
}

draw_wheel() {
  local pos=$1           # current top slot index
  local highlight=$2     # 1 = highlight top slot (pointer)

  # Show 7 slots in a vertical strip with the pointer at slot index 3 (middle)
  local visible=7
  local half=$((visible / 2))

  echo ""
  printf "%s\n" "$(center_text "┌$(printf '─%.0s' $(seq 1 $WHEEL_WIDTH))┐")"

  for ((v=0; v<visible; v++)); do
    local slot_idx=$(( (pos - half + v + WHEEL_SIZE * 100) % WHEEL_SIZE ))
    local label="${WHEEL[$slot_idx]}"
    local col_idx=$((slot_idx % NC))
    local color="${COLORS[$col_idx]}"

    # Truncate label if too long
    local max_label=$(( WHEEL_WIDTH - 6 ))
    if [[ ${#label} -gt $max_label ]]; then
      label="${label:0:$((max_label-1))}…"
    fi

    # Pad label to fill width
    local pad_total=$(( WHEEL_WIDTH - 2 - ${#label} ))
    local lpad=$(( pad_total / 2 ))
    local rpad=$(( pad_total - lpad ))
    local lpad_str=$(printf "%${lpad}s" "")
    local rpad_str=$(printf "%${rpad}s" "")

    if [[ $v -eq $half && $highlight -eq 1 ]]; then
      # Pointer row
      printf "%s\n" "$(center_text "├${BOLD}${color}▶ ${lpad_str}${label}${rpad_str} ◀${RESET}┤")"
    else
      printf "%s\n" "$(center_text "│ ${color}${lpad_str}${label}${rpad_str}${RESET} │")"
    fi
  done

  printf "%s\n" "$(center_text "└$(printf '─%.0s' $(seq 1 $WHEEL_WIDTH))┘")"
}

draw_header() {
  echo ""
  printf "%s\n" "$(center_text "${BOLD}★  SPIN  THE  WHEEL  ★${RESET}")"
  printf "%s\n" "$(center_text "${DIM}$(printf '·%.0s' $(seq 1 40))${RESET}")"
  echo ""
}

draw_legend() {
  echo ""
  printf "%s\n" "$(center_text "${DIM}Entries: $N  │  Wheel slices: $WHEEL_SIZE${RESET}")"
}

# ─── Spin animation ────────────────────────────────────────────────────────────
printf "%s" "$HIDE_CURSOR"
trap "printf '%s' '$SHOW_CURSOR'; echo ''" EXIT INT TERM

clear
draw_header
printf "%s\n" "$(center_text "  Press ENTER to spin!  ")"
draw_legend
read -r

# Calculate spin: we want to land on FINAL_POS
# Start somewhere random and spin SPIN_FRAMES frames landing at FINAL_POS
START_POS=$((RANDOM % WHEEL_SIZE))

# Build eased trajectory: start fast, end slow, land on FINAL_POS
# Total distance = full revolutions + offset to land
FULL_REVS=5
TOTAL_SLOTS=$(( FULL_REVS * WHEEL_SIZE + (FINAL_POS - START_POS + WHEEL_SIZE) % WHEEL_SIZE ))

declare -a POSITIONS
for ((f=0; f<=SPIN_FRAMES; f++)); do
  # Ease-out cubic
  t=$(awk -v f="$f" -v total="$SPIN_FRAMES" 'BEGIN{ printf "%.6f", f/total }')
  eased=$(awk -v t="$t" 'BEGIN{ v = 1-(1-t)^3; printf "%.6f", v }')
  slot=$(awk -v eased="$eased" -v total="$TOTAL_SLOTS" -v start="$START_POS" -v ws="$WHEEL_SIZE" 'BEGIN{
    pos = int(start + eased * total) % ws
    print pos
  }')
  POSITIONS+=($slot)
done

# Frame delays: ease from fast to slow
declare -a DELAYS
for ((f=0; f<=SPIN_FRAMES; f++)); do
  delay=$(awk -v f="$f" -v total="$SPIN_FRAMES" -v ds="$SPIN_DELAY_START" -v de="$SPIN_DELAY_END" 'BEGIN{
    t = f/total
    d = ds + (de - ds) * t * t
    printf "%.4f", d
  }')
  DELAYS+=("$delay")
done

LINES_DRAWN=$(( 7 + 6 + 4 ))  # approx lines to clear each frame

for ((f=0; f<=SPIN_FRAMES; f++)); do
  # Move cursor up to redraw
  if [[ $f -gt 0 ]]; then
    printf "${ESC}[${LINES_DRAWN}A"
  fi

  clear
  draw_header

  if [[ $f -eq $SPIN_FRAMES ]]; then
    printf "%s\n" "$(center_text "${BOLD}🎯  SPINNING...  🎯${RESET}")"
  else
    speed=$(awk -v f="$f" -v total="$SPIN_FRAMES" 'BEGIN{
      pct = int((1 - f/total) * 100)
      if (pct > 70) print "WHIRRING..."
      else if (pct > 40) print "SLOWING DOWN..."
      else if (pct > 15) print "ALMOST THERE..."
      else print "STOPPING..."
    }')
    printf "%s\n" "$(center_text "${DIM}${speed}${RESET}")"
  fi

  cur_pos=${POSITIONS[$f]}
  is_last=0
  [[ $f -eq $SPIN_FRAMES ]] && is_last=1
  draw_wheel "$cur_pos" "$is_last"
  draw_legend

  sleep "${DELAYS[$f]}"
done

# ─── Reveal result ─────────────────────────────────────────────────────────────
echo ""
echo ""
printf "%s\n" "$(center_text "$(printf '═%.0s' $(seq 1 50))")"
printf "%s\n" "$(center_text "${BOLD}🎉  YOU LANDED ON:  🎉${RESET}")"
echo ""

# Find winner color
WINNER_COL=0
for i in "${!LABELS[@]}"; do
  [[ "${LABELS[$i]}" == "$WINNER" ]] && WINNER_COL=$((FINAL_POS % NC)) && break
done
WCOL="${COLORS[$WINNER_COL]}"

printf "%s\n" "$(center_text "${BOLD}${WCOL}★  ${WINNER}  ★${RESET}")"
echo ""
printf "%s\n" "$(center_text "$(printf '═%.0s' $(seq 1 50))")"
echo ""

printf "%s" "$SHOW_CURSOR"
trap - EXIT
