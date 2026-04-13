#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'

manifest_path = ARGV[0]
runtime_config_dir = ARGV[1]
domains_dir = ARGV[2]

abort 'usage: render_runtime_configs.rb <manifest.json> <runtime_config_dir> <domains_dir>' unless manifest_path && runtime_config_dir && domains_dir

manifest = JSON.parse(File.read(manifest_path))
FileUtils.mkdir_p(runtime_config_dir)

default_target = manifest.dig('project', 'default_target')
nodes = manifest.fetch('nodes', []).select { |node| node['target'] == default_target && node['enabled'] }
outbounds_payload = manifest.fetch('outbounds', {})
outbounds = outbounds_payload.fetch('outbounds', []).select { |outbound| outbound['enabled'] }
outbound_groups = outbounds_payload.fetch('outbound_groups', [])
routing = manifest.fetch('routing', {}).fetch('routing', {})
dns = manifest.fetch('dns', {}).fetch('dns', {})

def load_domain_group(domains_dir, group_name)
  path = File.join(domains_dir, "#{group_name}.list")
  return [] unless File.exist?(path)

  File.readlines(path, chomp: true).map(&:strip).reject(&:empty?).reject { |line| line.start_with?('#') }
end

def xray_domain_strategy(stack)
  case stack
  when 'ipv6'
    'UseIPv6v4'
  else
    'UseIPv4v6'
  end
end

def singbox_domain_strategy(stack)
  case stack
  when 'ipv6'
    'prefer_ipv6'
  when 'ipv4'
    'prefer_ipv4'
  else
    'prefer_ipv4'
  end
end

enabled_outbound_ids = outbounds.map { |outbound| outbound['id'] }

resolve_xray_outbound = lambda do |outbound_id|
  return outbound_id if enabled_outbound_ids.include?(outbound_id)

  group = outbound_groups.find { |item| item['id'] == outbound_id }
  return 'direct' unless group

  member = Array(group['members']).find { |item| enabled_outbound_ids.include?(item) }
  member || 'direct'
end

def normalize_domains(entries)
  entries.map do |entry|
    if entry.start_with?('domain:')
      entry
    elsif entry.start_with?('full:')
      entry
    else
      "domain:#{entry}"
    end
  end
end

def singbox_domain_suffix(entries)
  entries.map do |entry|
    if entry.start_with?('domain:')
      entry.sub('domain:', '')
    elsif entry.start_with?('full:')
      entry.sub('full:', '')
    end
  end.compact
end

xray_outbounds = outbounds.map do |outbound|
  case outbound['type']
  when 'direct'
    {
      'tag' => outbound['id'],
      'protocol' => 'freedom',
      'settings' => {
        'domainStrategy' => xray_domain_strategy(outbound['stack'])
      }
    }
  when 'block'
    {
      'tag' => outbound['id'],
      'protocol' => 'blackhole'
    }
  when 'socks5'
    {
      'tag' => outbound['id'],
      'protocol' => 'socks',
      'settings' => {
        'servers' => [
          {
            'address' => outbound['server'],
            'port' => outbound['port'],
            'users' => [
              {
                'user' => outbound.dig('auth_ref', 'user'),
                'pass' => outbound.dig('auth_ref', 'pass')
              }
            ]
          }
        ]
      }
    }
  end
end.compact

xray_dns_servers = []
global_policy = dns.fetch('policies', {}).fetch('global', {})
global_server = dns.fetch('servers', []).find { |server| server['id'] == global_policy['server'] }
xray_dns_servers << global_server['address'] if global_server

dns.fetch('policies', {}).each do |group_name, policy|
  next if group_name == 'global'
  server = dns.fetch('servers', []).find { |item| item['id'] == policy['server'] }
  next unless server

  domains = normalize_domains(load_domain_group(domains_dir, group_name))
  next if domains.empty?

  xray_dns_servers << {
    'address' => server['address'],
    'domains' => domains,
    'skipFallback' => true
  }
end

xray_inbounds = nodes.map do |node|
  case [node['protocol'], node['security'], node['transport']]
  when ['vless', 'reality', 'tcp']
    {
      'tag' => node['id'],
      'listen' => '::',
      'port' => node.dig('listen', 'port'),
      'protocol' => 'vless',
      'settings' => {
        'clients' => [
          {
            'id' => node.dig('auth', 'uuid_ref') || node.dig('auth', 'uuid'),
            'flow' => node['xtls_flow'] || 'xtls-rprx-vision'
          }
        ],
        'decryption' => 'none'
      },
      'streamSettings' => {
        'network' => 'tcp',
        'security' => 'reality',
        'realitySettings' => {
          'show' => false,
          'target' => "#{node.dig('reality', 'target_host')}:#{node.dig('reality', 'target_port') || 443}",
          'serverNames' => Array(node.dig('reality', 'server_names')),
          'privateKey' => node.dig('reality', 'key_ref', 'private') || node.dig('reality', 'private'),
          'shortIds' => Array(node.dig('reality', 'short_ids'))
        }
      },
      'sniffing' => {
        'enabled' => true,
        'destOverride' => %w[http tls quic]
      }
    }
  when ['vless', 'tls', 'ws']
    {
      'tag' => node['id'],
      'listen' => '::',
      'port' => node.dig('listen', 'port'),
      'protocol' => 'vless',
      'settings' => {
        'clients' => [
          {
            'id' => node.dig('auth', 'uuid_ref') || node.dig('auth', 'uuid')
          }
        ],
        'decryption' => 'none'
      },
      'streamSettings' => {
        'network' => 'ws',
        'security' => 'tls',
        'tlsSettings' => {
          'serverName' => node.dig('connect', 'sni') || node.dig('connect', 'host'),
          'certificates' => [
            {
              'certificateFile' => node.dig('tls', 'cert_ref', 'fullchain'),
              'keyFile' => node.dig('tls', 'cert_ref', 'privkey')
            }
          ]
        },
        'wsSettings' => {
          'path' => node.dig('connect', 'path') || '/'
        }
      }
    }
  when ['vmess', 'tls', 'ws']
    {
      'tag' => node['id'],
      'listen' => '::',
      'port' => node.dig('listen', 'port'),
      'protocol' => 'vmess',
      'settings' => {
        'clients' => [
          {
            'id' => node.dig('auth', 'uuid_ref') || node.dig('auth', 'uuid'),
            'alterId' => 0
          }
        ]
      },
      'streamSettings' => {
        'network' => 'ws',
        'security' => 'tls',
        'tlsSettings' => {
          'serverName' => node.dig('connect', 'sni') || node.dig('connect', 'host'),
          'certificates' => [
            {
              'certificateFile' => node.dig('tls', 'cert_ref', 'fullchain'),
              'keyFile' => node.dig('tls', 'cert_ref', 'privkey')
            }
          ]
        },
        'wsSettings' => {
          'path' => node.dig('connect', 'path') || '/'
        }
      }
    }
  when ['vmess', 'none', 'tcp']
    inbound = {
      'tag' => node['id'],
      'listen' => '::',
      'port' => node.dig('listen', 'port'),
      'protocol' => 'vmess',
      'settings' => {
        'clients' => [
          {
            'id' => node.dig('auth', 'uuid_ref') || node.dig('auth', 'uuid'),
            'alterId' => 0
          }
        ]
      },
      'streamSettings' => {
        'network' => 'tcp'
      }
    }
    if node.dig('dynamic_port', 'enabled')
      inbound['allocate'] = {
        'strategy' => node.dig('dynamic_port', 'strategy') || 'random',
        'refresh' => node.dig('dynamic_port', 'refresh') || 5,
        'concurrency' => node.dig('dynamic_port', 'concurrency') || 1
      }
    end
    inbound
  when ['vmess', 'none', 'mkcp']
    inbound = {
      'tag' => node['id'],
      'listen' => '::',
      'port' => node.dig('listen', 'port'),
      'protocol' => 'vmess',
      'settings' => {
        'clients' => [
          {
            'id' => node.dig('auth', 'uuid_ref') || node.dig('auth', 'uuid'),
            'alterId' => 0
          }
        ]
      },
      'streamSettings' => {
        'network' => 'kcp',
        'kcpSettings' => {
          'mtu' => node.dig('connect', 'mkcp_mtu') || 1350,
          'tti' => node.dig('connect', 'mkcp_tti') || 50,
          'uplinkCapacity' => node.dig('connect', 'mkcp_uplink_capacity') || 12,
          'downlinkCapacity' => node.dig('connect', 'mkcp_downlink_capacity') || 100,
          'congestion' => false
        }
      }
    }
    if node.dig('dynamic_port', 'enabled')
      inbound['allocate'] = {
        'strategy' => node.dig('dynamic_port', 'strategy') || 'random',
        'refresh' => node.dig('dynamic_port', 'refresh') || 5,
        'concurrency' => node.dig('dynamic_port', 'concurrency') || 1
      }
    end
    inbound
  when ['vmess', 'tls', 'grpc']
    {
      'tag' => node['id'],
      'listen' => '::',
      'port' => node.dig('listen', 'port'),
      'protocol' => 'vmess',
      'settings' => {
        'clients' => [
          {
            'id' => node.dig('auth', 'uuid_ref') || node.dig('auth', 'uuid'),
            'alterId' => 0
          }
        ]
      },
      'streamSettings' => {
        'network' => 'grpc',
        'security' => 'tls',
        'tlsSettings' => {
          'serverName' => node.dig('connect', 'sni') || node.dig('connect', 'host'),
          'certificates' => [
            {
              'certificateFile' => node.dig('tls', 'cert_ref', 'fullchain'),
              'keyFile' => node.dig('tls', 'cert_ref', 'privkey')
            }
          ]
        },
        'grpcSettings' => {
          'serviceName' => node.dig('connect', 'service_name') || 'grpc'
        }
      }
    }
  when ['vless', 'tls', 'grpc']
    {
      'tag' => node['id'],
      'listen' => '::',
      'port' => node.dig('listen', 'port'),
      'protocol' => 'vless',
      'settings' => {
        'clients' => [
          {
            'id' => node.dig('auth', 'uuid_ref') || node.dig('auth', 'uuid')
          }
        ],
        'decryption' => 'none'
      },
      'streamSettings' => {
        'network' => 'grpc',
        'security' => 'tls',
        'tlsSettings' => {
          'serverName' => node.dig('connect', 'sni') || node.dig('connect', 'host'),
          'certificates' => [
            {
              'certificateFile' => node.dig('tls', 'cert_ref', 'fullchain'),
              'keyFile' => node.dig('tls', 'cert_ref', 'privkey')
            }
          ]
        },
        'grpcSettings' => {
          'serviceName' => node.dig('connect', 'service_name') || 'grpc'
        }
      }
    }
  when ['vless', 'tls', 'xhttp']
    {
      'tag' => node['id'],
      'listen' => '::',
      'port' => node.dig('listen', 'port'),
      'protocol' => 'vless',
      'settings' => {
        'clients' => [
          {
            'id' => node.dig('auth', 'uuid_ref') || node.dig('auth', 'uuid')
          }
        ],
        'decryption' => 'none'
      },
      'streamSettings' => {
        'network' => 'xhttp',
        'security' => 'tls',
        'tlsSettings' => {
          'serverName' => node.dig('connect', 'sni') || node.dig('connect', 'host'),
          'certificates' => [
            {
              'certificateFile' => node.dig('tls', 'cert_ref', 'fullchain'),
              'keyFile' => node.dig('tls', 'cert_ref', 'privkey')
            }
          ]
        },
        'xhttpSettings' => {
          'path' => node.dig('connect', 'path') || '/xhttp',
          'host' => node.dig('connect', 'xhttp_host') || node.dig('connect', 'host'),
          'mode' => node.dig('connect', 'xhttp_mode') || 'auto'
        }
      }
    }
  when ['trojan', 'tls', 'ws']
    {
      'tag' => node['id'],
      'listen' => '::',
      'port' => node.dig('listen', 'port'),
      'protocol' => 'trojan',
      'settings' => {
        'clients' => [
          {
            'password' => node.dig('auth', 'password_ref') || node.dig('auth', 'password')
          }
        ]
      },
      'streamSettings' => {
        'network' => 'ws',
        'security' => 'tls',
        'tlsSettings' => {
          'serverName' => node.dig('connect', 'sni') || node.dig('connect', 'host'),
          'certificates' => [
            {
              'certificateFile' => node.dig('tls', 'cert_ref', 'fullchain'),
              'keyFile' => node.dig('tls', 'cert_ref', 'privkey')
            }
          ]
        },
        'wsSettings' => {
          'path' => node.dig('connect', 'path') || '/'
        }
      }
    }
  when ['trojan', 'tls', 'grpc']
    {
      'tag' => node['id'],
      'listen' => '::',
      'port' => node.dig('listen', 'port'),
      'protocol' => 'trojan',
      'settings' => {
        'clients' => [
          {
            'password' => node.dig('auth', 'password_ref') || node.dig('auth', 'password')
          }
        ]
      },
      'streamSettings' => {
        'network' => 'grpc',
        'security' => 'tls',
        'tlsSettings' => {
          'serverName' => node.dig('connect', 'sni') || node.dig('connect', 'host'),
          'certificates' => [
            {
              'certificateFile' => node.dig('tls', 'cert_ref', 'fullchain'),
              'keyFile' => node.dig('tls', 'cert_ref', 'privkey')
            }
          ]
        },
        'grpcSettings' => {
          'serviceName' => node.dig('connect', 'service_name') || 'grpc'
        }
      }
    }
  end
end.compact

xray_rules = []
if routing.dig('defaults', 'block_bittorrent')
  xray_rules << {
    'type' => 'field',
    'protocol' => ['bittorrent'],
    'outboundTag' => 'blocked'
  }
end

routing.fetch('rules', []).each do |rule|
  next unless rule['enabled']

  match = rule['match'] || {}
  outbound_tag = resolve_xray_outbound.call(rule.dig('action', 'outbound'))
  if match['inbound_tags']
    xray_rules << {
      'type' => 'field',
      'inboundTag' => Array(match['inbound_tags']),
      'outboundTag' => outbound_tag
    }
    next
  end

  groups = []
  groups << match['domain_group'] if match['domain_group']
  groups.concat(Array(match['domain_groups']))
  domains = groups.flat_map { |group_name| normalize_domains(load_domain_group(domains_dir, group_name)) }.uniq
  next if domains.empty?

  xray_rules << {
    'type' => 'field',
    'domain' => domains,
    'outboundTag' => outbound_tag
  }
end

xray_config = {
  'log' => {
    'loglevel' => 'warning'
  },
  'dns' => {
    'queryStrategy' => 'UseIP',
    'servers' => xray_dns_servers
  },
  'inbounds' => xray_inbounds,
  'outbounds' => xray_outbounds,
  'routing' => {
    'domainStrategy' => 'IPIfNonMatch',
    'rules' => xray_rules
  }
}

singbox_outbounds = outbounds.map do |outbound|
  case outbound['type']
  when 'direct'
    {
      'type' => 'direct',
      'tag' => outbound['id'],
      'domain_strategy' => singbox_domain_strategy(outbound['stack'])
    }
  when 'block'
    {
      'type' => 'block',
      'tag' => outbound['id']
    }
  when 'socks5'
    {
      'type' => 'socks',
      'tag' => outbound['id'],
      'server' => outbound['server'],
      'server_port' => outbound['port'],
      'username' => outbound.dig('auth_ref', 'user'),
      'password' => outbound.dig('auth_ref', 'pass'),
      'version' => '5',
      'domain_resolver' => outbound['domain_resolver']
    }
  end
end.compact

enabled_singbox_member_tags = singbox_outbounds.map { |outbound| outbound['tag'] }
rendered_groups = outbound_groups.map do |group|
  members = Array(group['members']).select { |member| enabled_singbox_member_tags.include?(member) }
  next if members.empty?
  {
    'type' => group['type'],
    'tag' => group['id'],
    'outbounds' => members,
    'url' => group['url'],
    'interval' => "#{group['interval'] || 300}s"
  }
end.compact
singbox_outbounds.concat(rendered_groups)
rendered_singbox_outbound_tags = singbox_outbounds.map { |outbound| outbound['tag'] }

dns_servers = dns.fetch('servers', []).map do |server|
  {
    'tag' => server['id'],
    'address' => server['address']
  }
end

dns_rules = dns.fetch('policies', {}).map do |group_name, policy|
  next if group_name == 'global'
  domains = singbox_domain_suffix(load_domain_group(domains_dir, group_name))
  next if domains.empty?
  {
    'domain_suffix' => domains,
    'server' => policy['server']
  }
end.compact

singbox_inbounds = nodes.map do |node|
  case node['protocol']
  when 'hysteria2'
    {
      'type' => 'hysteria2',
      'tag' => node['id'],
      'listen' => '::',
      'listen_port' => node.dig('listen', 'port'),
      'users' => [
        {
          'password' => node.dig('auth', 'password_ref') || node.dig('auth', 'password')
        }
      ],
      'ignore_client_bandwidth' => false,
      'tls' => {
        'enabled' => true,
        'alpn' => Array(node.dig('tls', 'alpn')),
        'certificate_path' => node.dig('tls', 'cert_ref', 'fullchain'),
        'key_path' => node.dig('tls', 'cert_ref', 'privkey')
      }
    }
  when 'tuic'
    {
      'type' => 'tuic',
      'tag' => node['id'],
      'listen' => '::',
      'listen_port' => node.dig('listen', 'port'),
      'users' => [
        {
          'uuid' => node.dig('auth', 'uuid_ref') || node.dig('auth', 'uuid'),
          'password' => node.dig('auth', 'password_ref') || node.dig('auth', 'password')
        }
      ],
      'congestion_control' => 'bbr',
      'tls' => {
        'enabled' => true,
        'alpn' => Array(node.dig('tls', 'alpn')),
        'certificate_path' => node.dig('tls', 'cert_ref', 'fullchain'),
        'key_path' => node.dig('tls', 'cert_ref', 'privkey')
      }
    }
  when 'ss2022'
    {
      'type' => 'shadowsocks',
      'tag' => node['id'],
      'listen' => '::',
      'listen_port' => node.dig('listen', 'port'),
      'method' => node.dig('auth', 'method') || '2022-blake3-aes-128-gcm',
      'password' => node.dig('auth', 'password_ref') || node.dig('auth', 'password')
    }
  end
end.compact

singbox_rules = []
if routing.dig('defaults', 'block_bittorrent')
  singbox_rules << {
    'protocol' => ['bittorrent'],
    'outbound' => 'blocked'
  }
end

routing.fetch('rules', []).each do |rule|
  next unless rule['enabled']

  match = rule['match'] || {}
  action_outbound = rule.dig('action', 'outbound') || 'direct'
  action_outbound = 'direct' unless rendered_singbox_outbound_tags.include?(action_outbound)

  if match['inbound_tags']
    singbox_rules << {
      'inbound' => Array(match['inbound_tags']),
      'outbound' => action_outbound
    }
    next
  end

  groups = []
  groups << match['domain_group'] if match['domain_group']
  groups.concat(Array(match['domain_groups']))
  domains = groups.flat_map { |group_name| singbox_domain_suffix(load_domain_group(domains_dir, group_name)) }.uniq
  next if domains.empty?

  singbox_rules << {
    'domain_suffix' => domains,
    'outbound' => action_outbound
  }
end

singbox_config = {
  'log' => {
    'level' => 'warn',
    'timestamp' => true
  },
  'dns' => {
    'servers' => dns_servers,
    'rules' => dns_rules,
    'final' => global_policy['server'] || 'dns-main',
    'strategy' => 'prefer_ipv4'
  },
  'inbounds' => singbox_inbounds,
  'outbounds' => singbox_outbounds,
  'route' => {
    'auto_detect_interface' => true,
    'final' => routing.dig('defaults', 'final_outbound') || 'direct',
    'rules' => singbox_rules
  }
}

File.write(File.join(runtime_config_dir, 'xray.json'), JSON.pretty_generate(xray_config) + "\n")
File.write(File.join(runtime_config_dir, 'sing-box.json'), JSON.pretty_generate(singbox_config) + "\n")
