# Reticle reflects View getters/setters and Compose semantics by name at
# runtime. Keep the agent and reflected entry points so release builds that
# link the agent still expose a faithful tree.
-keep class dev.reticle.agent.** { *; }
-keep class dev.reticle.core.** { *; }
-keepclassmembers class * {
    @androidx.annotation.Keep *;
}
