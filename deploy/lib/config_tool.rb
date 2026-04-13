#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'
require 'securerandom'
require 'base64'
require 'shellwords'

config_dir = ARGV.shift
secrets_file = ARGV.shift
command = ARGV.shift

abort 'usage: config_tool.rb <config_dir> <secrets_file> <command> [args...]' unless config_dir && secrets_file && command

def load_yaml(path)
  YAML.safe_load(File.read(path), permitted_classes: [], aliases: false) || {}
end

def dump_yaml(data)
  YAML.dump(data, line_width: -1).sub(/\A---\s*\n/, '')
end

def save_yaml(path, data)
  File.write(path, dump_yaml(data))
end

def load_env(path)
  env = {}
  return env unless File.exist?(path)

  File.readlines(path, chomp: true).each do |line|
    next if line.strip.empty? || line.strip.start_with?('#')
    key, value = line.split('=', 2)
    next if key.nil? || value.nil?
    env[key] = value
  end
  env
end

def save_env_values(path, updates)
  lines = File.exist?(path) ? File.readlines(path, chomp: true) : []
  pending = updates.dup
  written = lines.map do |line|
    if !line.strip.empty? && !line.strip.start_with?('#') && line.include?('=')
      key, = line.split('=', 2)
      if pending.key?(key)
        value = pending.delete(key)
        "#{key}=#{value}"
      else
        line
      end
    else
      line
    end
  end

  unless pending.empty?
    written << '' unless written.empty? || written.last.empty?
    pending.each do |key, value|
      written << "#{key}=#{value}"
    end
  end

  File.write(path, written.join("\n") + "\n")
end

def parse_kv(argv)
  options = {}
  until argv.empty?
    key = argv.shift
    abort "invalid option #{key}" unless key.start_with?('--')
    value = argv.shift
    abort "missing value for #{key}" if value.nil?
    options[key.sub(/\A--/, '')] = value
  end
  options
end

def bool_value(value)
  case value.to_s
  when 'true', '1', 'yes', 'on'
    true
  when 'false', '0', 'no', 'off'
    false
  else
    abort "invalid boolean value: #{value}"
  end
end

def env_key_prefix(id)
  id.to_s.upcase.gsub(/[^A-Z0-9]+/, '_')
end

def random_password(length = 24)
  alphabet = [('a'..'z'), ('A'..'Z'), ('0'..'9')].flat_map(&:to_a)
  Array.new(length) { alphabet[SecureRandom.random_number(alphabet.length)] }.join
end

def random_short_id
  SecureRandom.hex(4)
end

def random_ss2022_key
  Base64.strict_encode64(SecureRandom.random_bytes(16))
end

def xray_binary_candidates
  runtime_dir = ENV['BIU_RUNTIME_DIR']
  [
    ENV['BIU_XRAY_BIN'],
    runtime_dir && File.join(runtime_dir, 'bin', 'xray'),
    'xray',
    '/opt/myproxy/bin/xray'
  ].compact.uniq
end

def generate_reality_keypair
  bin = xray_binary_candidates.find do |candidate|
    candidate == 'xray' ? system('command -v xray >/dev/null 2>&1') : File.executable?(candidate)
  end
  abort 'unable to generate REALITY keypair: xray binary not found' unless bin

  output = `#{Shellwords.escape(bin)} x25519 2>/dev/null`
  private_key = output[/Private key:\s*([A-Za-z0-9._-]+)/, 1]
  public_key = output[/Public key:\s*([A-Za-z0-9._-]+)/, 1]
  abort 'failed to parse xray x25519 output' unless private_key && public_key

  [private_key, public_key]
end

def normalize_port(value)
  return value if value.is_a?(String) && value.include?('-')
  Integer(value)
end

def tls_ref(cert_dir)
  {
    'cert_mode' => 'acme',
    'cert_ref' => {
      'fullchain' => "#{cert_dir}/fullchain.pem",
      'privkey' => "#{cert_dir}/privkey.pem"
    }
  }
end

def default_export_groups(protocol, transport, security)
  return %w[default reality-only v4-only v6-only] if protocol == 'vless' && security == 'reality'
  return %w[default udp-only] if %w[hysteria2 tuic].include?(protocol)
  return %w[default fallback-only] if protocol == 'ss2022'

  ['default']
end

def xray_tls_node(id:, group:, target:, stack:, port:, host:, protocol:, transport:, auth:, tls:, connect:, extra: {})
  {
    'id' => id,
    'enabled' => true,
    'group' => group,
    'target' => target,
    'core' => 'xray',
    'protocol' => protocol,
    'transport' => transport,
    'security' => 'tls',
    'listen' => { 'stack' => stack, 'port' => port },
    'connect' => connect.merge('host' => host),
    'auth' => auth,
    'tls' => tls,
    'export' => {
      'enabled' => true,
      'groups' => default_export_groups(protocol, transport, 'tls'),
      'clients' => %w[v2rayn clash shadowrocket]
    }
  }.merge(extra)
end

def xray_plain_node(id:, group:, target:, stack:, port:, host:, protocol:, transport:, auth:, connect:, extra: {})
  {
    'id' => id,
    'enabled' => true,
    'group' => group,
    'target' => target,
    'core' => 'xray',
    'protocol' => protocol,
    'transport' => transport,
    'security' => 'none',
    'listen' => { 'stack' => stack, 'port' => port },
    'connect' => connect.merge('host' => host),
    'auth' => auth,
    'export' => {
      'enabled' => true,
      'groups' => ['default'],
      'clients' => %w[v2rayn clash shadowrocket]
    }
  }.merge(extra)
end

app_env = load_env(File.join(config_dir, 'app.env.example'))
nodes_path = File.join(config_dir, 'nodes.yaml')
outbounds_path = File.join(config_dir, 'outbounds.yaml')
dns_path = File.join(config_dir, 'dns.yaml')
routing_path = File.join(config_dir, 'routing.yaml')

nodes_data = load_yaml(nodes_path)
outbounds_data = load_yaml(outbounds_path)
dns_data = load_yaml(dns_path)
routing_data = load_yaml(routing_path)
secrets = load_env(secrets_file)

nodes = Array(nodes_data['nodes'])
outbounds = Array(outbounds_data['outbounds'])
outbound_groups = Array(outbounds_data['outbound_groups'])

find_node = lambda do |id|
  nodes.find { |node| node['id'] == id } || abort("node not found: #{id}")
end

find_outbound = lambda do |id|
  outbounds.find { |outbound| outbound['id'] == id } || abort("outbound not found: #{id}")
end

find_outbound_group = lambda do |id|
  outbound_groups.find { |group| group['id'] == id } || abort("outbound group not found: #{id}")
end

cert_base_dir = app_env['CERT_DIR'] || '/opt/myproxy/certs'

case command
when 'node-add'
  opts = parse_kv(ARGV)
  preset = opts.fetch('preset')
  target = opts.fetch('target')
  host = opts.fetch('host')
  id = opts['id'] || "#{preset}-#{target}"
  abort "node already exists: #{id}" if nodes.any? { |node| node['id'] == id }
  port = normalize_port(opts['port'] || case preset
                                        when 'reality-main', 'hy2-main' then 443
                                        when 'ss2022-fallback', 'ss2022-main' then 24444
                                        when 'tuic-alt' then 8443
                                        when 'ws-tls-main', 'vless-ws-tls' then 8444
                                        when 'vmess-legacy', 'vmess-ws-tls' then 8445
                                        when 'vmess-grpc-tls' then 9445
                                        when 'vless-grpc-tls' then 9444
                                        when 'vless-xhttp-tls' then 10443
                                        when 'trojan-ws-tls' then 10444
                                        when 'trojan-grpc-tls' then 11443
                                        when 'vmess-tcp' then 20080
                                        when 'vmess-mkcp' then 20081
                                        when 'vmess-tcp-dynamic' then '20000-20100'
                                        when 'vmess-mkcp-dynamic' then '20101-20200'
                                        else 8443
                                        end)
  group = opts['group'] || 'default'
  stack = opts['stack'] || 'dual'
  cert_dir = File.join(cert_base_dir, id)
  prefix = env_key_prefix(id)
  updates = {}

  node =
    case preset
    when 'reality-main'
      uuid_ref = "#{prefix}_UUID"
      private_ref = "#{prefix}_PRIVATE_KEY"
      public_ref = "#{prefix}_PUBLIC_KEY"
      private_key, public_key = generate_reality_keypair
      updates[uuid_ref] = SecureRandom.uuid
      updates[private_ref] = private_key
      updates[public_ref] = public_key
      target_host = opts['reality-target-host'] || 'www.microsoft.com'
      server_name = opts['server-name'] || target_host
      {
        'id' => id,
        'enabled' => true,
        'group' => group,
        'target' => target,
        'core' => 'xray',
        'protocol' => 'vless',
        'transport' => 'tcp',
        'security' => 'reality',
        'xtls_flow' => 'xtls-rprx-vision',
        'listen' => { 'stack' => stack, 'port' => port },
        'connect' => { 'host' => host, 'sni' => nil },
        'auth' => { 'uuid_ref' => uuid_ref },
        'reality' => {
          'mode' => 'vision',
          'target_host' => target_host,
          'target_port' => 443,
          'server_names' => [server_name],
          'short_ids' => [opts['short-id'] || random_short_id],
          'spider_x_pattern' => '/?ed=2048',
          'key_ref' => { 'private' => private_ref, 'public' => public_ref }
        },
        'export' => {
          'enabled' => true,
          'groups' => %w[default reality-only v4-only v6-only],
          'clients' => %w[v2rayn clash shadowrocket]
        }
      }
    when 'ws-tls-main', 'vless-ws-tls'
      uuid_ref = "#{prefix}_UUID"
      updates[uuid_ref] = SecureRandom.uuid
      xray_tls_node(
        id: id,
        group: group,
        target: target,
        stack: stack,
        port: port,
        host: host,
        protocol: 'vless',
        transport: 'ws',
        auth: { 'uuid_ref' => uuid_ref },
        tls: tls_ref(cert_dir),
        connect: { 'sni' => opts['sni'] || host, 'path' => opts['path'] || "/ws-#{random_short_id}", 'ws_host' => opts['ws-host'] || host }
      )
    when 'vless-grpc-tls'
      uuid_ref = "#{prefix}_UUID"
      updates[uuid_ref] = SecureRandom.uuid
      xray_tls_node(
        id: id,
        group: group,
        target: target,
        stack: stack,
        port: port,
        host: host,
        protocol: 'vless',
        transport: 'grpc',
        auth: { 'uuid_ref' => uuid_ref },
        tls: tls_ref(cert_dir),
        connect: { 'sni' => opts['sni'] || host, 'service_name' => opts['service-name'] || "grpc-#{random_short_id}" }
      )
    when 'vless-xhttp-tls'
      uuid_ref = "#{prefix}_UUID"
      updates[uuid_ref] = SecureRandom.uuid
      xray_tls_node(
        id: id,
        group: group,
        target: target,
        stack: stack,
        port: port,
        host: host,
        protocol: 'vless',
        transport: 'xhttp',
        auth: { 'uuid_ref' => uuid_ref },
        tls: tls_ref(cert_dir),
        connect: {
          'sni' => opts['sni'] || host,
          'path' => opts['path'] || "/xhttp-#{random_short_id}",
          'xhttp_host' => opts['xhttp-host'] || host,
          'xhttp_mode' => opts['xhttp-mode'] || 'auto'
        }
      )
    when 'hy2-main'
      password_ref = "#{prefix}_PASSWORD"
      updates[password_ref] = random_password(32)
      {
        'id' => id,
        'enabled' => true,
        'group' => group,
        'target' => target,
        'core' => 'sing-box',
        'protocol' => 'hysteria2',
        'transport' => 'quic',
        'security' => 'tls',
        'listen' => { 'stack' => stack, 'port' => port },
        'connect' => { 'host' => host, 'sni' => opts['sni'] || host },
        'tls' => {
          'cert_mode' => 'acme',
          'alpn' => ['h3'],
          'cert_ref' => {
            'fullchain' => "#{cert_dir}/fullchain.pem",
            'privkey' => "#{cert_dir}/privkey.pem"
          }
        },
        'auth' => { 'password_ref' => password_ref },
        'export' => {
          'enabled' => true,
          'groups' => %w[default udp-only],
          'clients' => %w[v2rayn clash shadowrocket]
        }
      }
    when 'tuic-alt'
      uuid_ref = "#{prefix}_UUID"
      password_ref = "#{prefix}_PASSWORD"
      updates[uuid_ref] = SecureRandom.uuid
      updates[password_ref] = random_password(32)
      {
        'id' => id,
        'enabled' => true,
        'group' => group,
        'target' => target,
        'core' => 'sing-box',
        'protocol' => 'tuic',
        'transport' => 'quic',
        'security' => 'tls',
        'listen' => { 'stack' => stack, 'port' => port },
        'connect' => { 'host' => host, 'sni' => opts['sni'] || host },
        'tls' => {
          'cert_mode' => 'acme',
          'alpn' => ['h3'],
          'cert_ref' => {
            'fullchain' => "#{cert_dir}/fullchain.pem",
            'privkey' => "#{cert_dir}/privkey.pem"
          }
        },
        'auth' => { 'uuid_ref' => uuid_ref, 'password_ref' => password_ref },
        'export' => {
          'enabled' => true,
          'groups' => %w[default udp-only],
          'clients' => %w[v2rayn clash shadowrocket]
        }
      }
    when 'ss2022-fallback'
      password_ref = "#{prefix}_PASSWORD"
      updates[password_ref] = random_ss2022_key
      {
        'id' => id,
        'enabled' => true,
        'group' => group,
        'target' => target,
        'core' => 'sing-box',
        'protocol' => 'ss2022',
        'transport' => 'tcpudp',
        'listen' => { 'stack' => stack, 'port' => port },
        'connect' => { 'host' => host },
        'auth' => { 'method' => '2022-blake3-aes-128-gcm', 'password_ref' => password_ref },
        'export' => {
          'enabled' => true,
          'groups' => %w[default fallback-only],
          'clients' => %w[v2rayn clash shadowrocket]
        }
      }
    when 'ss2022-main'
      password_ref = "#{prefix}_PASSWORD"
      updates[password_ref] = random_ss2022_key
      {
        'id' => id,
        'enabled' => true,
        'group' => group,
        'target' => target,
        'core' => 'sing-box',
        'protocol' => 'ss2022',
        'transport' => 'tcpudp',
        'listen' => { 'stack' => stack, 'port' => port },
        'connect' => { 'host' => host },
        'auth' => { 'method' => '2022-blake3-aes-128-gcm', 'password_ref' => password_ref },
        'export' => {
          'enabled' => true,
          'groups' => %w[default fallback-only],
          'clients' => %w[v2rayn clash shadowrocket]
        }
      }
    when 'vmess-legacy', 'vmess-ws-tls'
      uuid_ref = "#{prefix}_UUID"
      updates[uuid_ref] = SecureRandom.uuid
      xray_tls_node(
        id: id,
        group: group,
        target: target,
        stack: stack,
        port: port,
        host: host,
        protocol: 'vmess',
        transport: 'ws',
        auth: { 'uuid_ref' => uuid_ref },
        tls: tls_ref(cert_dir),
        connect: { 'sni' => opts['sni'] || host, 'path' => opts['path'] || "/vm-#{random_short_id}", 'ws_host' => opts['ws-host'] || host }
      )
    when 'vmess-grpc-tls'
      uuid_ref = "#{prefix}_UUID"
      updates[uuid_ref] = SecureRandom.uuid
      xray_tls_node(
        id: id,
        group: group,
        target: target,
        stack: stack,
        port: port,
        host: host,
        protocol: 'vmess',
        transport: 'grpc',
        auth: { 'uuid_ref' => uuid_ref },
        tls: tls_ref(cert_dir),
        connect: { 'sni' => opts['sni'] || host, 'service_name' => opts['service-name'] || "grpc-#{random_short_id}" }
      )
    when 'vmess-tcp'
      uuid_ref = "#{prefix}_UUID"
      updates[uuid_ref] = SecureRandom.uuid
      xray_plain_node(
        id: id,
        group: group,
        target: target,
        stack: stack,
        port: port,
        host: host,
        protocol: 'vmess',
        transport: 'tcp',
        auth: { 'uuid_ref' => uuid_ref },
        connect: {}
      )
    when 'vmess-mkcp'
      uuid_ref = "#{prefix}_UUID"
      updates[uuid_ref] = SecureRandom.uuid
      xray_plain_node(
        id: id,
        group: group,
        target: target,
        stack: stack,
        port: port,
        host: host,
        protocol: 'vmess',
        transport: 'mkcp',
        auth: { 'uuid_ref' => uuid_ref },
        connect: { 'mkcp_header_type' => opts['mkcp-header-type'] || 'none' }
      )
    when 'vmess-tcp-dynamic'
      uuid_ref = "#{prefix}_UUID"
      updates[uuid_ref] = SecureRandom.uuid
      xray_plain_node(
        id: id,
        group: group,
        target: target,
        stack: stack,
        port: port,
        host: host,
        protocol: 'vmess',
        transport: 'tcp',
        auth: { 'uuid_ref' => uuid_ref },
        connect: {},
        extra: {
          'dynamic_port' => {
            'enabled' => true,
            'strategy' => opts['dynamic-strategy'] || 'random',
            'refresh' => Integer(opts['dynamic-refresh'] || 5),
            'concurrency' => Integer(opts['dynamic-concurrency'] || 1)
          }
        }
      )
    when 'vmess-mkcp-dynamic'
      uuid_ref = "#{prefix}_UUID"
      updates[uuid_ref] = SecureRandom.uuid
      xray_plain_node(
        id: id,
        group: group,
        target: target,
        stack: stack,
        port: port,
        host: host,
        protocol: 'vmess',
        transport: 'mkcp',
        auth: { 'uuid_ref' => uuid_ref },
        connect: { 'mkcp_header_type' => opts['mkcp-header-type'] || 'none' },
        extra: {
          'dynamic_port' => {
            'enabled' => true,
            'strategy' => opts['dynamic-strategy'] || 'random',
            'refresh' => Integer(opts['dynamic-refresh'] || 5),
            'concurrency' => Integer(opts['dynamic-concurrency'] || 1)
          }
        }
      )
    when 'trojan-ws-tls'
      password_ref = "#{prefix}_PASSWORD"
      updates[password_ref] = random_password(24)
      xray_tls_node(
        id: id,
        group: group,
        target: target,
        stack: stack,
        port: port,
        host: host,
        protocol: 'trojan',
        transport: 'ws',
        auth: { 'password_ref' => password_ref },
        tls: tls_ref(cert_dir),
        connect: { 'sni' => opts['sni'] || host, 'path' => opts['path'] || "/trojan-#{random_short_id}", 'ws_host' => opts['ws-host'] || host }
      )
    when 'trojan-grpc-tls'
      password_ref = "#{prefix}_PASSWORD"
      updates[password_ref] = random_password(24)
      xray_tls_node(
        id: id,
        group: group,
        target: target,
        stack: stack,
        port: port,
        host: host,
        protocol: 'trojan',
        transport: 'grpc',
        auth: { 'password_ref' => password_ref },
        tls: tls_ref(cert_dir),
        connect: { 'sni' => opts['sni'] || host, 'service_name' => opts['service-name'] || "grpc-#{random_short_id}" }
      )
    else
      abort "unknown preset: #{preset}"
    end

  nodes << node
  nodes_data['nodes'] = nodes
  save_yaml(nodes_path, nodes_data)
  save_env_values(secrets_file, updates) unless updates.empty?
  puts "node-added #{id}"
when 'node-toggle'
  opts = parse_kv(ARGV)
  node = find_node.call(opts.fetch('id'))
  node['enabled'] = bool_value(opts.fetch('enabled'))
  save_yaml(nodes_path, nodes_data)
  puts "node-toggled #{node['id']}=#{node['enabled']}"
when 'node-set-port'
  opts = parse_kv(ARGV)
  node = find_node.call(opts.fetch('id'))
  node['listen'] ||= {}
  node['listen']['port'] = normalize_port(opts.fetch('port'))
  save_yaml(nodes_path, nodes_data)
  puts "node-port #{node['id']}=#{node.dig('listen', 'port')}"
when 'node-rotate-secret'
  opts = parse_kv(ARGV)
  node = find_node.call(opts.fetch('id'))
  prefix = env_key_prefix(node['id'])
  updates = {}
  case node['protocol']
  when 'vless', 'vmess'
    ref = node.dig('auth', 'uuid_ref') || "#{prefix}_UUID"
    node['auth'] ||= {}
    node['auth']['uuid_ref'] = ref
    updates[ref] = SecureRandom.uuid
  when 'hysteria2'
    ref = node.dig('auth', 'password_ref') || "#{prefix}_PASSWORD"
    node['auth'] ||= {}
    node['auth']['password_ref'] = ref
    updates[ref] = random_password(32)
  when 'tuic'
    uuid_ref = node.dig('auth', 'uuid_ref') || "#{prefix}_UUID"
    password_ref = node.dig('auth', 'password_ref') || "#{prefix}_PASSWORD"
    node['auth'] ||= {}
    node['auth']['uuid_ref'] = uuid_ref
    node['auth']['password_ref'] = password_ref
    updates[uuid_ref] = SecureRandom.uuid
    updates[password_ref] = random_password(32)
  when 'ss2022'
    ref = node.dig('auth', 'password_ref') || "#{prefix}_PASSWORD"
    node['auth'] ||= {}
    node['auth']['password_ref'] = ref
    updates[ref] = random_ss2022_key
  when 'trojan'
    ref = node.dig('auth', 'password_ref') || "#{prefix}_PASSWORD"
    node['auth'] ||= {}
    node['auth']['password_ref'] = ref
    updates[ref] = random_password(24)
  end

  if node['security'] == 'reality'
    private_ref = node.dig('reality', 'key_ref', 'private') || "#{prefix}_PRIVATE_KEY"
    public_ref = node.dig('reality', 'key_ref', 'public') || "#{prefix}_PUBLIC_KEY"
    private_key, public_key = generate_reality_keypair
    node['reality'] ||= {}
    node['reality']['key_ref'] = { 'private' => private_ref, 'public' => public_ref }
    node['reality']['short_ids'] = [random_short_id]
    updates[private_ref] = private_key
    updates[public_ref] = public_key
  end

  save_yaml(nodes_path, nodes_data)
  save_env_values(secrets_file, updates) unless updates.empty?
  puts "node-rotated #{node['id']}"
when 'node-delete'
  opts = parse_kv(ARGV)
  id = opts.fetch('id')
  before = nodes.length
  nodes.reject! { |node| node['id'] == id }
  abort "node not found: #{id}" if before == nodes.length
  nodes_data['nodes'] = nodes
  save_yaml(nodes_path, nodes_data)
  puts "node-deleted #{id}"
when 'outbound-add-socks5'
  opts = parse_kv(ARGV)
  id = opts.fetch('id')
  abort "outbound already exists: #{id}" if outbounds.any? { |outbound| outbound['id'] == id }
  role = opts.fetch('role')
  prefix = env_key_prefix(id)
  user_ref = "#{prefix}_USER"
  pass_ref = "#{prefix}_PASS"
  save_env_values(secrets_file, {
                    user_ref => opts.fetch('user'),
                    pass_ref => opts.fetch('pass')
                  })
  outbound = {
    'id' => id,
    'role' => role,
    'type' => 'socks5',
    'enabled' => bool_value(opts['enabled'] || 'true'),
    'server' => opts.fetch('server'),
    'port' => Integer(opts.fetch('port')),
    'auth_ref' => { 'user' => user_ref, 'pass' => pass_ref },
    'udp' => bool_value(opts['udp'] || 'true'),
    'stack' => opts['stack'] || 'dual',
    'domain_resolver' => opts['domain_resolver'] || 'dns-main',
    'export_tag' => role
  }
  outbounds << outbound
  group = outbound_groups.find { |item| item['id'] == 'residential-auto' }
  if group
    group['members'] = Array(group['members'])
    group['members'] << id unless group['members'].include?(id)
  end
  outbounds_data['outbounds'] = outbounds
  outbounds_data['outbound_groups'] = outbound_groups
  save_yaml(outbounds_path, outbounds_data)
  puts "outbound-added #{id}"
when 'outbound-toggle'
  opts = parse_kv(ARGV)
  outbound = find_outbound.call(opts.fetch('id'))
  outbound['enabled'] = bool_value(opts.fetch('enabled'))
  save_yaml(outbounds_path, outbounds_data)
  puts "outbound-toggled #{outbound['id']}=#{outbound['enabled']}"
when 'outbound-set-server'
  opts = parse_kv(ARGV)
  outbound = find_outbound.call(opts.fetch('id'))
  outbound['server'] = opts.fetch('server')
  outbound['port'] = Integer(opts.fetch('port'))
  save_yaml(outbounds_path, outbounds_data)
  puts "outbound-server #{outbound['id']}=#{outbound['server']}:#{outbound['port']}"
when 'outbound-set-credentials'
  opts = parse_kv(ARGV)
  outbound = find_outbound.call(opts.fetch('id'))
  user_ref = outbound.dig('auth_ref', 'user') || "#{env_key_prefix(outbound['id'])}_USER"
  pass_ref = outbound.dig('auth_ref', 'pass') || "#{env_key_prefix(outbound['id'])}_PASS"
  outbound['auth_ref'] = { 'user' => user_ref, 'pass' => pass_ref }
  save_yaml(outbounds_path, outbounds_data)
  save_env_values(secrets_file, {
                    user_ref => opts.fetch('user'),
                    pass_ref => opts.fetch('pass')
                  })
  puts "outbound-credentials #{outbound['id']}"
when 'outbound-group-set'
  opts = parse_kv(ARGV)
  group = find_outbound_group.call(opts.fetch('id'))
  group['members'] = opts.fetch('members').split(',').map(&:strip).reject(&:empty?)
  save_yaml(outbounds_path, outbounds_data)
  puts "outbound-group #{group['id']}=#{group['members'].join(',')}"
when 'outbound-delete'
  opts = parse_kv(ARGV)
  id = opts.fetch('id')
  before = outbounds.length
  outbounds.reject! { |outbound| outbound['id'] == id }
  abort "outbound not found: #{id}" if before == outbounds.length
  outbound_groups.each do |group|
    group['members'] = Array(group['members']).reject { |member| member == id }
  end
  outbounds_data['outbounds'] = outbounds
  outbounds_data['outbound_groups'] = outbound_groups
  save_yaml(outbounds_path, outbounds_data)
  puts "outbound-deleted #{id}"
when 'dns-set-global'
  opts = parse_kv(ARGV)
  dns_data['dns'] ||= {}
  dns_data['dns']['policies'] ||= {}
  dns_data['dns']['policies']['global'] ||= {}
  dns_data['dns']['policies']['global']['server'] = opts.fetch('server')
  save_yaml(dns_path, dns_data)
  puts "dns-global #{opts['server']}"
when 'dns-add-server'
  opts = parse_kv(ARGV)
  dns_data['dns'] ||= {}
  dns_data['dns']['servers'] ||= []
  servers = dns_data['dns']['servers']
  abort "dns server already exists: #{opts['id']}" if servers.any? { |server| server['id'] == opts['id'] }
  servers << {
    'id' => opts.fetch('id'),
    'type' => opts.fetch('type'),
    'address' => opts.fetch('address')
  }
  save_yaml(dns_path, dns_data)
  puts "dns-server-added #{opts['id']}"
when 'route-set-final'
  opts = parse_kv(ARGV)
  routing_data['routing'] ||= {}
  routing_data['routing']['defaults'] ||= {}
  routing_data['routing']['defaults']['final_outbound'] = opts.fetch('outbound')
  save_yaml(routing_path, routing_data)
  puts "route-final #{opts['outbound']}"
when 'route-toggle-default'
  opts = parse_kv(ARGV)
  field = opts.fetch('field')
  abort "unsupported default field: #{field}" unless %w[block_bittorrent block_udp_443].include?(field)
  routing_data['routing'] ||= {}
  routing_data['routing']['defaults'] ||= {}
  routing_data['routing']['defaults'][field] = bool_value(opts.fetch('enabled'))
  save_yaml(routing_path, routing_data)
  puts "route-default #{field}=#{routing_data['routing']['defaults'][field]}"
else
  abort "unknown command: #{command}"
end
