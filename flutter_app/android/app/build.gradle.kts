import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
    // firebase_crashlytics injects its build ID; without the plugin the
    // native FirebaseInitProvider hard-crashes at startup (issue #289
    // emulator DoD).
    id("com.google.firebase.crashlytics")
}

android {
    // dev.fa1.app matches the iOS bundle id (owner ruling 2026-09-13, issue
    // #289): the applicationId is IMMUTABLE after the first Play Console
    // upload, so it was aligned BEFORE any upload exists.
    namespace = "dev.fa1.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.fa1.app"
        // You can update the following values to match your application needs.
        // For more information, see https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // ── Flavor tiers (issue #622) ───────────────────────────────────────────
    // `store` is the Play-safe build (no accessibility/projection/shell
    // surface); `god` is sideload-only and carries the automation stack.
    // Release signing comes from the shared `release` build type below, so
    // both flavors sign with the same upload config — no per-flavor setup.
    flavorDimensions += "tier"
    productFlavors {
        create("store") {
            dimension = "tier"
            applicationId = "dev.fa1.app"
        }
        create("god") {
            dimension = "tier"
            applicationId = "dev.fa1.app.god"
        }
    }

    // BuildConfig.FLAVOR drives the mobile-channel provider selection in
    // MainActivity; AGP 8+ no longer generates BuildConfig by default.
    buildFeatures {
        buildConfig = true
    }

    // ── Release signing (issue #289) ────────────────────────────────────────
    // The upload keystore never lives in git. CI decodes it from the
    // ANDROID_KEYSTORE_BASE64 secret into the build dir; a local,
    // gitignored android/key.properties (storeFile/storePassword/keyAlias/
    // keyPassword) works too. Debug builds are untouched.
    val signingEnv = System.getenv()
    val keyProps = Properties()
    val rootPropsFile = rootProject.file("key.properties")
    val appPropsFile = project.file("key.properties")
    val propsFile = if (rootPropsFile.exists()) rootPropsFile else appPropsFile
    if (propsFile.exists()) {
        propsFile.inputStream().use { keyProps.load(it) }
    }
    val keystoreFromEnv: File? =
        signingEnv["ANDROID_KEYSTORE_BASE64"]?.takeIf { it.isNotBlank() }?.let { encoded ->
            val decoded = File(project.layout.buildDirectory.get().asFile, "upload-keystore.jks")
            decoded.parentFile.mkdirs()
            decoded.writeBytes(Base64.getDecoder().decode(encoded))
            decoded
        }
    val uploadStoreFile: File? =
        keyProps.getProperty("storeFile")?.let { project.file(it) } ?: keystoreFromEnv
    val uploadStorePassword: String? =
        keyProps.getProperty("storePassword") ?: signingEnv["ANDROID_KEYSTORE_PASSWORD"]
    val uploadKeyAlias: String? =
        keyProps.getProperty("keyAlias") ?: signingEnv["ANDROID_KEY_ALIAS"]
    val uploadKeyPassword: String? =
        keyProps.getProperty("keyPassword") ?: signingEnv["ANDROID_KEY_PASSWORD"]
    val strictReleaseSigning =
        signingEnv["ANDROID_STRICT_RELEASE_SIGNING"] in setOf("1", "true")

    signingConfigs {
        val hasAny = uploadStoreFile != null || uploadStorePassword != null ||
            uploadKeyAlias != null || uploadKeyPassword != null
        if (hasAny) {
            if (uploadStoreFile == null || uploadStorePassword == null ||
                uploadKeyAlias == null || uploadKeyPassword == null) {
                throw GradleException(
                    "Incomplete Android release signing config: provide ALL of " +
                        "key.properties (storeFile/storePassword/keyAlias/keyPassword) or the " +
                        "ANDROID_KEYSTORE_BASE64/ANDROID_KEYSTORE_PASSWORD/ANDROID_KEY_ALIAS/" +
                        "ANDROID_KEY_PASSWORD env vars — refusing to half-sign a release build.",
                )
            }
            create("upload") {
                storeFile = uploadStoreFile
                storePassword = uploadStorePassword
                keyAlias = uploadKeyAlias
                keyPassword = uploadKeyPassword
            }
        }
    }

    buildTypes {
        release {
            val upload = signingConfigs.findByName("upload")
            when {
                upload != null -> signingConfig = upload
                strictReleaseSigning -> throw GradleException(
                    "Release build without the upload keystore while " +
                        "ANDROID_STRICT_RELEASE_SIGNING is on: set the ANDROID_KEYSTORE_BASE64/" +
                        "ANDROID_KEYSTORE_PASSWORD/ANDROID_KEY_ALIAS/ANDROID_KEY_PASSWORD " +
                        "secrets (or android/key.properties). A debug-signed AAB cannot be " +
                        "uploaded to Play — failing loudly instead of shipping one.",
                )
                else -> {
                    // Local dev / emulator installs only (issue #289 DoD):
                    // keep `flutter run --release` working without secrets.
                    println(
                        "WARNING: building the RELEASE type with DEBUG signing keys — no " +
                            "upload keystore found (ANDROID_KEYSTORE_BASE64 et al. or " +
                            "android/key.properties). Fine for local/emulator installs; " +
                            "NEVER uploadable to Play.",
                    )
                    signingConfig = signingConfigs.getByName("debug")
                }
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// ── 16 KB page-size gate for prebuilt native assets (gh-746) ─────────────
// flutter_gemma's LiteRT-LM native bundle ships Qualcomm QNN HTP Skel
// libraries whose ELF LOAD segments declare a 4 KB alignment; Google Play
// rejects uploads containing such libraries. The flutter tool stages native
// assets under build/intermediates/flutter/<variant>/native_assets/jniLibs
// during compileFlutterBuild<Variant>, and copyJniLibsflutterBuild<Variant>
// syncs them into the APK afterwards — the patch task runs in between and
// lifts every congruent LOAD segment's p_align to 16 KB (loud failure when a
// future blob needs a real relink instead). Idempotent: already-aligned
// files are left untouched, so the task is safe to run on every build.
//
// When the staging dir is absent the task logs a LOUD warning and no-ops
// instead of skipping silently (review round 1): the path is an internal
// Flutter Gradle-plugin detail, and a silent skip would let a future layout
// change ship 4 KB-aligned blobs again — resurfacing the Play rejection at
// upload time with no signal in the build log.
val patch16kScript = rootProject.layout.projectDirectory
    .file("../../scripts/patch_elf_16k_alignment.dart")
// Gradle's Exec does not resolve batch-file wrappers: on Windows the Dart
// SDK ships dart.bat, so a bare "dart" fails with "cannot run program".
val dartExe = System.getenv("DART")
    ?: if (System.getProperty("os.name").orEmpty()
            .startsWith("Windows", ignoreCase = true)) "dart.bat" else "dart"
tasks.matching { it.name.startsWith("compileFlutterBuild") }.all {
    val variant = name.removePrefix("compileFlutterBuild")
    val variantDir = variant.replaceFirstChar { it.lowercase() }
    val nativeAssetsDir = layout.buildDirectory
        .dir("intermediates/flutter/$variantDir/native_assets/jniLibs")
    val patchTask = tasks.register("patch16kNativeLibs$variant", Exec::class.java) {
        group = "build"
        description = "Patches prebuilt native .so assets for 16 KB page sizes (gh-746)"
        dependsOn(this@all)
        executable = dartExe
        args(
            patch16kScript.asFile.absolutePath,
            nativeAssetsDir.get().asFile.absolutePath,
        )
        // The patch is in place, so the task's inputs are also its outputs;
        // declaring the inputs (plus a permissive up-to-date spec) lets
        // Gradle skip the JIT run when the staged libs did not change.
        inputs.dir(nativeAssetsDir)
            .withPropertyName("nativeAssets")
            .optional()
        outputs.upToDateWhen { true }
        doFirst {
            if (!patch16kScript.asFile.exists()) {
                throw GradleException(
                    "16 KB patch script not found: ${patch16kScript.asFile} " +
                        "(run the build from the repo checkout, not an android-only export)",
                )
            }
            if (!nativeAssetsDir.get().asFile.isDirectory) {
                logger.warn(
                    "[gh-746] $name: no native assets staged at " +
                        "${nativeAssetsDir.get().asFile} — nothing to patch. " +
                        "Expected when this variant ships no native assets; " +
                        "but if it should (QNN Skel etc.), the Flutter " +
                        "staging layout changed and the 16 KB gate is no " +
                        "longer patching those blobs (Play would reject " +
                        "the upload).",
                )
                // Skip without failing the build: swap in a portable no-op
                // (the resolved Dart executable, --version) for the patch
                // command line.
                commandLine = listOf(dartExe, "--version")
            }
        }
    }
    tasks.matching { it.name == "copyJniLibsflutterBuild$variant" }.all {
        dependsOn(patchTask)
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    // Shizuku shell bridge — flavor-scoped so the store APK never links it.
    "godImplementation"("dev.rikka.shizuku:api:13.1.5")
}
