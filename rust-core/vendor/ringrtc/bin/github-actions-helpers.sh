#!/bin/bash

set -eou pipefail

get_size() {
  if [ "$(uname)" = "Darwin" ]; then
    stat -f "%z" "$1"
  else  # on github windows' bash appears to use mingw, which uses GNU stat
    stat --format="%s" "$1"
  fi
}

BASE_KEY_PREFIX="base_"
MISSING_SIZE="unknown"

# cache was unavailable; fail gracefully
add_base_fallback() {
  local output_key=$1

  output="${BASE_KEY_PREFIX}${output_key}=${MISSING_SIZE}"
  echo "debug: ${output}"
  echo "$output" >> "${OUTPUT_DEST}"
}

output_desktop_size() {
  local ringrtc_node
  ringrtc_node="$(find src/node/build/ -name 'libringrtc*')"

  # e.g., turn src/node/build/darwin/libringrtc-arm64.node into darwin_libringrtc-arm64_size
  local platform
  platform="$(basename "$(dirname "${ringrtc_node}")")"  # e.g. darwin
  local file_no_ext
  file_no_ext="$(basename "${ringrtc_node%.node}")"      # e.g. libringrtc-arm64
  local output_key
  output_key="${KEY_PREFIX}${platform}_${file_no_ext}_size"

  if [ "${ADD_BASE_FALLBACKS:-n}" = "y" ]; then
    add_base_fallback "${output_key}"
  fi

  local output
  output="${output_key}=$(get_size "$ringrtc_node")"

  echo "debug: ${output}"
  echo "$output" >> "${OUTPUT_DEST}"
}

output_android_size() {
  local rffi_size
  rffi_size=$(get_size out/android-"${RINGRTC_ARCH}"/release/libringrtc_rffi.so)
  rffi_key="${KEY_PREFIX}android_${RINGRTC_ARCH}_rffi_size"
  local rffi_output
  rffi_output="${rffi_key}=${rffi_size}"

  local ringrtc_size
  ringrtc_size=$(get_size out/android-"${RINGRTC_ARCH}"/release/libringrtc.so)
  ringrtc_key="${KEY_PREFIX}android_${RINGRTC_ARCH}_ringrtc_size"
  local ringrtc_output
  ringrtc_output="${ringrtc_key}=${ringrtc_size}"

  if [ "${ADD_BASE_FALLBACKS:-n}" = "y" ]; then
    add_base_fallback "${rffi_key}"
    add_base_fallback "${ringrtc_key}"
  fi

  echo -e "debug: ${rffi_output}\n${ringrtc_output}"
  echo -e "${rffi_output}\n${ringrtc_output}" >> "${OUTPUT_DEST}"
}

output_size_wrapper() {
  if [ "${GENERATE_BASE}" = "y" ]; then
    rm -f "${BASE_PATH}"  # ignore error if it doesn't exist
    KEY_PREFIX="${BASE_KEY_PREFIX}"
    OUTPUT_DEST="${BASE_PATH}"
  else
    KEY_PREFIX=""
    OUTPUT_DEST="${GITHUB_OUTPUT}"

    if [ ! -f "${BASE_PATH}" ]; then
      ADD_BASE_FALLBACKS="y"  # Cache-miss case
    else
      cat "${BASE_PATH}" >> "${OUTPUT_DEST}"
    fi
  fi

  if [ "$1" == "output_desktop_size" ]; then
    output_desktop_size
  elif [ "$1" = "output_android_size" ]; then
    output_android_size
  else
    echo "Unknown command $1"
    exit 1
  fi
}

fmt_value() {
  if [ "$1" = "${MISSING_SIZE}" ]; then
    echo "N/A"
  else
    numfmt --format='%.1f' --to=iec -- "$1"
  fi
}

fmt_and_print_line() {
  local ty=$1
  local before=$2
  local after=$3
  local delta
  local delta_pct
  if [ "${before}" = "${MISSING_SIZE}" ]; then
    delta="${MISSING_SIZE}"
    delta_pct="N/A"
  else
    delta=$((after - before))
    delta_pct=$(python3 -c "print('{0:+.2f}%'.format(${delta} * 100 / ${before}))")
  fi
  echo -e "${ty} | $(fmt_value "${before}") | $(fmt_value "${after}") | $(fmt_value "$delta") | ${delta_pct}"
}

# Markdown-formatted header; see
# https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/organizing-information-with-tables
table_header() {
  # Note that this is the literal string <<EOF - we don't want to interpret it while running this script; rather we want
  # it to influence how github assigns to *its* ringrtc_size_delta_report variable.
  echo 'ringrtc_size_delta_report<<EOF'
  echo "Compared with ${BASE_COMMIT}:"
  echo
  echo "Type | Before | After | Delta | Delta percent"
  echo "---  | ---:    | ---:  | ---:   | ---:"
}

table_footer() {
  echo
  echo
  # Used to identify the comment to edit; keep in sync with ringrtc.yml
  echo identifying_ringrtc_size_comment_string
  echo EOF
}

print_table() {
  table_header

  fmt_and_print_line "Mac" "$BASE_MACOS_SIZE" "$MACOS_SIZE"
  fmt_and_print_line "Linux x64" "$BASE_UBUNTU_X64_SIZE"  "$UBUNTU_X64_SIZE"
  fmt_and_print_line "Linux arm" "$BASE_UBUNTU_ARM64_SIZE" "$UBUNTU_ARM64_SIZE"
  fmt_and_print_line "Windows" "$BASE_WINDOWS_SIZE" "$WINDOWS_SIZE"
  fmt_and_print_line "Android arm64 RFFI" "$BASE_ANDROID_ARM64_RFFI_SIZE" "$ANDROID_ARM64_RFFI_SIZE"
  fmt_and_print_line "Android arm64 ringrtc" "$BASE_ANDROID_ARM64_RINGRTC_SIZE" "$ANDROID_ARM64_RINGRTC_SIZE"
  local android_base_total
  if [ "${BASE_ANDROID_ARM64_RFFI_SIZE}" = "${MISSING_SIZE}" ] || [ "${BASE_ANDROID_ARM64_RINGRTC_SIZE}" = "${MISSING_SIZE}" ]; then
    android_base_total="${MISSING_SIZE}"
  else
    android_base_total=$((BASE_ANDROID_ARM64_RFFI_SIZE + BASE_ANDROID_ARM64_RINGRTC_SIZE))
  fi
  fmt_and_print_line "Android arm64 total" "${android_base_total}" "$((ANDROID_ARM64_RFFI_SIZE + ANDROID_ARM64_RINGRTC_SIZE))"

  table_footer
}

if [ "$1" = "print_table" ]; then
  print_table >> "${GITHUB_OUTPUT}"
else
  output_size_wrapper "$1"
fi

