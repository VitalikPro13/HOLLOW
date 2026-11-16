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
                        "-DFVP_DEPS_URL=https://github.com/wang-bin/mdk-sdk/releases/download/v0.40.1",
                        "-DFVP_DEPS_SHA256=80079993f308bcd0afb5b34421e9f4034dcefb6d901d0f31e23b8508d694630f",
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
