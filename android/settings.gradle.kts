pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        // GitHub Actions 的共享出口 IP 常被 Maven Central 限流（HTTP 429），
        // plugins.gradle.org 又会被重定向到 repo.maven.apache.org。这里把 Google
        // 官方维护的 Maven Central 镜像排在前面，命中即不再走限流域名；镜像缺件
        // 时仍会依次回落到 mavenCentral()/gradlePluginPortal()。
        maven("https://maven-central.storage-download.googleapis.com/maven2/")
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

include(":app")
