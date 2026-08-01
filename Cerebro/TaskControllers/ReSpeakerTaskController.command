#!/bin/sh

#echo "*********************************"
#echo "OrbitusRobotics v1.0"
#echo "ReSpeaker DOA"
#echo "*********************************"

if [ -z "$CEREBRO_RESPEAKER_SCRIPT" ]; then
    echo "CEREBRO_RESPEAKER_SCRIPT is not configured" >&2
    exit 64
fi

"${CEREBRO_PYTHON_EXECUTABLE:-python3}" "$CEREBRO_RESPEAKER_SCRIPT"
