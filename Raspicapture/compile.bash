#!/usr/bin/bash

EXECUTABLE="raspicapture"

# FPC="/media/dbannon/68058302-90c2-48af-9deb-fb6c477efea1/libqt5pas1/raspitest/FPC/fpc-3.2.2/bin/fpc"

# FPC="/home/dbannon/ExtDrv/FPC/fpc-3.2.2/bin/fpc"
FPC="fpc"

if [ -e "$EXECUTABLE" ]; then
    rm -f "$EXECUTABLE"-old
    mv "$EXECUTABLE" "$EXECUTABLE"-old
fi

# "$FPC" -Cn pi_data_utils.pas
# "$FPC" -Cn plotter.pas  

if [ "$1" == "debug" ]; then
    "$FPC" -MObjFPC -Scghi -gl -gh -CX -Cg -O1 -XX -l -vewnhibq -Fu.  -FU./lib/arm-linux-gnueabihf -FE.  -oraspicapture raspicapture.lpr
    echo "---------- Compile in debug mode --------------"
else
    "$FPC" -MObjFPC -Scghi -CX -Cg -O3 -XX -l -vewnhibq -Fu.  -FU./lib/arm-linux-gnueabihf -FE.  -oraspicapture raspicapture.lpr
fi

# "$FPC" -MObjFPC -Scghi -Cg -O1 -g -gl -l -vewnhibq -Fu.  -FU./lib/arm-linux-gnueabihf -FE.  -oraspicapture raspicapture.lpr

exit

if [ -e "$EXECUTABLE" ]; then
    echo "======== Compile Complete =========="
    ./"$EXECUTABLE"  -L ./logfile
else
    echo "======= Sorry, Compile Failed ======"
fi

