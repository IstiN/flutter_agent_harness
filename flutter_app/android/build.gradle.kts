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

// Pub-resolved plugins (the flutter_js fork pins Kotlin 1.8, flutter_gemma
// pins Java 11) trip AGP 9's "Inconsistent JVM-target compatibility"
// check. Align every plugin subproject to the app's JVM 17 (issue #289):
// the android extension's compileOptions is overridden after each plugin's
// own script ran (afterEvaluate), and the Kotlin compile tasks' jvmTarget
// is set through the task extension/getter so the root script needs no
// Kotlin Gradle Plugin on its classpath.
subprojects {
    if (name == "app") return@subprojects
    afterEvaluate {
        val androidExt = extensions.findByName("android") ?: return@afterEvaluate
        val compileOptions = androidExt.javaClass
            .getMethod("getCompileOptions")
            .invoke(androidExt)
        // The AGP-decorated CompileOptions setters take org.gradle.api.JavaVersion,
        // but the root script's JavaVersion class can come from a different
        // classloader than AGP's — match the parameter by NAME and read the
        // VERSION_17 constant through the setter's own classloader.
        for (setterName in listOf("setSourceCompatibility", "setTargetCompatibility")) {
            val setter = compileOptions.javaClass.methods
                .singleOrNull {
                    it.name == setterName &&
                        it.parameterCount == 1 &&
                        it.parameterTypes[0].name == "org.gradle.api.JavaVersion"
                }
            if (setter == null) {
                val available = compileOptions.javaClass.methods
                    .filter { it.name.startsWith("set") }
                    .joinToString(", ") { "${it.name}(${it.parameterTypes.joinToString { p -> p.simpleName }})" }
                throw GradleException(
                    "cannot align $name JVM target: no $setterName(JavaVersion) on ${compileOptions.javaClass}; available: $available",
                )
            }
            val version17 = setter.parameterTypes[0].getField("VERSION_17").get(null)
            setter.invoke(compileOptions, version17)
        }
    }
    tasks.configureEach {
        val kotlinOptions = extensions.findByName("kotlinOptions")
            ?: try {
                javaClass.getMethod("getKotlinOptions").invoke(this)
            } catch (_: ReflectiveOperationException) {
                null
            } ?: return@configureEach
        try {
            kotlinOptions.javaClass
                .getMethod("setJvmTarget", String::class.java)
                .invoke(kotlinOptions, "17")
        } catch (_: ReflectiveOperationException) {
            // Not a Kotlin compile task — nothing to align.
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
