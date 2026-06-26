// reticle-core — pure JVM shared models. Shared by the host CLI and the
// in-app agent, so it must stay free of any Android framework dependency.
plugins {
    id("org.jetbrains.kotlin.jvm")
    id("org.jetbrains.kotlin.plugin.serialization") version "2.0.21"
}

dependencies {
    api("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")

    testImplementation(kotlin("test"))
    // Test-only: validate emitted JSON against the authoritative protocol schema.
    // Stays out of the main classpath so the Android agent (which consumes core
    // as Java 8 bytecode) never links it.
    testImplementation("com.networknt:json-schema-validator:1.5.2")
}

tasks.test {
    useJUnitPlatform()
}

// The authoritative protocol spec + golden fixtures live in reticle-protocol/
// (a sibling, language-neutral directory — not a Gradle module). Expose them to
// the contract test as test resources rather than duplicating them into core.
sourceSets {
    test {
        resources {
            srcDir(rootProject.layout.projectDirectory.dir("reticle-protocol"))
        }
    }
}

java {
    sourceCompatibility = JavaVersion.VERSION_1_8
    targetCompatibility = JavaVersion.VERSION_1_8
}

// Core is consumed by the Android agent (Java 8 bytecode), so pin Kotlin's
// JVM target to 1.8 to match compileJava and stay Android-consumable.
kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_1_8)
    }
}
