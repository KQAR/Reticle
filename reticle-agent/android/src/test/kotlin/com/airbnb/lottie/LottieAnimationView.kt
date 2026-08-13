package com.airbnb.lottie

import android.content.Context
import android.widget.ImageView

/**
 * A stand-in for Lottie's own view, under Lottie's own package name.
 *
 * The agent must not LINK Lottie (a target app may not use it), so
 * `LottieBridge` recognises the view by fully-qualified class name and reads the
 * parsed composition reflectively. That means a test cannot supply a mock: the
 * class name is part of the contract under test. Declaring one here — in test
 * sources only, never shipped in the AAR — lets the real bridge code run end to
 * end against a stand-in model whose method and field names are Lottie's.
 *
 * What this does NOT prove is that Lottie still SPELLS things this way; only a
 * real Lottie build can say that, and `scenario.lottieOnlyDialog` in
 * `scripts/e2e-android.sh` is where that is measured. What it does prove is the
 * half the e2e cannot isolate: the composition→screen arithmetic, the
 * justification placement, and every refusal path.
 */
open class LottieAnimationView(context: Context) : ImageView(context) {
    /** Read by the bridge as `getComposition()`. */
    var composition: Any? = null
}
