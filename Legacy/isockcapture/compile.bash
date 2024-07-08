#!/usr/bin/bash

# this script is intended to compile the small app that listens for data
# from the Raspberry Pico that is controlling the pump that circulates
# water from the collector (when hot enough) to the tank.
# This app is intended to run on a Raspberry Pi, 'One' is fine, and the
# raspicapture app runs on same Pi. They communicate over IPC.
# Pico <tcp socket> isockcapture <ipc> raspicapture.

EXECUTABLE="isockcapture"

# FPC="/media/dbannon/68058302-90c2-48af-9deb-fb6c477efea1/libqt5pas1/raspitest/FPC/fpc-3.2.2/bin/fpc"

FPC="/home/dbannon/ExtDrv/FPC/fpc-3.2.2/bin/fpc"


if [ -e "$EXECUTABLE" ]; then
    rm -f "$EXECUTABLE"-old
    mv "$EXECUTABLE" "$EXECUTABLE"-old
fi

if [ "$1" == "debug" ]; then
    "$FPC" -MObjFPC -Scghi -gl -gh -CX -Cg -O1 -XX -l -vewnhibq -Fu.  -FU./lib/arm-linux-gnueabihf -FE.  -oisockcapture  isocksvr.pp
    echo "---------- Compile in debug mode --------------"
else
    "$FPC" -MObjFPC -Scghi -CX -Cg -O3 -XX -l -vewnhibq -Fu.  -FU./lib/arm-linux-gnueabihf -FE.  -oisockcapture isocksvr.pp
fi

exit

if [ -e "$EXECUTABLE" ]; then
    echo "======== Compile Complete =========="
    ./"$EXECUTABLE"  -L ./logfile
else
    echo "======= Sorry, Compile Failed ======"
fi

