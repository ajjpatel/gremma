# Gremma for Android

This is the Android Studio project, separate from the iPhone/Xcode app in `Gremma/`. Open this `AndroidStudio/` directory in Android Studio and let Gradle sync. It uses Kotlin, Jetpack Compose, Android's document/photo pickers, on-device ML Kit text recognition, and Google's LiteRT-LM Kotlin runtime.

## Current implementation

- Imports a `.litertlm` chat model into the app's private `files/Models` folder and runs local text conversation through LiteRT-LM.
- Reads text from a selected image with on-device ML Kit.
- Includes an app-private, versioned JSON memory store and conservative lexical lookup foundation.
- Does not make network requests or bundle model weights.

## iOS parity still to implement

The Android project is a functional starting point, not a complete port of all iOS flows. Its current UI does not yet expose saving observations, camera capture, voice interaction, multimodal object extraction, room confirmation, resumable video indexing/library, Taj Mahal fact pack, or model metadata validation/model selection. Those features live across `Gremma/AppController.swift`, `Gremma/Core/`, `Gremma/Voice/`, and `Gremma/Runtime/` and need Android-native equivalents. In particular, video processing should preserve the iOS rule that a room is confirmed before indexing and commit each frame's observations atomically before checkpointing progress.

## Models

Use a LiteRT-LM compatible `.litertlm` file. No weights are included. The app currently initializes the CPU backend for broad device support; GPU/NPU selection and capability/memory checks need device-specific implementation. The LiteRT-LM Android dependency is pinned to `0.18.1`, matching the iOS runtime version. Android runtime support and supported model features can differ by device and model.

## Build

Use Android Studio with JDK 17 and Android SDK 35 installed. Select the `app` run configuration and a device with sufficient memory. Models are large; import them from device storage after install. This initial project has not been built or device-validated yet.
