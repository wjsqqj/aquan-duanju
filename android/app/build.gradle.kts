plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 发布签名：优先 android/key.properties（本机开发），其次环境变量（CI secrets），
// 都没有时回退 debug 签名——保证任何环境都能出可安装的包。
fun releaseSigning(): com.android.build.gradle.internal.dsl.SigningConfig? {
    val props = java.util.Properties()
    val keyPropsFile = rootProject.file("key.properties")
    if (keyPropsFile.exists()) {
        keyPropsFile.inputStream().use { props.load(it) }
    }
    fun prop(name: String, env: String): String =
        props.getProperty(name) ?: System.getenv(env) ?: ""

    val path = prop("storeFile", "ANDROID_KEYSTORE_PATH")
    val password = prop("storePassword", "ANDROID_KEYSTORE_PASSWORD")
    val alias = prop("keyAlias", "ANDROID_KEYSTORE_ALIAS")
    val keyPassword = prop("keyPassword", "ANDROID_KEYSTORE_KEY_PASSWORD")
    if (path.isEmpty() || password.isEmpty() || alias.isEmpty() || keyPassword.isEmpty()) {
        return null
    }
    return signingConfigs.create("release") {
        storeFile = file(path)
        storePassword = password
        keyAlias = alias
        keyPassword = keyPassword
    }
}

android {
    namespace = "com.aquan.duanju"
    compileSdk = flutter.compileSdkVersion
    // 固定与 CI 安装的版本一致，避免 gradle 现场再下载另一份 NDK。
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.aquan.duanju"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = releaseSigning()
                ?: signingConfigs.getByName("debug")
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
