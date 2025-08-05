#!/bin/sh

echo "*********************************"
echo "OrbitusRobotics v1.0"
echo "JoinWifi"
echo $1 $2 $3
echo "*********************************"

/usr/sbin/networksetup -setairportnetwork $1 $2 $3
