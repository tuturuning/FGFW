#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'
require 'json'
require 'time'
require 'base64'
require 'fileutils'

config_dir = ARGV[0]
output_dir = ARGV[1]
secrets_file = ARGV[2]

abort 'usage: render_manifest.rb <config_dir> <output_dir> <secrets_file>' unless config_dir && output_dir && secrets_file

def load_yaml(path)
  YAML.safe_load(File.read(path), permitted_classes: [], aliases: false) || {}
end

def load_env(path)
  env = {}
  File.readlines(path, chomp: true).each do |line|
    next if line.strip.empty? || line.strip.start_with?('#')
    key, value = line.split('=', 2)
    next if key.nil? || value.nil?
    env[key.strip] = value.strip
  end
  env
end

def resolve_ref(secrets, ref)
  return nil if ref.nil?
  secrets[ref] || ref
end

def bool_value(value)
  value == true
end

def deep_resolve(value, secrets)
  case value
  when Hash
    value.each_with_object({}) do |(k, v), memo|
      memo[k] = deep_resolve(v, secrets)
    end
  when Array
    value.map { |item| deep_resolve(item, secrets) }
  when String
    secrets.fetch(value, value)
  else
    value
  end
end

def protocol_network(protocol)
  case protocol
  when 'hysteria2', 'tuic'
    %w[udp]
  when 'ss2022'
    %w[tcp udp]
  else
    %w[tcp]
  end
end

def expand_ports(port)
  case port
  when Integer
    [port]
  when String
    if port.include?('-')
      start_port, end_port = port.split('-', 2).map(&:to_i)
      (start_port..end_port).to_a
    else
      [port.to_i]
    end
  else
    []
  end
end

def validate_ports!(targets, nodes)
  targets_by_id = targets.each_with_object({}) { |target, memo| memo[target['id']] = target }
  seen = {}

  nodes.each do |node|
    target = targets_by_id[node['target']] or abort "Unknown target for node #{node['id']}: #{node['target']}"
    ports = expand_ports(node.dig('listen', 'port'))
    preserve_ports = Array(target.dig('preserve', 'ports'))
    overlap = ports & preserve_ports
    unless overlap.empty?
      abort "Node #{node['id']} uses preserved port #{overlap.first} on target #{target['id']}"
    end

    protocol_network(node['protocol']).each do |network|
      ports.each do |port|
        key = [node['target'], network, port]
        abort "Port conflict on target #{node['target']}: #{port}/#{network} used by #{seen[key]} and #{node['id']}" if seen.key?(key)
        seen[key] = node['id']
      end
    end
  end
end

def node_link(node, secrets)
  connect = node.fetch('connect', {})
  listen = node.fetch('listen', {})
  host = connect['host'] || 'example.invalid'
  port = listen['port'] || 0
  id = node['id'] || 'node'
  export_clients = node.fetch('export', {}).fetch('clients', [])

  case node['protocol']
  when 'vless'
    if node['security'] == 'reality'
      reality = node.fetch('reality', {})
      public_key = resolve_ref(secrets, reality.dig('key_ref', 'public')) || 'replace-me'
      short_id = Array(reality['short_ids']).first || 'replace-me'
      server_name = Array(reality['server_names']).first || reality['target_host'] || host
      uuid = resolve_ref(secrets, node.dig('auth', 'uuid_ref')) || 'replace-me-uuid'
      query = [
        'encryption=none',
        "flow=#{node['xtls_flow'] || 'xtls-rprx-vision'}",
        'security=reality',
        "sni=#{server_name}",
        'fp=chrome',
        "pbk=#{public_key}",
        "sid=#{short_id}",
        "type=#{node['transport'] || 'tcp'}",
        'headerType=none'
      ].join('&')
      "vless://#{uuid}@#{host}:#{port}?#{query}##{id}"
    else
      uuid = resolve_ref(secrets, node.dig('auth', 'uuid_ref')) || 'replace-me-uuid'
      sni = connect['sni'] || host
      query = ['encryption=none', "security=#{node['security'] || 'tls'}", "sni=#{sni}"]
      case node['transport']
      when 'ws'
        query.concat([
          'type=ws',
          "host=#{connect['ws_host'] || host}",
          "path=#{connect['path'] || '/'}"
        ])
      when 'grpc'
        query.concat([
          'type=grpc',
          "serviceName=#{connect['service_name'] || 'grpc'}"
        ])
      when 'xhttp'
        query.concat([
          'type=xhttp',
          "host=#{connect['xhttp_host'] || host}",
          "path=#{connect['path'] || '/xhttp'}",
          "mode=#{connect['xhttp_mode'] || 'auto'}"
        ])
      else
        query.concat([
          "type=#{node['transport'] || 'tcp'}"
        ])
      end
      "vless://#{uuid}@#{host}:#{port}?#{query.join('&')}##{id}"
    end
  when 'vmess'
    return nil if node.dig('dynamic_port', 'enabled')
    uuid = resolve_ref(secrets, node.dig('auth', 'uuid_ref')) || 'replace-me-uuid'
    network = node['transport'] || 'ws'
    payload = {
      v: '2',
      ps: id,
      add: host,
      port: port.to_s,
      id: uuid,
      aid: '0',
      scy: 'auto',
      net: network,
      type: 'none',
      host: connect['ws_host'] || host,
      path: connect['path'] || '/',
      tls: node['security'] == 'tls' ? 'tls' : '',
      sni: connect['sni'] || host
    }
    case network
    when 'grpc'
      payload[:path] = connect['service_name'] || 'grpc'
      payload[:host] = ''
      payload[:type] = 'gun'
    when 'kcp'
      payload[:path] = ''
      payload[:host] = ''
      payload[:type] = connect['mkcp_header_type'] || 'none'
    when 'tcp'
      payload[:path] = ''
    end
    "vmess://#{Base64.strict_encode64(payload.to_json)}"
  when 'trojan'
    password = resolve_ref(secrets, node.dig('auth', 'password_ref')) || 'replace-me'
    sni = connect['sni'] || host
    query = ["security=#{node['security'] || 'tls'}", "sni=#{sni}"]
    case node['transport']
    when 'ws'
      query.concat([
        'type=ws',
        "host=#{connect['ws_host'] || host}",
        "path=#{connect['path'] || '/'}"
      ])
    when 'grpc'
      query.concat([
        'type=grpc',
        "serviceName=#{connect['service_name'] || 'grpc'}"
      ])
    else
      query.concat(["type=#{node['transport'] || 'tcp'}"])
    end
    "trojan://#{password}@#{host}:#{port}?#{query.join('&')}##{id}"
  when 'hysteria2'
    password = resolve_ref(secrets, node.dig('auth', 'password_ref')) || 'replace-me'
    sni = connect['sni'] || host
    "hysteria2://#{password}@#{host}:#{port}?security=tls&alpn=h3&sni=#{sni}##{id}"
  when 'tuic'
    uuid = resolve_ref(secrets, node.dig('auth', 'uuid_ref')) || 'replace-me-uuid'
    password = resolve_ref(secrets, node.dig('auth', 'password_ref')) || 'replace-me'
    sni = connect['sni'] || host
    "tuic://#{uuid}:#{password}@#{host}:#{port}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=#{sni}##{id}"
  when 'ss2022'
    method = node.dig('auth', 'method') || '2022-blake3-aes-128-gcm'
    password = resolve_ref(secrets, node.dig('auth', 'password_ref')) || 'replace-me'
    encoded = Base64.strict_encode64("#{method}:#{password}@#{host}:#{port}")
    "ss://#{encoded}##{id}"
  else
    nil
  end.tap do |link|
    if link.nil? && !export_clients.empty?
      warn "Unsupported protocol for export: #{node['protocol']}"
    end
  end
end

def clash_exportable_node?(node)
  connect = node[:connect] || {}
  listen = node[:listen] || {}
  host = connect['host']
  port = listen['port']

  return false if host.nil? || port.nil?
  return false if port.is_a?(String) && port.include?('-')

  case node[:protocol]
  when 'vless'
    return true if node[:security] == 'reality'

    node[:security] == 'tls' && %w[ws grpc].include?(node[:transport])
  when 'vmess'
    %w[tcp ws grpc].include?(node[:transport] || 'tcp')
  when 'trojan'
    node[:security] == 'tls' && %w[ws grpc].include?(node[:transport] || 'tcp')
  when 'hysteria2', 'ss2022'
    true
  else
    false
  end
end

def clash_dns_server_addresses(dns_config, preferred_ids = nil)
  servers = Array(dns_config['servers'])
  servers.select! { |server| preferred_ids.include?(server['id']) } if preferred_ids
  servers.map { |server| server['address'] }.compact.uniq
end

def clash_server_host_for(node)
  connect = node[:connect] || {}
  export = node[:export] || {}

  export['server_ipv4'] || export['server'] || connect['host']
end

def clash_tls_server_name_for(node, host, host_sni)
  connect = node[:connect] || {}

  connect['sni'] || host_sni || host
end

def clash_proxy_for(node)
  connect = node[:connect] || {}
  listen = node[:listen] || {}
  auth = node[:auth] || {}
  tls = node[:tls] || {}
  reality = node[:reality] || {}
  host = clash_server_host_for(node)
  host_sni = connect['host']
  port = listen['port']
  return nil if host.nil? || port.nil?
  return nil if port.is_a?(String) && port.include?('-')

  base = {
    'name' => node[:id],
    'server' => host,
    'port' => port,
    'udp' => true
  }

  case node[:protocol]
  when 'vless'
    proxy = base.merge(
      'type' => 'vless',
      'uuid' => auth['uuid_ref'] || auth['uuid'],
      'network' => (node[:transport] || 'tcp')
    )

    if node[:security] == 'reality'
      proxy['tls'] = true
      proxy['skip-cert-verify'] = true
      proxy['servername'] = Array(reality['server_names']).first || reality['target_host'] || host_sni || host
      proxy['client-fingerprint'] = 'chrome'
      proxy['flow'] = node[:xtls_flow] || 'xtls-rprx-vision'
      proxy['packet-encoding'] = 'xudp'
      proxy['reality-opts'] = {
        'public-key' => reality.dig('key_ref', 'public') || reality['public'],
        'short-id' => Array(reality['short_ids']).first
      }
    elsif node[:security] == 'tls'
      proxy['tls'] = true
      proxy['skip-cert-verify'] = true
      proxy['servername'] = clash_tls_server_name_for(node, host, host_sni)
      proxy['client-fingerprint'] = 'chrome'
      case node[:transport]
      when 'ws'
        proxy['ws-opts'] = {
          'path' => connect['path'] || '/',
          'headers' => {
            'Host' => connect['ws_host'] || host_sni || host
          }
        }
      when 'grpc'
        proxy['grpc-opts'] = {
          'grpc-mode' => 'gun',
          'grpc-service-name' => connect['service_name'] || 'grpc'
        }
      when 'xhttp'
        proxy['xhttp-opts'] = {
          'path' => connect['path'] || '/',
          'host' => Array(connect['xhttp_host'] || host_sni || host),
          'mode' => connect['xhttp_mode'] || 'auto'
        }
      end
    end

    proxy
  when 'vmess'
    proxy = base.merge(
      'type' => 'vmess',
      'uuid' => auth['uuid_ref'] || auth['uuid'],
      'alterId' => 0,
      'cipher' => 'auto',
      'network' => (node[:transport] || 'tcp')
    )

    if node[:security] == 'tls'
      proxy['tls'] = true
      proxy['skip-cert-verify'] = true
      proxy['servername'] = clash_tls_server_name_for(node, host, host_sni)
      proxy['client-fingerprint'] = 'chrome'
      case node[:transport]
      when 'ws'
        proxy['ws-opts'] = {
          'path' => connect['path'] || '/',
          'headers' => {
            'Host' => connect['ws_host'] || host_sni || host
          }
        }
      when 'grpc'
        proxy['grpc-opts'] = {
          'grpc-mode' => 'gun',
          'grpc-service-name' => connect['service_name'] || 'grpc'
        }
      end
    end

    proxy
  when 'trojan'
    proxy = base.merge(
      'type' => 'trojan',
      'password' => auth['password_ref'] || auth['password'],
      'sni' => clash_tls_server_name_for(node, host, host_sni),
      'network' => (node[:transport] || 'tcp'),
      'tls' => true,
      'client-fingerprint' => 'chrome',
      'skip-cert-verify' => true
    )

    case node[:transport]
    when 'ws'
      proxy['ws-opts'] = {
        'path' => connect['path'] || '/',
        'headers' => {
          'Host' => connect['ws_host'] || host_sni || host
        }
      }
    when 'grpc'
      proxy['grpc-opts'] = {
        'grpc-mode' => 'gun',
        'grpc-service-name' => connect['service_name'] || 'grpc'
      }
    end

    proxy
  when 'hysteria2'
    base.merge(
      'type' => 'hysteria2',
      'password' => auth['password_ref'] || auth['password'],
      'auth' => auth['password_ref'] || auth['password'],
      'sni' => connect['sni'] || host_sni || host,
      'alpn' => Array(tls['alpn']),
      'skip-cert-verify' => true
    )
  when 'ss2022'
    base.merge(
      'type' => 'ss',
      'cipher' => auth['method'] || '2022-blake3-aes-128-gcm',
      'password' => auth['password_ref'] || auth['password']
    )
  else
    nil
  end
end

def node_transport_label(node)
  case [node[:protocol], node[:security], node[:transport]]
  when ['vless', 'reality', 'tcp']
    'VLESS Reality Vision'
  when ['hysteria2', 'tls', 'quic']
    'Hysteria2'
  when ['ss2022', nil, 'tcpudp']
    'Shadowsocks 2022'
  when ['vmess', 'none', 'tcp']
    'VMess TCP'
  when ['vmess', 'none', 'mkcp']
    'VMess mKCP'
  when ['vmess', 'tls', 'ws']
    'VMess WS TLS'
  when ['vmess', 'tls', 'grpc']
    'VMess gRPC TLS'
  when ['vless', 'tls', 'ws']
    'VLESS WS TLS'
  when ['vless', 'tls', 'grpc']
    'VLESS gRPC TLS'
  when ['vless', 'tls', 'xhttp']
    'VLESS XHTTP TLS'
  when ['trojan', 'tls', 'ws']
    'Trojan WS TLS'
  when ['trojan', 'tls', 'grpc']
    'Trojan gRPC TLS'
  else
    [node[:protocol], node[:transport], node[:security]].compact.join(' ').upcase
  end
end

def node_usage_note(node)
  case node[:id]
  when /res-chain/
    '专用链式住宅节点；客户端选中后，服务端会强制把全部流量转到静态住宅出口。'
  when /reality/
    '主力通用节点，优先用于日常代理和兼容性测试。'
  when /hy2/
    '强 UDP 节点，适合网络质量好时测速或大流量场景。'
  when /ss2022-fallback/
    '备用轻量节点，适合兼容性兜底。'
  when /ss2022-main/
    '主用 SS2022 备用节点，适合简单客户端或兜底。'
  when /vmess-tcp/
    '最基础 TCP 形态，适合做兼容性对照测试。'
  when /vmess-mkcp/
    'mKCP 形态，适合特定网络环境测试，不建议默认主用。'
  when /vmess-ws-tls/
    'WebSocket over TLS，兼容性较稳，适合 CDN 风格形态参考。'
  when /vmess-grpc-tls/
    'gRPC over TLS，适合和 WS/TCP 做兼容性对照。'
  when /vless-ws-tls/
    'VLESS WebSocket over TLS，适合通用客户端兼容场景。'
  when /vless-grpc-tls/
    'VLESS gRPC over TLS，适合与 WS/Reality 做对照测试。'
  when /vless-xhttp-tls/
    'VLESS XHTTP over TLS，新版 Mihomo 可用，适合专项测试。'
  when /trojan-ws-tls/
    'Trojan WebSocket over TLS，适合 Trojan 客户端兼容场景。'
  when /trojan-grpc-tls/
    'Trojan gRPC over TLS，适合 Trojan 形态对照测试。'
  else
    '通用节点。'
  end
end

app_env = load_env(File.join(config_dir, 'app.env.example'))
targets = load_yaml(File.join(config_dir, 'targets.yaml')).fetch('targets', [])
nodes = load_yaml(File.join(config_dir, 'nodes.yaml')).fetch('nodes', [])
outbounds = load_yaml(File.join(config_dir, 'outbounds.yaml'))
routing = load_yaml(File.join(config_dir, 'routing.yaml'))
dns = load_yaml(File.join(config_dir, 'dns.yaml'))
acme = load_yaml(File.join(config_dir, 'acme.yaml')).fetch('acme', {})
argo = load_yaml(File.join(config_dir, 'argo.yaml'))
warp = load_yaml(File.join(config_dir, 'warp.yaml'))
exports = load_yaml(File.join(config_dir, 'export.yaml')).fetch('exports', {})
secrets = load_env(secrets_file)

enabled_nodes = nodes.select { |node| bool_value(node['enabled']) }
validate_ports!(targets, enabled_nodes)

manifest_nodes = enabled_nodes.map do |node|
  link = node_link(node, secrets)
  target_info = targets.find { |target| target['id'] == node['target'] } || {}
  {
    id: node['id'],
    group: node['group'],
    target: node['target'],
    core: node['core'],
    protocol: node['protocol'],
    transport: node['transport'],
    security: node['security'],
    xtls_flow: node['xtls_flow'],
    enabled: node['enabled'],
    listen: node['listen'],
    connect: node['connect'],
    auth: deep_resolve(node['auth'], secrets),
    tls: deep_resolve(node['tls'], secrets),
    reality: deep_resolve(node['reality'], secrets),
    export: (node['export'] || {}).merge(
      'server_ipv4' => target_info['public_ipv4'],
      'server_ipv6' => target_info['public_ipv6']
    ),
    link: link
  }
end

manifest = {
  generated_at: Time.now.utc.iso8601,
  project: {
    name: app_env['PROJECT_NAME'],
    namespace: app_env['PROJECT_NAMESPACE'],
    default_target: app_env['DEFAULT_TARGET'],
    enable_acme: app_env['ENABLE_ACME'],
    cert_mode: app_env['CERT_MODE'],
    cert_dir: app_env['CERT_DIR'],
    acme_provider: app_env['ACME_PROVIDER'],
    acme_email: app_env['ACME_EMAIL']
  },
  targets: targets,
  nodes: manifest_nodes,
  outbounds: outbounds,
  routing: routing,
  dns: dns,
  acme: acme,
  argo: argo,
  warp: warp,
  exports: exports
}

FileUtils.mkdir_p(output_dir)
File.write(File.join(output_dir, 'manifest.json'), JSON.pretty_generate(manifest) + "\n")

links = manifest_nodes.map { |node| node[:link] }.compact
File.write(File.join(output_dir, 'links.txt'), links.join("\n") + (links.empty? ? '' : "\n"))

v2rayn_links = manifest_nodes
  .select { |node| node.dig(:export, 'clients')&.include?('v2rayn') }
  .map { |node| node[:link] }
  .compact
File.write(File.join(output_dir, 'nodes-v2rayn.txt'), v2rayn_links.join("\n") + (v2rayn_links.empty? ? '' : "\n"))

shadowrocket_links = manifest_nodes
  .select { |node| node.dig(:export, 'clients')&.include?('shadowrocket') }
  .map { |node| node[:link] }
  .compact
File.write(File.join(output_dir, 'nodes-shadowrocket.txt'), shadowrocket_links.join("\n") + (shadowrocket_links.empty? ? '' : "\n"))

acme_requests = manifest_nodes.each_with_object([]) do |node, memo|
  tls = node[:tls] || {}
  next unless tls['cert_mode'] == 'acme'

  host = node.dig(:connect, 'host')
  next if host.nil? || host.empty?

  target_acme = manifest.fetch(:acme, {}).fetch('targets', {}).fetch(node[:target], {}) rescue {}
  challenge = target_acme['challenge'] || manifest.fetch(:acme, {})['default_challenge'] || 'standalone'
  standalone_port = target_acme['standalone_port'] || manifest.fetch(:acme, {})['standalone_port'] || 80
  dns_provider = target_acme['dns_provider'] || manifest.fetch(:acme, {})['dns_provider']
  dns_env = target_acme['dns_env'] || manifest.fetch(:acme, {})['dns_env'] || {}
  domains = [host, node.dig(:connect, 'sni')].compact.uniq

  memo << {
    node_id: node[:id],
    target: node[:target],
    domains: domains,
    main_domain: domains.first,
    challenge: challenge,
    standalone_port: standalone_port,
    key_type: target_acme['key_type'] || manifest.fetch(:acme, {})['default_key_type'] || 'ec-256',
    server: target_acme['ca'] || manifest.fetch(:acme, {})['default_ca'] || app_env['ACME_PROVIDER'] || 'letsencrypt',
    email: app_env['ACME_EMAIL'],
    install_dir: manifest.fetch(:acme, {})['install_dir'] || '/root/.acme.sh',
    reload_mode: manifest.fetch(:acme, {})['renew_reload_mode'] || 'restart',
    dns_provider: dns_provider,
    dns_env: deep_resolve(dns_env, secrets),
    cert_path: node.dig(:tls, 'cert_ref', 'fullchain'),
    key_path: node.dig(:tls, 'cert_ref', 'privkey')
  }
end
File.write(File.join(output_dir, 'acme-plan.json'), JSON.pretty_generate(acme_requests) + "\n")

node_notes = +"# Node Notes\n\n"
manifest_nodes.each do |node|
  node_notes << "## #{node[:id]}\n"
  node_notes << "- Type: #{node_transport_label(node)}\n"
  node_notes << "- Target: #{node[:target]}\n"
  node_notes << "- Port: #{node.dig(:listen, 'port')}\n"
  node_notes << "- Host: #{node.dig(:connect, 'host')}\n"
  node_notes << "- Clients: #{Array(node.dig(:export, 'clients')).join(', ')}\n"
  node_notes << "- Note: #{node_usage_note(node)}\n"
  node_notes << "\n"
end
File.write(File.join(output_dir, 'node-notes.md'), node_notes)

clash_redir_path = File.join(output_dir, 'clash-verge-redir-host.yaml')
clash_fakeip_path = File.join(output_dir, 'clash-verge-fake-ip.yaml')

clash_proxies = manifest_nodes
  .select { |node| node.dig(:export, 'clients')&.include?('clash') }
  .select { |node| clash_exportable_node?(node) }
  .map { |node| clash_proxy_for(node) }
  .compact

proxy_names = clash_proxies.map { |proxy| proxy['name'] }
dns_main = clash_dns_server_addresses(dns, %w[dns-main dns-cn])
dns_fallback = clash_dns_server_addresses(dns, ['dns-fallback'])

clash_dns_base = {
  'enable' => true,
  'ipv6' => true,
  'respect-rules' => true,
  'use-hosts' => true,
  'default-nameserver' => %w[223.5.5.5 1.1.1.1],
  'proxy-server-nameserver' => dns_main.empty? ? ['https://1.1.1.1/dns-query'] : dns_main,
  'nameserver' => dns_main.empty? ? ['https://1.1.1.1/dns-query'] : dns_main
}
clash_dns_base['fallback'] = dns_fallback unless dns_fallback.empty?

clash_base = {
  'mixed-port' => 7890,
  'allow-lan' => false,
  'mode' => 'rule',
  'log-level' => 'info',
  'ipv6' => true,
  'proxies' => clash_proxies,
  'proxy-groups' => [
    {
      'name' => 'PROXY',
      'type' => 'select',
      'proxies' => ['AUTO'] + proxy_names + ['DIRECT']
    },
    {
      'name' => 'AUTO',
      'type' => 'url-test',
      'proxies' => proxy_names,
      'url' => 'https://cp.cloudflare.com/generate_204',
      'interval' => 300
    }
  ],
  'rules' => [
    'DOMAIN-SUFFIX,local,DIRECT',
    'DOMAIN-SUFFIX,lan,DIRECT',
    'IP-CIDR,127.0.0.0/8,DIRECT,no-resolve',
    'IP-CIDR,10.0.0.0/8,DIRECT,no-resolve',
    'IP-CIDR,172.16.0.0/12,DIRECT,no-resolve',
    'IP-CIDR,192.168.0.0/16,DIRECT,no-resolve',
    'IP-CIDR,::1/128,DIRECT,no-resolve',
    'IP-CIDR,fc00::/7,DIRECT,no-resolve',
    'MATCH,PROXY'
  ]
}

clash_redir = clash_base.merge(
  'dns' => clash_dns_base.merge(
    'enhanced-mode' => 'redir-host'
  )
)

clash_fakeip = clash_base.merge(
  'dns' => clash_dns_base.merge(
    'enhanced-mode' => 'fake-ip',
    'fake-ip-range' => '198.18.0.1/16',
    'fake-ip-filter' => [
      '*.lan',
      '*.local',
      'localhost',
      '+.msftconnecttest.com',
      '+.msftncsi.com'
    ]
  )
)

File.write(clash_redir_path, YAML.dump(clash_redir))
File.write(clash_fakeip_path, YAML.dump(clash_fakeip))
