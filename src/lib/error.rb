# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2011
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

class KadeployError < Exception
  attr_reader :errno, :context
  attr_writer :context
  def initialize(errno,context={},msg='')
    super(msg)
    @errno = errno
    @context = context
  end

  def self.to_msg(errno)
    case errno
    when APIError::BAD_CONFIGURATION
      "Error in configuration files"
    when APIError::INVALID_CONTENT_TYPE
      "Invalid Content-Type in HTTP request"
    when APIError::HTTP_METHOD_NOT_SUPPORTED
      "HTTP method not supported on this path"
    when APIError::INVALID_WORKFLOW_ID
      "Invalid workflow ID"
    when APIError::NO_USER
      "No user specified"
    when APIError::INVALID_NODELIST
      "Invalid node list"
    when APIError::INVALID_ENVIRONMENT
      "Invalid environment specification"
    when APIError::INVALID_CLIENT
      "Invalid client"
    when APIError::INVALID_CONTENT
      "Invalid Content in HTTP request"
    when APIError::EXISTING_ELEMENT
      "Element already exists"
    when APIError::CONFLICTING_ELEMENTS
      "Some elements already exists and are conflicting"
    when APIError::NOTHING_MODIFIED
      "Unexpected error, no element was modified"
    when APIError::DATABASE_ERROR
      "Database issue"
    when KadeployError::NODES_DISCARDED
      "All the nodes have been discarded"
    when KadeployError::NO_RIGHT_TO_DEPLOY
      "Invalid options or invalid rights on nodes"
    when KadeployError::UNKNOWN_NODE_IN_SINGULARITY_FILE
      "Unknown node in singularity file"
    when KadeployError::NODE_NOT_EXIST
      "At least one node in your node list does not exist"
    when KadeployError::VLAN_MGMT_DISABLED
      "The VLAN management has been disabled on the site"
    when KadeployError::LOAD_ENV_FROM_DESC_ERROR
      "The environment cannot be loaded from the description you specified"
    when KadeployError::LOAD_ENV_FROM_DB_ERROR
      "The environment does not exist"
    when KadeployError::NO_ENV_CHOSEN
      "You must choose an environment"
    when KadeployError::CONFLICTING_OPTIONS
      "Some options are conflicting"
    when KadeployError::DB_ERROR
      "Database issue"
    when KadeployError::EXECUTE_ERROR
      "The execution of a command failed"
    when FetchFileError::INVALID_ENVIRONMENT_TARBALL
      "Invalid environment image archive"
    when FetchFileError::INVALID_PREINSTALL
      "Invalid environment preinstall"
    when FetchFileError::PREINSTALL_TOO_BIG
      "Environment's preinstall archive is too big"
    when FetchFileError::INVALID_POSTINSTALL
      "Invalid environment postinstall"
    when FetchFileError::POSTINSTALL_TOO_BIG
      "Environment's postinstall archive is too big"
    when FetchFileError::INVALID_KEY
      "Invalid key file"
    when FetchFileError::INVALID_CUSTOM_FILE
      "Invalid custom file"
    when FetchFileError::INVALID_PXE_FILE
      "Invalid PXE file"
    when FetchFileError::TEMPFILE_CANNOT_BE_CREATED_IN_CACHE
      "Tempfile creation failed"
    when FetchFileError::FILE_CANNOT_BE_MOVED_IN_CACHE
      "File cannot be moved in cache"
    when FetchFileError::CACHE_FILE_TOO_BIG
      "File is too big for the cache"
    when FetchFileError::INVALID_MD5
      "Invalid checksum"
    when FetchFileError::CACHE_INTERNAL_ERROR
      "Internal cache error"
    when FetchFileError::CACHE_FULL
      "The cache is full"
    when FetchFileError::UNKNOWN_PROTOCOL
      "Unknown protocol"
    when KarebootError::REBOOT_FAILED_ON_SOME_NODES
      "Reboot failed on some nodes"
    when KarebootError::DEMOLISHING_ENV
      "Cannot reboot since the nodes have been previously deployed with a demolishinf environment"
    when KarebootError::PXE_FILE_FETCH_ERROR
      "Some PXE files cannot be fetched"
    when KarebootError::NO_RIGHT_TO_DEPLOY
      "You do not have the right to deploy on all the nodes"
    when KarebootError::UNKNOWN_NODE_IN_SINGULARITY_FILE
      "Unknown node in singularity file"
    when KarebootError::NODE_NOT_EXIST
      "At least one node in your node list does not exist"
    when KarebootError::VLAN_MGMT_DISABLED
      "The VLAN management has been disabled on the site"
    when KarebootError::LOAD_ENV_FROM_DB_ERROR
      "The environment does not exist"
    else
      ""
    end
  end
end

class KadeployHTTPError < KadeployError
  def initialize(errno)
    super(errno)
  end
end

class KadeployExecuteError < KadeployError
  def initialize(msg)
    super(KadeployError::EXECUTE_ERROR,nil,msg)
  end
end

class TempfileException < RuntimeError
end

class MoveException < RuntimeError
end

class APIError
  BAD_CONFIGURATION = 0
  INVALID_CONTENT_TYPE = 1 # 415
  HTTP_METHOD_NOT_SUPPORTED = 2 # 405
  INVALID_WORKFLOW_ID = 3 # 400
  NO_USER = 4 # 400, 401
  INVALID_NODELIST = 5 # 400
  INVALID_ENVIRONMENT = 6 # 400
  INVALID_CLIENT = 7 # 400
  INVALID_OPTION = 8 # 400
  INVALID_CONTENT = 9 # 400
  EXISTING_ELEMENT = 10 # 409
  CONFLICTING_ELEMENTS = 11
  NOTHING_MODIFIED = 12
  DATABASE_ERROR = 13
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
  INVALID_MD5 = 111
  CACHE_INTERNAL_ERROR = 112
  CACHE_FILE_TOO_BIG = 113
  CACHE_FULL = 114
  UNKNOWN_PROTOCOL = 115
end

class KadeployError
  NO_ERROR = 200
  NODES_DISCARDED = 201
  NO_RIGHT_TO_DEPLOY = 202
  UNKNOWN_NODE_IN_SINGULARITY_FILE = 203
  NODE_NOT_EXIST = 204
  VLAN_MGMT_DISABLED = 205
  LOAD_ENV_FROM_DESC_ERROR = 206
  LOAD_ENV_FROM_DB_ERROR = 207
  NO_ENV_CHOSEN = 208
  CONFLICTING_OPTIONS = 209
  DB_ERROR = 210
  EXECUTE_ERROR = 211
end

class KarebootError
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

class KapowerError
  NO_ERROR = 400
end
