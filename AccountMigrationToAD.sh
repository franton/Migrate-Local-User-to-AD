#!/bin/bash

# Script to migrate local accounts to Active Directory accounts

# Author : <richard @ richard - purves dot com>

# Define variables here

export errorcode=0
export LocalAdminPW="$3"

export loggedinuser=$( python -c 'from SystemConfiguration import SCDynamicStoreCopyConsoleUser; import sys; username = (SCDynamicStoreCopyConsoleUser(None, None, None) or [None])[0]; username = [username,""][username in [u"loginwindow", None, u""]]; sys.stdout.write(username + "\n");' )

export cdialog="/usr/local/cs/bin/cocoaDialog.app"
export cdialogbin="${cdialog}/Contents/MacOS/cocoaDialog"

export icon="/usr/local/cs/imgs/cs.icns"

# Define functions here

CD()
{
	local type="$1"
	local text="$2"
	local title="$3"
	local title2="$4"
	local button1="$5"
	local button2="$6"
	local items="$7"

	case $type
		inputbox)
			"$cdialogbin" "$type" --title "$title" --informative-text "$title2" --text "$title" --icon-file "$icon" --string-output --float --button1 "$button1"
		;;
		msgbox)
			"$cdialogbin" "$type" --title "$title" --informative-text "$title2" --icon-file "$icon" --float --timeout 90 --button1 "$button1" --button2 "$button2"
		;;
		dropbox)
			"$cdialogbin" "type" --title "$title" --text "$text" --icon-file "$icon" --items "$items" --string-output --button1 "$button1"
		;;
		*)
			echo "Invalid CocoaDialog mode selected: $type"
		;;
	esac
}


AreWeADBound()
{
	adbound=$( /usr/bin/dscl localhost -list . | grep "Active Directory" )
	
	if [ "${check4AD}" != "Active Directory" ];
	then
		echo "This machine is not bound to Active Directory."
		adbound="no"
		errorcode=1
	else
		echo "Bound to Active Directory. Proceeding."
		adbound="yes"
	fi
	
	# Find the domain name here too
	domain=$( dsconfigad -show | grep "Active Directory Domain" | awk '{print substr ($0, index($0, $5)) }' )
}

DoLocalAccountsExist()
{
	accounts=$( dscl . list /Users UniqueID | awk '$2 > 500 && $2 < 1000 { print $1 }' )

	if [ "$accounts" = "" ]];
	then
		localaccounts="no"
	else
		localaccounts="yes"
	fi
}

LoggedIn()
{
	# Spawn process and proceed.

cat <<'EOF' >> /Library/LaunchAgent/com.cs.accountmigrate-bootstrap.plist
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.cs.accountmigrate-bootstrap</string>
	<key>RunAtLoad</key>
	<true/>
	<key>LimitLoadToSessionType</key>
	<string>LoginWindow</string>
	<key>ProgramArguments</key>
	<array>
        <string>/private/tmp/AccountMigrationToAd.sh</string>
        <string>'-bootstrap'</string>
	</array>
</dict>
</plist>
EOF

	chown root:wheel /Library/LaunchAgent/com.cs.accountmigrate-bootstrap.plist
	chmod 644 /Library/LaunchAgent/com.cs.accountmigrate-bootstrap.plist

	cp "$0" /private/tmp/AccountMigrationToAd.sh
	chown root:wheel /private/tmp/AccountMigrationToAd.sh
	chmod 700 /private/tmp/AccountMigrationToAd.sh

	# If user logged in, warn, quit all apps and logout for user.
	
	if [ "$loggedinuser" != "" ];
	then
		# Warn about closing apps and logging out
		local AllOk="false"
	
		while [ "$AllOk" = "false" ]
		do
			arewesure=$( CS "msgbox" "." "Computer needs to close all apps and logout" "Logout Warning" "Logout" )
			
			if [ "$arewesure" = "1" ];
			then
				AllOk="true"
			fi
		done
		
		# Kill all the apps and force a logout
		applist="$(sudo -u "$loggedinuser" osascript -e "tell application \"System Events\" to return displayed name of every application process whose (background only is false and displayed name is not \"Finder\")")"
		
		applistarray=$(echo "$applist" | sed -e 's/^/\"/' -e 's/$/\"/' -e 's/, /\" \"/g')
		eval set "$applistarray"
		for appname in "$@"
		do
			sudo -u "$loggedinuser" osascript -e "ignoring application responses" -e "tell application \"$appname\" to quit" -e "end ignoring"
		done
		
		osascript -e "ignoring application responses" -e "tell application \"loginwindow\" to $(printf \\xc2\\xab)event aevtrlgo$(printf \\xc2\\xbb)" -e "end ignoring"
	fi

}

SelectAccounts()
{
	username=$( CD "dropbox" "Select User Account" "Select User Account" "" "Ok" "" "$accounts" )
}

GetADAccountDetails()
{
	local AllOk="false"
	
	while [ "$AllOk" = "false" ]
	do
		adusername=$( CD "inputbox" "AD Account" "Please enter your AD Username:" "" "Ok" )
		adpassword=$( CD "inputbox" "AD Password" "Please enter your AD Password:" "" "Ok" )
	
		arewesure=$( CS "msgbox" "$adusername @adpassword" "Is this information correct?" "Warning" "Yes" "No" )
		
		if [ "$arewesure" = "1" ];
		then
			AllOk="true"
		fi
	done
}

CreateADAccount()
{
	# Make new user folder with correct permissions in /Users
	mkdir /Users/$adusername
	chown -R $adusername /Users/$adusername

	# Use an macOS command to create the mobile account user record
	/System/Library/CoreServices/ManagedClient.app/Contents/Resources/createmobileaccount –v –P –n $adusername

	# The user home folder we created will be totally blank. Get the OS to copy from the User Template.
	# Start by deleting the folder we just created (!) then using another OS tool to do the work.
	rm -r /Users/$adusername
	createhomedir -c -u $adusername
}

MigrateAccount()
{
	# Move existing user data
	mv -f /Users/$username/ /Users/$adusername/

	# Fix new user folder permissions

	chown -R $username:"$domain\Domain Users" /Users/$username
	chmod 755 /Users/$username
	chmod -R 700 /Users/$username/Desktop/
	chmod -R 700 /Users/$username/Documents/
	chmod -R 700 /Users/$username/Downloads/
	chmod -R 700 /Users/$username/Library/
	chmod -R 700 /Users/$username/Movies/
	chmod -R 700 /Users/$username/Pictures/
	chmod 755 /Users/$username/Public/
	chmod -R 733 /Users/$username/Public/Drop\ Box/

	# Delete original account
	/usr/bin/dscl . -delete "/Users/$username"
	rm -rf /Users/$username

	# Add new user to FileVault 2
	fdesetup add -usertoadd $adusername
	
	/usr/bin/expect <<EOF
	expect "Enter a password for '/', or the recovery key:"
	send "$LocalAdminPW\r"
	expect "Enter the password for the added user '$aduser':"
	send "$adpassword\r"
	EOF
	
}

CleanUpBootstrap()
{
	srm /Library/LaunchAgent/com.cs.accountmigrate-bootstrap.plist
	srm /private/tmp/AccountMigrationToAd.sh
}

Reboot()
{
	reboot
}

# Main code here

AreWeADBound

if [ "$adbound" = "yes" ];
then
	DoLocalAccountsExist

	if [ "$localaccounts" = "yes" ];
	then
		LoggedIn
		SelectAccounts
		GetADAccountDetails
		CreateADAccount
		MigrateAccount
		CleanUpBootstrap
		Reboot
	fi
fi

# All Done!
exit $errorcode