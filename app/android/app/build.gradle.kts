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
            // MINIFICAÇÃO DESLIGADA — EXPERIMENTO, NÃO DECISÃO DEFINITIVA.
            //
            // O logcat do emulador (Android 11 x86_64, APK release 1.0.7)
            // mostrou o que "(2) Unexpected runtime error" escondia:
            //
            //   E/ExoPlayerImplInternal: Playback error
            //     X.n: Unexpected runtime error
            //   Caused by: java.lang.NullPointerException
            //     at C1.c.f(Unknown Source:1)
            //     at X.U.h(SourceFile:241)
            //
            // NPE dentro do ExoPlayer, em classes de nome ofuscado, 260 ms
            // depois do Init — antes de tocar a rede. O erro é idêntico no
            // stream MP3 contínuo e no HLS, o que já descartou o transporte;
            // servidor, manifesto, permissões e sessão de áudio também já
            // foram verificados e estão corretos.
            //
            // Resta separar "o R8 quebrou o media3" de "bug legítimo". Com a
            // minificação desligada isso se decide numa tentativa: se o som
            // sair, era o R8, e o passo seguinte é reativar o R8 COM as regras
            // de keep corretas — não deixar desligado, que incha o APK e é
            // remédio pior que a doença.
            isMinifyEnabled = false
            isShrinkResources = false

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
