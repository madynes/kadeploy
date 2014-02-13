module Kadeploy

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
    when APIError::INVALID_WORKFLOW_ID
      "Invalid workflow ID"
    when APIError::INVALID_OPTION
      "Invalid option in the request"
    when APIError::INVALID_NODELIST
      "Invalid node list"
    when APIError::INVALID_RIGHTS
      "You do not have sufficient rights to perform the operation on all the nodes"
    when APIError::INVALID_ENVIRONMENT
      "Invalid environment specification"
    when APIError::INVALID_CUSTOMOP
      "Invalid custom operations specification"
    when APIError::INVALID_CLIENT
      "Invalid client's export"
    when APIError::INVALID_FILE
      "Invalid file"
    when APIError::INVALID_VLAN
      "Invalid VLAN"
    when APIError::EXISTING_ELEMENT
      "Element already exists"
    when APIError::CONFLICTING_ELEMENTS
      "Some elements already exists and are conflicting"
    when APIError::CONFLICTING_OPTIONS
      "Some options are conflicting"
    when APIError::MISSING_OPTION
      "Some options are missing"
    when APIError::NOTHING_MODIFIED
      "No element has been modified"
    when APIError::EXECUTE_ERROR
      "The execution of a command failed"
    when APIError::DATABASE_ERROR
      "Database issue"
    when APIError::CACHE_ERROR
      "Something went wrong with the cache system"
    when APIError::CACHE_FULL
      "The cache is full"
    when APIError::DESTRUCTIVE_ENVIRONMENT
      "Cannot reboot since the last deployed environment was destructive"
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
    super(APIError::EXECUTE_ERROR,nil,msg)
  end
end

class APIError
  BAD_CONFIGURATION = 0
  INVALID_WORKFLOW_ID = 1
  INVALID_NODELIST = 2
  INVALID_CLIENT = 3
  INVALID_OPTION = 4
  INVALID_FILE = 5
  INVALID_RIGHTS = 6
  INVALID_ENVIRONMENT = 7
  INVALID_CUSTOMOP = 8
  INVALID_VLAN = 9
  EXISTING_ELEMENT = 10
  CONFLICTING_ELEMENTS = 11
  MISSING_OPTION = 12
  CONFLICTING_OPTIONS = 13
  NOTHING_MODIFIED = 14
  EXECUTE_ERROR = 15
  DATABASE_ERROR = 20
  CACHE_ERROR = 21
  CACHE_FULL = 22
  DESTRUCTIVE_ENVIRONMENT = 30
end

end
