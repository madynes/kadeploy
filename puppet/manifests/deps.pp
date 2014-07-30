class {'kabootstrap::kadeploy::deps':
  kind => build,
  http_proxy => $facter_http_proxy,
}
