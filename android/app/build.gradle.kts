import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 发布签名：优先 android/key.properties（本机开发），其次环境变量（CI secrets），
// 最后回落到仓库内置的 keystore。
//
// 内置 keystore 是**刻意入库**的：CI runner 上的 debug.keystore 每次重建都是新的，
// 用它签出来的 release 包签名会变，装机只能卸载重装。固定一套证书后，无论在哪
// 构建都能覆盖安装。口令是公开的（仓库可见），要真正保密就用 key.properties
// 或环境变量换成自己的证书。
val builtinKeystore = rootProject.file("keystore/aquan-release.jks")

val keystoreProperties = Properties().apply {
    val keyPropsFile = rootProject.file("key.properties")
    if (keyPropsFile.exists()) {
        keyPropsFile.inputStream().use { load(it) }
    }
}

fun signingValue(propName: String, envName: String, fallback: String): String =
    keystoreProperties.getProperty(propName) ?: System.getenv(envName) ?: fallback

val ksPath = signingValue("storeFile", "ANDROID_KEYSTORE_PATH", builtinKeystore.absolutePath)
val ksPassword = signingValue("storePassword", "ANDROID_KEYSTORE_PASSWORD", "aquan-duanju")
val ksAlias = signingValue("keyAlias", "ANDROID_KEYSTORE_ALIAS", "aquan")
val ksKeyPassword = signingValue("keyPassword", "ANDROID_KEYSTORE_KEY_PASSWORD", "aquan-duanju")
val hasReleaseSigning =
    listOf(ksPath, ksPassword, ksAlias, ksKeyPassword).all { it.isNotEmpty() }
if (hasReleaseSigning && !file(ksPath).exists()) {
    throw GradleException("找不到签名 keystore：${file(ksPath).absolutePath}")
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

    signingConfigs {
        create("release") {
            storeFile = file(ksPath)
            storePassword = ksPassword
            keyAlias = ksAlias
            keyPassword = ksKeyPassword
        }
    }

    buildTypes {
        release {
            // 始终用 release 签名：debug 签名不跨机器稳定，会导致无法覆盖安装。
            signingConfig = signingConfigs.getByName("release")
        }
    }

    packaging {
        jniLibs {
            // libffmpeg.so 是 PIE 可执行文件（不是共享库）：必须解压到
            // nativeLibraryDir 才能 exec；strip 会把它改坏，务必跳过。
            useLegacyPackaging = true
            keepDebugSymbols += "**/libffmpeg.so"
        }
    }
}

dependencies {
    // 应用内更新：FileProvider（API 24+ 不允许 file:// 跨应用暴露 APK）。
    implementation("androidx.core:core-ktx:1.13.1")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
