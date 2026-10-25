#!/bin/sh
# Build, install and relaunch the app, then wait for Gemma to load.
set -e
cd "$(dirname "$0")"
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ANDROID_HOME="$HOME/Library/Android/sdk" GRADLE_USER_HOME="$HOME/.gradle"
./gradlew assembleDebug -q 2>&1 | grep -E "^e:|BUILD FAILED" && exit 1
adb install -r app/build/outputs/apk/debug/app-debug.apk | tail -1
adb logcat -c
adb shell am start -n com.gremma.android/.MainActivity >/dev/null 2>&1
for _ in $(seq 1 90); do
  sleep 2
  line=$(adb logcat -d -s GremmaGemma:I | grep "loaded" || true)
  [ -n "$line" ] && { echo "$line" | sed 's/.*GremmaGemma *: //'; exit 0; }
done
echo "Gemma did not load in 180 s"; adb logcat -d | grep -E "FATAL|AndroidRuntime" | tail -5
