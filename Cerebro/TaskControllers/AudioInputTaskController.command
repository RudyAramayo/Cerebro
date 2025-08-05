#!/bin/sh

echo "*********************************"
echo "OrbitusRobotics v1.0"
echo "AudioInputTaskController"
echo $1
echo "*********************************"

export GOOGLE_APPLICATION_CREDENTIALS="/Users/rob/Desktop/ROBOT-d309c5b55928.json"

/usr/local/bin/python3 /Users/rob/Desktop/python_google_speech $1
