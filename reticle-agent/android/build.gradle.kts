// reticle-agent — Android library (AAR). An in-process HTTP server plus
// view/accessibility/semantics capture, auto-started by a no-op ContentProvider
// so a host app only needs to add the dependency (no code changes).
plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

// Nesting the module under reticle-agent/ makes the Gradle leaf project name
// `android`, which would name the AAR `android-release.aar`. Pin the artifact
// base name so it stays `reticle-agent-android` regardless of directory layout.
base {
    archivesName.set("reticle-agent-android")
}

android {
    namespace = "dev.reticle.agent"
    compileSdk = 35

    defaultConfig {
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    kotlinOptions {
        jvmTarget = "1.8"
    }
}

// A standalone configuration resolving to the runtime JARs the injectable dex
// payload bundles. Created before `dependencies {}` so the block below can add
// to it. Kept separate from the AGP runtime classpath (which mixes AARs) so
// `dexPayload` can hand plain JARs straight to d8.
val payload: Configuration by configurations.creating {
    isCanBeConsumed = false
    isCanBeResolved = true
}

dependencies {
    api(project(":reticle-core"))
    implementation("androidx.annotation:annotation:1.9.1")
    // Compose semantics bridge is reflective + optional; no hard Compose dep so
    // the agent links cleanly into pure-View apps too.
    compileOnly("androidx.compose.ui:ui:1.7.5")

    // The exact JARs the injected dex must carry at runtime for the UNLINKED
    // (JDWP-injection) path: reticle-core + kotlin-stdlib + kotlinx-serialization.
    // Android framework classes are provided by the host process; Compose stays
    // compileOnly, so neither lands in the payload.
    "payload"(project(":reticle-core"))
    "payload"("org.jetbrains.kotlin:kotlin-stdlib:2.0.21")
    "payload"("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
}

/**
 * Dex the agent + its runtime deps into a single loadable archive
 * (`reticle-agent-payload.jar`, containing classes.dex). The host CLI pushes this
 * into a debuggable app over JDWP and loads it with a DexClassLoader, then calls
 * `dev.reticle.agent.Bootstrap.start()`. minApi 24 matches the agent's minSdk.
 */
val dexPayload by tasks.registering(Exec::class) {
    group = "reticle"
    description = "Dex the agent + runtime deps into an injectable payload jar."

    // Consume the bundle task's declared output rather than a hand-written
    // intermediates path, which shifts between AGP versions.
    val bundleTask = tasks.named("bundleLibRuntimeToJarRelease")
    dependsOn(bundleTask)

    val sdkDir = android.sdkDirectory
    // Derive the build-tools and platform from the AGP config so this doesn't
    // break when only a different SDK version is installed locally / in CI.
    val buildToolsVer = android.buildToolsVersion
    val compileSdkVersion = android.compileSdk ?: error("android.compileSdk is not set")
    val minApi = android.defaultConfig.minSdk ?: 24
    val d8 = File(sdkDir, "build-tools/$buildToolsVer/d8")
    val androidJar = File(sdkDir, "platforms/android-$compileSdkVersion/android.jar")
    val classesJars = bundleTask.map { task -> task.outputs.files.filter { it.name.endsWith(".jar") } }
    val outJar = layout.buildDirectory.file("reticle-payload/reticle-agent-payload.jar")

    inputs.files(classesJars)
    inputs.files(payload)
    outputs.file(outJar)

    doFirst {
        require(d8.exists()) { "d8 not found at $d8 (build-tools $buildToolsVer). Install it via the SDK manager." }
        require(androidJar.exists()) { "android.jar not found at $androidJar (platform android-$compileSdkVersion)." }
        outJar.get().asFile.parentFile.mkdirs()
        val args = buildList {
            add(d8.absolutePath)
            add("--release")
            add("--min-api"); add(minApi.toString())
            add("--lib"); add(androidJar.absolutePath)
            add("--output"); add(outJar.get().asFile.absolutePath)
            classesJars.get().forEach { add(it.absolutePath) }
            payload.files.forEach { add(it.absolutePath) }
        }
        commandLine(args)
    }
}
