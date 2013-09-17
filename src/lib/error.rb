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
      "You do not have sufficient rights to perform the operation"
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
    when APIError::NOTHING_MODIFIED
      "No element has been modified"
    when APIError::DATABASE_ERROR
      "Database issue"
    when APIError::CACHE_ERROR
      "Something went wront with the cache system"
    when APIError::CACHE_FULL
      "The cache is full"
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
  CONFLICTING_OPTIONS = 12
  NOTHING_MODIFIED = 13
  DATABASE_ERROR = 20
  CACHE_ERROR = 21
  CACHE_FULL = 22
end

end
