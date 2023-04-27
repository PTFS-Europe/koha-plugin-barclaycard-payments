#!/bin/bash

echo "Creating and releasing .kpz file"

FILE=./koha-plugin-barclaycard-payments.kpz
if test -f "$FILE"; then
    echo "Plugin .kpz file already exists, previous version deleted"
    rm -r koha-plugin-barclaycard-payments.kpz
fi
echo "Creating new .kpz file"
zip -r koha-plugin-barclaycard-payments.kpz Koha/

NEW_VERSION=$(node checkVersionNumber.js)
NEW_VERSION_NUMBER=${NEW_VERSION:1}
PREVIOUS_VERSION=$(git log -1 --pretty=oneline | grep -E -o 'v.{0,4}')
PREVIOUS_VERSION_NUMBER=${PREVIOUS_VERSION:-1}
echo "New version: ${NEW_VERSION_NUMBER}"
echo "Previous version: ${PREVIOUS_VERSION_NUMBER}"

if [ $NEW_VERSION_NUMBER != $PREVIOUS_VERSION_NUMBER ]; then
    echo "Version has been updated - starting upload"
    git add .
    git commit -m "$NEW_VERSION"
    git push
    echo "Plugin has been pushed to Github and a release is being generated"
else
    echo "WARNING: The Plugin version needs to be updated - please check the .pm file and update the version"
fi
