#!/bin/bash

MAJOR_VERSION=`cat ../../major_version`
MINOR_VERSION=`cat ../../minor_version`
RELEASE_VERSION=`cat ../../release_version`

case "$RELEASE_VERSION" in
	git)
		RELEASE_VERSION=$(git log --pretty=format:'%H' -n 1)git
	;;
esac
: ${RELEASE_VERSION:="stable"}


sed '
s/MAJOR_VERSION/'"$MAJOR_VERSION"'/
s/MINOR_VERSION/'"$MINOR_VERSION"'/
s/RELEASE_VERSION/'"$RELEASE_VERSION"'/
' <kadeploy.spec.in

