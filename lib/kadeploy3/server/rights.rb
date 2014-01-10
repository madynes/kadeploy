module Kadeploy

module Rights
  class Factory
    def self.create(kind, db = nil)
      case kind
      when 'dummy'
        return RightsDummy.new
      when 'db'
        return RightsDatabase.new(db)
      else
        raise 'Invalid kind of rights check'
      end
    end
  end

  class Rights
    def add(user,nodes=nil,parts=nil)
      true
    end

    def get(user,nodes=nil)
      true
    end

    def delete(user,nodes=nil)
      true
    end

    def granted?(user,nodes,parts=nil)
      true
    end

    protected
    def prepare(user=nil,nodes=nil,parts=nil)
      parts = [ parts ] if parts and !parts.is_a?(Array)
      nodes = [ nodes.hostname ] if nodes.is_a?(Nodes::Node)
      nodes = nodes.make_array_of_hostname if nodes.is_a?(Nodes::NodeSet)
      nodes.uniq! if nodes.is_a?(Array)
      user = nil if user and user.empty?
      parts = nil if parts and parts.empty?

      if nodes
        tmp = []
        nodes.each do |node|
          if Nodes::REGEXP_NODELIST =~ node
            tmp += Nodes::NodeSet::nodes_list_expand("#{node}")
          else
            tmp << node
          end
        end
        nodes = tmp
      end
      nodes = nil if nodes and nodes.empty?

      [user,nodes,parts]
    end
  end

  class RightsDummy < Rights
    def get(user,nodes=nil)
      user,nodes = prepare(user,nodes)
      if nodes and !nodes.empty?
        nodes.uniq! if nodes.is_a?(Array)
        nodes.inject({}){|h,n| h[n] = '*'; h}
      else
        {}
      end
    end
  end

  class RightsDatabase < Rights
    def initialize(db)
      @db = db
    end

    def add(user,nodes=nil,parts=nil)
      user,nodes,parts = prepare(user,nodes,parts)
      raise if !user or user.empty?
      existing = get(user,nodes)
      existing = existing[user] if existing
      parts = ['*'] unless parts

      treatment = Proc.new do |h,n,p| #h: to_add, p: rights that already in the base
        if p.sort != parts.sort and !p.include?('*') # some modifications are needed and the already set rights do not include the ones we want to set
          if parts.include?('*')
            # we delete all previously set rights
            if n == '*'
              delete(user)
            else
              delete(user,[n])
            end
            h[n] = ['*'] # and add all rights to this node
          else
            parts.each do |part|
              unless p.include?(part) # if this right do not already exists
                h[n] = [] unless h[n]
                h[n] << part
              end
            end
          end
        end
      end

      to_add = {}
      if nodes
        if existing.is_a?(Array) # User have rights on every nodes
          nodes.each do |n|
            treatment.call(to_add,node,existing)
          end
        elsif existing.is_a?(Hash)
          existing.each do |n,p|
            treatment.call(to_add,n,p)
          end

          # The nodes that did not have any rights
          (nodes-existing.keys).each do |node|
            to_add[node] = parts
          end
        else
          nodes.each do |node|
            to_add[node] = parts
          end
        end
      else
        if existing.is_a?(Array) # User have rights on every nodes
          treatment.call(to_add,'*',existing)
        elsif existing.is_a?(Hash)
          if parts.include?('*')
            delete(user)
            to_add['*'] = ['*']
          else
            raise # Some rights have to be set for every nodes but there is already some sets in the db
          end
        else
          to_add['*'] = parts
        end
      end

      if to_add.empty?
        nil
      else
        args = []
        size = 0
        to_add.each do |n,ps|
          ps.each do |p|
            args << user
            args << n
            args << p
            size += 1
          end
        end
        values = ([ "(?, ?, ?)" ] * size).join(", ")
        query = "INSERT INTO rights (user, node, part) VALUES #{values}"
        db_run(query,*args)
        { user => to_add }
      end
    end

    def get(user=nil,nodes=nil)
      user,nodes = prepare(user,nodes)
      query = "SELECT * FROM rights"
      args = []
      where = []
      if user
        where << '(user = ?)'
        args << user
      end
      if nodes and !nodes.empty?
        tmp = db_nodelist(nodes)
        where << tmp[0]
        args += tmp[1]
      end
      query << " WHERE #{where.join(' AND ')}" unless where.empty?
#hash if right on some nodes, array if rights on all nodes

      res = db_run(query,*args)
      if res
        ret = {}
        res.each do |usr,nods|
          # nods.collect!
          if nods.include?('*')
            ret[usr] = nods['*']
          else
            ret[usr] = nods
          end
        end
        res = nil
        ret
      else
        nil
      end
    end

    def delete(user,nodes=nil,parts=nil)
      user,nodes,parts = prepare(user,nodes,parts)
      raise if !user or user.empty?
      query = "DELETE FROM rights"
      where = ['(user = ?)']
      args = [user]
      if nodes
        if parts
          tmp = db_partlist(parts,nodes)
          where << tmp[0]
          args += tmp[1]
        else
          tmp = db_nodelist(nodes)
          where << tmp[0]
          args += tmp[1]
        end
      else
        if parts
          tmp = db_partlist(parts)
          where << tmp[0]
          args += tmp[1]
        end
      end
      query << " WHERE #{where.join(' AND ')}"
      if db_run(query,*args)
        ret = {}
        ret[user] = {}
        if nodes
          nodes.each do |node|
            if parts
              ret[user][node] = parts
            else
              ret[user][node] = ['*']
            end
          end
        else
          if parts
            ret[user]['*'] = parts
          else
            ret[user]['*'] = ['*']
          end
        end
        ret
      else
        nil
      end
    end

    # if parts.empty? => check if some rights on nodes
    def granted?(user,nodes,parts=nil)
      raise unless nodes
      user,nodes,parts = prepare(user,nodes,parts)
      rights = get(user,nodes)
      rights = rights[user] if rights
      parts = ['*'] unless parts

      if rights.is_a?(Array)
        # check if rights includes parts
        parts[0].empty? or rights[0] == '*' or (parts.sort-rights.sort).empty?
      elsif rights.is_a?(Hash)
        if nodes.sort == rights.keys.sort
          unless parts[0].empty?
            rights.each do |n,p|
              return false if p[0] != '*' and !(parts.sort-p.sort).empty?
            end
          end
          true
        else
          false
        end
      else
        false
      end
    end

    private
    def db_run(query,*args)
      res = @db.run_query(query,*args)
      if res.affected_rows > 0
        ret = res.to_hash.inject({}) do |h,v|
          h[v['user']] = {} unless h[v['user']]
          h[v['user']][v['node']] = [] unless h[v['user']][v['node']]
          h[v['user']][v['node']] << v['part']
          h
        end
        res = nil
        ret
      else
        nil
      end
    end

    def db_nodelist(nodes,field='node')
      tmp = nodes.dup
      tmp << '*'
      Database::where_nodelist(tmp,field)
    end

    def db_partlist(parts,nodes=nil,partfield='part',nodefield='node')
      if nodes
        queries = []
        args = []
        nodes.each do |node|
          query = '('
          query << "(#{nodefield} = ? ) AND"
          args << node
          query << (["(#{partfield} = ? )"] * parts.size).join(' OR ')
          args += parts
          query << ')'
          queries << query
        end
        ["(#{queries.join(' OR ')})",args]
      else
        ["(#{(["(#{partfield} = ? )"] * parts.size).join(' OR ')})",parts]
      end
    end
  end
end

end
