/*
 * Copyright 2026 Signal Messenger, LLC
 * SPDX-License-Identifier: AGPL-3.0-only
 */

package org.signal.ringrtc;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.util.Objects;

/**
* SVC configuration describes the SVC parameters to use when creating and handling
* SVC-enabled group/adhoc calls.
*/
public class SvcConfig {
  public final @NonNull  String  mode;
  public final @NonNull  String  modeForScreenshare;
  public final @Nullable Integer maxBitrateBps;

  public SvcConfig(@NonNull String   mode,
                   @NonNull String   modeForScreenshare,
                   @Nullable Integer maxBitrateBps) {
      this.mode = mode;
      this.modeForScreenshare = modeForScreenshare;
      this.maxBitrateBps = maxBitrateBps;
  }

  @Override
  public String toString() {
    return "SvcConfig{" +
           "mode=" + mode +
           ", modeForScreenshare=" + modeForScreenshare +
           ", maxBitrateBps=" + maxBitrateBps +
           "}";
  }

  @Override
  public boolean equals(Object o) {
    if (this == o) return true;
    if (o == null || getClass() != o.getClass()) return false;
    SvcConfig that = (SvcConfig) o;
    return Objects.equals(mode, that.mode) &&
           Objects.equals(modeForScreenshare, that.modeForScreenshare) &&
           Objects.equals(maxBitrateBps, that.maxBitrateBps);
  }

  @Override
  public int hashCode() {
    return Objects.hash(mode, modeForScreenshare, maxBitrateBps);
  }
}
