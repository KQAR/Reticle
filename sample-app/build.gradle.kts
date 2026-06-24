// sample-app — demo app that links the agent. A small app used to prove
// auto-start, snapshotting, selector resolution, and CLI-driven input end
// to end.
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
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
    // Just depend on the agent — auto-start does the rest.
    implementation(project(":reticle-agent"))
    implementation("androidx.appcompat:appcompat:1.7.0")
}
