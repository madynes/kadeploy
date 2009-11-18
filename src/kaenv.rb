#!/usr/bin/ruby -w

# Kadeploy 3.0
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008, 2009
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadeploy libs
require 'config'
require 'db'
require 'environment'
require 'md5'

#Ruby libs
require 'drb'

USER = `id -nu`.chomp

# List the environments of a user defined in Config.exec_specific.user
#
# Arguments
# * config: instance of Config
# * db: database handler
# Output
# * print the environments of a given user
def list_environments(config, db)
  env = EnvironmentManagement::Environment.new
  if (config.exec_specific.user == "*") then #we show the environments of all the users
    if (config.exec_specific.show_all_version == false) then
      if (config.exec_specific.version != "") then
        query = "SELECT * FROM environments WHERE version=\"#{config.exec_specific.version}\" \
                                            AND visibility<>\"private\" \
                                            GROUP BY name \
                                            ORDER BY user,name"
      else
        query = "SELECT * FROM environments e1 \
                          WHERE e1.visibility<>\"private\" \
                          AND e1.version=(SELECT MAX(e2.version) FROM environments e2 \
                                                                 WHERE e2.name=e1.name \
                                                                 AND e2.user=e1.user \
                                                                 AND e2.visibility<>\"private\" \
                                                                 GROUP BY e2.user,e2.name) \
                          ORDER BY user,name"
      end
    else
      query = "SELECT * FROM environments WHERE visibility<>\"private\" ORDER BY user,name,version"
    end
  else
    #If the user wants to print the environments of another user, private environments are not shown
    if (config.exec_specific.user != USER) then
      mask_private_env = true
    end
    if (config.exec_specific.show_all_version == false) then
      if (config.exec_specific.version != "") then
        if mask_private_env then
          query = "SELECT * FROM environments \
                            WHERE user=\"#{config.exec_specific.user}\" \
                            AND version=\"#{config.exec_specific.version}\" \
                            AND visibility<>\"private\" \
                            ORDER BY user,name"
        else
          query = "SELECT * FROM environments \
                            WHERE (user=\"#{config.exec_specific.user}\" AND version=\"#{config.exec_specific.version}\") \
                            OR (user<>\"#{config.exec_specific.user}\" AND version=\"#{config.exec_specific.version}\" AND visibility=\"public\") \
                            ORDER BY user,name"
        end
      else
        if mask_private_env then
          query = "SELECT * FROM environments e1\
                            WHERE e1.user=\"#{config.exec_specific.user}\" \
                            AND e1.visibility<>\"private\" \
                            AND e1.version=(SELECT MAX(e2.version) FROM environments e2 \
                                                                   WHERE e2.name=e1.name \
                                                                   AND e2.user=e1.user \
                                                                   AND e2.visibility<>\"private\" \
                                                                   GROUP BY e2.user,e2.name) \
                            ORDER BY e1.user,e1.name"
        else
          query = "SELECT * FROM environments e1\
                            WHERE (e1.user=\"#{config.exec_specific.user}\" \
                            OR (e1.user<>\"#{config.exec_specific.user}\" AND e1.visibility=\"public\")) \
                            AND e1.version=(SELECT MAX(e2.version) FROM environments e2 \
                                                                   WHERE e2.name=e1.name \
                                                                   AND e2.user=e1.user \
                                                                   AND (e2.user=\"#{config.exec_specific.user}\" \
                                                                    OR (e2.user<>\"#{config.exec_specific.user}\" AND e2.visibility=\"public\")) \
                                                                   GROUP BY e2.user,e2.name) \
                            ORDER BY e1.user,e1.name"
        end
      end
    else
      if mask_private_env then
        query = "SELECT * FROM environments WHERE user=\"#{config.exec_specific.user}\" \
                                            AND visibility<>\"private\" \
                                            ORDER BY name,version"
      else
        query = "SELECT * FROM environments WHERE user=\"#{config.exec_specific.user}\" \
                                            OR (user<>\"#{config.exec_specific.user}\" AND visibility=\"public\") \  
                                            ORDER BY user,name,version"

      end
    end
  end
  res = db.run_query(query)
  if (res.num_rows > 0) then
    env.short_view_header
    res.each_hash { |row|
      env.load_from_hash(row)
      env.short_view
    }
  else
    puts "No environment has been found"
  end
end

# Add an environment described in the file Config.exec_specific.file
#
# Arguments
# * config: instance of Config
# * db: database handler
# Output
# * nothing
def add_environment(config, db)
  env = EnvironmentManagement::Environment.new
  if env.load_from_file(config.exec_specific.file, config.common.almighty_env_users) then
    query = "SELECT * FROM environments WHERE name=\"#{env.name}\" AND version=\"#{env.version}\" AND user=\"#{env.user}\""
    res = db.run_query(query)
    if (res.num_rows != 0) then
      puts "An environment with the name #{env.name} and the version #{env.version} has already been recorded for the user #{env.user}"
      return
    end
    if (env.visibility == "public") then
      query = "SELECT * FROM environments WHERE name=\"#{env.name}\" AND version=\"#{env.version}\" AND visibility=\"public\""
      res = db.run_query(query)
      if (res.num_rows != 0) then
        puts "A public environment with the name #{env.name} and the version #{env.version} has already been recorded"
        return
      end
    end
    query = "INSERT INTO environments (name, \
                                       version, \
                                       description, \
                                       author, \
                                       tarball, \
                                       preinstall, \
                                       postinstall, \
                                       kernel, \
                                       kernel_params, \
                                       initrd, \
                                       hypervisor, \
                                       hypervisor_params, \
                                       fdisk_type, \
                                       filesystem, \
                                       user, \
                                       environment_kind, \
                                       visibility, \
                                       demolishing_env) \
                               VALUES (\"#{env.name}\", \
                                       \"#{env.version}\", \
                                       \"#{env.description}\", \
                                       \"#{env.author}\", \
                                       \"#{env.flatten_tarball_with_md5()}\", \
                                       \"#{env.flatten_pre_install_with_md5()}\", \
                                       \"#{env.flatten_post_install_with_md5()}\", \
                                       \"#{env.kernel}\", \
                                       \"#{env.kernel_params}\", \
                                       \"#{env.initrd}\", \
                                       \"#{env.hypervisor}\", \
                                       \"#{env.hypervisor_params}\", \
                                       \"#{env.fdisk_type}\", \
                                       \"#{env.filesystem}\", \
                                       \"#{env.user}\", \
                                       \"#{env.environment_kind}\", \
                                       \"#{env.visibility}\", \
                                       \"#{env.demolishing_env}\")"
    db.run_query(query)
  end
end

# Delete the environment specified in Config.exec_specific.env_name
#
# Arguments
# * config: instance of Config
# * db: database handler
# Output
# * nothing
def delete_environment(config, db)
  if (config.exec_specific.version != "") then
    version = config.exec_specific.version
  else
    version = get_max_version(db, config.exec_specific.env_name, USER)
  end
  query = "DELETE FROM environments WHERE name=\"#{config.exec_specific.env_name}\" \
                                    AND version=\"#{version}\" \
                                    AND user=\"#{USER}\""
  db.run_query(query)
  if (db.get_nb_affected_rows == 0) then
    puts "No environment has been deleted"
  end
end

# Print the environment designed by Config.exec_specific.env_name and that belongs to the user specified in Config.exec_specific.user
#
# Arguments
# * config: instance of Config
# * db: database handler
# Output
# * print the specified environment that belongs to the specified user
def print_environment(config, db)
  env = EnvironmentManagement::Environment.new
  mask_private_env = false
  #If the user wants to print the environments of another user, private environments are not shown
  if (config.exec_specific.user != USER) then
    mask_private_env = true
  end

  if (config.exec_specific.show_all_version == false) then
    if (config.exec_specific.version != "") then
      version = config.exec_specific.version
    else
      version = get_max_version(db, config.exec_specific.env_name, config.exec_specific.user)
    end
    if mask_private_env then
      query = "SELECT * FROM environments WHERE name=\"#{config.exec_specific.env_name}\" \
                                          AND user=\"#{config.exec_specific.user}\" \
                                          AND version=\"#{version}\" \
                                          AND visibility<>\"private\""
    else
      query = "SELECT * FROM environments WHERE name=\"#{config.exec_specific.env_name}\" \
                                          AND user=\"#{config.exec_specific.user}\" \
                                          AND version=\"#{version}\""
    end
  else
    if mask_private_env then
      query = "SELECT * FROM environments WHERE name=\"#{config.exec_specific.env_name}\" \
                                          AND user=\"#{config.exec_specific.user}\" \
                                          AND visibility<>\"private\" \
                                          ORDER BY version"
    else
      query = "SELECT * FROM environments WHERE name=\"#{config.exec_specific.env_name}\" \
                                          AND user=\"#{config.exec_specific.user}\" \
                                          ORDER BY version"
    end
  end
  res = db.run_query(query)
  if (res.num_rows > 0) then
    res.each_hash { |row|
      puts "###"
      env.load_from_hash(row)
      env.full_view
    }
  else
    puts "The environment does not exist"
  end
end

# Get the highest version of an environment
#
# Arguments
# * db: database handler
# * env_name: environment name
# * user: owner of the environment
# Output
# * return the highest version number or -1 if no environment is found
def get_max_version(db, env_name, user)
  #If the user wants to print the environments of another user, private environments are not shown
  if (user != USER) then
    mask_private_env = true
  end

  if mask_private_env then
    query = "SELECT MAX(version) FROM environments WHERE user=\"#{user}\" \
                                                   AND name=\"#{env_name}\" \
                                                   AND visibility<>\"private\""
  else
    query = "SELECT MAX(version) FROM environments WHERE user=\"#{user}\" \
                                                   AND name=\"#{env_name}\""
  end
  res = db.run_query(query)
  if (res.num_rows > 0) then
    row = res.fetch_row
    return row[0]
  else
    return -1
  end
end


# Update the md5sum of the tarball
# Sub function of update_preinstall_md5
#
# * db: database handler
# * env_name: environment name
# * env_version: environment version
# * env_user: environment user
# Output
# * nothing
def _update_tarball_md5(db, env_name, env_version, env_user)
  if (env_version != "") then
    version = env_version
  else
    version = get_max_version(db, env_name, env_user)
  end
  query = "SELECT * FROM environments WHERE name=\"#{env_name}\" \
                                      AND user=\"#{env_user}\" \
                                      AND version=\"#{version}\""
  res = db.run_query(query)
  res.each_hash  { |row|
    env = EnvironmentManagement::Environment.new
    env.load_from_hash(row)
    tarball = "#{env.tarball["file"]}|#{env.tarball["kind"]}|#{MD5::get_md5_sum(env.tarball["file"])}"
    
    query2 = "UPDATE environments SET tarball=\"#{tarball}\" WHERE name=\"#{env_name}\" \
                                                             AND user=\"#{env_user}\" \
                                                             AND version=\"#{version}\""
    db.run_query(query2)
    if (db.get_nb_affected_rows == 0) then
      puts "No update has been performed"
    end
  }
end

# Update the md5sum of the tarball
#
# * config: instance of Config
# * db: database handler
# Output
# * nothing
def update_tarball_md5(config, db)
  _update_tarball_md5(db, config.exec_specific.env_name, config.exec_specific.version, USER)
end

# Update the md5sum of the preinstall
# Sub function of update_preinstall_md5
#
# * db: database handler
# * env_name: environment name
# * env_version: environment version
# * env_user: environment user
# Output
# * nothing
def _update_preinstall_md5(db, env_name, env_version, env_user)
  if (env_version != "") then
    version = env_version
  else
    version = get_max_version(db, env_name, env_user)
  end
  query = "SELECT * FROM environments WHERE name=\"#{env_name}\" \
                                      AND user=\"#{env_user}\" \
                                      AND version=\"#{version}\""
  res = db.run_query(query)
  res.each_hash  { |row|
    env = EnvironmentManagement::Environment.new
    env.load_from_hash(row)
    if (env.preinstall != nil) then
      tarball = "#{env.preinstall["file"]}|#{env.preinstall["kind"]}|#{MD5::get_md5_sum(env.preinstall["file"])}|#{env.preinstall["script"]}"
      
      query2 = "UPDATE environments SET preinstall=\"#{tarball}\" WHERE name=\"#{env_name}\" \
                                                                  AND user=\"#{env_user}\" \
                                                                  AND version=\"#{version}\""
      db.run_query(query2)
      if (db.get_nb_affected_rows == 0) then
        puts "No update has been performed"
      end
    else
      puts "No preinstall to update"
    end
  }
end

# Update the md5sum of the preinstall
#
# * db: database handler
# * config: instance of Config
# Output
# * nothing
def update_preinstall_md5(config, db)
  _update_preinstall_md5(db, config.exec_specific.env_name, config.exec_specific.version, USER)
end

# Update the md5sum of the postinstall files
# Sub function of update_postinstalls_md5
#
# * db: database handler
# * env_name: environment name
# * env_version: environment version
# * env_user: environment user
# Output
# * nothing
def _update_postinstall_md5(db, env_name, env_version, env_user)
  if (env_version != "") then
    version = env_version
  else
    version = get_max_version(db, env_name, env_user)
  end
  query = "SELECT * FROM environments WHERE name=\"#{env_name}\" \
                                      AND user=\"#{env_user}\" \
                                      AND version=\"#{version}\""
  res = db.run_query(query)
  res.each_hash  { |row|
    env = EnvironmentManagement::Environment.new
    env.load_from_hash(row)
    if (env.postinstall != nil) then
      postinstall_array = Array.new
      env.postinstall.each { |p|
        postinstall_array.push("#{p["file"]}|#{p["kind"]}|#{MD5::get_md5_sum(p["file"])}|#{p["script"]}")
      }
      query2 = "UPDATE environments SET postinstall=\"#{postinstall_array.join(",")}\" \
                                    WHERE name=\"#{env_name}\" \
                                    AND user=\"#{env_user}\" \
                                    AND version=\"#{version}\""
      db.run_query(query2)
      if (db.get_nb_affected_rows == 0) then
        puts "No update has been performed"
      end
    else
      puts "No postinstall to update"
    end
  }
end

# Update the md5sum of the postinstall files
#
# * config: instance of Config
# * db: database handler
# Output
# * nothing
def update_postinstall_md5(config, db)
  _update_postinstall_md5(db, config.exec_specific.env_name, config.exec_specific.version, USER)
end

# Remove the demolishing tag on an environment
#
# Arguments
# * config: instance of Config
# * db: database handler
# Output
# * nothing
def remove_demolishing_tag(config, db)
  #if no version number is given, we only remove the demolishing tag on the last version
  if (config.exec_specific.version != "") then
    version = config.exec_specific.version
  else
    version = get_max_version(db, config.exec_specific.env_name, USER)
  end
  query = "UPDATE environments SET demolishing_env=0 WHERE name=\"#{config.exec_specific.env_name}\" \
                                                     AND user=\"#{USER}\" \
                                                     AND version=\"#{version}\""
  db.run_query(query)
  if (db.get_nb_affected_rows == 0) then
    puts "No update has been performed"
  end
end

# Modify the visibility tag of an environment
#
# Arguments
# * config: instance of Config
# * db: database handler
# Output
# * nothing
def set_visibility_tag(config, db)
  if (config.exec_specific.visibility_tag == "public") && (not config.common.almighty_env_users.include?(USER)) then
    puts "Only the environment administrators can set the \"public\" tag"
  else
    query = "UPDATE environments SET visibility=\"#{config.exec_specific.visibility_tag}\" \
                                 WHERE name=\"#{config.exec_specific.env_name}\" \
                                 AND user=\"#{config.exec_specific.user}\" \
                                 AND version=\"#{config.exec_specific.version}\""
    db.run_query(query)
    if (db.get_nb_affected_rows == 0) then
      puts "No update has been performed"
    end
  end
end

# Move some file locations in the environment table
#
# Arguments
# * config: instance of Config
# * db: database handler
# Output
# * nothing
def move_files(config, db)
  if (not config.common.almighty_env_users.include?(USER)) then
    puts "Only the environment administrators can move the files in the environments"
  else
    query = "SELECT * FROM environments"
    res = db.run_query(query)
    if (res.num_rows > 0) then
      #Let's check each environment
      res.each_hash { |row|
        config.exec_specific.files_to_move.each { |file|
          ["tarball", "preinstall", "postinstall"].each { |kind_of_file|
            if row[kind_of_file].include?(file["src"]) then
              modified_file = row[kind_of_file].gsub(file["src"], file["dest"])
              query2 = "UPDATE environments SET #{kind_of_file}=\"#{modified_file}\" \
                                            WHERE id=#{row["id"]}"
              db.run_query(query2)
              if (db.get_nb_affected_rows > 0) then
                puts "The #{kind_of_file} of {#{row["name"]},#{row["version"]},#{row["user"]}} has been updated"
                puts "Let's now update the md5 for this file"
                send("_update_#{kind_of_file}_md5".to_sym, db, row["name"], row["version"], row["user"])
              end
            end
          }
        }
      }
    else
      puts "There is no recorded environment"
    end
  end
end

def _exit(exit_code, dbh)
  dbh.disconnect if (dbh != nil)
  exit(exit_code)
end

begin
  config = ConfigInformation::Config.new("kaenv")
rescue
  _exit(1, nil)
end

#Connect to the Kaeploy server to get the common configuration
client_config = ConfigInformation::Config.load_client_config_file
DRb.start_service()
uri = "druby://#{client_config.kadeploy_server}:#{client_config.kadeploy_server_port}"
kadeploy_server = DRbObject.new(nil, uri)
config.common = kadeploy_server.get_common_config

if (config.check_config("kaenv") == true)
  if config.exec_specific.get_version then
    puts "Kaenv version: #{kadeploy_server.get_version()}"
    _exit(0, nil)
  end

  db = Database::DbFactory.create(config.common.db_kind)
  db.connect(config.common.deploy_db_host,
             config.common.deploy_db_login,
             config.common.deploy_db_passwd,
             config.common.deploy_db_name)
  case config.exec_specific.operation
  when "list"
    list_environments(config, db)
  when "add"
    add_environment(config, db)
  when "delete"
    delete_environment(config, db)
  when "print"
    print_environment(config, db)
  when "update-tarball-md5"
    update_tarball_md5(config, db)
  when "update-preinstall-md5"
    update_preinstall_md5(config, db)
  when "update-postinstalls-md5"
    update_postinstall_md5(config, db)
  when "remove-demolishing-tag"
    remove_demolishing_tag(config, db)
  when "set-visibility-tag"
    set_visibility_tag(config, db)
  when "move-files"
    move_files(config, db)
  end
  _exit(0, db)
else
  _exit(1, db)
end
