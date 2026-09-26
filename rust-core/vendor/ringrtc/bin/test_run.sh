#!/bin/bash

#
# Copyright 2024 Signal Messenger, LLC
# SPDX-License-Identifier: AGPL-3.0-only
#

set -e

# shellcheck source=bin/env.sh
. "$(dirname "$0")"/env.sh

# Tests that take < 1 minutes.
SMALL_CORRECTNESS_TESTS="examples_unittests \
  video_capture_tests \
  webrtc_lib_link_test \
  time_delta_rs_unittests \
  timestamp_rs_unittests \
  audio_decoder_unittests \
  voip_unittests \
  neteq_pcmu_quality_test \
  neteq_pcm16b_quality_test \
  rtc_stats_unittests \
  resource_adaptation_tests \
  neteq_opus_quality_test \
  system_wrappers_unittests \
  video_adaptation_tests \
  dcsctp_unittests \
  call_tests \
  rtc_pc_unittests \
  common_audio_unittests \
  rtc_media_unittests \
  common_video_unittests \
  webrtc_nonparallel_tests \
  audio_engine_tests"

# Tests that take > 1 minutes.
MEDIUM_CORRECTNESS_TESTS="rtc_unittests \
  rtc_p2p_unittests \
  slow_peer_connection_unittests \
  webrtc_opus_fec_test \
  modules_tests \
  peerconnection_unittests \
  test_support_unittests"

# Tests that take > 5 minutes
LARGE_CORRECTNESS_TESTS="modules_unittests \
  video_tests \
  svc_tests"

PERF_TESTS="audio_codec_speed_tests \
  video_codec_perf_tests \
  webrtc_perf_tests"

usage()
{
    echo "usage: $0 [-s|--small] [-m|--medium] [-l|--large] [-a|--all] [-p|--perf] [-d|--debug] [-r|--release] -o|--output=<filename>
    where:
        --small to run \"small\" correctness tests.
        --medium to run \"medium\" correctness tests.
        --large to run \"large\" correctness tests.
        --all to run all correctness tests.
        --perf to run all performance tests. [NOTE: this can take 1+ hour]
        -d to use a debug build (default)
        -r to use a release build

        -o=<filename>, which must be specified, is the file to which output will go.

        Note that the flags are not mutually exclusive. For instance, one may
        specify --small and --all."
}

function run_test() {
  set +e
  set -o pipefail
  # This line's a bit complex, so it's worth digging into.
  # First, we run the command, redirecting *its* stderr to stdout, so we can
  # output it to the specified file.
  # Then, we need to capture the output of `time`, which is a bash builtin and
  # doesn't directly write to stdout or stderr. So, we run the `time` in a
  # subshell and redirect that *subshell's* output. Finally, we use `tee` to
  # echo the output of time to both stdout *AND* the output file, so that the
  # person running the script, if any, can get updates on progress.
  ( time $1 >> "$2" 2>&1 ) 2>&1 | tee -a "$2"
  echo " =========== $1 exit status $? ======= " | tee -a "$2"
}

function run_suite() {
  for t in $1
  do
    echo "$t" | tee -a "$3"
    run_test "${WEBRTC_SRC_DIR}"/out/"${2}"/"${t}" "$3"
    echo | tee -a "$3"
    echo | tee -a "$3"
  done
}

BUILD_TYPE=debug
while [ "$1" != "" ]; do
    case $1 in
        -s | --small )
            RUN_SMALL=yes
            ;;
        -m | --medium )
            RUN_MEDIUM=yes
            ;;
        -l | --large )
            RUN_LARGE=yes
            ;;
        -a | --all )
            RUN_SMALL=yes
            RUN_MEDIUM=yes
            RUN_LARGE=yes
            ;;
        -p | --perf )
            RUN_PERF=yes
            ;;
        -r | --release )
            BUILD_TYPE=release
            ;;
        -d | --debug )
            BUILD_TYPE=debug
            ;;
        -o=* | --output=*)
          OUT="${1#*=}"
          ;;
        -h | --help )
            usage "$0"
            exit
            ;;
        * )
            usage "$0"
            exit 1
    esac
    shift
done

if [ -z "$OUT" ]
then
  usage "$0"
  exit 1
fi

if [ -n "$RUN_SMALL" ]
then
  run_suite "${SMALL_CORRECTNESS_TESTS}" "$BUILD_TYPE" "$OUT"
fi

if [ -n "$RUN_MEDIUM" ]
then
  run_suite "${MEDIUM_CORRECTNESS_TESTS}" "$BUILD_TYPE" "$OUT"
fi

if [ -n "$RUN_LARGE" ]
then
  run_suite "${LARGE_CORRECTNESS_TESTS}" "$BUILD_TYPE" "$OUT"
fi

if [ -n "$RUN_PERF" ]
then
  run_suite "${PERF_TESTS}" "$BUILD_TYPE" "$OUT"
fi
