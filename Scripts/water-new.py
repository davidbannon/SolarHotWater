#!/usr/bin/python2.7

# -a says Alt System, the veggie garden, default near backdoor
# -t Time to run in Minutes
#55 9 * * Fri,Sun,Tue,Wed python2.7 -u /home/dbannon/bin/water-new.py -a -t25 >> /home/dbannon/logs/water.log 2>&1
#46 11 * * Fri,Sun,Tue,Wed python2.7 -u /home/dbannon/bin/water-new.py -v -a -t1 >> /home/dbannon/logs/water.log 2>&1

# At 4 minutes past 9:00am, we run morning water.
# 4 9 * * * python2.7 -u /home/dbannon/bin/water-new.py -t25 >> /home/dbannon/logs/water.log 2>&1



import os
import glob
import time
import sys
from datetime import datetime
import argparse
import RPi.GPIO as GPIO

PIN = 22
ALTPIN = 24

# base_dir = '/sys/bus/w1/devices/'

def do_watering():
    if args.altpin:
        ThePin = ALTPIN
    else:
        ThePin = PIN
    GPIO.setmode(GPIO.BOARD)
    GPIO.setup(ThePin, GPIO.OUT)
    try:
        GPIO.output(ThePin, True)
        time.sleep(60*args.minutes)
        GPIO.output(ThePin, False)
    except :
        GPIO.output(ThePin, False)       # Low is solenoid off
        if args.verbose :
            print "Goodbye and thanks for all the fish..."
	sys.exit(0)
    finally:
        GPIO.cleanup()

def pulse_output():
    # The power on an input will cause the RasPi's input to be low, ie false.
    if args.altpin:
        ThePin = ALTPIN
    else:
        ThePin = PIN
    # Set the mode of numbering the pins.
    GPIO.setmode(GPIO.BOARD)
    GPIO.setup(ThePin, GPIO.OUT)
    try:
        while 1:
            GPIO.output(ThePin, False)
            if args.verbose:
                print "Board Pin %d Low" % (ThePin)
            time.sleep(5)
            GPIO.output(ThePin, True)
            if args.verbose:
                print "Board Pin %d high" % (ThePin)
            time.sleep(5)
    except KeyboardInterrupt:
        GPIO.output(ThePin, False)       # Low is solenoid off
	print "Goodbye and thanks for all the fish..."
	sys.exit(0)
    finally:
        GPIO.cleanup()
    

parser = argparse.ArgumentParser()
parser.add_argument("-o", "--optional", action="store_true", help="Watering optional, depends on heat")
# parser.add_argument("-r", "--repeat", action="store_true", help="Repeat current readings until ctrl C")
# parser.add_argument("-k", "--kernel", action="store_true", help="Insert kernel modules and exit (run as root)")
# parser.add_argument("-w", "--web", action="store_true", help="Write temp data to web file")
parser.add_argument("-I", "--initialise", action="store_true", help="Initialise with all OFF")
parser.add_argument("-a", "--altpin", action="store_true", help="Use Alt Pin output, board 24 instead of 22")
parser.add_argument("-v", "--verbose", action="store_true", help="show stuff on std out")
parser.add_argument("-p", "--pulse", action="store_true", help="pulse on and off, 5 seconds, testing")
parser.add_argument("-t", dest="minutes", help="watering time in minutes, default 20", type=int, default=20)
parser.add_argument("-d", dest="directory", help="directory to put pid file (remember trailing /)", default="./")
# parser.add_argument("-d", "--size", help="Size", type=int)
# action="store" is the default. Data ends up in name based on '--' name, or dest

args = parser.parse_args()

if not args.initialise:
    # Write out PID so its easy to kill later......
    fpid = open(args.directory + "water.pid", "w")
    fpid.write(str(os.getpid()))
    fpid.flush()
    os.fsync(fpid.fileno())
    fpid.close

if args.initialise:
    GPIO.setmode(GPIO.BOARD)
    GPIO.setup(PIN, GPIO.OUT)
    GPIO.output(PIN, False)
    GPIO.setup(ALTPIN, GPIO.OUT)
    GPIO.output(ALTPIN, False);
    GPIO.cleanup()    
    if args.verbose :
        print "Both ports forced OFF"
    sys.exit(0)

if args.pulse:
    if args.verbose:
        print "Pulsing, ctrl C to stop"
    pulse_output()
    sys.exit(0)

if args.verbose :
    #print "Watering for ", args.minutes, " minutes ", (datetime.date.today()).strftime("%Y-%m-%d %h:%m")
    today = datetime.now()
    print "Watering for ", args.minutes, " minutes ", today

do_watering()
    
