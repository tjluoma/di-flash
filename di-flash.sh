#!/bin/zsh -f
# Purpose: download and install (or update, if needed) Flash for OS X
# Adapted from http://oit.ncsu.edu/macintosh/adobe-flash-os-x-unattended-silent-install
#
# From:	Tj Luo.ma
# Mail:	luomat at gmail dot com
# Web: 	http://RhymesWithDiploma.com
# Date:	2015-12-10

PATH=/usr/local/bin:/usr/bin:/usr/sbin:/sbin:/bin

################################################################################################################
#
#

NAME="$0:t:r"

zmodload zsh/datetime	# needed for EPOCHSECONDS

zmodload zsh/stat		# needed for file size

TIME=$(strftime "%Y-%m-%d-at-%H.%M.%S" "$EPOCHSECONDS")

function timestamp { strftime "%Y-%m-%d--%H.%M.%S" "$EPOCHSECONDS" }

LOG="/var/log/$NAME/$TIME.log"

[[ -d "$LOG:h" ]] || mkdir -p "$LOG:h"
[[ -e "$LOG" ]]   || touch "$LOG"

function timestamp { strftime "%Y-%m-%d at %H:%M:%S" "$EPOCHSECONDS" }

function log { echo "$NAME @ `timestamp`: $@ " | tee -a "$LOG" }

##################################################################################################################################

if [[ "$EUID" != "0" ]]
then
	log "Must be run as root. EUID = $EUID"

	exit 1
fi

##################################################################################################################################

CFG="/Library/Application Support/Macromedia/mms.cfg"

if [[ ! -e "$CFG" ]]
then

TMPFILE=`mktemp /tmp/$NAME.XXXXXXX`

cat <<EOINPUT > "$TMPFILE"
AutoUpdateDisable=0
SilentAutoUpdateEnable=1
AutoUpdateInterval=1
DisableProductDownload=0
SilentAutoUpdateVerboseLogging=0
EOINPUT

	# Create directory if needed
[[ ! -d "$CFG:h" ]] \
	&& mkdir -p "$CFG:h" \
		&& log "Created directory: $CFG:h"

mv -vf "$TMPFILE" "$CFG" \
	&& chmod 644 "$CFG" \
		&& chown root:wheel "$CFG" \
			&& log "Created $CFG (chmod 644/chown root)"

fi

################################################################################################################
#
#	Check current version on website
#

LATEST_VERSION=`curl --silent --fail --location \
	'http://fpdownload2.macromedia.com/get/flashplayer/update/current/xml/version_en_mac_pl.xml' \
| awk -F'"' '/version=/{print $2}' \
| tr ',' '.'`

if [[ "$LATEST_VERSION" = "" ]]
then
	log "LATEST_VERSION is empty"
	exit 0
fi

################################################################################################################
#
#	Check local (installed version) if any
#

PLIST='/Library/Internet Plug-Ins/Flash Player.plugin/Contents/version.plist'

if [[ -e "$PLIST" ]]
then
		# if the plist is installed, check the version number
	INSTALLED_VERSION=`defaults read "$PLIST" CFBundleShortVersionString`

	autoload is-at-least

	is-at-least "$LATEST_VERSION" "$INSTALLED_VERSION"

	if [ "$?" = "0" ]
	then
		log "Up-To-Date (Installed = $INSTALLED_VERSION vs Latest = $LATEST_VERSION)"
		exit 0
	fi

else
	INSTALLED_VERSION=""
fi

################################################################################################################
#
#	Define function for later
#
function do_download
{
	REMOTE_SIZE=`curl -sfL --head "${PKG_URL}" | awk -F' ' '/Content-Length:/{print $NF}' | tr -dc '[0-9]'`

	if [ "$REMOTE_SIZE" = "" ]
	then
		log "Failed to get Content-Length for $PKG_URL"
		exit 0
	fi

	if [ -e "$FILENAME" ]
	then
		log "Continuing download of $PKG_URL to $FILENAME"
			# if the file is already there, continue download
		curl -fL --progress-bar --continue-at - --output "$FILENAME" "$PKG_URL"
	else
		log "Downloading $PKG_URL to $FILENAME"
			# if the file is NOT there, don't try to continue
		curl -fL --progress-bar --output "$FILENAME" "$PKG_URL"
	fi

	SIZE=$(zstat -L +size "$FILENAME")

	if [ "$SIZE" != "$REMOTE_SIZE" ]
	then
		log "Download of $PKG_URL to $FILENAME failed. File size mismatch: expected $REMOTE_SIZE, have $SIZE"
		exit 0
	fi
}

	##################################################################################################################################
	#
	#	If we get here we need to download/install new version
	#

if [[ "$INSTALLED_VERSION" == "" ]]
then
	log "Installing $LATEST_VERSION"
else
	log "Updating to $LATEST_VERSION from $INSTALLED_VERSION"
fi

MAJOR_VERSION=`echo "$LATEST_VERSION" | cut -d . -f 1`

PKG_URL="https://fpdownload.macromedia.com/get/flashplayer/current/licensing/mac/install_flash_player_${MAJOR_VERSION}_osx_pkg.dmg"

HTTP_STATUS=`curl -sfL --head "$PKG_URL" | awk -F' ' '/^HTTP/{print $2}'`

if [[ "$HTTP_STATUS" != "200" ]]
then
		# If we don't get anything, we can't proceed.
		# This is probably an indication that PKG_URL needs to be verified as still correct
	log "HTTP_STATUS for $PKG_URL is $HTTP_STATUS"
	exit 0
fi

TEMPDIR=`mktemp -d /tmp/$NAME.XXXXXXXXX`

FILENAME="${TEMPDIR}/FlashPlayer-$LATEST_VERSION.dmg"

	# This is where we do the download (if it isn't already downloaded)
if [[ -s "$FILENAME" ]]
then
	SIZE=$(zstat -L +size "$FILENAME")

	if [[ "$SIZE" == "$REMOTE_SIZE" ]]
	then
		log "$FILENAME is already completely downloaded"
	else
		do_download
	fi
else
	do_download
fi

####|####|####|####|####|####|####|####|####|####|####|####|####|####|####
#
#		This is where we mount the DMG we have downloaded
#

MNTPNT=$(hdiutil attach -nobrowse -noverify -noautoopen -plist "$FILENAME" 2>/dev/null \
		| fgrep -A 1 '<key>mount-point</key>' \
		| tail -1 \
		| sed 's#</string>.*##g ; s#.*<string>##g')

if [[ "$MNTPNT" = "" ]]
then
	log "MNTPNT is empty. $FILENAME failed to mount, so it will be deleted"
	rm -f "$FILENAME"
	exit 0
fi

	# This is where we look for the .pkg file in the mounted DMG
PKG=`find "$MNTPNT" -iname \*.pkg -maxdepth 1 -print`

if [[ "$PKG" = "" ]]
then
	log "PKG is empty"
	exit 1
fi

installer -pkg "$PKG" -target / -lang en 2>&1 | tee -a "$LOG"

EXIT="$?"

if [ "$EXIT" != "0" ]
then

	log "Installation failed. Exit code = $EXIT"

	exit 0
fi

##################################################################################################################################
#
# If we get here, installation succeeded

if (( $+commands[po.sh] ))
then

	if [[ "$INSTALLED_VERSION" == "" ]]
	then
		log "Installed $LATEST_VERSION"
		po.sh "$NAME: Installed $LATEST_VERSION"
	else
		log "Updated to $LATEST_VERSION from $INSTALLED_VERSION"
		po.sh "$NAME: Updated to $LATEST_VERSION from $INSTALLED_VERSION"
	fi
fi

##################################################################################################################################

MAX_ATTEMPTS="10"

SECONDS_BETWEEN_ATTEMPTS="5"

	# strip away anything that isn't a 0-9 digit
SECONDS_BETWEEN_ATTEMPTS=$(echo "$SECONDS_BETWEEN_ATTEMPTS" | tr -dc '[0-9]')

MAX_ATTEMPTS=$(echo "$MAX_ATTEMPTS" | tr -dc '[0-9]')

	# initialize the counter
COUNT=0

	# NOTE this 'while' loop can be changed to something else
while [[ -d "$MNTPNT" ]]
do
		# increment counter (this is why we init to 0 not 1)
	((COUNT++))

		# check to see if we have exceeded maximum attempts
	if [ "$COUNT" -gt "$MAX_ATTEMPTS" ]
	then
		log "Exceeded $MAX_ATTEMPTS"
		exit 0
	fi

		# don't sleep the first time through the loop
	[[ "$COUNT" != "1" ]] && sleep ${SECONDS_BETWEEN_ATTEMPTS}

		# eject the DMG (or at least try)
	diskutil eject "${MNTPNT}" 2>&1 | tee -a "${LOG}"

done

##################################################################################################################################

ADOBE_PLIST='/Library/LaunchDaemons/com.adobe.fpsaud.plist'

if [ -e "$ADOBE_PLIST" ]
then

		## How often do you want to check for updates?
		# 86400 = 24 hours
		# 21600 =  6 hours
		#  3600 =  1 hour
	RUN_SECONDS='21600'

	INTERVAL=`defaults read "$ADOBE_PLIST" StartInterval 2>/dev/null`

	if [ "$INTERVAL" != "$RUN_SECONDS" ]
	then
			# run every 6 hours (21600)
		defaults write "$ADOBE_PLIST" StartInterval -integer ${RUN_SECONDS}
		
		chmod 644 "$ADOBE_PLIST"
		
		chown root:wheel "$ADOBE_PLIST"
	fi
fi

exit 0
#
#EOF
##################################################################################################################################
