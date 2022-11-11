# EmberOSMint
Script to turn any random box running Mint into a Kaithem automation hub and Kiosk display.


## Install

Start with a clean recent Mint or maybe debian install.  It must have the user names "ember" with a good password.

Run kioskify.sh.


### What it will do

You'll get a Kiosk browser on boot showing whatever is under /var/www/html/index.html. Look in /home/ember/.config/autostart to change what runs at boot.

You will also get kaithemautomation and all optional dependencies, running on port 8002.  You log into kaithem using the system credentials for the user it runs under, in this case "ember".

The script sets up a lot of tweaks that prevent wearing out the internal flash on cheap machines.

SSH will be enabled, as will passwordless sudo.


### Other stuff that gets installed


#### Zigbee2MQTT

Enable with systemctl enable zigbee2mqtt.  It's in /opt.  Watch out with zigbee, it might not be a good idea to invest in the system now that Matter is out.


### If you get some keyring was not unlocked nonsense at boot

Go into your passwords and keys, right click login, do change password and make it blanck for auto login.
