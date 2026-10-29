#!/usr/bin/env bash
# Runs the whole pipeline in order, showing which step is running, for how
# long, and its latest output. Each step's full output goes to its own log in
# logs/<run>/ (not work/, which Planetiler empties). Stops at the first failing
# step and prints the command that resumes from it.
#
# Usage: scripts/build-all.sh [--from STEP | --only STEP,STEP] [--refresh] [BASE_URL]
#   --from STEP   start at STEP, skipping the ones before it
#   --only STEPS  run just these steps, in pipeline order (e.g. trails,static)
#   --refresh     only the steps an OpenStreetMap refresh changes (download,
#                 basemap, trails, static); elevation and the world layer
#                 depend on coverage only
#   BASE_URL      passed to build-static.sh (default http://localhost:$LOCAL_PORT)
#
# Steps: download dem basemap world trails contours terrain static
set -euo pipefail
source "$(dirname "$0")/config.sh"

all_steps=(download dem basemap world trails contours terrain static)
refresh_steps=(download basemap trails static)

usage() { sed -n '/^# Usage/,/^# Steps/s/^# \{0,1\}//p' "$0" >&2; exit 1; }

from=""
only=""
steps=("${all_steps[@]}")
base_url=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --from) [[ $# -ge 2 ]] || usage; from=$2; shift 2 ;;
    --only) [[ $# -ge 2 ]] || usage; only=$2; shift 2 ;;
    --refresh) steps=("${refresh_steps[@]}"); shift ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) base_url=$1; shift ;;
  esac
done

if [[ -n $only ]]; then
  IFS=, read -ra wanted <<<"$only"
  for step in "${wanted[@]}"; do
    [[ " ${all_steps[*]} " == *" $step "* ]] || { echo "Unknown step '$step'; steps: ${all_steps[*]}" >&2; exit 1; }
  done
  steps=()
  for step in "${all_steps[@]}"; do
    [[ ",$only," == *",$step,"* ]] && steps+=("$step")
  done
fi

if [[ -n $from ]]; then
  for i in "${!steps[@]}"; do
    [[ ${steps[$i]} == "$from" ]] && { steps=("${steps[@]:$i}"); from=""; break; }
  done
  [[ -z $from ]] || { echo "Unknown step '$from'; steps: ${all_steps[*]}" >&2; exit 1; }
fi

command_for() {
  case $1 in
    download) echo "$ROOT/scripts/download.sh" ;;
    dem) echo "$ROOT/scripts/download-dem.sh" ;;
    static) echo "$ROOT/scripts/build-static.sh${base_url:+ $base_url}" ;;
    *) echo "$ROOT/scripts/build-$1.sh" ;;
  esac
}

output_of() {
  case $1 in
    download) echo "$MERGED_PBF" ;;
    dem) echo "$DEM_DIR" ;;
    terrain) echo "$BUILD_DIR/terrain.mbtiles" ;;
    static) echo "$STATIC_DIR" ;;
    *) echo "$BUILD_DIR/$1.pmtiles" ;;
  esac
}

clock() { printf '%02d:%02d:%02d' $(($1 / 3600)) $(($1 % 3600 / 60)) $(($1 % 60)); }

# Last non-empty line of a log, without colours or carriage-return redraws
last_line() {
  tail -c 4000 "$1" 2>/dev/null | tr '\r' '\n' | sed 's/\x1b\[[0-9;]*m//g' \
    | grep -v '^[[:space:]]*$' | tail -n 1 | sed 's/^[[:space:]]*//' || true
}

free_gb=$(df -BG --output=avail "$ROOT" | tail -n 1 | tr -dc 0-9)
if [[ ${steps[*]} == *contours* && $free_gb -lt 50 ]]; then
  echo "Warning: ${free_gb} GB free; a full build with contours needs up to about 50 GB." >&2
fi

run_dir="$ROOT/logs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$run_dir"
interactive=$([[ -t 1 ]] && echo 1 || echo "")
total=${#steps[@]}
started=$SECONDS
summary=()

echo "Building: ${steps[*]}"
echo "Logs: $run_dir"
echo

for i in "${!steps[@]}"; do
  step=${steps[$i]}
  n=$((i + 1))
  log="$run_dir/$(printf '%d' "$n")-$step.log"
  label=$(printf '[%d/%d] %-9s' "$n" "$total" "$step")
  step_started=$SECONDS

  # shellcheck disable=SC2046 # the command for "static" carries an optional argument
  $(command_for "$step") >"$log" 2>&1 &
  pid=$!

  if [[ -n $interactive ]]; then
    while kill -0 "$pid" 2>/dev/null; do
      width=$(( $(tput cols 2>/dev/null || echo 100) - 30 ))
      printf '\r\033[K%s %s  %s' "$label" "$(clock $((SECONDS - step_started)))" \
        "$(last_line "$log" | cut -c1-"$((width > 10 ? width : 10))")"
      sleep 2
    done
    printf '\r\033[K'
  fi

  status=0
  wait "$pid" || status=$?
  took=$(clock $((SECONDS - step_started)))

  if [[ $status -ne 0 ]]; then
    echo "$label failed after $took (exit $status). Last lines of $log:"
    tail -n 15 "$log" | tr '\r' '\n' | sed 's/\x1b\[[0-9;]*m//g' | grep -v '^[[:space:]]*$' | tail -n 10 | sed 's/^/    /'
    echo
    echo "Fix the cause, then resume with: scripts/build-all.sh --from $step${base_url:+ $base_url}"
    exit "$status"
  fi

  size=$(du -sh "$(output_of "$step")" 2>/dev/null | cut -f1)
  echo "$label done in $took  ${size:+($size)}"
  summary+=("$(printf '%-9s %s  %s' "$step" "$took" "$size")")
done

echo
echo "All steps done in $(clock $((SECONDS - started)))"
printf '  %s\n' "${summary[@]}"
echo "Build: $(du -sh --exclude=static "$BUILD_DIR" | cut -f1) in $BUILD_DIR"
