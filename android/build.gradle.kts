allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// fvp downloads its mdk SDK from a moving nightly with no checksum unless told
// otherwise. Pin the tagged release by sha256, the version third_party/mdk/mdk_pin.cmake
// pins on desktop; fvp checks the digest before extracting.
subprojects {
    if (name == "fvp") {
        val pinMdk = {
            extensions.findByType(com.android.build.gradle.LibraryExtension::class.java)
                ?.defaultConfig?.externalNativeBuild?.cmake?.arguments?.addAll(
                    listOf(
                        "-DFVP_DEPS_URL=https://github.com/wang-bin/mdk-sdk/releases/download/v0.39.0",
                        "-DFVP_DEPS_SHA256=cd196c9f6fb1872c4f35184848522ca3ab9c91196da47ca9761d8fb50e3e9cf3",
                    ),
                )
        }
        if (state.executed) pinMdk() else afterEvaluate { pinMdk() }
    }
}

// A tree whose Kotlin was compiled incrementally may hold an empty plugin jar that Gradle
// still calls up to date (gradle.properties, kotlin.incremental). Changing this input makes
// every Kotlin task rebuild once in full; bump it if that ever has to happen again.
subprojects {
    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
        inputs.property("hollowKotlinFullBuild", 1)
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
