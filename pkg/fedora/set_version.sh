#!/bin/bash

MAJOR_VERSION=`cat ../../major_version`
MINOR_VERSION=`cat ../../minor_version | sed 's/-/./'`

sed '
s/MAJOR_VERSION/'"$MAJOR_VERSION"'/
s/MINOR_VERSION/'"$MINOR_VERSION"'/
' <kadeploy.spec.in

