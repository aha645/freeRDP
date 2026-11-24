// remote_desktop_android: Kotlin plugin + rdp_bridge 네이티브 라이브러리.
// 네이티브 코드는 저장소의 native/rdp_bridge/CMakeLists.txt를 NDK로 빌드하고,
// scripts/build.sh가 만든 dist/android-<arch>의 FreeRDP 정적 라이브러리를 링크합니다.

group = "com.aha645.remotedesktop"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.4.0"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.1.0")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

// 저장소 최상위 (packages/remote_desktop_android/android 기준)
val repoRoot = projectDir.resolve("../../..").canonicalFile

// FreeRDP를 빌드해 둔 ABI만 포함합니다. 하나도 없으면 CMake가 빌드 방법을 알려 줍니다.
val builtAbis = listOf("arm64-v8a" to "android-arm64", "x86_64" to "android-x86_64")
    .filter { (_, target) -> repoRoot.resolve("dist/$target/lib/libfreerdp3.a").exists() }
    .map { (abi, _) -> abi }

android {
    namespace = "com.aha645.remotedesktop"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24 // scripts/build.sh의 ANDROID_API와 같아야 함

        ndk {
            if (builtAbis.isNotEmpty()) {
                abiFilters += builtAbis
            } else {
                abiFilters += listOf("arm64-v8a")
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = repoRoot.resolve("native/rdp_bridge/CMakeLists.txt")
            version = "3.22.1"
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}
