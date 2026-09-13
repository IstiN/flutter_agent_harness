import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
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

    // ── Release signing (issue #289) ────────────────────────────────────────
    // The upload keystore never lives in git. CI decodes it from the
    // ANDROID_KEYSTORE_BASE64 secret into the build dir; a local,
    // gitignored android/key.properties (storeFile/storePassword/keyAlias/
    // keyPassword) works too. Debug builds are untouched.
    val signingEnv = System.getenv()
    val keyProps = java.util.Properties().apply {
        val propsFile = rootProject.file("key.properties")
        if (!propsFile.exists()) {
            val appPropsFile = project.file("key.properties")
            if (appPropsFile.exists()) appPropsFile.inputStream().use { load(it) }
        } else {
            propsFile.inputStream().use { load(it) }
        }
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
