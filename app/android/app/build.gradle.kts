import java.util.Properties
import java.io.FileInputStream

// Assinatura de release.
//
// O `flutter create` deixa o release assinado com a chave de DEBUG, o que
// gera um APK que a Google Play recusa. Aqui lemos android/key.properties,
// criado pela esteira de CI a partir dos segredos do repositório.
//
// O arquivo NUNCA é versionado (ver .gitignore). Se não existir, o build
// cai na chave de debug — útil para rodar localmente, inútil para publicar.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val temAssinatura = keystorePropertiesFile.exists()
if (temAssinatura) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "br.net.onebit.bitradio"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "br.net.onebit.bitradio"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (temAssinatura) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = keystoreProperties["storeFile"]?.let { file(it) }
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // R8 LIGADO, MAS COM O media3 PRESERVADO. Ver proguard-rules.pro.
            //
            // Sem essas regras o ExoPlayer quebrava com um NullPointerException
            // engolido como "(2) Unexpected runtime error", e a rádio ficava
            // muda em qualquer transporte. Provado por eliminação em emulador:
            // com isMinifyEnabled = false o som sai; com R8 sem regras, não.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )

            signingConfig = if (temAssinatura) {
                signingConfigs.getByName("release")
            } else {
                // Sem keystore: cai no debug para o build local funcionar.
                // NÃO publicável — a Play Store recusa APK com chave de debug.
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}
