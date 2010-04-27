# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2010
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

class FetchFileError
  NO_ERROR = 0
  INVALID_ENVIRONMENT_TARBALL = 1
  INVALID_PREINSTALL = 2
  PREINSTALL_TOO_BIG = 3
  INVALID_POSTINSTALL = 4
  POSTINSTALL_TOO_BIG = 5
  INVALID_KEY = 6
  INVALID_CUSTOM_FILE = 7
  INVALID_PXE_FILE = 8
end
