// reticle-cli — JVM host CLI plus the host-side action backend. It talks to
// the in-app server over `adb forward` and drives real input through
// `adb shell input` / `sendevent`.
plugins {
    id("org.jetbrains.kotlin.jvm")
    application
}

dependencies {
    implementation(project(":reticle-core"))
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")

    testImplementation(kotlin("test"))
}

application {
    applicationName = "reticle"
    mainClass.set("dev.reticle.cli.MainKt")
}

tasks.test {
    useJUnitPlatform()
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    jvmToolchain(17)
}
