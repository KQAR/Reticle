pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "Reticle"

// Pure-JVM shared models, shared by the helper and the in-app agent.
include(":reticle-core")
// Android library (AAR): in-process HTTP server + view/semantics capture.
// `reticle-agent/` is a GROUPING DIRECTORY ONLY — no build.gradle of its own;
// only the per-platform child is a Gradle module. Future siblings
// (reticle-agent/ios via SwiftPM, reticle-agent/harmony via hvigor) are
// intentionally NOT included here — invisible to Gradle by design.
include(":reticle-agent:android")
// Android host layer (Kotlin): adb + JDWP injector + input + loopback client.
// Ships as the no-JDK native `reticle-helper` that the Swift host drives.
include(":reticle-helper")
// Demo app that links the agent.
include(":sample-app")
