SolarHotWater
===========

<sub>(markdown generated from "SolaHotWater" note.)</sub>



This project is almost certainly not of interest to anyone but me. Maybe some ideas may be interesting ?



I have a Solar hot water system that consists of a collector on the roof, a storage tank on the ground and a small circulation pump that operates when a controller believes that water in the collector is hotter than that in the tank.



I have long believed that the supplied controller did not do a good jobs, set up for 'average' conditions like distance between collector and tank. This was brought to a head when the controller failed. Faced with the prospect of purchasing a new one (with the same problems) or DIY I choose the latter.



This project, at present, is really about understanding the system in detail so is seen as step one.  The controller was replaced with a Raspberry Pi Pico and a small electronics board that used the existing Pt1000 sensors and a small relay to switch the 240v pump. Using the existing sensors was seen as easy but getting accurate temperature readings over the necessary 0 to 120c (?)  with the electronics themselves varying between 0 to 45c was not easy. The Pico's A/D convert is noisy and irreproducible. So, once I  understand the true temperature range of the (particularly collector) sensors, I'll consider using **DS18B20** Temperature Sensors, accurate, precise and cheap but are limited to a max of 125c, probably not a problem but I need to be sure. Summer is coming ....



I already have a Raspberry Pi One with a handful of DS18B20 sensors monitoring a number of things (and controlling watering systems etc) so decided to get the Pico to report its temperatures to there and give me a record of what I need.



So, code here is for my security, its not intended to be documentation for someone else to duplicate my project. But I am happy to discuss or receive comments !



Davo










