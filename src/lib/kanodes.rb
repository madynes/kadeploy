module Kanodes
  API_DEPLOY_PATH = '/nodes'

  def nodes_path(path='',prefix='')
    File.join(prefix,API_DEPLOY_PATH,path)
  end

  def nodes_init_exec_context()
    ret = init_exec_context()
    # ...
    ret
  end

  def nodes_prepare(params,operation=:get)
    context = nodes_init_exec_context()

    # Check user/key
    context.user = parse_user(params['user'])
    context.secret_key = parse_secret_key(params['secret_key'])
    context.cert = parse_cert(params['cert'])

    context
  end

  def nodes_rights?(cexec,operation,*args)
    true
  end

  def nodes_get(cexec,nodes=nil)
    config.common.nodes_desc.set.collect{|node| node.hostname}
  end
end
