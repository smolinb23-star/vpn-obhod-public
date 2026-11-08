plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.local.vpnservice"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "dev.local.vpnservice"
        // org.amnezia.awg (amneziawg-android 2.3.7) требует minSdk 24
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // flutter_vless требует извлечения нативных библиотек (libxray.so, libtun2socks.so)
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
        resources {
            // okhttp 5.x (через amneziawg-android) и другие JVM-артефакты несут
            // дублирующиеся OSGi-манифесты — при merge JavaRes нужен exclude.
            excludes += setOf(
                "META-INF/versions/9/OSGI-INF/MANIFEST.MF",
                "META-INF/DEPENDENCIES",
                "META-INF/INDEX.LIST",
                "META-INF/NOTICE",
                "META-INF/LICENSE",
                "META-INF/LICENSE.txt",
            )
        }
    }

    buildTypes {
        release {
            // TODO(non-blocking): подписать релизный APK ключом разработчика.
            // Для отладочных сборок через CI используется debug-подпись Flutter.
            signingConfig = signingConfigs.getByName("debug")
            // Flutter по умолчанию включает shrinkResources в release;
            // без minify это ошибка конфигурации — отключаем оба явно.
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Нативный движок AmneziaWG: обфускация handshake (Jc/Jmin/Jmax, S1/S2, H1..H4)
    implementation("com.zaneschepke:amneziawg-android:2.3.7")
    testImplementation("junit:junit:4.13.2")
}
