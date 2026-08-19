import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing, if a key has been set up on this machine.
//
// android/key.properties is gitignored and holds the passwords, so the repo
// stays publishable. When it is absent the release build falls back to the
// debug key so `flutter build apk --release` still works for anyone who clones
// this - but note that a debug-signed APK can never update a properly signed
// install, because Android refuses an update whose signature differs.
//
// To create one:
//   keytool -genkey -v -keystore ~/glickr-release.jks -keyalg RSA \
//     -keysize 2048 -validity 10000 -alias glickr
//   printf 'storePassword=...\nkeyPassword=...\nkeyAlias=glickr\nstoreFile=/Users/you/glickr-release.jks\n' \
//     > android/key.properties
//
// Keep the .jks and its passwords backed up somewhere safe: lose them and you
// can never ship an update that existing installs will accept.
val keyPropertiesFile = rootProject.file("key.properties")
val keyProperties = Properties().apply {
    if (keyPropertiesFile.exists()) {
        keyPropertiesFile.inputStream().use { load(it) }
    }
}
val hasReleaseKey = keyProperties.getProperty("storeFile") != null

android {
    namespace = "com.glickr.glickr"

    // Pinned rather than taken from flutter.compileSdkVersion (35): both
    // photo_manager and flutter_secure_storage compile against SDK 36 and
    // warn loudly below it.
    compileSdk = 36

    // Highest NDK required across the plugin set. Every one of
    // connectivity_plus, flutter_image_compress, flutter_secure_storage,
    // package_info_plus, path_provider, photo_manager, share_plus, sqflite,
    // url_launcher, video_compress, video_player and wakelock_plus asks for
    // this exact version; leaving it unpinned is a runtime-surprise generator.
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.glickr.glickr"

        // 28 (Android 9), not the Flutter default of 21. BitmapFactory only
        // learned to decode HEIC/HEIF at API 28, and a photo app that cannot
        // open the format modern phones shoot in is not worth the handful of
        // pre-2018 devices it would reach. flutter_secure_storage needs 23
        // regardless, so 21 was never actually available.
        minSdk = 28
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}
