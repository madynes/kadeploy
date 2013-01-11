# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2011
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

class KadeployError < Exception
  attr_reader :errno, :context
  def initialize(errno,context={})
    super('')
    @errno = errno
    @context = context
  end
end

class TempfileException < RuntimeError
end

class MoveException < RuntimeError
end

class FetchFileError
  NO_ERROR = 100
  INVALID_ENVIRONMENT_TARBALL = 101
  INVALID_PREINSTALL = 102
  PREINSTALL_TOO_BIG = 103
  INVALID_POSTINSTALL = 104
  POSTINSTALL_TOO_BIG = 105
  INVALID_KEY = 106
  INVALID_CUSTOM_FILE = 107
  INVALID_PXE_FILE = 108
  TEMPFILE_CANNOT_BE_CREATED_IN_CACHE = 109
  FILE_CANNOT_BE_MOVED_IN_CACHE = 110
end

class KadeployAsyncError
  NO_ERROR = 200
  NODES_DISCARDED = 201
  NO_RIGHT_TO_DEPLOY = 202
  UNKNOWN_NODE_IN_SINGULARITY_FILE = 203
  NODE_NOT_EXIST = 204
  VLAN_MGMT_DISABLED = 205
  LOAD_ENV_FROM_FILE_ERROR = 206
  LOAD_ENV_FROM_DB_ERROR = 207
  NO_ENV_CHOSEN = 208
  CONFLICTING_OPTIONS = 209

  def self.to_msg(errno)
    case errno
    when NODES_DISCARDED
      "All the nodes have been discarded"
    when NO_RIGHT_TO_DEPLOY
      "Invalid options or invalid rights on nodes"
    when UNKNOWN_NODE_IN_SINGULARITY_FILE
      "Unknown node in singularity file"
    when NODE_NOT_EXIST
      "At least one node in your node list does not exist"
    when VLAN_MGMT_DISABLED
      "The VLAN management has been disabled on the site"
    when LOAD_ENV_FROM_FILE_ERROR
      "The environment cannot be loaded from the file you specified"
    when LOAD_ENV_FROM_DB_ERROR
      "The environment does not exist"
    when NO_ENV_CHOSEN
      "You must choose an environment"
    when CONFLICTING_OPTIONS
      "Some options are conflicting"
    else
      ""
    end
  end
end

class KarebootAsyncError
  NO_ERROR = 300
  REBOOT_FAILED_ON_SOME_NODES = 301
  DEMOLISHING_ENV = 302
  PXE_FILE_FETCH_ERROR = 303
  NO_RIGHT_TO_DEPLOY = 304
  UNKNOWN_NODE_IN_SINGULARITY_FILE = 305
  NODE_NOT_EXIST = 306
  VLAN_MGMT_DISABLED = 307
  LOAD_ENV_FROM_DB_ERROR = 308
end

class KapowerAsyncError
  NO_ERROR = 300
end
