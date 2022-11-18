#!/bin/bash

set -x
set -e


# Everything will happen under this user. 
# You must have a user named ember at uid1000(This is the default user made throught the install GUI)

# After following this, go into your passwords and keys, right click login, do change password and make it blanck for auto login.

# SSH WILL BE ENABLED. As will passwordless sudo. Use a good passwod when you make the ember user.

# The kaithem password will be the 


usermod -aG sudo ember

# This new user has passwordless sudo
cat << EOF > /etc/sudoers.d/99-ember
ember ALL=(ALL) NOPASSWD: ALL
EOF



# Embedded PC disk protector

! systemctl disable systemd-readahead-collect.service
! systemctl disable systemd-readahead-replay.service


#Eliminate the apt-daily updates that can't work anyway on read only roots,
#And were the suspected cause of periodic crashes in real deployments
sudo systemctl mask apt-daily-upgrade
sudo systemctl mask apt-daily.service
sudo systemctl mask apt-daily.timer

systemctl mask systemd-update-utmp.service
systemctl mask systemd-random-seed.service
systemctl disable systemd-update-utmp.service
systemctl disable systemd-random-seed.service
sudo systemctl disable apt-daily-upgrade.timer
sudo systemctl disable apt-daily.timer
sudo systemctl disable apt-daily.service


## O yeah ssh
sudo apt-get install openssh-server
sudo systemctl enable ssh --now


cat << EOF > /etc/systemd/system/ember-update.timer
[Unit]
Description=EmberOS minimal updater, just the stuff that will break without it
RefuseManualStart=no # Allow manual starts
RefuseManualStop=no # Allow manual stops 

[Timer]
#Execute job if it missed a run due to machine being off
Persistent=yes
OnCalendar=*-*-01 02:00:00
Unit=ember-update.service

[Install]
WantedBy=timers.target
EOF

cat << EOF > /etc/systemd/system/ember-update.service
[Unit]
Description=EmberOS minimal updater, just the stuff that will break without it
[Service] 

Type=simple
ExecStart=/bin/bash /usr/bin/ember-update.sh
Type=oneshot
EOF

cat << EOF > /usr/bin/ember-update.sh
#!/bin/bash
yes | apt update
apt install ca-certificates
apt install tzdata
EOF



chmod 755 /usr/bin/ember-update.sh

systemctl enable ember-update.timer





curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -
echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list
sudo apt update


# Install Node.js;
! apt-get purge -y nodejs nodejs-doc

curl -fsSL https://deb.nodesource.com/setup_16.x | bash -
apt-get install -y nodejs


sudo apt-get install -y git make g++ gcc
npm install --global yarn


cat << 'EOF' > /usr/bin/fs_bindings.py
#!/usr/bin/python3

from __future__ import print_function
import pwd
import sys, traceback


def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)


#Sorts by which ordrer we should do the bindings.
#Obviously we need to bind lower lever dirs before higher level ones.
#Or the lower ones would just cover everything up.
def bindSortKeyHelper(source, data):
    if isinstance(data, dict):
        if 'bindat' in data:
            return len(data['bindat'])
        else:
            #Default to on top of the source
            return len(source)
    else:
        #Simple binding
        return len(source)


"""

Takes config files like

----------------------------------------

# Complex binding, implemented with more advanced tools like bindfs
# Any binding that isn't just a target string is considered complex.
/sketch/config:
    # If not present, the dir binds on top of itself.
    bindat: /etc/sketchconfig

and 

/sketch/config:
    bindat: /etc/sketchconfig

    # You can think of a mode as applying that permission
    # to the folder itself, even thoug the transformed view is elsewhere.

    #Simple bindings sources from /sketch/config are automatically
    #Mapped to the transformed view.
    mode: "0755"

    #Note: This actually binds /etc/sketchconfig/hosts
    #Not /sketch/config/hosts
    #Because bindfiles uses the permission-transformed view
    bindfiles:
        hosts: /etc/hosts
        hostname: /etc/hostname

    pre_cmd:
        - SomeCommand
        - SomeOtherCommanda
and:

#This will actually bind /etc/sketchconfig/simple, because
#Simple bindings use permission transformed views.

#It does not matter if the simple binding is in the same file
#As the complex binding it is based on

#A simple binding is defined just by a string target
/sketch/config/simple: /simple


#This one binds a tmpfs on top of /foo/bar.
#It will be ordered correctly with everything else based on bindat.
#Tmpfses are complex bindings.
# All three params are mandatory 
#Name must be unique. For real.

__tmpfsoverlay__UNIQUENAME:
    bindat: /foo/bar
    mode: 0755
    user: ember 
-----------------


and merges them together, then uses them to set up bindings.

In this case we are saying: Make /sketch/config viewable at /etc/sketchconfig.

in the second file, we say(Note relative paths), make /etc/sketchconfig/hosts viewable at /etc/hosts

Bindfiles are relative to the main bindat location for that path.

The line /sketch/config/simple: /simple binds  /etc/sketchconfig/simple to /simple,
because the path gets rebased on the top configured directory/

All binding files lists for a path are merged together, you can specify multiple lists for one dir, in different config files.

If bindat is specified in more than one gile for a given path, it is undefined who wins.

Bindfiles relative paths are interpreted relative to bindat.

It is an error to use an absolute path for a bindfile source.

File bindings happen after the top level path bindings.


Pre_cmd is executed before the binding happends, post_cmd comes after.

pre_cmd can be a single command line, or a list of them.


Bindings happen in two steps. First the complex bindings,
then the file bindings and the simple bindings.

In each step, whatever has the shortest target path is always bound first(To do otherwise
would interfere with layering, and higher level subdirs woud cover things up.).


You should not use a subfolder of any binding as the source for a complex binding,
as the ordering is defined based on the destinations.

"""

import yaml, subprocess, os

#Our current merged config
mergedConfig = {}

configdir = "/etc/fsbindings"


def tmpfs_overlay(onto, user, mode):
    "Apply a tmpfs overlay on top of whatever you pass it"
    tmp = "/dev/shm/" + onto.replace("/", "_") + "tmp"
    wrk = "/dev/shm/" + onto.replace("/", "_") + "work"
    subprocess.check_call(["mkdir", "-p", tmp])
    subprocess.check_call(["mkdir", "-p", wrk])
    subprocess.check_call(["chmod", mode, tmp])
    subprocess.check_call(["chmod", mode, wrk])
    subprocess.check_call(["chown", user, tmp])
    subprocess.check_call(["chown", user, wrk])
    subprocess.check_call([
        "mount", "-t", 'overlay', '-o',
        'lowerdir=' + onto + ',upperdir=' + tmp + ',workdir=' + wrk, 'overlay',
        onto
    ])


def overlay(upper, onto):
    "Apply a normal overlay on top of whatever you pass it"
    wrk = "/dev/shm/" + onto.replace("/", "_") + "work"
    subprocess.check_call(["mkdir", "-p", wrk])
    subprocess.check_call([
        "mount", "-t", 'overlay', '-o',
        'lowerdir=' + onto + ',upperdir=' + upper + ',workdir=' + wrk,
        'overlay', onto
    ])


for i in os.listdir(configdir):
    try:
        if i.endswith(".yaml"):
            with open(os.path.join(configdir, i)) as f:
                thisConfig = yaml.load(f.read())
                topLevelConfigToMerge = {}
                #Merge all the bindfile lists so we can define bindings for the same dir in multiple folders
                for j in thisConfig:
                    #Normalize
                    if not j.endswith("/"):
                        path = j + "/"
                    else:
                        path = j

                    #If it is not a string, that's because it's a simple binding
                    #Merge logic
                    if not isinstance(thisConfig[j], str):
                        if path in mergedConfig:
                            thisConfig[j]['referenced_by'] = mergedConfig[
                                path]['referenced_by']

                            b = mergedConfig[path].get("bindfiles", {})
                            newfiles = thisConfig[j].get("bindfiles", {})

                            for i in newfiles:
                                if i in b:
                                    raise RuntimeError(
                                        "Conflict on where to bind file:" + i)
                                else:
                                    b[i] = newfiles[i]

                            thisConfig[j]['bindfiles'] = b

                            for key in [
                                    'bindat', 'mode', 'user', 'pre_cmd',
                                    "post_cmd"
                            ]:
                                if key in mergedConfig[path]:
                                    if key in thisConfig[j]:
                                        raise RuntimeError(
                                            key +
                                            " was already specified for path "
                                            + j + " in another file")
                                    else:
                                        thisConfig[j][key] = mergedConfig[
                                            path][key]

                    topLevelConfigToMerge[path] = thisConfig[j]
                    if isinstance(topLevelConfigToMerge[path], dict):
                        if not "referenced_by" in topLevelConfigToMerge[path]:
                            topLevelConfigToMerge[path]['referenced_by'] = []

                        topLevelConfigToMerge[path]['referenced_by'].append(i)

                mergedConfig.update(topLevelConfigToMerge)
    except:
        eprint("Exception loading config file: " + i + "\n\n" +
               traceback.format_exc())

#Compute an effective bind point, which may just be the path itself if no bind is done
for i in sorted(list(mergedConfig.keys()),
                key=lambda x: bindSortKeyHelper(x, mergedConfig[x])):

    try:
        bindingConfig = mergedConfig[i]

        #Simple bindimng
        if isinstance(bindingConfig, str):
            continue

        if 'bindat' in bindingConfig:
            dest = bindingConfig['bindat']
        else:
            dest = i

        dest = dest.replace("%uid1000", pwd.getpwuid(1000).pw_name)


        #Keep track of where we are actually going to mount it.
        bindingConfig['mounted_at'] = dest
    except:
        eprint("Exception \n\n" + traceback.format_exc())

print(yaml.dump(mergedConfig))

#Shortest first, to do upper dirs
#Use the length of whereever we are binding to,
for i in sorted(list(mergedConfig.keys()),
                key=lambda x: bindSortKeyHelper(x, mergedConfig[x])):

    i = i.replace("%uid1000", pwd.getpwuid(1000).pw_name)

    try:
        bindingConfig = mergedConfig[i]

        if isinstance(bindingConfig, str):
            print("Simple Binding", bindingConfig)
            continue

        if 'bindat' in bindingConfig:
            dest = bindingConfig['bindat']
        else:
            dest = i

        dest = dest.replace("%uid1000", pwd.getpwuid(1000).pw_name)

        if 'pre_cmd' in bindingConfig:
            print(bindingConfig['pre_cmd'])
            if isinstance(bindingConfig['pre_cmd'], str):
                subprocess.call(bindingConfig['pre_cmd'], shell=True)

            elif isinstance(bindingConfig['pre_cmd'], list):
                for command in bindingConfig['pre_cmd']:
                    subprocess.check_call(command, shell=True)

        if 'mode' in bindingConfig or 'user' in bindingConfig or 'bindat' in bindingConfig:
            if 'mode' in bindingConfig:
                m = str(bindingConfig['mode'])
                if len(m) == 3:
                    m = '0' + m

                for c in m:
                    if not c in "01234567":
                        raise RuntimeError(
                            "Nonsense mode" + m +
                            " ,mode should only contain 01234567. Try using quotes in the config?"
                        )
            else:
                m = None

            i = i.replace("%uid1000", pwd.getpwuid(1000).pw_name)

            if not i.startswith("__"):
                if bindingConfig.get("type", "bindfs") == "bindfs":
                    cmd = ['bindfs', '-o', 'nonempty']
                    if m:
                        cmd.extend(['-p', m])
                    if 'user' in bindingConfig:
                        cmd.extend(['-u', bindingConfig['user']])
                    # Mount over itself with the given options
                    cmd.extend([i, dest])
                    print(cmd)
                    subprocess.call(cmd)
                elif bindingConfig.get("type", "bindfs") == "overlay":
                    overlay(i, dest)
                else:
                    raise RuntimeError("Bad binding type:" +
                                       bindingConfig.get("type", "bindfs"))

            else:
                if i.startswith("__tmpfsoverlay__"):
                    tmpfs_overlay(dest, bindingConfig['user'],
                                  bindingConfig['mode'])
                elif i == '__tmpfs__':
                    m = m or '1777'
                    subprocess.call([
                        "mount", "-t"
                        "tmpfs", "-o",
                        "size=" + str(bindingConfig.get('size', '32M')) +
                        ",mode=" + m + ",nonempty", "tmpfs", dest
                    ])

        if 'post_cmd' in bindingConfig:
            print(bindingConfig['post_cmd'])
            subprocess.call(bindingConfig['post_cmd'], shell=True)

    except:
        eprint("Exception in config for: " + i + "\n\n" +
               traceback.format_exc())


def searchConfig(f):
    if not f.endswith("/"):
        f = f + '/'

    if f in mergedConfig and not isinstance(mergedConfig[f], str):
        return f, mergedConfig[f]

    while len(f) > 1:
        #Split does not do what you think it should if path ends in /
        f = os.path.split(f if not f[-1] == '/' else f[:-1])[0]
        if not f.endswith("/"):
            f = f + '/'
        if f in mergedConfig and not isinstance(mergedConfig[f], str):
            return f, mergedConfig[f]
    return f, {}


#Now we handle simple bindings, and individual file bindings.
for i in sorted(list(mergedConfig.keys()),
                key=lambda x: bindSortKeyHelper(x, mergedConfig[x])):
    bindingConfig = mergedConfig[i]

    #Simple bindings
    if isinstance(bindingConfig, str):
        try:
            #Bind to the permission-transformed view, not the original
            #Not the search path thing, because we might be in a subfolder of something BindFSed elsewhere,
            #And we need to find that "elsewhere".

            #We don't have to worry about ordering relative to the permission transformed
            #views.sorted
            l, topConfig = searchConfig(i) or {}

            #Start with the path
            thisConfig = i

            mounted = topConfig.get('mounted_at', '/')

            if not mounted.endswith("/"):
                mounted = mounted + '/'

            #Now rebase it on wherever the topmost configured parent dir is mounted
            thisConfig = thisConfig.replace(l, mounted)

            
            thisConfig = thisConfig.replace("%uid1000", pwd.getpwuid(1000).pw_name)
            bindingConfig = bindingConfig.replace("%uid1000", pwd.getpwuid(1000).pw_name)

            cmd = [
                'mount', '--rbind', '-o', 'nonempty', thisConfig, bindingConfig
            ]
            print(cmd)
            subprocess.call(cmd)
        except:
            eprint("Exception in binding for: " + i + " on " + bindingConfig +
                   "\n\n" + traceback.format_exc())

    elif 'bindfiles' in bindingConfig:
        for j in bindingConfig['bindfiles']:
            dest = None
            try:
                dest = bindingConfig['bindfiles'][j]

                l, topConfig = searchConfig(i) or {}
                thisConfig = os.path.join(topConfig.get('mounted_at', '/'), i)

                mounted = topConfig.get('mounted_at', '/')

                if not mounted.endswith("/"):
                    mounted = mounted + '/'

                thisConfig = thisConfig.replace(l, mounted)
                thisConfig = os.path.join(thisConfig, j)

                thisConfig = thisConfig.replace("%uid1000", pwd.getpwuid(1000).pw_name)

                cmd = ['mount', '--rbind', '-o', 'nonempty', thisConfig, dest]

                print(cmd)
                subprocess.call(cmd)
            except:
                eprint(
                    "Exception in binding for: " +
                    os.path.join(bindingConfig.get("mounted_at", "ERR"), j) +
                    " on " + dest + "\n\n" + traceback.format_exc())
EOF


chmod 744 /usr/bin/fs_bindings.py

cat << EOF >> /etc/fstab

tmpfs /media tmpfs  defaults,noatime,nosuid,nodev,noexec,mode=0755,size=1M 0 0
tmpfs /mnt tmpfs  defaults,noatime,nosuid,nodev,noexec,mode=0755,size=1M 0 0
tmpfs /tmp tmpfs  defaults,noatime,nosuid,nodev,mode=1777,size=256M 0 0
tmpfs    /var/log    tmpfs    defaults,noatime,nosuid,mode=0755,size=128M    0 0
tmpfs    /var/lib/logrotate    tmpfs    defaults,noatime,nosuid,mode=0755,size=32m    0 0
tmpfs    /var/lib/sudo    tmpfs    defaults,noatime,nosuid,mode=0700,size=8m    0 0
tmpfs    /var/lib/systemd    tmpfs    defaults,noatime,nosuid,mode=0755,size=64m    0 0
tmpfs   /var/lib/chrony    tmpfs    defaults,noatime,nosuid,mode=0755,size=8m    0 0
tmpfs    /var/tmp    tmpfs    defaults,noatime,nosuid,mode=1777,size=128M    0 0
tmpfs    /var/lib/NetworkManager    tmpfs    defaults,noatime,nosuid,mode=0700,size=64M    0 0
EOF



cat << 'EOF' > /etc/systemd/system/fsbindings.service
[Unit]
Description=Configure BindFS sketch management
After=systemd-remount-fs.service
#Possiblye issue here if we start *after* something important, don't forget to include things!
Before=multi-user.target systemd-hostnamed.service systemd-resolved.service sysinit.target NetworkManager.service chronyd.service kaithem.service firewalld.service regenerate_ssh_host_keys.service smbd.service nmbd.service console-setup.service yggdrasil.service nodered.service ssh.service console-setup.service serviceconfig.service 
RequiresMountsFor=/etc/ /sketch/ /home/
DefaultDependencies=no


[Service]
TimeoutStartSec=0
ExecStart=/usr/bin/fs_bindings.py > /var/log/fs_bindings
#We don't want syste
KillMode=process
Type=oneshot
OOMScoreAdjust=-1000
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

chmod 644 /etc/systemd/system/fsbindings.service
systemctl enable fsbindings.service


mkdir -p /etc/fsbindings/


cat << EOF > /etc/fsbindings/ember-home.yaml
__tmpfs__pwstate:
    bindat: /home/ember/.local/state/pipewire
    size: 24M
EOF

cat << EOF > /etc/fsbindings/emberos-misc-ramdisks.yaml

__tmpfsoverlay__varliblightdm:
    bindat: /var/lib/lightdm
    mode: '1777'
    user: lightdm
    size: 128M

__tmpfsoverlay__varcachelightdm:
    bindat: /var/cache/lightdm
    mode: '1777'
    user: lightdm
    size: 128M

__tmpfsoverlay__varlibminidlna:
    bindat: /var/lib/minidlna
    mode: '755'
    user: minidlna
    size: 128M

__tmpfsoverlay__varcacheminidlna:
    bindat: /var/cache/minidlna
    mode: '755'
    user: minidlna
    size: 128M

__tmpfsoverlay__varlibminidlna:
    bindat: /var/lib/minidlna
    mode: '755'
    user: minidlna
    size: 128M

__tmpfsoverlay__varcachesamba:
    bindat: /var/cache/samba
    mode: '755'
    user: root
    size: 128M

__tmpfsoverlay__varspoolsamba:
    bindat: /var/spool/samba
    mode: '1777'
    user: root
    size: 128M


__tmpfs__ntp:
    bindat: /var/lib/ntp
    mode: '755'
    user: root
    size: 1M

__tmpfs__publictmp:
    bindat: /public.tmp
    mode: '1777'
    user: root
    size: 32M


__tmpfs__varlibpulse:
    bindat: /var/lib/pulse
    mode: '755'
    user: root
    size: 8MB

__tmpfs__dhcp:
    bindat: /var/lib/dhcp
    mode: '755'
    user: root
    size: 8MB

_tmpfs__rfkill:
    bindat: /var/lib/rfkill
    mode: '755'
    user: root
    size: 8MB
EOF



cat << EOF > /etc/systemd/journald.conf
[Journal]                                                                                                                                                                                                                                                                                                                       
Storage=volatile
Seal=no
SystemMaxUse=24M
RuntimeMaxUse=24M
EOF



sudo apt -y install chromium-browser
sudo apt-get -y purge firefox
xdg-settings set default-web-browser chromium-browser.desktop


mkdir -p /etc/chromium/policies/recommended/
# override-insecure-http.local bypasses restrictions on insecure origins.  The intended use case is
# to enable local RTC signalling.  If an attacker can trick you into going to a bad site on this domain,
# they have already won and could just trick you into going to their site.  If incompetent people use this
# for bad things, and they're on your lan.. you've already lost.  And it is fairly obviously a shady looking url.
cat << EOF > /etc/chromium/policies/recommended/emberos-policy.json
{
  "AudioCaptureAllowedUrls": ["http://localhost","http://localhost:8002","https://localhost:8001", "http://localhost:1880"],
  "VideoCaptureAllowedUrls": ["http://localhost","http://localhost:8002","https://localhost:8001", "http://localhost:1880"],
  "AutoplayWhitelist":       ["http://localhost","http://localhost:8002", "https://localhost:8001","http://localhost:1880", "http://*.local"],
}
EOF


# Disable uBlock Origin. It crashed several times, and might not even be supported in a year.
cat << EOF > /etc/chromium/master_preferences
{
	"alternate_error_pages":{
		"enabled":false
	},
	"extensions":{
		"settings":{
			"cjpalhdlnbpafiamejdnhcphjbkeiagm":{
				"location":1,
				"manifest":{
					"manifest_version":2,
					"key":"MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAmJNzUNVjS6Q1qe0NRqpmfX/oSJdgauSZNdfeb5RV1Hji21vX0TivpP5gq0fadwmvmVCtUpOaNUopgejiUFm/iKHPs0o3x7hyKk/eX0t2QT3OZGdXkPiYpTEC0f0p86SQaLoA2eHaOG4uCGi7sxLJmAXc6IsxGKVklh7cCoLUgWEMnj8ZNG2Y8UKG3gBdrpES5hk7QyFDMraO79NmSlWRNgoJHX6XRoY66oYThFQad8KL8q3pf3Oe8uBLKywohU0ZrDPViWHIszXoE9HEvPTFAbHZ1umINni4W/YVs+fhqHtzRJcaKJtsTaYy+cholu5mAYeTZqtHf6bcwJ8t9i2afwIDAQAB",
					"name":"uBlock Origin",
					"permissions":["contextMenus","privacy","storage","tabs","unlimitedStorage","webNavigation","webRequest","webRequestBlocking","<all_urls>"],
					"update_url":"https://clients2.google.com/service/update2/crx",
					"version":"0.0"
				},
				"granted_permissions":{
					"api":["contextMenus","privacy","storage","tabs","unlimitedStorage","webNavigation","webRequest","webRequestBlocking"],
					"explicit_host":["<all_urls>","chrome://favicon/*","http://*/*","https://*/*"],
					"scriptable_host":["http://*/*","https://*/*"]
				},
				"path":"cjpalhdlnbpafiamejdnhcphjbkeiagm\\0.0",
				"state":0
			},
			"aleakchihdccplidncghkekgioiakgal":{
				"location":1,
				"manifest":{
					"manifest_version":2,
                    "key":"MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAxpuYJpBArlJinXxN4oxx4UuFNreRTNO5Cl3TNF5FtDmgNLflbtYyC2nC5eZGxpNibzauHmGTD8ekFCfNZhHFpUEIZWd9AHI7TZdhu6gPxaK1lPEMukVEewFs2ovaEkjZbe3gy3v0eUDnADUkiaex7XeAWR6mJLzmcUaPFgzFRsDkozsE9tXLNN6oEYuWHN/yRsM1RYo7PYPulutHF8POL/8vDSyWHx/W9YDTnbv+2SBJZO7Dxi1/PbutasUag+/jma0X1nGhrEufr67NMvtpjPWSISWkIwxPR8u7EVyrKTSXs6U7jCbhKedhomeu9E/xZ1Er0dGWYWnhpdo0GNvblwIDAQAB",
					"name":"h264ify",
					"permissions":["storage"],
					"update_url":"https://clients2.google.com/service/update2/crx",
					"version":"0.0"
				},
				"granted_permissions":{
					"api":["storage"],
					"manifest_permissions":[],
					"scriptable_host":["*://*.youtube.com/*","*://*.youtube-nocookie.com/*","*://*.youtu.be/*"]
				},
				"path":"aleakchihdccplidncghkekgioiakgal\\0.0",
				"state":1
			}
		},
		"theme":{
			"id":"",
			"use_system":true
		}
	},
	"browser":{
		"custom_chrome_frame":false,
		"default_browser_infobar_last_declined":"1"
	},
	"default_search_provider":{
		"synced_guid":"9A111FB4-A8D3-4FDD-84CE-76178E50246B"
	},
	"default_search_provider_data":{
		"template_url_data":{
			"alternate_urls":[],
			"created_by_policy":false,
			"date_created":"13114024949603971",
			"favicon_url":"",
			"id":"7",
			"image_url":"",
			"image_url_post_params":"",
			"input_encodings":[],
			"instant_url":"",
			"instant_url_post_params":"",
			"keyword":"duckduckgo.com",
			"last_modified":"13114024949603971",
			"new_tab_url":"",
			"originating_url":"",
			"prepopulate_id":0,
			"safe_for_autoreplace":false,
			"search_terms_replacement_key":"",
			"search_url_post_params":"",
			"short_name":"DuckDuckGo",
			"suggestions_url":"",
			"suggestions_url_post_params":"",
			"synced_guid":"9A111FB4-A8D3-4FDD-84CE-76178E50246B",
			"url":"https://duckduckgo.com/?q={searchTerms}&t=raspberrypi",
			"usage_count":0
		}
	},
	"search":{
	    "suggest_enabled":false
	},
	"profile":{
	    "default_content_setting_values":{
	        "plugins":0
	    }
	},
	"first_run_tabs":["http://localhost"]
}

EOF




## Install the core set of automation stuff

mkdir -p /etc/mosquitto/conf.d/

cat <<EOF > /etc/mosquitto.conf
persistence false
listener 1883
allow_anonymous true

# Disable's Nagle's algorithm on the assumption that we
# will be doing small numbers of short packages.
set_tcp_nodelay true
EOF





mkdir -p /home/ember/ember_build_cache
cd /home/ember/ember_build_cache

if [ ! -d /home/ember/ember_build_cache/zigbee2mqtt ]
then
git clone --recursive --depth 1 https://github.com/Koenkk/zigbee2mqtt.git
else
cd /home/ember/ember_build_cache/zigbee2mqtt
git pull --rebase
fi


#Do all the install work inside the build cache so it persists
sudo chown -R ember:ember /home/ember/ember_build_cache/zigbee2mqtt
# Install dependencies (as user "ember")
cd /home/ember/ember_build_cache/zigbee2mqtt
sudo --user=ember yarn install



mkdir -p /opt/zigbee2mqtt/data
rsync -avz /home/ember/ember_build_cache/zigbee2mqtt/ /opt/zigbee2mqtt/

#There is a big problem with this, it has an initial build step.
#Which means it needs a *writable* opt.  What a horror!
sudo chown -R ember:ember /opt/zigbee2mqtt



cat << EOF > /etc/systemd/system/zigbee2mqtt.service
[Unit]
Description=zigbee2mqtt
After=network.target fs_bindings.service mosquitto.service

[Service]
ExecStart=/usr/bin/yarn start
WorkingDirectory=/opt/zigbee2mqtt
StandardOutput=null
# Or use StandardOutput=null if you don't want Zigbee2MQTT messages filling syslog, for more options see systemd.exec(5)
StandardError=inherit
Restart=always
RestartSec=30
User=1000

[Install]
WantedBy=multi-user.target
EOF

cat << EOF > /opt/zigbee2mqtt/data/configuration.yaml
# Optional: Home Assistant integration (MQTT discovery) (default: false)
homeassistant: true

# Optional: allow new devices to join.
# WARNING: Disable this after all devices have been paired! (default: false)
permit_join: false

# Required: MQTT settings
mqtt:
  # Required: MQTT base topic for Zigbee2MQTT MQTT messages
  base_topic: zigbee2mqtt
  # Required: MQTT server URL (use mqtts:// for SSL/TLS connection)
  server: 'mqtt://localhost:1883'
  # Optional: absolute path to SSL/TLS certificate of CA used to sign server and client certificates (default: nothing)
  #ca: '/etc/ssl/mqtt-ca.crt'
  # Optional: absolute paths to SSL/TLS key and certificate for client-authentication (default: nothing)
  #key: '/etc/ssl/mqtt-client.key'
  #cert: '/etc/ssl/mqtt-client.crt'
  # Optional: MQTT server authentication user (default: nothing)
  #user: my_user
  # Optional: MQTT server authentication password (default: nothing)
  #password: my_password
  # Optional: MQTT client ID (default: nothing)
  #client_id: 'MY_CLIENT_ID'
  # Optional: disable self-signed SSL certificates (default: true)
  reject_unauthorized: true
  # Optional: Include device information to mqtt messages (default: false)
  include_device_information: true
  # Optional: MQTT keepalive in seconds (default: 60)
  keepalive: 60
  # Optional: MQTT protocol version (default: 4), set this to 5 if you
  # use the 'retention' device specific configuration
  version: 4
  # Optional: Disable retain for all send messages. ONLY enable if you MQTT broker doesn't
  # support retained message (e.g. AWS IoT core, Azure IoT Hub, Google Cloud IoT core, IBM Watson IoT Platform).
  # Enabling will break the Home Assistant integration. (default: false)
  force_disable_retain: false

# Required: serial settings
serial:
  # Required: location of the adapter (e.g. CC2531).
  # To autodetect the port, set 'port: null'.
  #Maybe use /dev/ttyACM0 if autodetect fails
  port: null
  # Optional: disable LED of the adapter if supported (default: false)
  disable_led: false
  # Optional: adapter type, not needed unless you are experiencing problems (default: shown below, options: zstack, deconz)
  #adapter: null

# Optional: Block devices from the network (by ieeeAddr) (default: empty)
# Previously called 'ban' (which is deprecated)
#blocklist:
#  - '0x000b57fffec6a5b2'

# Optional: Allow only certain devices to join the network (by ieeeAddr)
# Note that all devices not on the passlist will be removed from the network!
# (default: empty)
# Previously called 'whitelist' (which is deprecated)
#passlist:
#  - '0x000b57fffec6a5b3'

# Optional: advanced settings
advanced:
  # Optional: ZigBee pan ID (default: shown below)
  # Setting pan_id: GENERATE will make Zigbee2MQTT generate a new panID on next startup
  pan_id: GENERATE
  # Optional: Zigbee extended pan ID (default: shown below)
  #ext_pan_id: [0xDD, 0xDD, 0xDD, 0xDD, 0xDD, 0xDD, 0xDD, 0xDD]
  # Optional: ZigBee channel, changing requires re-pairing of all devices. (Note: use a ZLL channel: 11, 15, 20, or 25 to avoid Problems)
  # (default: 11)
  channel: 11
  # Optional: state caching, MQTT message payload will contain all attributes, not only changed ones.
  # Has to be true when integrating via Home Assistant (default: true)
  cache_state: true
  # Optional: persist cached state, only used when cache_state: true (default: true)
  cache_state_persistent: false
  # Optional: send cached state on startup, only used when cache_state_persistent: true (default: true)
  cache_state_send_on_startup: false
  # Optional: Logging level, options: debug, info, warn, error (default: info)
  log_level: info
  # Optional: Location of log directory (default: shown below)
  log_directory: data/log/%TIMESTAMP%
  # Optional: Log file name, can also contain timestamp, e.g.: zigbee2mqtt_%TIMESTAMP%.log (default: shown below)
  log_file: log.txt
  # Optional: Log rotation (default: shown below)
  log_rotation: true
  # Optional: Output location of the log (default: shown below), leave empty to supress logging (log_output: [])
  # possible options: 'console', 'file', 'syslog'
  log_output:
    - console
  # Create a symlink called "current" in the log directory which points to the latests log directory. (default: false)
  log_symlink_current: false
  # Optional: syslog configuration, skip values or entirely to use defaults. Only use when 'syslog' in 'log_output' (see above)
  log_syslog:
    host: localhost # The host running syslogd, defaults to localhost.
    port: 123 # The port on the host that syslog is running on, defaults to syslogd's default port.
    protocol: tcp4 # The network protocol to log over (e.g. tcp4, udp4, tls4, unix, unix-connect, etc).
    path:  /dev/log # The path to the syslog dgram socket (i.e. /dev/log or /var/run/syslog for OS X).
    pid: process.pid # PID of the process that log messages are coming from (Default process.pid).
    facility: local0 # Syslog facility to use (Default: local0).
    localhost: localhost # Host to indicate that log messages are coming from (Default: localhost).
    type: "5424" # The type of the syslog protocol to use (Default: BSD, also valid: 5424).
    app_name: Zigbee2MQTT # The name of the application (Default: Zigbee2MQTT).
    eol: '\n' # The end of line character to be added to the end of the message (Default: Message without modifications).
  # Optional: Baud rate speed for serial port, this can be anything firmware support but default is 115200 for Z-Stack and EZSP, 38400 for Deconz, however note that some EZSP firmware need 57600.
  baudrate: 115200
  # Optional: RTS / CTS Hardware Flow Control for serial port (default: false)
  rtscts: false
  # Optional: soft reset ZNP after timeout (in seconds); 0 is disabled (default: 0)
  soft_reset_timeout: 0
  # Optional: network encryption key, will improve security (Note: changing requires repairing of all devices) (default: shown below)
  # Setting network_key: GENERATE will make Zigbee2MQTT generate a new network key on next startup
  network_key: GENERATE
  # Optional: Add a last_seen attribute to MQTT messages, contains date/time of last Zigbee message
  # possible values are: disable (default), ISO_8601, ISO_8601_local, epoch (default: disable)
  last_seen: 'disable'
  # Optional: Add an elapsed attribute to MQTT messages, contains milliseconds since the previous msg (default: false)
  elapsed: true
  # Optional: Availability timeout in seconds, disabled by default (0).
  # When enabled, devices will be checked if they are still online.
  # Only AC powered routers are checked for availability. (default: 0)
  availability_timeout: 0
  # Optional: Prevent devices from being checked for availability (default: empty)
  # Previously called 'availability_blacklist' (which is deprecated)
  #availability_blocklist:
  #  - DEVICE_FRIENDLY_NAME or DEVICE_IEEE_ADDRESS
  # Optional: Only enable availability check for certain devices (default: empty)
  # Previously called 'availability_whitelist' (which is deprecated)
  #availability_passlist:
  #  - DEVICE_FRIENDLY_NAME or DEVICE_IEEE_ADDRESS
  # Optional: Enables report feature, this feature is DEPRECATED since reporting is now setup by default
  # when binding devices. Docs can still be found here: https://github.com/Koenkk/zigbee2mqtt.io/blob/master/docs/information/report.md
  report: true
  # Optional: Home Assistant discovery topic (default: shown below)
  homeassistant_discovery_topic: 'homeassistant'
  # Optional: Home Assistant status topic (default: shown below)
  homeassistant_status_topic: 'homeassistant/status'
  # Optional: Home Assistant legacy triggers (default: shown below), when enabled:
  # - Zigbee2mqt will send an empty 'action' or 'click' after one has been send
  # - A 'sensor_action' and 'sensor_click' will be discoverd
  homeassistant_legacy_triggers: true
  # Optional: log timestamp format (default: shown below)
  timestamp_format: 'YYYY-MM-DD HH:mm:ss'
  # Optional: configure adapter concurrency (e.g. 2 for CC2531 or 16 for CC26X2R1) (default: null, uses recommended value)
  adapter_concurrent: null
  # Optional: disables the legacy api (default: shown below)
  legacy_api: true
  # Optional: use IKEA TRADFRI OTA test server, see OTA updates documentation (default: false)
  ikea_ota_use_test_url: false

# Optional: experimental options
experimental:
  # Optional: MQTT output type: json, attribute or attribute_and_json (default: shown below)
  # Examples when 'state' of a device is published
  # json: topic: 'zigbee2mqtt/my_bulb' payload '{"state": "ON"}'
  # attribute: topic 'zigbee2mqtt/my_bulb/state' payload 'ON"
  # attribute_and_json: both json and attribute (see above)
  output: 'json'
  # Optional: Transmit power setting in dBm (default: 5).
  # This will set the transmit power for devices that bring an inbuilt amplifier.
  # It can't go over the maximum of the respective hardware and might be limited
  # by firmware (for example to migrate heat, or by using an unsupported firmware).
  # For the CC2652R(B) this is 5 dBm, CC2652P/CC1352P-2 20 dBm.
  #transmit_power: 5

# Optional: networkmap options
map_options:
  graphviz:
    # Optional: Colors to be used in the graphviz network map (default: shown below)
    colors:
      fill:
        enddevice: '#fff8ce'
        coordinator: '#e04e5d'
        router: '#4ea3e0'
      font:
        coordinator: '#ffffff'
        router: '#ffffff'
        enddevice: '#000000'
      line:
        active: '#009900'
        inactive: '#994444'

# Optional: OTA update settings
ota:
    # Minimum time between OTA update checks, see https://www.zigbee2mqtt.io/information/ota_updates.html for more info
    update_check_interval: 1440
    # Disable automatic update checks, see https://www.zigbee2mqtt.io/information/ota_updates.html for more info
    disable_automatic_update_check: true

# Optional: see 'Device specific configuration' below
device_options: {}
# Optional, see 'External converters configuration' below
external_converters: []


frontend:
  port: 8003
  host: 0.0.0.0


EOF


sudo usermod -a -G audio daniel

# The allow any is needed or else rtkit won't let PipeWire work right.
cat << EOF > /usr/share/polkit-1/actions/org.freedesktop.RealtimeKit1.policy
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE policyconfig PUBLIC
        "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
        "http://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd">
<policyconfig>
        <vendor>Lennart Poettering</vendor>

        <action id="org.freedesktop.RealtimeKit1.acquire-high-priority">
                <description>Grant high priority scheduling to a user process</description>
                <description xml:lang="tr">Bir sürece yüksek öncelikli çalışabilme yetkisi ver</description>
                <message>Authentication is required to grant an application high priority scheduling</message>
                <message xml:lang="tr">Sürecin yüksek öncelikli çalıştırılabilmesi için yetki gerekiyor</message>
                <defaults>
                        <allow_any>yes</allow_any>
                        <allow_inactive>yes</allow_inactive>
                        <allow_active>yes</allow_active>
                </defaults>
        </action>

        <action id="org.freedesktop.RealtimeKit1.acquire-real-time">
                <description>Grant realtime scheduling to a user process</description>
                <description xml:lang="tr">Bir sürece gerçek zamanlı çalışabilme yetkisi ver</description>
                <message>Authentication is required to grant an application realtime scheduling</message>
                <message xml:lang="tr">Sürecin gerçek zamanlı çalıştırılabilmesi için yetki gerekiyor</message>
                <defaults>
                        <allow_any>yes</allow_any>
                        <allow_inactive>yes</allow_inactive>
                        <allow_active>yes</allow_active>
                </defaults>
        </action>

</policyconfig>
EOF



cat << EOF > /etc/security/limits.d/audio.conf 

# Provided by the jackd package.
#
# Changes to this file will be preserved.
#
# If you want to enable/disable realtime permissions, run
#
#    dpkg-reconfigure -p high jackd

@audio   -  rtprio     95
@audio   -  memlock    unlimited
@audio   -  nice      -15
EOF


# Here we turn on Pipewire


#No more of this
#apt-get -y install -y pulseaudio-module-jack pulseaudio-module-zeroconf pulsemixer 

#PipeWire

# To uninstall the old stuff you might need to try
# sudo apt purge  libpipewire-0.3-0 pipewire pipewire-bin libspa-0.2-modules

apt-get install -y pipewire libspa-0.2-jack pipewire-audio-client-libraries libspa-0.2-bluetooth 
apt-get remove -y pulseaudio-module-bluetooth 

! apt-get purge -y pipewire-media-session
apt-get -y install wireplumber


mkdir -p /etc/pipewire/media-session.d/
touch /etc/pipewire/media-session.d/with-pulseaudio

sudo touch /etc/pipewire/media-session.d/with-alsa
sudo cp /usr/share/doc/pipewire/examples/alsa.conf.d/99-pipewire-default.conf /etc/alsa/conf.d/

su -c 'XDG_RUNTIME_DIR="/run/user/$UID" DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus" systemctl --user  disable pulseaudio.socket' ember

su -c 'XDG_RUNTIME_DIR="/run/user/$UID" DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus" systemctl --user  disable pulseaudio.service' ember

# Can't get this to work. Leave it off and things will use the ALSA virtual device it makes.
su -c 'XDG_RUNTIME_DIR="/run/user/$UID" DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus" systemctl --user disable  pipewire-pulse' ember





su -c 'XDG_RUNTIME_DIR="/run/user/$UID" DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus" systemctl --user enable wireplumber' ember
su -c 'XDG_RUNTIME_DIR="/run/user/$UID" DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus" systemctl --user enable pipewire' ember

su -c 'XDG_RUNTIME_DIR="/run/user/$UID" DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus" systemctl --user mask pulseaudio' ember

mkdir -p /etc/pipewire/media-session.d/with
touch /etc/pipewire/media-session.d/with-jack
cp /usr/share/doc/pipewire/examples/ld.so.conf.d/pipewire-jack-*.conf /etc/ld.so.conf.d/
ldconfig



cat << EOF > /etc/pipewire/media-session.d/alsa-monitor.conf
# ALSA monitor config file #

properties = {
    # Create a JACK device. This is not enabled by default because
    # it requires that the PipeWire JACK replacement libraries are
    # not used by the session manager, in order to be able to
    # connect to the real JACK server.
    #alsa.jack-device = false

    # Reserve devices.
    #alsa.reserve = true
}

rules = [
    # An array of matches/actions to evaluate.
    {
        # Rules for matching a device or node. It is an array of
        # properties that all need to match the regexp. If any of the
        # matches work, the actions are executed for the object.
        matches = [
            {
                # This matches all cards. These are regular expressions
                # so "." matches one character and ".*" matches many.
                device.name = "~alsa_card.*"
            }
        ]
        actions = {
            # Actions can update properties on the matched object.
            update-props = {
                # Use ALSA-Card-Profile devices. They use UCM or
                # the profile configuration to configure the device
                # and mixer settings.
                api.alsa.use-acp = true

                # Use UCM instead of profile when available. Can be
                # disabled to skip trying to use the UCM profile.
                #api.alsa.use-ucm = true

                # Don't use the hardware mixer for volume control. It
                # will only use software volume. The mixer is still used
                # to mute unused paths based on the selected port.
                #api.alsa.soft-mixer = false

                # Ignore decibel settings of the driver. Can be used to
                # work around buggy drivers that report wrong values.
                #api.alsa.ignore-dB = false

                # The profile set to use for the device. Usually this
                # "default.conf" but can be changed with a udev rule
                # or here.
                #device.profile-set = "profileset-name"

                # The default active profile. Is by default set to "Off".
                #device.profile = "default profile name"

                # Automatically select the best profile. This is the
                # highest priority available profile. This is disabled
                # here and instead implemented in the session manager
                # where it can save and load previous preferences.
                api.acp.auto-profile = false

                # Automatically switch to the highest priority available
                # port. This is disabled here and implemented in the
                # session manager instead.
                api.acp.auto-port = false

                # Other properties can be set here.
                #device.nick = "My Device"
            }
        }
    }
    {
        matches = [
            {
                # Matches all sources. These are regular expressions
                # so "." matches one character and ".*" matches many.
                node.name = "~alsa_input.*"
            }
            {
                # Matches all sinks.
                node.name = "~alsa_output.*"
            }
        ]
        actions = {
            update-props = {
                #node.nick              = "My Node"
                #node.nick              = null
                #priority.driver        = 100
                #priority.session       = 100
                node.pause-on-idle      = false
                #resample.quality       = 4
                #channelmix.normalize   = false
                #channelmix.mix-lfe     = false
                #audio.channels         = 2
                #audio.format           = "S16LE"
                #audio.rate             = 44100
                #audio.position         = "FL,FR"
                api.alsa.period-size   = 256
                #api.alsa.headroom      = 0
                #api.alsa.disable-mmap  = false
                #api.alsa.disable-batch = false
                #api.alsa.use-chmap     = false
                #session.suspend-timeout-seconds = 5      # 0 disables suspend
            }
        }
    }
]

EOF

cat << EOF > /etc/pipewire/jack.conf

# JACK client config file for PipeWire version "0.3.24" #

context.properties = {
    ## Configure properties in the system.
    #mem.warn-mlock  = false
    #mem.allow-mlock = true
    #mem.mlock-all   = false
    log.level        = 0
}

context.spa-libs = {
    #<factory-name regex> = <library-name>
    #
    # Used to find spa factory names. It maps an spa factory name
    # regular expression to a library name that should contain
    # that factory.
    #
    support.* = support/libspa-support
}

context.modules = [
    #{   name = <module-name>
    #    [ args = { <key> = <value> ... } ]
    #    [ flags = [ [ ifexists ] [ nofail ] ]
    #}
    #
    # Loads a module with the given parameters.
    # If ifexists is given, the module is ignored when it is not found.
    # If nofail is given, module initialization failures are ignored.
    #
    #
    # Uses RTKit to boost the data thread priority.
    {   name = libpipewire-module-rtkit
        args = {
            #nice.level   = -11
            #rt.prio      = 88
            #rt.time.soft = 200000
            #rt.time.hard = 200000
        }
        flags = [ ifexists nofail ]
    }

    # The native communication protocol.
    {   name = libpipewire-module-protocol-native }

    # Allows creating nodes that run in the context of the
    # client. Is used by all clients that want to provide
    # data to PipeWire.
    {   name = libpipewire-module-client-node }

    # Allows applications to create metadata objects. It creates
    # a factory for Metadata objects.
    {   name = libpipewire-module-metadata }
]

jack.properties = {
     node.latency = 128/48000
     #jack.merge-monitor  = false
     #jack.short-name     = false
     #jack.filter-name    = false
}

EOF

cat << EOF > /etc/pipewire/media-session.d/bluez-monitor.conf
properties = {
    bluez5.msbc-support = true
    bluez5.sbc-xq-support = true
}
EOF



## Here we set up auto start kiosk stuff



# Xsession errors is a big offender for wrecking down your disk with writes
sed -i s/'ERRFILE=\$HOME\/\.xsession\-errors'/'ERRFILE\=\/var\/log\/\$USER\-xsession\-errors'/g /etc/X11/Xsession

cat << EOF > /etc/logrotate.d/xsession
/var/log/ember-xsession-errors {
  rotate 2 
  daily
  compress
  missingok
  notifempty
}
EOF

! rm  /home/ember/.xsession-errors
# Make it look like it's in the same place so we can get to it easily
ln -s /var/log/ember-xsession-errors /home/ember/.xsession-errors

mkdir -p /home/ember/.config/autostart/

cat << EOF > /home/ember/.config/autostart/kiosk.desktop
[Desktop Entry]
Name=EmberDefaultKiosk
Type=Application
Exec=/usr/bin/ember-kiosk-launch.sh http://localhost &
Terminal=false
EOF

sudo apt -y install unclutter

cat << EOF > /home/ember/.config/autostart/unclutter.desktop
[Desktop Entry]
Name=Unclutter
Type=Application
Exec=unclutter
Terminal=false
EOF


cat << 'EOF' >  /usr/bin/ember-kiosk-launch.sh
#!/bin/bash
mkdir -p /dev/shm/kiosk-temp-config
mkdir -p /dev/shm/kiosk-temp-cache
export XDG_CONFIG_HOME=/dev/shm/kiosk-temp-config
export XDG_CACHE_HOME=/dev/shm/kiosk-temp-cache
/usr/bin/chromium  --window-size=1920,1080 --start-fullscreen --kiosk --noerrdialogs --disable-translate --no-first-run --fast --fast-start --disable-infobars --disable-features=TranslateUI --autoplay-policy=no-user-gesture-required --no-default-browser-check --disk-cache-size=48000000 --no-first-run --simulate-outdated-no-au='Tue, 31 Dec 2099 23:59:59 GMT' $1
EOF


chmod 755 /usr/bin/ember-kiosk-launch.sh

cat << EOF >>  /etc/lightdm/lightdm.conf

[SeatDefaults]
autologin-guest=false
autologin-user=ember
autologin-user-timeout=0

EOF


## NetworkManager not suck

cat << EOF > /etc/NetworkManager/NetworkManager.conf
[main]
plugins=ifupdown,keyfile

[ifupdown]
managed=true

[device]
wifi.scan-rand-mac-address=no

[connection]
wifi.powersave = 2
EOF




apt-get -y install chrony

#Update timezones
apt-get -y install tzdata




cat << EOF > /etc/chrony/chrony.conf

# Welcome to the chrony configuration file. See chrony.conf(5) for more
# information about usuable directives.
pool 2.debian.pool.ntp.org iburst maxpoll 11

# Try three extremely common LAN addresses for the router, it might have an NTP server built in
# Which might be local and therefore preferable.  These addresses are safe-ish because they are almost always
# owned by the router/ap, not some other random device that could be another EmberOS node broadcasting false time.

# We also set minstratum 13 on them so it won't trust them.  Really this is kind of just a possible fallback.

server 192.168.0.1 maxpoll 11 minstratum 13
server 192.168.1.1 maxpoll 11 minstratum 13
server 10.0.0.1 maxpoll 11 minstratum 13

# Enable these if you are on the Yggrasil network and have no other time.
# Best to avoid it by default, they are hosted by individuals(nikat and mkb2191)

#server 202:a2a5:dead:ded:9a54:4ab5:6aa7:1645  maxpoll 12
#server 223:180a:b95f:6a53:5c70:e704:e9fc:8b8f  maxpoll 12

# Use this(Fill in your IP) if you have a hardware NTP server you trust
#server 192.168.0.15 iburst maxpoll 9 trust prefer


# This directive specify the location of the file containing ID/key pairs for
# NTP authentication.
keyfile /etc/chrony/chrony.keys

# This directive specify the file into which chronyd will store the rate
# information.
driftfile /var/lib/chrony/chrony.drift

# Uncomment the following line to turn logging on.
#log tracking measurements statistics

# Log files location.
logdir /var/log/chrony

# Stop bad estimates upsetting machine clock.
maxupdateskew 100.0

# This directive enables kernel synchronisation (every 11 minutes) of the
# real-time clock. Note that it can’t be used along with the 'rtcfile' directive.
rtcsync

# Step the system clock instead of slewing it if the adjustment is larger than
# one second, but only in the first three clock updates.
makestep 1 3

allow

# Local clock has to work

local stratum 14 orphan
EOF



mkdir -p /home/ember/kaithem
mkdir -p /home/ember/opt
git clone --depth 1 https://github.com/EternityForest/KaithemAutomation.git /home/ember/opt/KaithemAutomation



chown -R ember:ember /home/ember/kaithem
chmod -R 700 /home/ember/kaithem

chmod 755 /home/ember/opt/KaithemAutomation/kaithem/kaithem.py

chown -R ember:ember  /home/ember/opt/

cat << EOF >  /usr/bin/ember-launch-kaithem
#!/bin/bash
# Systemd utterly fails at launching this unless we give it it's own little script.
# If we run it directly from the service, jsonrpc times out over and over again.
/usr/bin/pw-jack /usr/bin/python3 /home/ember/opt/KaithemAutomation/kaithem/kaithem.py -c /home/ember/kaithem/config.yaml
EOF

chmod 755 /usr/bin/ember-launch-kaithem


mkdir -p    /home/ember/kaithem/system.mixer
cat << EOF >   /home/ember/kaithem/system.mixer/jacksettings.yaml
{jackDevice: '', jackMode: use, jackPeriodSize: 512, jackPeriods: 3, sharePulse: 'off',
  usbLatency: -1, usbPeriodSize: 512, usbPeriods: 3, usbQuality: 0, useAdditionalSoundcards: 'no'}
EOF


cat << EOF > /home/ember/kaithem/config.yaml
site-data-dir: ~/kaithem
ssl-dir: ~/kaithem/ssl
save-before-shutdown: yes
run-as-user: root
autosave-state: 2 hours
worker-threads: 16
http-thread-pool: 4
https-thread-pool: 16

#The port on which web pages will be served. The default port is 443, but we use 8001 in case you are running apache or something.
https-port : 8001
#The port on which unencrypted web pages will be served. The default port is 80, but we use 8001 in case you are running apache or something.
http-port : 8002

audio-paths:
    - /usr/share/tuxpaint/sounds
    - /usr/share/public.media/
    - __default__
EOF


cat << EOF > /etc/systemd/system/kaithem.service
[Unit]
Description=KaithemAutomation python based automation server
After=basic.target time-sync.target sysinit.service zigbee2mqtt.service pipewire.service
Type=simple


[Service]
TimeoutStartSec=0
ExecStart=/usr/bin/bash -o pipefail -c /usr/bin/ember-launch-kaithem
Restart=on-failure
RestartSec=15
OOMScoreAdjust=-800
Nice=-15
#Make it try to act like a GUI program if it can because some modules might
#make use of that.  Note that this is a bad hack hardcoding the UID.
#Pipewire breaks without it though.
Environment="DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u ember)/bus"
Environment="XDG_RUNTIME_DIR=/run/user/$(id -u ember)"

#This may cause some issues but I think it's a better way to go purely because of
#The fact that we can use PipeWire instead of managing jack, without any conflicts.

#Also, node red runs as pi/user$(id -u ember), lets stay standard.
User=$(id -u ember)
#Bluetooth scannning and many other things will need this
#Setting the system time is used for integration with GPS stuff.
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN CAP_NET_RAW CAP_SYS_TIME CAP_SYS_NICE
SecureBits=keep-caps

LimitRTPRIO= 95
LimitNICE= -20
LimitMEMLOCK= infinity

[Install]
WantedBy=multi-user.target
EOF


apt -y install mpv

systemctl enable kaithem.service

apt -y install python3 cython3 build-essential python3-msgpack python3-future 
apt -y install python3-serial  python3-tz  python3-dateutil  lm-sensors  python3-netifaces python3-jack-client  python3-gst-1.0  python3-libnacl  jack-tools  jackd2  gstreamer1.0-plugins-good  gstreamer1.0-plugins-bad  swh-plugins  tap-plugins  caps   gstreamer1.0-plugins-ugly  python3-psutil  fluidsynth libfluidsynth3  network-manager python3-paho-mqtt python3-dbus python3-lxml gstreamer1.0-pocketsphinx x42-plugins baresip autotalent libmpv-dev python3-dev  libbluetooth-dev libcap2-bin rtl-433  python3-toml  python3-rtmidi python3-pycryptodome  gstreamer1.0-opencv  gstreamer1.0-vaapi python3-pillow python3-scipy ffmpeg python3-skimage python3-evdev python3-xlib


# Hope at least 1 works!
! pip3 install https://github.com/hjonnala/snippets/blob/main/wheels/python3.10/tflite_runtime-2.5.0.post1-cp310-cp310-linux_x86_64.whl?raw=true
! python3 -m pip install tflite-runtime 


# node red
apt-get -y install -y fonts-hack
npm install -g --unsafe-perm node-red
npm install -g --unsafe-perm node-red-node-pi-gpio@latest node-red-node-random@latest node-red-node-ping@latest node-red-contrib-play-audio@latest node-red-node-smooth@latest node-red-node-serialport@latest


#This appears to be missing in the latest raspbian?
cat << EOF > /etc/systemd/system/nodered.service
# systemd service file to start Node-RED

[Unit]
Description=Node-RED graphical event wiring tool
Wants=network.target
Documentation=http://nodered.org/docs/hardware/raspberrypi.html

[Service]
Type=simple
# Run as normal pi user - change to the user name you wish to run Node-RED as
User=$(id -u ember)
Group=pi
WorkingDirectory=~

Environment="NODE_OPTIONS=--max_old_space_size=512"
# uncomment and edit next line if you need an http proxy
#Environment="HTTP_PROXY=my.httpproxy.server.address"
# uncomment the next line for a more verbose log output
#Environment="NODE_RED_OPTIONS=-v"
# uncomment next line if you need to wait for time sync before starting
#ExecStartPre=/bin/bash -c '/bin/journalctl -b -u systemd-timesyncd | /bin/grep -q "systemd-timesyncd.* Synchronized to time server"'


#Make it try to act like a GUI program if it can because some modules might
#make use of that.  Note that this is a bad hack hardcoding the UID.
#Pipewire breaks without it though.
Environment="DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u ember)/bus"
Environment="XDG_RUNTIME_DIR=/run/user/$(id -u ember)"

ExecStart=/usr/bin/pw-jack /usr/bin/env node-red $NODE_OPTIONS $NODE_RED_OPTIONS
#ExecStart=/usr/bin/env node $NODE_OPTIONS red.js $NODE_RED_OPTIONS
# Use SIGINT to stop
KillSignal=SIGINT
# Auto restart on crash
Restart=on-failure
RestartSec=20
# Tag things in the log
SyslogIdentifier=Node-RED
#StandardOutput=syslog


AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN CAP_NET_RAW CAP_SYS_TIME CAP_SYS_NICE
SecureBits=keep-caps

LimitRTPRIO= 95
LimitNICE= -20
LimitMEMLOCK= infinity


[Install]
WantedBy=multi-user.target

EOF


## Ok now we are gonna install some basic utilities


apt-get -y install deluge audacity vlc vlc-plugin-base vlc-plugin-access-extra vlc-plugin-jack vlc-plugin-skins2 vlc-plugin-svg
apt-get -y install mumble-server baresip twinkle 
sudo systemctl disable mumble-server.service
apt-get -y install mumble qtox gimp solaar



apt -y install gpsd 


apt-get -y install chkservice onboard kmag
apt-get -y install gnome-screenshot gnome-system-monitor gnome-logs
apt-get -y install nmap robotfindskitten ncdu mc curl fatrace gstreamer1.0-tools pavucontrol xawtv evince stegosuite unzip
apt-get -y install vim-tiny xcas units git wget htop lsof fzf chafa nast git-lfs git-repair xloadimage iotop zenity rename sshpass nethogs


# Gui and CLI tools for dealing with CDs and DVDs
apt-get -y install sound-juicer python3-cdio
apt-get -y install abcde --no-install-recommends
apt-get -y install glyrc imagemagick libdigest-sha-perl vorbis-tools atomicparsley eject eyed3 id3 id3v2 mkcue normalize-audio vorbisgain
apt-get -y install k3b

apt-get -y install gstreamer1.0-plugins-good gstreamer1.0-plugins-bad a2jmidid  jack-tools jack-stdio libgstreamer1.0-dev libgstrtspserver-1.0-0 gstreamer1.0-libav gstreamer1.0-pipewire
apt-get -y install swh-plugins tap-plugins caps  gstreamer1.0-plugins-ugly zynaddsubfx vmpk autotalent x42-plugins
apt-get -y install jaaa qjackctl ffmpeg

pip3 install ansible-core
pip3 install paramiko

apt-get -y install python3 systemd cython3 build-essential python3-serial cutecom xoscope sigrok sigrok-firmware-fx2lafw python3-matplotlib
apt-get -y install python3-pyqt5 python3-pyqt5.qtsvg python3-pyqt5.qtchart libinput-tools
apt-get -y install python3-tz python3-babel python3-boto3 python3-dateutil lm-sensors python3-lxml python3-six python3-requests avahi-discover python3-psutil backintime-qt4 python3-toml python3-hamlib


#This is a pregenerated block of randomness used to enhance the security of the randomness we generate at boot.
#This is really not needed, we generate enough at boot, but since we don't save any randomness at shutdown anymore,
#we might as well.

#Note that it is useless here because it is a fixed known thing, this was originally a script run directly on the pi.
#Kept fror consistency and because it still has very minor utility in confusing attacks by people who never find out which ember image
#you are running on, such as some odd HW backdoor that doesn't know about this
touch /etc/distro-random-supplement
chmod 700  /etc/distro-random-supplement
echo "Generating random numbers, this might be a while."


dd bs=1 count=128 if=/dev/random of=/etc/distro-random-supplement >/dev/null


# Even more paranoia, add a block of numbers that can be updated periodically by some later service or ansible job or some such.
touch /etc/random-supplement
chmod 700  /etc/random-supplement
echo "Generating random numbers, this might be a while."


dd bs=1 count=128 if=/dev/random of=/etc/random-supplement >/dev/null

echo "Generated random numbers"




cat << EOF > /etc/systemd/system/embedtools.service
[Unit]
Description=make systemd random seeding work, and whatever else needs to happen at boot for RO systems.
After=systemd-remount-fs.service
Before=sysinit.target nmbd.service smbd.service apache2.service systemd-logind.service
RequiresMountsFor=/etc/ /var/log/
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/usr/bin/embedtools_service.sh

[Install]
WantedBy=sysinit.target

EOF

cat << EOF > /usr/bin/embedtools_service.sh
#!/bin/bash

#Generate 32 real hardware random bytes, plus we use 32
#Saved random bytes. I'm pretty sure this is enough entropy.
#16 bytes alone should be totally fine if the algorithms are good,

#If a hw rng is available, we use 256 generated bytes and a block of fixed saved bytes just because we can
#And also because we should probably not completely trust the hw rng
set -e
set -x

cat  /etc/distro-random-supplement > /dev/random

# Check for any extra fixed random seed that could be there to further confuse a HW backdoor
if [ -f /etc/random-supplement ] ; then
cat  /etc/distro-random-supplement > /dev/random 
fi


#If the on chip hwrng isn't random, this might actually help if there is a real RTC installed.
date +%s%N > /dev/random


dd if=/dev/random of=/dev/random bs=32 count=1 > /dev/null


#HWRNG might have unpredictable timing, no reason not to use the timer again.
#Probably isn't helping much but maybe makes paranoid types feel better?
date +%s%N > /dev/random

#The RNG should already be well seeded, but the systemd thing needs to think its doing something
touch /var/lib/systemd/random-seed
chmod 700 /var/lib/systemd/random-seed
dd bs=1 count=32K if=/dev/urandom of=/var/lib/systemd/random-seed > /dev/null
touch /run/cprng-seeded




####Permissions on tmp dirs,something seems to mess it up

chmod 1777 /tmp 


###--------------------------------Apache shimming-----------------------------
#Only if var log is mounted a tmpfs.
if mount | grep "/var/log type tmpfs"; then

    if [ ! -d /var/log/apache ] ; then
        mkdir -p /var/log/apache
        touch /var/log/apache/access.log
        chmod 700 /var/log/apache/access.log
    fi

    if [ ! -d /var/log/apache2 ] ; then
        mkdir -p /var/log/apache2
        touch /var/log/apache2/access.log
        chmod 700 /var/log/apache2/access.log
    fi
fi


###--------------------------------Samba shimming-----------------------------
mkdir -p /tmp/samba
mkdir -p /tmp/cache
mkdir -p /tmp/cache/samba
mkdir -p /var/log/samba


## --------------------------- Morse shimming---------------------------------
#This has to exist, supervisord won't make it apparently. Not a fan!
mkdir -p /var/log/supervisor

# This also has to exist or systemd login thingy pitches a fit
mkdir -p /var/lib/systemd/linger
###-------------------------------Mosquitto shimming---------------------------
mkdir -p /var/log/mosquitto
#In case the user doesn't actually exist
! chown mosquitto /var/log/mosquitto


echo "Complete!"
EOF

chmod 755 /usr/bin/embedtools_service.sh
chown root /usr/bin/embedtools_service.sh
chmod 744 /etc/systemd/system/embedtools.service
chown root /etc/systemd/system/embedtools.service

systemctl enable embedtools.service





apt-get -y install apache2 

#Enable .htaccess
cat << 'EOF' > /etc/apache2/apache2.conf
# This is the main Apache server configuration file.  It contains the
# configuration directives that give the server its instructions.
# See http://httpd.apache.org/docs/2.4/ for detailed information about
# the directives and /usr/share/doc/apache2/README.Debian about Debian specific
# hints.
#
#
# Summary of how the Apache 2 configuration works in Debian:
# The Apache 2 web server configuration in Debian is quite different to
# upstream's suggested way to configure the web server. This is because Debian's
# default Apache2 installation attempts to make adding and removing modules,
# virtual hosts, and extra configuration directives as flexible as possible, in
# order to make automating the changes and administering the server as easy as
# possible.

# It is split into several files forming the configuration hierarchy outlined
# below, all located in the /etc/apache2/ directory:
#
#       /etc/apache2/
#       |-- apache2.conf
#       |       `--  ports.conf
#       |-- mods-enabled
#       |       |-- *.load
#       |       `-- *.conf
#       |-- conf-enabled
#       |       `-- *.conf
#       `-- sites-enabled
#               `-- *.conf
#
#
# * apache2.conf is the main configuration file (this file). It puts the pieces
#   together by including all remaining configuration files when starting up the
#   web server.
#
# * ports.conf is always included from the main configuration file. It is
#   supposed to determine listening ports for incoming connections which can be
#   customized anytime.
#
# * Configuration files in the mods-enabled/, conf-enabled/ and sites-enabled/
#   directories contain particular configuration snippets which manage modules,
#   global configuration fragments, or virtual host configurations,
#   respectively.
#
#   They are activated by symlinking available configuration files from their
#   respective *-available/ counterparts. These should be managed by using our
#   helpers a2enmod/a2dismod, a2ensite/a2dissite and a2enconf/a2disconf. See
#   their respective man pages for detailed information.
#
# * The binary is called apache2. Due to the use of environment variables, in
#   the default configuration, apache2 needs to be started/stopped with
#   /etc/init.d/apache2 or apache2ctl. Calling /usr/bin/apache2 directly will not
#   work with the default configuration.


# Global configuration
#

#
# ServerRoot: The top of the directory tree under which the server's
# configuration, error, and log files are kept.
#
# NOTE!  If you intend to place this on an NFS (or otherwise network)
# mounted filesystem then please read the Mutex documentation (available
# at <URL:http://httpd.apache.org/docs/2.4/mod/core.html#mutex>);
# you will save yourself a lot of trouble.
#
# Do NOT add a slash at the end of the directory path.
#
#ServerRoot "/etc/apache2"

#
# The accept serialization lock file MUST BE STORED ON A LOCAL DISK.
#
#Mutex file:${APACHE_LOCK_DIR} default

#
# The directory where shm and other runtime files will be stored.
#

DefaultRuntimeDir ${APACHE_RUN_DIR}

#
# PidFile: The file in which the server should record its process
# identification number when it starts.
# This needs to be set in /etc/apache2/envvars
#
PidFile ${APACHE_PID_FILE}

#
# Timeout: The number of seconds before receives and sends time out.
#
Timeout 300

#
# KeepAlive: Whether or not to allow persistent connections (more than
# one request per connection). Set to "Off" to deactivate.
#
KeepAlive On

#
# MaxKeepAliveRequests: The maximum number of requests to allow
# during a persistent connection. Set to 0 to allow an unlimited amount.
# We recommend you leave this number high, for maximum performance.
#
MaxKeepAliveRequests 100

#
# KeepAliveTimeout: Number of seconds to wait for the next request from the
# same client on the same connection.
#
KeepAliveTimeout 5


# These need to be set in /etc/apache2/envvars
User ${APACHE_RUN_USER}
Group ${APACHE_RUN_GROUP}

#
# HostnameLookups: Log the names of clients or just their IP addresses
# e.g., www.apache.org (on) or 204.62.129.132 (off).
# The default is off because it'd be overall better for the net if people
# had to knowingly turn this feature on, since enabling it means that
# each client request will result in AT LEAST one lookup request to the
# nameserver.
#
HostnameLookups Off

# ErrorLog: The location of the error log file.
# If you do not specify an ErrorLog directive within a <VirtualHost>
# container, error messages relating to that virtual host will be
# logged here.  If you *do* define an error logfile for a <VirtualHost>
# container, that host's errors will be logged there and not here.
#
ErrorLog ${APACHE_LOG_DIR}/error.log

#
# LogLevel: Control the severity of messages logged to the error_log.
# Available values: trace8, ..., trace1, debug, info, notice, warn,
# error, crit, alert, emerg.
# It is also possible to configure the log level for particular modules, e.g.
# "LogLevel info ssl:warn"
#
LogLevel warn

# Include module configuration:
IncludeOptional mods-enabled/*.load
IncludeOptional mods-enabled/*.conf

# Include list of ports to listen on
Include ports.conf


# Sets the default security model of the Apache2 HTTPD server. It does
# not allow access to the root filesystem outside of /usr/share and /var/www.
# The former is used by web applications packaged in Debian,
# the latter may be used for local directories served by the web server. If
# your system is serving content from a sub-directory in /srv you must allow
# access here, or in any related virtual host.
<Directory />
        Options FollowSymLinks
        AllowOverride None
        Require all denied
</Directory>

<Directory /usr/share>
        AllowOverride None
        Require all granted
</Directory>

<Directory /var/www/>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
</Directory>

#<Directory /srv/>
#       Options Indexes FollowSymLinks
#       AllowOverride None
#       Require all granted
#</Directory>




# AccessFileName: The name of the file to look for in each directory
# for additional configuration directives.  See also the AllowOverride
# directive.
#
AccessFileName .htaccess

#
# The following lines prevent .htaccess and .htpasswd files from being
# viewed by Web clients.
#
<FilesMatch "^\.ht">
        Require all denied
</FilesMatch>


#
# The following directives define some format nicknames for use with
# a CustomLog directive.
#
# These deviate from the Common Log Format definitions in that they use %O
# (the actual bytes sent including headers) instead of %b (the size of the
# requested file), because the latter makes it impossible to detect partial
# requests.
#
# Note that the use of %{X-Forwarded-For}i instead of %h is not recommended.
# Use mod_remoteip instead.
#
LogFormat "%v:%p %h %l %u %t \"%r\" %>s %O \"%{Referer}i\" \"%{User-Agent}i\"" vhost_combined
LogFormat "%h %l %u %t \"%r\" %>s %O \"%{Referer}i\" \"%{User-Agent}i\"" combined
LogFormat "%h %l %u %t \"%r\" %>s %O" common
LogFormat "%{Referer}i -> %U" referer
LogFormat "%{User-agent}i" agent

# Include of directories ignores editors' and dpkg's backup files,
# see README.Debian for details.

# Include generic snippets of statements
IncludeOptional conf-enabled/*.conf

# Include the virtual host configurations:
IncludeOptional sites-enabled/*.conf

# vim: syntax=apache ts=4 sw=4 sts=4 sr noet
EOF


cat << 'EOF' > /etc/apache2/sites-available/000-default.conf
<VirtualHost *:80>
        # The ServerName directive sets the request scheme, hostname and port that
        # the server uses to identify itself. This is used when creating
        # redirection URLs. In the context of virtual hosts, the ServerName
        # specifies what hostname must appear in the request's Host: header to
        # match this virtual host. For the default virtual host (this file) this
        # value is not decisive as it is used as a last resort host regardless.
        # However, you must set it for any further virtual host explicitly.
        #ServerName www.example.com

        ServerAdmin webmaster@localhost
        DocumentRoot /var/www/html

        # Available loglevels: trace8, ..., trace1, debug, info, notice, warn,
        # error, crit, alert, emerg.
        # It is also possible to configure the loglevel for particular
        # modules, e.g.
        #LogLevel info ssl:warn

        ErrorLog ${APACHE_LOG_DIR}/error.log
        CustomLog ${APACHE_LOG_DIR}/access.log combined

        # For most configuration files from conf-available/, which are
        # enabled or disabled at a global level, it is possible to
        # include a line for only one particular virtual host. For example the
        # following line enables the CGI configuration for this host only
        # after it has been globally disabled with "a2disconf".
        #Include conf-available/serve-cgi-bin.conf

        <Directory /var/www/>
                Options Indexes FollowSymLinks MultiViews
                AllowOverride All
                Order allow,deny
                allow from all
        </Directory>
</VirtualHost>

# vim: syntax=apache ts=4 sw=4 sts=4 sr noet
EOF

sudo apt-get install -y php-bcmath php-bz2 php-intl php-gd php-mbstring php-pgsql php-zip php-xml php-gd php-sqlite3 php-json


apt-get install libapache2-mod-php -y
#Needed for .htaccess
! a2enmod rewrite
! a2enmod php7.4

cat << EOF > /var/www/html/index.html

<h1 id="welcome-to-emberos">Welcome to Ember 64</h1>
<p>Ember X64</p>

<p>

Ember x64 is a kios script that turns Linux Mint or something similar into a home automation hub or kiosk display. It will probably work on any
debian of any architecture.

This file is at /var/www/html/index.html

</p>

<p>You can of course exit back to the desktop with Alt+F4.</p>


<dl>

<dt>Kaithem</dt>
<dd>Automation server on port 8002/ 8001 HTTPS</dd>

<dt>Zigbee2MQTT</dt>
<dd>Zigbee dongle manager on port 8003</dd>

</dl>

EOF

systemctl enable apache2.service



# Bye bye to the screen savier.
gsettings set org.gnome.desktop.screensaver lock-delay 3600
gsettings set org.gnome.desktop.screensaver lock-enabled false
gsettings set org.gnome.desktop.screensaver idle-activation-enabled false