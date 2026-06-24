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

// Pure-JVM shared models, shared by the CLI and the in-app agent.
include(":reticle-core")
// Android library (AAR): in-process HTTP server + view/semantics capture.
include(":reticle-agent")
// JVM host CLI: adb forward + loopback evidence + input backend.
include(":reticle-cli")
// Demo app that links the agent.
include(":sample-app")
