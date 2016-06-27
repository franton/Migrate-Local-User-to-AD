#!/bin/bash

# Script to migrate local accounts to Active Directory accounts

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

	case $type in
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
			/bin/echo "Invalid CocoaDialog mode selected: $type"
		;;
	esac
}


AreWeADBound()
{
	adbound=$( /usr/bin/dscl localhost -list . | grep "Active Directory" )
	
	if [ "${adbound}" != "Active Directory" ];
	then
		/bin/echo "This machine is not bound to Active Directory."
		adbound="no"
		errorcode=1
	else
		/bin/echo "Bound to Active Directory. Proceeding."
		adbound="yes"
	fi
	
	# Find the domain name here too
	domain=$( /usr/sbin/dsconfigad -show | grep "Active Directory Domain" | awk '{print substr ($0, index($0, $5)) }' )
}

DoLocalAccountsExist()
{
	accounts=$( /usr/bin/dscl . list /Users UniqueID | awk '$2 > 500 && $2 < 1000 { print $1 }' )

	if [ "$accounts" = "" ];
	then
		localaccounts="no"
	else
		localaccounts="yes"
	fi
}

LoggedIn()
{
	# Spawn process and proceed.

cat <<'EOF' >> /Library/LaunchAgents/com.cs.accountmigrate-bootstrap.plist
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
	</array>
</dict>
</plist>
EOF

	/usr/sbin/chown root:wheel /Library/LaunchAgents/com.cs.accountmigrate-bootstrap.plist
	/bin/chmod 644 /Library/LaunchAgents/com.cs.accountmigrate-bootstrap.plist

	cp "$0" /private/tmp/AccountMigrationToAd.sh
	/usr/sbin/chown root:wheel /private/tmp/AccountMigrationToAd.sh
	/bin/chmod 700 /private/tmp/AccountMigrationToAd.sh

	# If user logged in, warn, quit all apps and logout for user.
	
	if [ "$loggedinuser" != "" ];
	then
		# Warn about closing apps and logging out
		local AllOk="false"
	
		while [ "$AllOk" = "false" ]
		do
			arewesure=$( CD "msgbox" "." "Computer needs to close all apps and logout" "Logout Warning" "Logout" )
			
			if [ "$arewesure" = "1" ];
			then
				AllOk="true"
			fi
		done
		
		# Kill all the apps and force a logout
		applist="$(/usr/bin/sudo -u "$loggedinuser" osascript -e "tell application \"System Events\" to return displayed name of every application process whose (background only is false and displayed name is not \"Finder\")")"
		
		applistarray=$(/bin/echo "$applist" | sed -e 's/^/\"/' -e 's/$/\"/' -e 's/, /\" \"/g')
		eval set "$applistarray"
		for appname in "$@"
		do
			/usr/bin/sudo -u "$loggedinuser" osascript -e "ignoring application responses" -e "tell application \"$appname\" to quit" -e "end ignoring"
		done
		
		/usr/sbin/osascript -e "ignoring application responses" -e "tell application \"loginwindow\" to $(printf \\xc2\\xab)event aevtrlgo$(printf \\xc2\\xbb)" -e "end ignoring"
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
	
		arewesure=$( CD "msgbox" "$adusername @adpassword" "Is this information correct?" "Warning" "Yes" "No" )
		
		if [ "$arewesure" = "1" ];
		then
			AllOk="true"
		fi
	done
}

CreateADAccount()
{
	# Make new user folder with correct permissions in /Users
	/bin/mkdir /Users/$adusername
	/usr/sbin/chown -R $adusername /Users/$adusername

	# Use an macOS command to create the mobile account user record
	/System/Library/CoreServices/ManagedClient.app/Contents/Resources/createmobileaccount –v –P –n $adusername

	# The user home folder we created will be totally blank. Get the OS to copy from the User Template.
	# Start by deleting the folder we just created (!) then using another OS tool to do the work.
	/bin/rm -r /Users/$adusername
	/usr/sbin/createhomedir -c -u $adusername
}

MigrateAccount()
{
	# Move existing user data
	/bin/mv -f /Users/$username/ /Users/$adusername/

	# Fix new user folder permissions

	/usr/sbin/chown -R $adusername:"$domain\Domain Users" /Users/$adusername
	/bin/chmod 755 /Users/$username
	/bin/chmod -R 700 /Users/$adusername/Desktop/
	/bin/chmod -R 700 /Users/$adusername/Documents/
	/bin/chmod -R 700 /Users/$adusername/Downloads/
	/bin/chmod -R 700 /Users/$adusername/Library/
	/bin/chmod -R 700 /Users/$adusername/Movies/
	/bin/chmod -R 700 /Users/$adusername/Pictures/
	/bin/chmod 755 /Users/$adusername/Public/
	/bin/chmod -R 733 /Users/$adusername/Public/Drop\ Box/

	# Delete original account
	/usr/bin/dscl . -delete "/Users/$username"
	/bin/rm -rf /Users/$username

	# Add new user to FileVault 2
	/usr/bin/fdesetup add -usertoadd $adusername
	
	/usr/bin/expect << EOF
	expect "Enter a password for '/', or the recovery key:"
	send "$LocalAdminPW\r"
	expect "Enter the password for the added user '$aduser':"
	send "$adpassword\r"
	EOF

}

CleanUpBootstrap()
{
	/usr/bin/srm /Library/LaunchAgent/com.cs.accountmigrate-bootstrap.plist
	/usr/bin/srm /private/tmp/AccountMigrationToAd.sh
}

Reboot()
{
	/sbin/reboot
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