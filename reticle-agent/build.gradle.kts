// reticle-agent — Android library (AAR). An in-process HTTP server plus
// view/accessibility/semantics capture, auto-started by a no-op ContentProvider
// so a host app only needs to add the dependency (no code changes).
plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
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

dependencies {
    api(project(":reticle-core"))
    implementation("androidx.annotation:annotation:1.9.1")
    // Compose semantics bridge is reflective + optional; no hard Compose dep so
    // the agent links cleanly into pure-View apps too.
    compileOnly("androidx.compose.ui:ui:1.7.5")
}
