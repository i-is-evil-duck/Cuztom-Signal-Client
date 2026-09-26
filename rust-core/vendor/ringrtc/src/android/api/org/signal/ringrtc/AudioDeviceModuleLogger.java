/*
 * Copyright 2026 Signal Messenger, LLC
 * SPDX-License-Identifier: AGPL-3.0-only
 */

package org.signal.ringrtc;

import org.webrtc.audio.JavaAudioDeviceModule;

final class AudioDeviceModuleLogger
    implements JavaAudioDeviceModule.AudioRecordErrorCallback,
               JavaAudioDeviceModule.AudioRecordStateCallback,
               JavaAudioDeviceModule.AudioTrackErrorCallback,
               JavaAudioDeviceModule.AudioTrackStateCallback {

  private static final String TAG = AudioDeviceModuleLogger.class.getSimpleName();

  @Override
  public void onWebRtcAudioRecordInitError(String errorMessage) {
    Log.e(TAG, "onWebRtcAudioRecordInitError: " + errorMessage);
  }

  @Override
  public void onWebRtcAudioRecordStartError(JavaAudioDeviceModule.AudioRecordStartErrorCode errorCode, String errorMessage) {
    Log.e(TAG, "onWebRtcAudioRecordStartError: " + errorCode + ": " + errorMessage);
  }

  @Override
  public void onWebRtcAudioRecordError(String errorMessage) {
    Log.e(TAG, "onWebRtcAudioRecordError: " + errorMessage);
  }

  @Override
  public void onWebRtcAudioRecordStart() {
    Log.i(TAG, "onWebRtcAudioRecordStart: ");
  }

  @Override
  public void onWebRtcAudioRecordStop() {
    Log.i(TAG, "onWebRtcAudioRecordStop: ");
  }

  @Override
  public void onWebRtcAudioTrackInitError(String errorMessage) {
    Log.e(TAG, "onWebRtcAudioTrackInitError: " + errorMessage);
  }

  @Override
  public void onWebRtcAudioTrackStartError(JavaAudioDeviceModule.AudioTrackStartErrorCode errorCode, String errorMessage) {
    Log.e(TAG, "onWebRtcAudioTrackStartError: " + errorCode + ": " + errorMessage);
  }

  @Override
  public void onWebRtcAudioTrackError(String errorMessage) {
    Log.e(TAG, "onWebRtcAudioTrackError: " + errorMessage);
  }

  @Override
  public void onWebRtcAudioTrackStart() {
    Log.i(TAG, "onWebRtcAudioTrackStart: ");
  }

  @Override
  public void onWebRtcAudioTrackStop() {
    Log.i(TAG, "onWebRtcAudioTrackStop: ");
  }
}
