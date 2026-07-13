// sample-app — demo app that links the agent. A small app used to prove
// auto-start, snapshotting, selector resolution, and CLI-driven input end
// to end.
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
}

android {
    namespace = "dev.reticle.sample"
    compileSdk = 35

    defaultConfig {
        applicationId = "dev.reticle.sample"
        minSdk = 24
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
        }
        release {
            isMinifyEnabled = false
        }
    }

    // Two flavors, differing ONLY in whether the agent is linked:
    //   linked  — depends on :reticle-agent:android; the runtime auto-starts (the demo).
    //   noagent — NO agent dependency; a distinct applicationId. This is the test
    //             target for `reticle app inject`: it reproduces a real-world
    //             debuggable app that doesn't carry dev.reticle.agent.* classes,
    //             so the injected dex is their sole source (no class collision).
    flavorDimensions += "agent"
    productFlavors {
        create("linked") {
            dimension = "agent"
        }
        create("noagent") {
            dimension = "agent"
            applicationIdSuffix = ".noagent"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    // Demo app: lintVitalRelease emits a known false-positive Instantiatable
    // error for AppCompatActivity in this AGP/lint combo. The activity runs
    // fine on-device. Don't fail the release assemble on it.
    lint {
        abortOnError = false
        checkReleaseBuilds = false
    }

    kotlinOptions {
        jvmTarget = "1.8"
    }
}

dependencies {
    // Only the `linked` flavor depends on the agent — auto-start does the rest.
    // The `noagent` flavor deliberately omits it and supplies a stub Reticle
    // facade (sample-app/src/noagent) so MainActivity still compiles, while the
    // APK carries none of the runtime classes.
    "linkedImplementation"(project(":reticle-agent:android"))
    implementation(libs.androidx.appcompat)
}
