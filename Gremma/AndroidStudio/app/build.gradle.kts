import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.gremma.android"
    compileSdk = 36
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    defaultConfig {
        applicationId = "com.gremma.android"
        minSdk = 31
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
    }
    buildFeatures { compose = true }
    packaging {
        jniLibs {
            useLegacyPackaging = true
            pickFirsts.add("**/liblitertlm_jni.so")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
        // LiteRT-LM is built with a newer Kotlin; without this the compiler crashes in its class checker.
        freeCompilerArgs.addAll("-Xskip-metadata-version-check")
    }
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2026.02.00"))
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-play-services:1.9.0")
    implementation("com.google.ai.edge.litertlm:litertlm-android:0.18.1")
    implementation("com.google.mlkit:text-recognition:16.0.1")
    implementation("com.google.mediapipe:tasks-vision:1.0.0")
    implementation("org.nanohttpd:nanohttpd:2.3.1")
    debugImplementation("androidx.compose.ui:ui-tooling")
}
