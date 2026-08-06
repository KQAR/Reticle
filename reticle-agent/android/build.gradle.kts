// reticle-agent — Android library (AAR). An in-process HTTP server plus
// view/accessibility/semantics capture, auto-started by a no-op ContentProvider
// so a host app only needs to add the dependency (no code changes).
plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
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

    // The agent's own unit tests run under Robolectric, against REAL framework
    // classes: a real TextView, laid out by the real android.text.Layout, is the
    // thing RegionProbe measures, and a mocked one would only test the mock. The
    // iOS half does the same by running XCTest on a simulator
    // (scripts/test-ios-agent.sh).
    // JUnit 4, not the platform: Robolectric ships a JUnit 4 runner, and the
    // whole point of these tests is the real framework classes it provides.
    testOptions {
        unitTests {
            isIncludeAndroidResources = true
        }
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
    implementation(libs.androidx.annotation)
    // Compose semantics bridge is reflective + optional; no hard Compose dep so
    // the agent links cleanly into pure-View apps too.
    compileOnly(libs.androidx.compose.ui)
    // Same treatment, same reason: the per-frame DOM read (WebFrameBridge) is
    // reflective and compileOnly, so an app that does not ship androidx.webkit links
    // the agent exactly as before and the read degrades with a marker. It also MUST
    // stay out of the payload: `app inject` pushes a dex into an arbitrary app, and a
    // support library bundled there would collide with the host's own copy.
    compileOnly(libs.androidx.webkit)

    // The exact JARs the injected dex must carry at runtime for the UNLINKED
    // (JDWP-injection) path: reticle-core + kotlin-stdlib + kotlinx-serialization.
    // These come from the SAME catalog entries reticle-core uses, so the payload
    // can't drift from what core links. Android framework classes are provided by
    // the host process; Compose stays compileOnly, so neither lands in the payload.
    testImplementation(kotlin("test"))
    testImplementation(libs.junit)
    testImplementation(libs.robolectric)
    // The Compose bridge is reflective and compileOnly in main; the tests need the
    // real classes to build a semantics node worth reflecting over.
    testImplementation(libs.androidx.compose.ui)
    // The per-frame bridge is reflective too; the tests need the real classes to have
    // something to reflect over.
    testImplementation(libs.androidx.webkit)

    "payload"(project(":reticle-core"))
    "payload"(libs.kotlin.stdlib)
    "payload"(libs.kotlinx.serialization.json)
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
