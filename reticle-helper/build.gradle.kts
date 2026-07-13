// reticle-helper — the Android host layer (Kotlin): adb + JDWP injector + input
// + loopback client. It is NOT a user-facing CLI; it ships as the no-JDK native
// `reticle-helper` whose `helper` subcommand is the RPC server the Swift host
// (reticle-host) drives. See reticle-protocol/helper-rpc.md.
plugins {
    alias(libs.plugins.kotlin.jvm)
    application
}

dependencies {
    implementation(project(":reticle-core"))
    implementation(libs.kotlinx.serialization.json)

    testImplementation(kotlin("test"))
}

application {
    applicationName = "reticle-helper"
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

/**
 * Compile into a no-JDK native single-file executable via GraalVM `native-image`.
 * This is the **helper** the Swift host spawns (its `helper` subcommand is the
 * long-lived RPC server); shipping it native means users need no JDK. macOS arm64
 * only — the project's only target.
 *
 * Requires a GraalVM with native-image. Point to it with $GRAALVM_HOME (or have
 * `native-image` on PATH). Output: build/native/reticle-helper.
 *
 * kotlinx-serialization 2.0 uses compile-time serializers, so this needs no
 * hand-written reflection config (verified: ping/listDevices/render all work).
 */
val nativeHelper by tasks.registering(Exec::class) {
    group = "reticle"
    description = "Compile into the no-JDK native reticle-helper (the Swift host's backend)."
    dependsOn("installDist")

    val installLib = layout.buildDirectory.dir("install/reticle-helper/lib")
    val outBin = layout.buildDirectory.file("native/reticle-helper")
    inputs.dir(installLib)
    outputs.file(outBin)

    doFirst {
        val graalHome = System.getenv("GRAALVM_HOME")
        val niName = "native-image"
        val ni = if (graalHome != null) File("$graalHome/bin/$niName").absolutePath else niName
        val libDir = installLib.get().asFile
        val cp = libDir.listFiles { f -> f.extension == "jar" }!!.joinToString(":") { it.absolutePath }
        outBin.get().asFile.parentFile.mkdirs()
        commandLine(
            ni,
            "-cp", cp,
            "dev.reticle.cli.MainKt",
            "-o", outBin.get().asFile.absolutePath,
            "--no-fallback",
            // RuntimeClient talks to the in-app loopback server over HTTP via
            // java.net.URL; native-image disables URL protocols by default, so
            // HTTP must be explicitly enabled or every device call fails with
            // "URL protocol http ... not enabled".
            "--enable-url-protocols=http",
            // Kotlin's stdlib is immutable and safe to initialize at build time.
            // Without this, GraalVM 21 aborts: "kotlin.DeprecationLevel was
            // unintentionally initialized at build time" (GraalVM 25 tolerates it
            // silently — pin the behavior so the build is toolchain-independent).
            "--initialize-at-build-time=kotlin",
            "-H:+ReportExceptionStackTraces",
        )
    }
}
