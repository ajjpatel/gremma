#!/bin/sh
# Ask the running app from the Mac and print its answer.
#   ./ask.sh "where are my keys?"
#   ./ask.sh --image room.jpg REMEMBER     (pushes the file to the phone first; actions: DESCRIBE REMEMBER READ_TEXT READ_MEDICINE READ_EXPIRY)
adb logcat -c
if [ "$1" = "--image" ]; then
  N=$(basename "$2")
  adb push "$2" "/data/local/tmp/$N" >/dev/null && adb shell "run-as com.gremma.android cp /data/local/tmp/$N files/$N"
  adb shell "am start -n com.gremma.android/.MainActivity --es image '/data/user/0/com.gremma.android/files/$N' --es action '${3:-DESCRIBE}'" >/dev/null 2>&1
else
  adb shell "am start -n com.gremma.android/.MainActivity --es ask '$1'" >/dev/null 2>&1
fi
for _ in $(seq 1 120); do
  sleep 1
  out=$(adb logcat -d -s Gremma:I GremmaGemma:I | grep -E "say \(|generate")
  echo "$out" | grep -q "say (" && { echo "$out" | sed 's/.*Gremma[A-Za-z]* *: //'; exit 0; }
done
echo "no answer after 120 s"
