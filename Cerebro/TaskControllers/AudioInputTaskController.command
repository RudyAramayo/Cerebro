#!/bin/sh

echo "*********************************"
echo "OrbitusRobotics v1.0"
echo "AudioInputTaskController"
echo $1
echo "*********************************"

if [ -z "$CEREBRO_AUDIO_INPUT_SCRIPT" ]; then
    echo "CEREBRO_AUDIO_INPUT_SCRIPT is not configured" >&2
    exit 64
fi

"${CEREBRO_PYTHON_EXECUTABLE:-python3}" "$CEREBRO_AUDIO_INPUT_SCRIPT" "$1"
