#!/bin/bash

INPUT_FILE=$1

MAJOR_VERSION=`cat ../../major_version`
MINOR_VERSION=`cat ../../minor_version`
RELEASE_VERSION=`cat ../../release_version`

if [ "$RELEASE_VERSION" = "stable" ]
then
	RELEASE_VERSION=
fi

sed '
s/MAJOR_VERSION/'"$MAJOR_VERSION"'/
s/MINOR_VERSION/'"$MINOR_VERSION"'/
s/RELEASE_VERSION/'"$RELEASE_VERSION"'/
' <$INPUT_FILE
