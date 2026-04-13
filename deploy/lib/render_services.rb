#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'

env_file = ARGV[0]
templates_dir = ARGV[1]
output_dir = ARGV[2]

abort 'usage: render_services.rb <app.env.example> <templates_dir> <output_dir>' unless env_file && templates_dir && output_dir

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

env = load_env(env_file)
runtime_dir = env['RUNTIME_DIR'] || '/opt/myproxy'
config_dir = env['CONFIG_DIR'] || "#{runtime_dir}/config"
bin_dir = "#{runtime_dir}/bin"

replacements = {
  '{{XRAY_BIN}}' => "#{bin_dir}/xray",
  '{{XRAY_CONFIG}}' => "#{config_dir}/xray.json",
  '{{SINGBOX_BIN}}' => "#{bin_dir}/sing-box",
  '{{SINGBOX_CONFIG}}' => "#{config_dir}/sing-box.json",
  '{{CLOUDFLARED_BIN}}' => "#{bin_dir}/cloudflared",
  '{{ARGO_TOKEN}}' => 'replace-me'
}

FileUtils.mkdir_p(output_dir)

Dir.glob(File.join(templates_dir, '*.tpl')).each do |template_path|
  content = File.read(template_path)
  replacements.each do |placeholder, value|
    content = content.gsub(placeholder, value)
  end

  filename = File.basename(template_path, '.tpl')
  File.write(File.join(output_dir, filename), content)
end
