#!/bin/bash

# Function to extract value from JSON using awk
# Arguments: JSON input, key to extract
extract_from_json() {
  echo "$1" | awk -v key="$2" '
    BEGIN {
      RS = "[},]";
      FS = "[:,]";
    }
    {
      for (i = 1; i <= NF; i += 2) {
        if ($i ~ "\"" key "\"") {
          gsub(/["{}]/, "", $(i + 1));
          gsub(/^[\t ]+|[\t ]+$/, "", $(i + 1));
          print $(i + 1);
          exit;
        }
      }
    }
  '
}

# Set the server URL as a variable
#jamfProURL="https://yourserver.jamfcloud.com"

###########or###############

# Prompt the user to select the server URL using AppleScript
jamfProURL=$(osascript <<EOD
set serverOptions to {"https://tamutest.jamfcloud.com", "https://tamu.jamfcloud.com"}
set chosenServer to choose from list serverOptions with title "Select Jamf Pro Server URL" with prompt "Choose the Jamf Pro server you want to use:" default items {"https://tamutest.jamfcloud.com"} without empty selection allowed

if chosenServer is false then
    return "EXIT"
else
    return item 1 of chosenServer
end if
EOD
)

# Check if the user chose to exit the script
if [ "$jamfProURL" = "EXIT" ]; then
    echo "No server selected. Script will now exit."
    exit 1
fi

# Prompt the user for Jamf Pro Username, Password, and Computer Serial Number using AppleScript
read -r -d '' applescriptCode <<EOD
display dialog "Enter your Jamf Pro Username:" default answer ""
set theUsername to text returned of result

display dialog "Enter your Jamf Pro Password:" default answer "" with hidden answer
set thePassword to text returned of result

display dialog "Enter the Computer Serial Number:" default answer ""
set theSerialNumber to text returned of result

return theUsername & "|" & thePassword & "|" & theSerialNumber
EOD

read -r jamfCredentialsAndSerial <<< $(osascript -e "$applescriptCode")

# Extract Jamf Pro Username, Password, and Computer Serial Number from the user input
username=$(echo "$jamfCredentialsAndSerial" | cut -d"|" -f1)
password=$(echo "$jamfCredentialsAndSerial" | cut -d"|" -f2)
COMPUTER_SERIAL=$(echo "$jamfCredentialsAndSerial" | cut -d"|" -f3)

# Request auth token
authToken=$( /usr/bin/curl \
--request POST \
--silent \
--url "$jamfProURL/api/v1/auth/token" \
--user "$username:$password" )

# Parse auth token
token=$( /usr/bin/plutil \
-extract token raw - <<< "$authToken" )

tokenExpiration=$( /usr/bin/plutil \
-extract expires raw - <<< "$authToken" )

localTokenExpirationEpoch=$( TZ=GMT /bin/date -j \
-f "%Y-%m-%dT%T" "$tokenExpiration" \
+"%s" 2> /dev/null )

# Send the API request to get the computer ID
response=$(curl -s -X GET \
  -H "Authorization: Bearer $token" \
  -H "Accept: application/xml" \
  "$jamfProURL/JSSResource/computers/serialnumber/$COMPUTER_SERIAL")

# Extract the computer ID based on the serial number from the response using xmllint and sed
computer_id=$(echo "$response" | xmllint --xpath 'string(/computer/general/id)' - | sed 's/[^0-9]*//g')

# Print the computer ID
#echo "Computer ID: $computer_id"

# Send API request to get the computer inventory details
response2=$(curl -s -X GET \
   -H "Authorization: Bearer $token" \
   -H "accept: application/json" \
   "$jamfProURL/api/v1/computers-inventory-detail/$computer_id")

# Extract the management ID from the response using awk
management_id=$(extract_from_json "$response2" "managementId")

# If the managementId is not directly in the top-level JSON object,
# try extracting from the "general" key
if [ -z "$management_id" ]; then
  management_id=$(extract_from_json "$response2" "general:managementId")
fi

# Print the management ID
#echo "Management ID: $management_id"

# Send API request to get the LAPS username
laps_username_response=$(curl -s -X GET \
   -H "Authorization: Bearer $token" \
   -H "accept: application/json" \
   "$jamfProURL/api/v2/local-admin-password/$management_id/accounts")

# Extract the LAPS username from the response using awk
laps_username=$(extract_from_json "$laps_username_response" "username")

# Print the LAPS username
#echo "LAPS Username: $laps_username"

# Send API request to get the LAPS password
laps_password_response=$(curl -s -X GET \
   -H "Authorization: Bearer $token" \
   -H "accept: application/json" \
   "$jamfProURL/api/v2/local-admin-password/$management_id/account/$laps_username/password")

# Extract the LAPS password from the response using awk
laps_password=$(extract_from_json "$laps_password_response" "password")

# Print the LAPS password
#echo "LAPS Password: $laps_password"

# Display LAPS Username and Password in an interactive dialog box
osascript <<EOD
display dialog "LAPS Username: $laps_username\nLAPS Password: $laps_password" with title "LAPS Credentials" buttons {"OK"} default button "OK" with icon note
EOD

# Expire auth token
/usr/bin/curl \
--header "Authorization: Bearer $token" \
--request POST \
--silent \
--url "$jamfProURL/api/v1/auth/invalidate-token"