import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing. Locally this comes from android/key.properties (gitignored);
// CI supplies the same four values through the environment instead. The keystore
// itself never lives in the repo -- see README for generating and backing it up.
val keystoreProperties = Properties().apply {
    // rootProject here is android/, since that is where settings.gradle.kts lives.
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

fun signingValue(propertyKey: String, envKey: String): String? =
    keystoreProperties.getProperty(propertyKey) ?: System.getenv(envKey)

val releaseStorePath: String? = signingValue("storeFile", "ANDROID_KEYSTORE_PATH")

// Falling back to the debug key is deliberate so `flutter run --release` works on
// a machine with no signing material, but it must never happen in CI: a
// debug-signed release installs happily and then can never be upgraded by a
// properly signed build. GitHub Actions always sets CI.
if (System.getenv("CI") != null && releaseStorePath == null) {
    throw GradleException(
        "Release signing material is missing. Set ANDROID_KEYSTORE_PATH, " +
            "ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS and ANDROID_KEY_PASSWORD.",
    )
}

android {
    namespace = "com.tampagamingguild.tggmobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications (NotificationService).
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // Permanent once the app is published to Google Play -- it cannot be
        // changed afterwards without shipping a brand new listing.
        applicationId = "com.tampagamingguild.tggmobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (releaseStorePath != null) {
                // Resolved against android/app/, so this must be an absolute path.
                storeFile = file(releaseStorePath)
                storePassword = signingValue("storePassword", "ANDROID_KEYSTORE_PASSWORD")
                keyAlias = signingValue("keyAlias", "ANDROID_KEY_ALIAS")
                keyPassword = signingValue("keyPassword", "ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (releaseStorePath != null) {
                signingConfigs.getByName("release")
            } else {
                // Local convenience only; the CI guard above rules this out there.
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
